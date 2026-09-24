import Foundation
@testable import Glowbeat

/// A scripted Night Shift. The suite never touches the real client: it reads private
/// API, and a test that depended on the machine's own Night Shift setting would pass or
/// fail depending on the time of day it was run at.
@MainActor
final class FakeNightShift: NightShiftSource {

    var onChange: (@MainActor () -> Void)?

    /// Nil stands for "the private API did not answer", which is the sandbox case and
    /// the "Apple removed it" case both.
    var status: NightShiftStatus?
    var sunSchedule: SunSchedule?
    private(set) var isObserving = false
    private(set) var statusReads = 0

    init(status: NightShiftStatus? = nil, sunSchedule: SunSchedule? = nil) {
        self.status = status
        self.sunSchedule = sunSchedule
    }

    func readStatus() -> NightShiftStatus? {
        statusReads += 1
        return status
    }

    func readSunSchedule() -> SunSchedule? {
        sunSchedule
    }

    func startObserving() {
        isObserving = true
    }

    func stopObserving() {
        isObserving = false
        onChange = nil
    }

    /// What CoreBrightness's notification block does: says something moved, never what.
    func notifyChange() {
        onChange?()
    }
}

extension NightShiftStatus {
    /// A status with only the two things a test usually cares about set.
    static func scripted(enabled: Bool,
                         mode: NightShiftStatus.Mode,
                         from: TimeOfDay = TimeOfDay(hour: 22, minute: 0),
                         to: TimeOfDay = TimeOfDay(hour: 7, minute: 0)) -> NightShiftStatus {
        NightShiftStatus(isActive: enabled,
                         isEnabled: enabled,
                         isSunSchedulePermitted: true,
                         rawMode: mode.rawValue,
                         schedule: NightShiftSchedule(from: from, to: to))
    }
}
