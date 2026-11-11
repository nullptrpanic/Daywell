import Foundation
import Testing

@testable import DaywellCore

struct MorningModeTests {
  @Test func additionsUpdateUpcomingMorningButPreserveAnAccumulatingUsageWindow() throws {
    var state = try morningState()
    let sleep = date("2026-11-09T23:30:00+08:00")
    state.refresh(at: sleep, calendar: shanghai)
    state.updateSelection(Data([2]), at: sleep) { Data(Set($0 + $1).sorted()) }
    #expect(state.activeSessions(at: sleep).first?.selectionData == Data([1, 2]))
    #expect(state.morningWindows.first?.selectionData == Data([1, 2]))
    let morning = date("2026-11-10T07:05:00+08:00")
    let window = try #require(state.pendingMornings(at: morning).first)
    let before = MonitorPlan.make(for: state, at: morning, calendar: shanghai)
      .first { $0.name == window.monitorName }
    state.updateSelection(Data([3]), at: morning) { Data(Set($0 + $1).sorted()) }
    state.refresh(at: morning, calendar: shanghai)
    let after = MonitorPlan.make(for: state, at: morning, calendar: shanghai)
      .first { $0.name == window.monitorName }
    #expect(after == before)
    let locked = date("2026-11-10T07:15:00+08:00")
    state.reachMorningLimit(monitorName: window.monitorName, at: locked, calendar: shanghai)
    let original = try #require(state.blockingSessions(at: locked).first)
    state.updateSelection(Data([4]), at: locked) { Data(Set($0 + $1).sorted()) }
    let updated = try #require(state.blockingSessions(at: locked).first)
    #expect(updated.selectionData == Data([1, 2, 4]))
    #expect(updated.occurrence == original.occurrence)
    #expect(updated.remainingCount == original.remainingCount)
    #expect(updated.morningSourceID == original.morningSourceID)
    try state.validate()
  }

  @Test func aFailedMergeDoesNotPartiallyUpdateTheCurrentSession() throws {
    var state = try morningState()
    let now = date("2026-11-09T23:30:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let before = state
    var calls = 0
    #expect(throws: DaywellError.invalidState) {
      try state.updateSelection(Data([2]), at: now) { old, added in
        calls += 1
        if calls == 2 { throw DaywellError.invalidState }
        return old + added
      }
    }
    #expect(state == before)
  }

  @Test func preparesMorningBeforeSleepAndCountsOnlyAfterItsEnd() throws {
    var state = try morningState()
    let now = date("2026-11-09T20:00:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let window = try #require(state.morningWindows.first)
    #expect(window.start == date("2026-11-10T07:00:00+08:00"))
    #expect(window.end == date("2026-11-10T23:00:00+08:00"))
    #expect(state.activeSessions(at: now).isEmpty)
    let plan = try #require(
      MonitorPlan.make(for: state, at: now, calendar: shanghai).first { $0.usage != nil })
    #expect(shanghai.date(from: plan.start) == date("2026-11-10T07:00:00+08:00"))
    #expect(plan.usage?.minutes == 10)
    #expect(plan.usage?.selectionData == Data([1]))
    #expect(!plan.repeats)
  }

