import Foundation
import Testing

@testable import DaywellCore

struct LockRulesTests {
  @Test func invalidStoredWorkoutTimestampIsRejectedBeforeScheduling() throws {
    var training = FitnessTraining(restEnabled: false)
    training.completeGroup(at: Date())
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(training)) as? [String: Any])
    json["lastCompletedAt"] = 1e30
    var s = DaywellState()
    s.fitness = try JSONDecoder().decode(
      FitnessTraining.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: DaywellError.invalidState) { try s.validate() }
  }

  @Test func finalGroupAlsoCancelsMorningWithoutLeavingWorkoutMonitors() throws {
    var s = try state()
    let now = date("2026-11-12T08:01:00+08:00")
    s.refresh(at: now.addingTimeInterval(-120), calendar: shanghai)
    s.refresh(at: now, calendar: shanghai)
    #expect(s.pendingMornings(at: now).count == 1)
    s.updateFitness(initial: FitnessTraining(progress: FitnessProgress(targetGroups: 1))) {
      $0.completeGroup(at: now)
    }
    #expect(s.fitness?.progress.completedGroups == 0)
    #expect(s.pendingMornings(at: now).isEmpty)
    #expect(
      !MonitorPlan.make(for: s, at: now, calendar: shanghai).contains {
        $0.name.contains(".fitness.")
      })
  }

  @Test func cancellingAFutureSleepDoesNotEndOrRestartCurrentMorningUsage() throws {
    var s = try state()
    var next = try LockPeriod(
      start: ClockTime(hour: 9, minute: 0), end: ClockTime(hour: 10, minute: 0))
    s.periods.append(next)
    s.refresh(at: date("2026-11-12T07:30:00+08:00"), calendar: shanghai)
    let morning = date("2026-11-12T08:05:00+08:00")
    s.refresh(at: morning, calendar: shanghai)
    let window = try #require(s.pendingMornings(at: morning).first)
    let original = try #require(
      MonitorPlan.make(for: s, at: morning, calendar: shanghai).first {
        $0.name == window.monitorName
      })
    next.isEnabled = false
    try s.savePeriod(next, at: morning, calendar: shanghai)
    let later = date("2026-11-12T09:05:00+08:00")
    s.refresh(at: later, calendar: shanghai)
    #expect(s.pendingMornings(at: later).map(\.id) == [window.id])
    #expect(
      MonitorPlan.make(for: s, at: later, calendar: shanghai).first {
        $0.name == window.monitorName
      } == original)
  }

  @Test(arguments: [false, true])
  func missedShortSleepStillCancelsOldTasks(_ workout: Bool) throws {
    var s = try state()
    s.periods.append(
      try LockPeriod(start: ClockTime(hour: 8, minute: 10), end: ClockTime(hour: 8, minute: 11)))
    s.refresh(at: date("2026-11-12T07:30:00+08:00"), calendar: shanghai)
    let before = date("2026-11-12T08:05:00+08:00")
    s.refresh(at: before, calendar: shanghai)
    let old = try #require(s.pendingMornings(at: before).first)
    s.reachMorningLimit(monitorName: old.monitorName, at: before, calendar: shanghai)
    if workout {
      s.updateFitness(initial: FitnessTraining(restEnabled: true)) { $0.completeGroup(at: before) }
    }
    let after = date("2026-11-12T08:12:00+08:00")
    s.refresh(at: after, calendar: shanghai)
    s = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(s))
    s.reachMorningLimit(monitorName: old.monitorName, at: after, calendar: shanghai)
    #expect(s.activeSessions(at: after).isEmpty)
    #expect(!s.hasFitnessRestriction(at: after))
    if workout { #expect(s.fitness?.progress.completedGroups == 1) }
  }

  @Test func newPeriodCannotOverlapAnEditedButStillRunningSnapshot() throws {
    var s = try state()
    let now = date("2026-11-12T07:30:00+08:00")
    s.refresh(at: now, calendar: shanghai)
    var edited = s.periods[0]
    edited.start = try ClockTime(hour: 9, minute: 0)
    edited.end = try ClockTime(hour: 10, minute: 0)
    try s.savePeriod(edited, at: now, calendar: shanghai)
    let conflicting = try LockPeriod(
      start: ClockTime(hour: 7, minute: 45), end: ClockTime(hour: 8, minute: 15))
    #expect(throws: (any Error).self) { try s.savePeriod(conflicting, at: now, calendar: shanghai) }
    #expect(s.periods.count == 1)
    let adjacent = try LockPeriod(
      start: ClockTime(hour: 8, minute: 0), end: ClockTime(hour: 8, minute: 30))
    try s.savePeriod(adjacent, at: now, calendar: shanghai)
    #expect(s.periods.count == 2)
  }

  @Test func onlySuccessfulGroupsExtendInactivityAndExpiredCountStartsAtOne() throws {
    let start = date("2026-11-12T08:00:00+08:00")
    var f = FitnessTraining(restEnabled: true)
    f.completeGroup(at: start)
    f.completeGroup(at: start.addingTimeInterval(29 * 60))
    f.refresh(at: start.addingTimeInterval(30 * 60))
    #expect(f.progress.completedGroups == 2)
    f.setRestSeconds(60)
    #expect(f.inactivityEndsAt == start.addingTimeInterval(59 * 60))
    f.refresh(at: start.addingTimeInterval(59 * 60))
    #expect(f.progress.completedGroups == 0)
    f.completeGroup(at: start.addingTimeInterval(60 * 60))
    #expect(f.progress.completedGroups == 1)
  }

  @Test func olderFitnessFilesMigrateOnceAndRetainTheirOriginalDeadline() throws {
    let now = date("2026-11-12T08:00:00+08:00")
    for rest in [false, true] {
      var f = FitnessTraining(restEnabled: rest)
      f.completeGroup(at: now)
      var json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) as? [String: Any])
      json.removeValue(forKey: "lastCompletedAt")
      json.removeValue(forKey: "locksAfterRest")
      var old = try JSONDecoder().decode(
        FitnessTraining.self, from: JSONSerialization.data(withJSONObject: json))
      old.refresh(at: now.addingTimeInterval(60))
      let deadline = try #require(old.inactivityEndsAt)
      #expect(deadline == now.addingTimeInterval(rest ? 1800 : 1860))
      old = try JSONDecoder().decode(FitnessTraining.self, from: JSONEncoder().encode(old))
      old.refresh(at: deadline)
      #expect(old.progress.completedGroups == 0)
      #expect(!old.isLocked(at: deadline))
    }
  }

  @Test func cancelledMorningReservationCannotConsumeOrRestoreAnything() throws {
    var s = try state()
    let now = date("2026-11-12T08:01:00+08:00")
    s.refresh(at: now.addingTimeInterval(-120), calendar: shanghai)
    s.refresh(at: now, calendar: shanghai)
    let morning = try #require(s.pendingMornings(at: now).first)
    s.reachMorningLimit(monitorName: morning.monitorName, at: now, calendar: shanghai)
    let reservation = try s.reserveExemption(at: now)
    s.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: now) }
    #expect(throws: DaywellError.staleReservation) {
      try s.commitExemption(reservation.id, at: now)
    }
    #expect(s.sessions.allSatisfy { $0.usedCount == 0 })
    #expect(s.activeSessions(at: now).isEmpty)
  }

  @Test func legacyConfigurationCanExemptWhenTheActualPlanFits() throws {
    var s = try state()
    s.periods = try (1...13).map {
      try LockPeriod(
        start: ClockTime(hour: $0, minute: 0), end: ClockTime(hour: $0, minute: 30),
        morningEnabled: true)
    }
    let now = date("2026-11-12T07:10:00+08:00")
    s.refresh(at: now, calendar: shanghai)
    #expect(MonitorPlan.requiredCapacity(for: s, at: now, calendar: shanghai) > 20)
    let reservation = try s.reserveExemption(at: now)
    #expect(MonitorPlan.make(for: s, at: now, calendar: shanghai).count <= 20)
    try s.commitExemption(reservation.id, at: now)
    #expect(s.activeSessions(at: now).first?.remainingCount == 1)
  }

  private func state() throws -> DaywellState {
    var state = DaywellState()
    state.selectionData = Data([1])
    state.hadAuthorization = true
    state.morningPolicy = try MorningPolicy(usageMinutes: 1, lockMinutes: 1440)
    state.periods = [
      try LockPeriod(
        start: ClockTime(hour: 7, minute: 0), end: ClockTime(hour: 8, minute: 0),
        morningEnabled: true)
    ]
    return state
  }

  @Test func newSleepPermanentlyCancelsMorningEvenDuringExemption() throws {
    var s = try state()
    s.periods.append(
      try LockPeriod(
        start: ClockTime(hour: 9, minute: 0), end: ClockTime(hour: 10, minute: 0),
        morningEnabled: true))
    s.refresh(at: date("2026-11-12T07:30:00+08:00"), calendar: shanghai)
    let old = try #require(s.morningWindows.first { $0.start == date("2026-11-12T08:00:00+08:00") })
    let trigger = date("2026-11-12T08:59:00+08:00")
    s.reachMorningLimit(monitorName: old.monitorName, at: trigger, calendar: shanghai)
    let grant = try s.reserveExemption(at: trigger)
    try s.commitExemption(grant.id, at: trigger)
    let takeover = date("2026-11-12T09:00:00+08:00")
    s.refresh(at: takeover, calendar: shanghai)
    #expect(s.activeSessions(at: takeover).count == 1)
    #expect(s.activeSessions(at: takeover).first?.isMorning == false)
    s = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(s))
    let later = date("2026-11-12T10:02:00+08:00")
    s.reachMorningLimit(monitorName: old.monitorName, at: later, calendar: shanghai)
    #expect(s.activeSessions(at: later).isEmpty)
    #expect(s.pendingMornings(at: later).count == 1)
    #expect(s.pendingMornings(at: later).first?.id != old.id)
  }

  @Test func completedGroupCancelsMorningWithRestDisabled() throws {
    var s = try state()
    let now = date("2026-11-12T08:01:00+08:00")
    s.refresh(at: now.addingTimeInterval(-120), calendar: shanghai)
    s.refresh(at: now, calendar: shanghai)
    let old = try #require(s.pendingMornings(at: now).first)
    s.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: now) }
    s.reachMorningLimit(
      monitorName: old.monitorName, at: now.addingTimeInterval(60), calendar: shanghai)
    #expect(s.pendingMornings(at: now).isEmpty)
    #expect(s.activeSessions(at: now.addingTimeInterval(60)).isEmpty)
    #expect(s.fitness?.progress.completedGroups == 1)
  }

  @Test func sleepTakeoverPreservesCountButOldWorkoutCannotRelock() throws {
    var s = try state()
    let group = date("2026-11-12T07:59:00+08:00")
    s.refresh(at: group, calendar: shanghai)
    let grant = try s.reserveExemption(at: group)
    try s.commitExemption(grant.id, at: group)
    s.updateFitness(initial: FitnessTraining(restEnabled: true)) { $0.completeGroup(at: group) }
    s.refresh(at: group.addingTimeInterval(30), calendar: shanghai)
    #expect(!s.hasFitnessRestriction(at: group.addingTimeInterval(30)))
    let end = date("2026-11-12T08:00:00+08:00")
    s.refresh(at: end, calendar: shanghai)
    #expect(s.fitness?.progress.completedGroups == 1)
    #expect(!s.hasFitnessRestriction(at: end))
    #expect(s.pendingMornings(at: end).count == 1)
    s.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: end) }
    s.refresh(at: end.addingTimeInterval(30), calendar: shanghai)
    #expect(s.hasFitnessRestriction(at: end.addingTimeInterval(30)))
    #expect(s.pendingMornings(at: end.addingTimeInterval(30)).isEmpty)
  }

  @Test func inactivityResetsWithoutClearingSleepAndRestCannotOutliveTimeout() throws {
    var s = try state()
    let group = date("2026-11-12T06:45:00+08:00")
    s.updateFitness(initial: FitnessTraining(restEnabled: true)) {
      $0.setRestSeconds(1800)
      $0.completeGroup(at: group)
    }
    let end = group.addingTimeInterval(1800)
    s.refresh(at: end, calendar: shanghai)
    #expect(s.fitness?.progress.completedGroups == 0)
    #expect(s.fitness?.restEndsAt == nil)
    #expect(!s.hasFitnessRestriction(at: end))
    #expect(s.activeSessions(at: end).first?.isMorning == false)
  }

  @Test func adjacentSleepHasNoIntermediateMorning() throws {
    var s = try state()
    s.periods.append(
      try LockPeriod(start: ClockTime(hour: 8, minute: 0), end: ClockTime(hour: 9, minute: 0)))
    s.refresh(at: date("2026-11-12T07:30:00+08:00"), calendar: shanghai)
    let boundary = date("2026-11-12T08:00:00+08:00")
    s.refresh(at: boundary, calendar: shanghai)
    #expect(s.pendingMornings(at: boundary).isEmpty)
    #expect(s.activeSessions(at: boundary).count == 1)
  }

  @Test func sixDailyMorningsNeverAccumulateAndKeepExemptionCapacity() throws {
    var s = try state()
    s.periods = try (7...12).map {
      try LockPeriod(
        start: ClockTime(hour: $0, minute: 0), end: ClockTime(hour: $0, minute: 30),
        morningEnabled: true)
    }
    for day in 12...14 {
      for hour in 7...12 {
        let start = date(String(format: "2026-11-%02dT%02d:00:00+08:00", day, hour))
        s.refresh(at: start, calendar: shanghai)
        let morning = start.addingTimeInterval(31 * 60)
        s.refresh(at: morning, calendar: shanghai)
        let window = try #require(s.pendingMornings(at: morning).first)
        s.reachMorningLimit(monitorName: window.monitorName, at: morning, calendar: shanghai)
        #expect(s.activeSessions(at: morning).count == 1)
        #expect(s.exemptionOffer(at: morning) != nil)
        let grant = try s.reserveExemption(at: morning)
        try s.commitExemption(grant.id, at: morning)
        #expect(MonitorPlan.requiredCapacity(for: s, at: morning, calendar: shanghai) <= 20)
        try s.validate()
      }
    }
  }
}
