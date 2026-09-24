import Foundation

/// Anything that can produce a stream of analyzed audio frames.
///
/// `SystemAudioTap` is the production implementation. The app's tests substitute a
/// scripted source so the Party Mode engine can be driven with no audio hardware.
public protocol AudioFrameSource: AnyObject, Sendable {
    /// Frames arrive roughly 50 times per second while the source is running.
    var frames: AsyncStream<AudioFrame> { get }
    /// Emits whenever the inferred permission state changes.
    var permissionUpdates: AsyncStream<AudioTapPermission> { get }
    func start() throws
    func stop()
}
