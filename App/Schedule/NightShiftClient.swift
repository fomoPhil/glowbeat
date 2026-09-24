import Foundation
import OSLog

/// Reads Night Shift out of CoreBrightness. Read only, by design and by review: this
/// type never calls a setter, so Glowbeat can follow the Mac's Night Shift without ever
/// being the reason it changed.
///
/// Everything here is private API and every call is guarded twice, because it can vanish
/// in any macOS update:
///
/// 1. `dlopen` on the framework, then `NSClassFromString`. The framework path is a broken
///    symlink on disk (the binary lives only in the dyld shared cache), so the path is
///    opened and never checked for existence.
/// 2. `responds(to:)` per selector, **plus** the `BOOL` the getter itself returns.
///    `supportsBlueLightReduction` is useless as an availability check: it returns true
///    under the App Sandbox where every getter fails.
///
/// The status buffer is deliberately over-allocated to 64 bytes and decoded by offset.
/// Apple added a seventh field to the struct in 10.14.6 and every app compiled against
/// the six field version corrupted its stack and crashed on launch. Swift does not
/// guarantee a struct's layout matches C either, so there is no Swift struct to get
/// wrong. Research: `docs/research/sleep-wake-nightshift-research.md` sections A1 to A7.
@MainActor
final class NightShiftClient: NightShiftSource {

    var onChange: (@MainActor () -> Void)?

    private let blueLight: NSObject?
    private let brightness: NSObject?
    /// The notification block, kept alive for as long as CoreBrightness might call it.
    private var notificationBlock: AnyObject?
    private let logger = Logger(subsystem: "com.philwoolley.glowbeat", category: "NightShift")

    private static let corebrightnessPath =
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    init() {
        // Opened once and never closed, and never checked for on disk first.
        _ = dlopen(Self.corebrightnessPath, RTLD_NOW)
        blueLight = Self.instantiate("CBBlueLightClient")
        brightness = Self.instantiate("BrightnessSystemClient")
        if blueLight == nil {
            logger.log("CBBlueLightClient did not resolve; Auto will follow the sun instead.")
        }
    }

    private static func instantiate(_ className: String) -> NSObject? {
        guard let type = NSClassFromString(className) as? NSObject.Type else { return nil }
        return type.init()
    }

    // MARK: Reading

    func readStatus() -> NightShiftStatus? {
        guard let blueLight, let sendMessage = Self.statusMessage else { return nil }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard blueLight.responds(to: selector) else { return nil }

        var buffer = [UInt8](repeating: 0, count: Self.statusBufferBytes)
        let answered = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return sendMessage(blueLight, selector, base).boolValue
        }
        // The one availability check that holds. Under the App Sandbox this is where it
        // fails: CoreBrightness proxies to `com.apple.backlightd` and the mach lookup is
        // denied, so the getter returns false and leaves the buffer untouched.
        guard answered else { return nil }

        return buffer.withUnsafeBytes { raw in
            NightShiftStatus(
                isActive: raw[0] != 0,
                isEnabled: raw[1] != 0,
                isSunSchedulePermitted: raw[2] != 0,
                rawMode: Int(raw.loadUnaligned(fromByteOffset: 4, as: Int32.self)),
                schedule: NightShiftSchedule(
                    from: TimeOfDay(
                        hour: Int(raw.loadUnaligned(fromByteOffset: 8, as: Int32.self)),
                        minute: Int(raw.loadUnaligned(fromByteOffset: 12, as: Int32.self))),
                    to: TimeOfDay(
                        hour: Int(raw.loadUnaligned(fromByteOffset: 16, as: Int32.self)),
                        minute: Int(raw.loadUnaligned(fromByteOffset: 20, as: Int32.self)))))
        }
    }

    func readSunSchedule() -> SunSchedule? {
        guard let brightness else { return nil }
        let selector = NSSelectorFromString("copyPropertyForKey:")
        guard brightness.responds(to: selector) else { return nil }
        // A `copy` method hands back an owned object, so the result is taken retained.
        guard let result = brightness.perform(selector, with: Self.sunScheduleKey as NSString),
              let dictionary = result.takeRetainedValue() as? [String: Any] else { return nil }
        func date(_ key: String) -> Date? {
            dictionary[key] as? Date
        }
        guard let previousSunrise = date("previousSunrise"),
              let sunrise = date("sunrise"),
              let nextSunrise = date("nextSunrise"),
              let previousSunset = date("previousSunset"),
              let sunset = date("sunset"),
              let nextSunset = date("nextSunset") else { return nil }
        return SunSchedule(previousSunrise: previousSunrise,
                           sunrise: sunrise,
                           nextSunrise: nextSunrise,
                           previousSunset: previousSunset,
                           sunset: sunset,
                           nextSunset: nextSunset)
    }

    // MARK: Notifications

    /// Best effort. The engine polls every thirty seconds whatever happens here, so a
    /// selector that does not resolve costs latency and nothing else.
    func startObserving() {
        guard let blueLight, notificationBlock == nil else { return }
        let selector = NSSelectorFromString("setStatusNotificationBlock:")
        guard blueLight.responds(to: selector) else {
            logger.log("setStatusNotificationBlock: did not resolve; polling only.")
            return
        }
        // A zero argument block: the handler is told that something changed, never what,
        // so it re-reads. It arrives on a background thread and fires once per mutation
        // rather than once per logical change, which is why the engine compares what it
        // reads rather than acting on the callback itself.
        let block: @convention(block) @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.onChange?()
            }
        }
        let object = block as AnyObject
        notificationBlock = object
        blueLight.perform(selector, with: object)
    }

    /// Stops delivering, without handing CoreBrightness a nil block: nothing documents
    /// what the framework does with one, and the block itself holds `self` weakly, so a
    /// released client simply stops answering.
    func stopObserving() {
        onChange = nil
    }

    // MARK: Runtime plumbing

    /// Sixty four bytes for a struct that is thirty three. See the type's note.
    private static let statusBufferBytes = 64

    private static let sunScheduleKey = "BlueLightSunSchedule"

    /// `getBlueLightStatus:` takes a pointer and returns a `BOOL`, which `perform` cannot
    /// express, so it goes through `objc_msgSend` itself. The symbol is looked up rather
    /// than imported because Swift does not expose `objc_msgSend` directly.
    private static let statusMessage:
        (@convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> ObjCBool)? = {
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
                return nil
            }
            return unsafeBitCast(
                symbol,
                to: (@convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> ObjCBool).self)
        }()
}
