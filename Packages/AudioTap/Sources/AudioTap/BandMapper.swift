import Accelerate
import Foundation

/// Turns a mono float stream into five band energies and an overall RMS.
///
/// Not `Sendable` on purpose: one instance belongs to exactly one thread. In the app it
/// lives on the CoreAudio IO thread; in tests it lives on the test thread.
public final class BandMapper {

    /// 1024 points at 48 kHz gives 46.875 Hz per bin, which is plenty for five bands.
    public static let fftSize = 1024

    /// Band boundaries in hertz. The outer bounds are Govee's 20 and 5000. The internal
    /// split is the standard one except that sub bass runs to 80 Hz rather than 60 Hz,
    /// so that a 60 Hz sine lands in sub bass as the spec requires.
    public static let bandEdgesHz: [Float] = [20, 80, 250, 500, 2000, 5000]

    private let sampleRate: Double
    private let smoothing: Float
    private let hopSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    /// The FFT bin range backing each band, low to high. Ordered and pairwise disjoint at
    /// every sample rate: bands are laid out in sequence, and a band whose edges round to
    /// an already claimed bin takes the next free bin instead of sharing one.
    let bandBins: [ClosedRange<Int>]

    private var ring: [Float]
    private var chronological: [Float]
    private var windowed: [Float]
    private var realPart: [Float]
    private var imaginaryPart: [Float]
    private var magnitudes: [Float]
    private var smoothed: [Float]

    private var writeIndex = 0
    private var filled = 0
    private var samplesSinceEmit = 0

    public init(sampleRate: Double, framesPerSecond: Int = 50, smoothing: Float = 0.35) {
        let size = BandMapper.fftSize
        precondition(sampleRate > 0, "BandMapper needs a positive sample rate.")
        self.sampleRate = sampleRate
        self.smoothing = min(1, max(0.01, smoothing))
        self.hopSize = max(1, Int(sampleRate / Double(max(1, framesPerSecond))))
        self.log2n = vDSP_Length(round(log2(Double(size))))

        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(round(log2(Double(size)))),
                                                  FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Unable to create an FFT setup for \(size) points.")
        }
        self.setup = fftSetup

        var hann = [Float](repeating: 0, count: size)
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        self.window = hann

        self.ring = [Float](repeating: 0, count: size)
        self.chronological = [Float](repeating: 0, count: size)
        self.windowed = [Float](repeating: 0, count: size)
        self.realPart = [Float](repeating: 0, count: size / 2)
        self.imaginaryPart = [Float](repeating: 0, count: size / 2)
        self.magnitudes = [Float](repeating: 0, count: size / 2)
        self.smoothed = [Float](repeating: 0, count: 5)

        let binWidth = Float(sampleRate) / Float(size)
        let highestBin = size / 2 - 1
        func bin(_ hertz: Float) -> Int {
            min(highestBin, max(1, Int((hertz / binWidth).rounded())))
        }
        var ranges: [ClosedRange<Int>] = []
        var nextFreeBin = 1
        for index in 0..<5 {
            let low = min(highestBin, max(nextFreeBin, bin(BandMapper.bandEdgesHz[index])))
            let high = min(highestBin, max(low, bin(BandMapper.bandEdgesHz[index + 1]) - 1))
            ranges.append(low...high)
            nextFreeBin = high + 1
        }
        self.bandBins = ranges
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    public func reset() {
        for index in ring.indices { ring[index] = 0 }
        for index in smoothed.indices { smoothed[index] = 0 }
        writeIndex = 0
        filled = 0
        samplesSinceEmit = 0
    }

    /// Realtime entry point. Calls `onFrame` once per completed hop.
    ///
    /// The analysis itself works entirely in preallocated buffers, but building each
    /// `AudioFrame` allocates one small array of five band values. That is acceptable at
    /// 50 frames per second, so this path is low allocation rather than strictly
    /// realtime safe.
    public func process(_ samples: UnsafePointer<Float>,
                        count: Int,
                        time: TimeInterval,
                        onFrame: (AudioFrame) -> Void) {
        let size = BandMapper.fftSize
        for index in 0..<count {
            ring[writeIndex] = samples[index]
            writeIndex = (writeIndex + 1) % size
            if filled < size { filled += 1 }
            samplesSinceEmit += 1
            if filled == size, samplesSinceEmit >= hopSize {
                samplesSinceEmit = 0
                onFrame(makeFrame(time: time + Double(index) / sampleRate))
            }
        }
    }

    /// Test friendly wrapper that collects the frames into an array.
    public func process(_ samples: [Float], time: TimeInterval) -> [AudioFrame] {
        var produced: [AudioFrame] = []
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            process(base, count: buffer.count, time: time) { produced.append($0) }
        }
        return produced
    }

    // MARK: Internals

    private func makeFrame(time: TimeInterval) -> AudioFrame {
        let size = BandMapper.fftSize

        for index in 0..<size {
            chronological[index] = ring[(writeIndex + index) % size]
        }

        var rms: Float = 0
        vDSP_rmsqv(chronological, 1, &rms, vDSP_Length(size))
        // A full scale sine has an RMS of about 0.707, so scale it to read near 1.
        let scaledRMS = min(1, rms * 2.0.squareRoot().float)

        vDSP_vmul(chronological, 1, window, 1, &windowed, 1, vDSP_Length(size))

        realPart.withUnsafeMutableBufferPointer { realBuffer in
            imaginaryPart.withUnsafeMutableBufferPointer { imaginaryBuffer in
                guard let realBase = realBuffer.baseAddress,
                      let imaginaryBase = imaginaryBuffer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                windowed.withUnsafeBufferPointer { input in
                    guard let inputBase = input.baseAddress else { return }
                    inputBase.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
            }
        }

        // zrip returns twice the true DFT, and a peak 1 Hann window halves the
        // amplitude, so 2 / size makes a full scale bin centered sine read 1.0.
        var scale = 2.0 / Float(size)
        magnitudes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(size / 2))
        }

        for index in 0..<5 {
            let range = bandBins[index]
            var peak: Float = 0
            magnitudes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_maxv(base + range.lowerBound, 1, &peak, vDSP_Length(range.count))
            }
            let clamped = min(1, max(0, peak))
            smoothed[index] += smoothing * (clamped - smoothed[index])
        }

        return AudioFrame(time: time, rms: scaledRMS, bands: smoothed)
    }
}

private extension Double {
    var float: Float { Float(self) }
}