  @Test func thresholdLocksOnceForConfiguredDurationAndSurvivesRelaunch() throws {
    var state = try preparedMorningState()
    let window = try #require(state.morningWindows.first)
    let now = date("2026-11-10T07:17:00+08:00")
    state.reachMorningLimit(monitorName: window.monitorName, at: now, calendar: shanghai)
    #expect(state.blockingSessions(at: now).count == 1)
    #expect(state.blockingSessions(at: now).first?.isMorning == true)
    #expect(
      state.blockingSessions(at: now).first?.occurrence.end == date("2026-11-10T07:47:00+08:00"))
    #expect(state.exemptionOffer(at: now)?.duration == 600)
    var restored = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(state))
    restored.reachMorningLimit(
      monitorName: window.monitorName, at: now.addingTimeInterval(60), calendar: shanghai)
    restored.reachMorningLimit(
      monitorName: window.monitorName, at: now.addingTimeInterval(1900), calendar: shanghai)
    #expect(restored.sessions.filter(\.isMorning).count == 1)
    #expect(restored.activeSessions(at: date("2026-11-10T07:47:00+08:00")).isEmpty)
    try restored.validate()
  }

  @Test func earlyStaleOrUnknownThresholdNeverLocks() throws {
    var state = try preparedMorningState()
    let window = try #require(state.morningWindows.first)
    for (name, instant) in [
      (window.monitorName, "2026-11-10T06:59:59+08:00"),
      (window.monitorName, "2026-11-10T07:00:01+08:00"),
      (window.monitorName, "2026-11-10T23:00:00+08:00"),
      ("daywell.morning.missing", "2026-11-10T07:30:00+08:00"),
    ] {
      state.reachMorningLimit(monitorName: name, at: date(instant), calendar: shanghai)
    }
    #expect(state.sessions.filter(\.isMorning).isEmpty)
  }

  @Test func closingAnActiveMorningRoundPreventsDelayedCallbacksFromRelocking() throws {
    var state = try preparedMorningState()
    state.refresh(at: date("2026-11-09T23:30:00+08:00"), calendar: shanghai)
    let window = try #require(state.morningWindows.first)
    let now = date("2026-11-10T07:20:00+08:00")
    state.reachMorningLimit(monitorName: window.monitorName, at: now, calendar: shanghai)
    let session = try #require(state.blockingSessions(at: now).first)
    #expect(session.isMorning)
    var disabled = state.periods[0]
    disabled.isEnabled = false

    try state.savePeriod(disabled, at: now, calendar: shanghai, verifiedSessionIDs: [session.id])
    let later = now.addingTimeInterval(60)
    state.reachMorningLimit(monitorName: window.monitorName, at: later, calendar: shanghai)

    #expect(state.blockingSessions(at: later).isEmpty)
    #expect(!state.morningWindows.contains { $0.id == window.id })
    try state.validate()
  }

  @Test func futureEditsUpdateWindowButActiveSleepFreezesItsMorning() throws {
    var state = try preparedMorningState()
    var edited = state.periods[0]
    state.morningPolicy = try MorningPolicy(usageMinutes: 15, lockMinutes: 45)
    try state.savePeriod(edited, at: date("2026-11-09T22:00:00+08:00"), calendar: shanghai)
    #expect(state.morningWindows.first?.morning.usageMinutes == 15)
    state.refresh(at: date("2026-11-09T23:10:00+08:00"), calendar: shanghai)
    edited.morningEnabled = false
    try state.savePeriod(edited, at: date("2026-11-10T06:00:00+08:00"), calendar: shanghai)
    state.selectionData = Data([2])
    state.policy = try ExemptionPolicy(allowedCount: 0, durationsMinutes: [10, 5, 3, 2, 1])
    state.refresh(at: date("2026-11-10T07:30:00+08:00"), calendar: shanghai)
    let window = try #require(state.morningWindows.first)
    state.reachMorningLimit(
      monitorName: window.monitorName, at: date("2026-11-10T07:30:00+08:00"), calendar: shanghai)
    let lock = try #require(state.sessions.first(where: { $0.isMorning }))
    #expect(lock.selectionData == Data([1]))
    #expect(lock.remainingCount == 2)
    #expect(lock.occurrence.end == date("2026-11-10T08:15:00+08:00"))
  }

  @Test func morningExemptionsDecreaseAndNeverOutlastMorningLock() throws {
    var state = try preparedMorningState()
    let window = try #require(state.morningWindows.first)
    let start = date("2026-11-10T07:20:00+08:00")
    state.reachMorningLimit(monitorName: window.monitorName, at: start, calendar: shanghai)
    let first = try state.reserveExemption(at: start)
    try state.commitExemption(first.id, at: start)
    let secondTime = date("2026-11-10T07:48:00+08:00")
    #expect(state.exemptionOffer(at: secondTime)?.duration == 120)
    let second = try state.reserveExemption(at: secondTime)
    try state.commitExemption(second.id, at: secondTime)
    state.endExemptions(at: secondTime)
    #expect(state.exemptionOffer(at: secondTime) == nil)
    #expect(state.blockingSessions(at: secondTime).first?.remainingCount == 0)
    #expect(state.blockingSessions(at: date("2026-11-10T07:50:00+08:00")).isEmpty)
  }

  @Test func endingMorningDoesNotRemoveAnotherSleepRestriction() throws {
    var state = try preparedMorningState()
    let window = try #require(state.morningWindows.first)
    state.periods.append(
      try LockPeriod(start: ClockTime(hour: 7, minute: 30), end: ClockTime(hour: 8, minute: 30)))
    state.reachMorningLimit(
      monitorName: window.monitorName, at: date("2026-11-10T07:20:00+08:00"), calendar: shanghai)
    state.refresh(at: date("2026-11-10T07:35:00+08:00"), calendar: shanghai)
    #expect(state.blockingSessions(at: date("2026-11-10T07:35:00+08:00")).count == 2)
    let after = date("2026-11-10T07:50:00+08:00")
    #expect(state.blockingSessions(at: after).count == 1)
    #expect(state.blockingSessions(at: after).first?.isMorning == false)
  }

  @Test func disabledDaysAndDeletedFuturePeriodsDoNotLeaveMorningMonitors() throws {
    var state = try morningState()
    state.periods[0].weekdays = [.monday]
    let now = date("2026-11-10T20:00:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    #expect(state.morningWindows.first?.start == date("2026-11-17T07:00:00+08:00"))
    state.removePeriod(state.periods[0].id, at: now, calendar: shanghai)
    state.refresh(at: now, calendar: shanghai)
    #expect(MonitorPlan.make(for: state, at: now, calendar: shanghai).isEmpty)
  }

  @Test func oneMinuteLockHasEndGuardAndDoesNotResetItsUsageMonitorOnRefresh() throws {
    var state = try morningState()
    state.morningPolicy = try MorningPolicy(usageMinutes: 1, lockMinutes: 1)
    let before = date("2026-11-09T22:00:00+08:00")
    state.refresh(at: before, calendar: shanghai)
    let original = MonitorPlan.make(for: state, at: before, calendar: shanghai).filter {
      $0.usage != nil
    }
    state.refresh(at: before.addingTimeInterval(60), calendar: shanghai)
    #expect(
      MonitorPlan.make(for: state, at: before.addingTimeInterval(60), calendar: shanghai).filter {
        $0.usage != nil
      } == original)
    let window = try #require(state.morningWindows.first)
    let now = date("2026-11-10T07:01:00+08:00").addingTimeInterval(0.5)
    state.reachMorningLimit(monitorName: window.monitorName, at: now, calendar: shanghai)
    let end = date("2026-11-10T07:02:01+08:00")
    let guardPlan = try #require(
      MonitorPlan.make(for: state, at: now, calendar: shanghai).first {
        $0.name == MonitorPlan.endGuardName(for: end)
      })
    #expect(shanghai.date(from: guardPlan.end) == end)
    #expect(shanghai.date(from: guardPlan.start) == date("2026-11-10T06:47:01+08:00"))
    #expect(
      !MonitorPlan.make(for: state, at: now, calendar: shanghai).contains {
        $0.name == window.monitorName
      })
  }

  @Test func oldStateMigratesWithoutChangingActiveQuota() throws {
    var old = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    old.refresh(at: now, calendar: shanghai)
    let pending = try old.reserveExemption(at: now)
    try old.commitExemption(pending.id, at: now)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
    var json = try #require(object as? [String: Any])
    json["schemaVersion"] = 1
    json.removeValue(forKey: "morningWindows")
    json.removeValue(forKey: "morningPolicy")
    json["periods"] = (json["periods"] as? [[String: Any]])?.map { period in
      var oldPeriod = period
      oldPeriod.removeValue(forKey: "morningEnabled")
      return oldPeriod
    }
    let restored = try JSONDecoder().decode(
      DaywellState.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.schemaVersion == 2)
    #expect(restored.activeSessions(at: now).first?.remainingCount == 1)
    #expect(restored.morningWindows.isEmpty)
    try restored.validate()
  }

  @Test func completedMorningHistoryKeepsItsSourceUntilBothCanBePruned() throws {
    var state = try preparedMorningState()
    state.morningPolicy = try MorningPolicy(usageMinutes: 10, lockMinutes: 1440)
    state.refresh(at: date("2026-11-09T22:00:00+08:00"), calendar: shanghai)
    let window = try #require(state.morningWindows.first)
    state.reachMorningLimit(
      monitorName: window.monitorName,
      at: date("2026-11-10T22:59:00+08:00"), calendar: shanghai)
    state.refresh(at: date("2026-11-19T00:00:00+08:00"), calendar: shanghai)
    try state.validate()
    #expect(state.sessions.contains { $0.morningSourceID == window.id })
    #expect(state.morningWindows.contains { $0.id == window.id })
  }

  @Test func shortMorningWindowPadsAfterTheDeadlineNotBeforeSleepEnds() throws {
    var state = try morningState()
    state.periods[0].start = try ClockTime(hour: 7, minute: 10)
    let now = date("2026-11-09T06:00:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let plan = try #require(
      MonitorPlan.make(for: state, at: now, calendar: shanghai).first { $0.usage != nil })
    #expect(shanghai.date(from: plan.start) == date("2026-11-09T07:00:00+08:00"))
    #expect(shanghai.date(from: plan.end) == date("2026-11-09T07:15:00+08:00"))
    state.reachMorningLimit(
      monitorName: plan.name, at: date("2026-11-09T07:12:00+08:00"), calendar: shanghai)
    #expect(state.sessions.filter(\.isMorning).isEmpty)
  }

  @Test func changingTimeZoneDoesNotReregisterTheActiveUsageWindow() throws {
    var state = try preparedMorningState()
    let now = date("2026-11-10T07:30:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let window = try #require(state.pendingMornings(at: now).first)
    let before = MonitorPlan.make(for: state, at: now, calendar: shanghai).first {
      $0.name == window.monitorName
    }
    var losAngeles = Calendar(identifier: .gregorian)
    losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    state.refresh(at: now, calendar: losAngeles)
    let after = MonitorPlan.make(for: state, at: now, calendar: losAngeles).first {
      $0.name == window.monitorName
    }
    #expect(before == after)
  }

  @Test func revokedTokensNeverRegisterUsageEventsBeforeReselection() throws {
    var state = try preparedMorningState()
    state.hadAuthorization = true
    let now = date("2026-11-10T07:30:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    state.markAuthorizationRevoked()
    let plans = MonitorPlan.make(for: state, at: now, calendar: shanghai)
    #expect(plans.allSatisfy { $0.usage == nil })
    state.replaceSelectionAfterAuthorization(Data([7]))
    state.refresh(at: now, calendar: shanghai)
    let restored = MonitorPlan.make(for: state, at: now, calendar: shanghai).compactMap(\.usage)
    #expect(!restored.isEmpty)
    #expect(restored.allSatisfy { $0.selectionData == Data([7]) })
  }

  @Test func clearingConfiguredSelectionDoesNotCancelTheFrozenMorning() throws {
    var state = try preparedMorningState()
    let window = try #require(state.morningWindows.first)
    let now = date("2026-11-10T07:30:00+08:00")
    state.selectionData = nil
    state.reachMorningLimit(monitorName: window.monitorName, at: now, calendar: shanghai)
    #expect(state.blockingSessions(at: now).first?.selectionData == Data([1]))
  }
}

private func morningState() throws -> DaywellState {
  var state = DaywellState()
  state.selectionData = Data([1])
  state.periods = [
    try LockPeriod(
      start: ClockTime(hour: 23, minute: 0), end: ClockTime(hour: 7, minute: 0),
      morningEnabled: true)
  ]
  return state
}

private func preparedMorningState() throws -> DaywellState {
  var state = try morningState()
  state.refresh(at: date("2026-11-09T20:00:00+08:00"), calendar: shanghai)
  return state
}
