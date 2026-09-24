import AudioTap
import Foundation

/// Opens and closes the audio tap away from the main actor, one call at a time.
///
/// Building a Core Audio tap takes tens of milliseconds, and `AudioDeviceStart` can sit
/// behind the Screen & System Audio Recording prompt for as long as the user takes to
/// answer it. Doing either inline on the main actor freezes the window, which is exactly
/// the moment the user is looking at it.
///
/// Actor isolation is also the ordering: a stop asked for while a start is still running
/// is applied after that start finishes, never halfway through it, so the tap can never
/// be left open by a stop that overtook the start it was meant to undo.
actor AudioLifecycle {

    private let source: any AudioFrameSource

    init(source: any AudioFrameSource) {
        self.source = source
    }

    func start() throws {
        try source.start()
    }

    func stop() {
        source.stop()
    }
}
