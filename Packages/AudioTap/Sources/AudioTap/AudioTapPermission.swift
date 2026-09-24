import Foundation

/// macOS reports success even when system audio capture is denied, so denial is
/// inferred from a run of completely silent buffers while the output volume is up.
public enum AudioTapPermission: String, Sendable, Equatable, CaseIterable {
    case unknown
    case granted
    case deniedOrSilent
}
