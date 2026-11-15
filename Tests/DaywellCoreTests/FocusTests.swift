import Foundation
import Testing

@testable import DaywellCore

struct FocusTests {
  private let calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }()
  private let now = ISO8601DateFormatter().date(from: "2026-11-12T08:00:00Z")!

  private func state() -> DaywellState {
    var state = DaywellState()
    state.hadAuthorization = true
    state.focusConfiguration.applicationData = Data([1])
    return state
  }

  @Test(arguments: [0.0, 0.25, 0.75])
  func twoMinuteCountdownDoesNotGainASecondAtFractionalStarts(fraction: Double) throws {
    var s = state()
    try s.focusConfiguration.setMinutes(2)
    let start = now.addingTimeInterval(fraction)
    try s.startFocus(at: start, calendar: calendar)
    let session = try #require(s.focusSession)
    #expect(session.end == start.addingTimeInterval(120))
    // The last UI tick can precede the action that starts the round.
    #expect(session.secondsRemaining(at: start.addingTimeInterval(-0.25)) == 120)
    #expect(session.secondsRemaining(at: start) == 120)
    #expect(session.secondsRemaining(at: start.addingTimeInterval(0.25)) == 120)
    #expect(session.secondsRemaining(at: start.addingTimeInterval(1)) == 119)
    #expect(session.secondsRemaining(at: start.addingTimeInterval(60)) == 60)
    #expect(session.secondsRemaining(at: start.addingTimeInterval(119.75)) == 1)
    #expect(session.secondsRemaining(at: start.addingTimeInterval(120)) == 0)
    #expect(session.secondsRemaining(at: start.addingTimeInterval(121)) == 0)
  }

  @Test func fractionalFocusDeadlineUsesALaterWholeSecondReleaseGuard() throws {
    var s = state()
    try s.focusConfiguration.setMinutes(2)
    let start = now.addingTimeInterval(0.25)
    try s.startFocus(at: start, calendar: calendar)
    let session = try #require(s.focusSession)
    let plan = try #require(
      MonitorPlan.make(for: s, at: start, calendar: calendar).first {
        $0.name == session.monitorName
      })
    #expect(calendar.date(from: plan.end) == now.addingTimeInterval(121))
    s.refresh(at: start.addingTimeInterval(119.75), calendar: calendar)
    #expect(s.focusSession?.id == session.id)
    s.refresh(at: start.addingTimeInterval(120), calendar: calendar)
    #expect(s.focusSession == nil)
    // A system callback rounded to seconds cannot restore an already finished round.
    s.refresh(at: now.addingTimeInterval(121), calendar: calendar)
    #expect(s.focusSession == nil)
  }

  @Test func startPersistsAbsoluteDeadlineAndSettingsOnlyAffectNextRound() throws {
    var s = state()
    try s.startFocus(at: now, calendar: calendar)
    let session = try #require(s.focusSession)
    #expect(session.end == now.addingTimeInterval(5400))
    try s.focusConfiguration.setMinutes(120)
    s = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(s))
    s.refresh(at: now.addingTimeInterval(300), calendar: calendar)
    #expect(s.focusSession == session)
    #expect(s.focusSession?.secondsRemaining(at: now.addingTimeInterval(300)) == 5100)
    s.refresh(at: session.end, calendar: calendar)
    #expect(s.focusSession == nil)
    s.refresh(at: now, calendar: calendar)
    #expect(s.focusSession == nil)
    #expect(s.focusConfiguration.minutes == 120)
  }

  @Test func successfulStartsKeepFiveUniqueRecentAppsAndSelectionAloneDoesNot() throws {
    var s = state()
    #expect(s.focusConfiguration.recentApplications.isEmpty)
    for token in UInt8(1)...6 {
      s.focusConfiguration.applicationData = Data([token])
      try s.startFocus(at: now, calendar: calendar)
      try s.endFocus(id: #require(s.focusSession?.id))
    }
    #expect(s.focusConfiguration.recentApplications == [6, 5, 4, 3, 2].map { Data([UInt8($0)]) })
    s.focusConfiguration.applicationData = Data([4])
    try s.startFocus(at: now, calendar: calendar)
    #expect(s.focusConfiguration.recentApplications == [4, 6, 5, 3, 2].map { Data([UInt8($0)]) })
  }

  @Test func invalidDurationAndMissingApplicationCannotStart() throws {
    var s = state()
    for invalid in [0, -1, 1441, Int.max] {
      #expect(throws: DaywellError.invalidFocusDuration) {
        try s.focusConfiguration.setMinutes(invalid)
      }
    }
    s.focusConfiguration.applicationData = nil
    #expect(throws: DaywellError.focusApplicationRequired) {
      try s.startFocus(at: now, calendar: calendar)
    }
    #expect(s.focusSession == nil)
    #expect(s.focusConfiguration.recentApplications.isEmpty)
  }

  @Test func duplicateStartAndStaleCloseCannotReplaceOrCloseNewRound() throws {
    var s = state()
    try s.startFocus(at: now, calendar: calendar)
    let original = try #require(s.focusSession)
    #expect(throws: DaywellError.focusAlreadyActive) {
      try s.startFocus(at: now.addingTimeInterval(1), calendar: calendar)
    }
    #expect(s.focusSession == original)
    try s.endFocus(id: original.id)
    try s.startFocus(at: now.addingTimeInterval(2), calendar: calendar)
    let latest = s.focusSession
    #expect(throws: DaywellError.staleFocusSession) { try s.endFocus(id: original.id) }
    #expect(s.focusSession == latest)
  }

  @Test func sleepPreemptsAndExemptionDoesNotAllowFocusToRestart() throws {
    var s = state()
    s.selectionData = Data([2])
    try s.startFocus(at: now, calendar: calendar)
    try s.savePeriod(
      LockPeriod(start: ClockTime(hour: 8, minute: 0), end: ClockTime(hour: 9, minute: 0)),
      at: now.addingTimeInterval(1), calendar: calendar)
    #expect(s.focusSession == nil)
    let reservation = try s.reserveExemption(at: now.addingTimeInterval(2))
    try s.commitExemption(reservation.id, at: now.addingTimeInterval(3))
    #expect(throws: DaywellError.focusUnavailable) {
      try s.startFocus(at: now.addingTimeInterval(4), calendar: calendar)
    }
    s.refresh(at: now.addingTimeInterval(3601), calendar: calendar)
    #expect(s.focusSession == nil)
  }

  @Test func morningUsageCoexistsButThresholdCancelsFocus() throws {
    var s = state()
    s.selectionData = Data([2])
    s.periods = [
      try LockPeriod(
        start: ClockTime(hour: 7, minute: 0), end: ClockTime(hour: 8, minute: 0),
        morningEnabled: true)
    ]
    s.refresh(at: now.addingTimeInterval(-60), calendar: calendar)
    try s.startFocus(at: now, calendar: calendar)
    let window = try #require(s.pendingMornings(at: now).first)
    #expect(s.hasFocusRestriction(at: now))
    s.reachMorningLimit(
      monitorName: window.monitorName, at: now.addingTimeInterval(600), calendar: calendar)
    #expect(s.focusSession == nil)
    #expect(s.activeSessions(at: now.addingTimeInterval(600)).first?.isMorning == true)
  }

  @Test func fitnessRestCoexistsAndDeadlineCancelsPermanentlyEvenAfterIdleTimeout() throws {
    var s = state()
    try s.startFocus(at: now, calendar: calendar)
    s.updateFitness(initial: FitnessTraining(restEnabled: true)) { $0.completeGroup(at: now) }
    s.refresh(at: now.addingTimeInterval(29), calendar: calendar)
    #expect(s.hasFocusRestriction(at: now.addingTimeInterval(29)))
    // Skip the rest callback and even the 30-minute reset callback.
    s.refresh(at: now.addingTimeInterval(1801), calendar: calendar)
    #expect(s.fitness?.progress.completedGroups == 0)
    #expect(s.focusSession == nil)
  }

  @Test func missedShortSleepEndsFocusWithoutResurrection() throws {
    var s = state()
    s.selectionData = Data([2])
    s.periods = [
      try LockPeriod(
        start: ClockTime(hour: 8, minute: 10), end: ClockTime(hour: 8, minute: 11))
    ]
    try s.startFocus(at: now, calendar: calendar)
    s.refresh(at: now.addingTimeInterval(720), calendar: calendar)
    #expect(s.focusSession == nil)
  }

  @Test func revokeRemovesInvalidFocusTokensButPreservesMinutes() throws {
    var s = state()
    try s.focusConfiguration.setMinutes(70)
    try s.startFocus(at: now, calendar: calendar)
    s.markAuthorizationRevoked()
    #expect(s.focusSession == nil)
    #expect(s.focusConfiguration.applicationData == nil)
    #expect(s.focusConfiguration.recentApplications.isEmpty)
    #expect(s.focusConfiguration.minutes == 70)
  }

  @Test func olderStateWithoutFocusFieldsLoadsAndOneMinuteFocusHasReleaseGuard() throws {
    let old = DaywellState()
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    json.removeValue(forKey: "focusConfiguration")
    json.removeValue(forKey: "focusSession")
    let restored = try JSONDecoder().decode(
      DaywellState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.focusConfiguration.minutes == 90)
    var s = state()
    try s.focusConfiguration.setMinutes(1)
    try s.startFocus(at: now, calendar: calendar)
    let session = try #require(s.focusSession)
    let plan = try #require(
      MonitorPlan.make(for: s, at: now, calendar: calendar).first { $0.name == session.monitorName }
    )
    #expect(!plan.repeats)
    #expect(calendar.date(from: plan.end) == now.addingTimeInterval(60))
    #expect(calendar.date(from: plan.start)! <= now.addingTimeInterval(-840))
    #expect(MonitorPlan.requiredCapacity(for: s, at: now, calendar: calendar) <= 20)
  }

  @Test func focusFitsWithTwelveDailySchedulesMorningUsageAndSuppressedRest() throws {
    var s = state()
    s.selectionData = Data([2])
    s.periods = [
      try LockPeriod(
        start: ClockTime(hour: 7, minute: 0), end: ClockTime(hour: 8, minute: 0),
        morningEnabled: true)
    ]
    for hour in 8...18 {
      s.periods.append(
        try LockPeriod(
          start: ClockTime(hour: hour, minute: 10), end: ClockTime(hour: hour, minute: 30)))
    }
    s.refresh(at: now.addingTimeInterval(-60), calendar: calendar)
    // Sleep suppresses locking for this group; its rest/idle state still coexists with focus.
    s.updateFitness(initial: FitnessTraining(restEnabled: true)) {
      $0.completeGroup(at: now.addingTimeInterval(-10))
    }
    try s.startFocus(at: now, calendar: calendar)
    #expect(s.pendingMornings(at: now).count == 1)
    #expect(s.fitness?.locksAfterRest == false)
    #expect(s.focusSession != nil)
    #expect(MonitorPlan.requiredCapacity(for: s, at: now, calendar: calendar) == 20)
    #expect(MonitorPlan.make(for: s, at: now, calendar: calendar).count <= 18)
  }
}
