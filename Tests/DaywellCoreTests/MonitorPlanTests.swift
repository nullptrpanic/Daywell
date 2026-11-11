import Foundation
import Testing

@testable import DaywellCore

struct MonitorPlanTests {
  @Test func oneMinuteExemptionStillRegistersRecoveryBeforeUnlocking() throws {
    var state = try sampleState()
    state.policy = try ExemptionPolicy(allowedCount: 1, durationsMinutes: [1, 5, 3, 2, 1])
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let pending = try state.reserveExemption(at: now)
    let plan = try #require(
      MonitorPlan.make(for: state, at: now, calendar: shanghai).first {
        $0.name.hasPrefix("daywell.grace.")
      })
    let start = try #require(shanghai.date(from: plan.start))
    let end = try #require(shanghai.date(from: plan.end))
    #expect(end == date("2026-11-09T13:02:00+08:00"))
    #expect(end.timeIntervalSince(start) >= 15 * 60)
    #expect(state.blockingSessions(at: now).count == 1)
    try state.commitExemption(pending.id, at: now)
    #expect(state.blockingSessions(at: date("2026-11-09T13:02:00+08:00")).count == 1)
  }

  @Test func shortPeriodStartsAtTheActualTimeAndHasAnIndependentEnd() throws {
    var state = DaywellState()
    state.periods = [
      try LockPeriod(
        start: ClockTime(hour: 0, minute: 5),
        end: ClockTime(hour: 0, minute: 10), weekdays: [.monday])
    ]
    state.selectionData = Data([1])
    let start = date("2026-11-09T00:05:00+08:00")
    let end = date("2026-11-09T00:10:00+08:00")
    let plans = MonitorPlan.make(
      for: state, at: date("2026-11-09T00:00:00+08:00"), calendar: shanghai)
    let plan = try #require(plans.first { $0.repeats })
    #expect(plan.start.hour == 0 && plan.start.minute == 5)
    #expect(plan.end.hour == 0 && plan.end.minute == 20)
    #expect(plan.warning == nil)
    #expect(plan.start.weekday == nil)

    let endGuardName = MonitorPlan.endGuardName(for: end)
    let endGuard = try #require(plans.first { $0.name == endGuardName })
    #expect(shanghai.date(from: endGuard.end) == end)
    state.refresh(at: start, calendar: shanghai)
    let running = MonitorPlan.make(for: state, at: start, calendar: shanghai)
    #expect(running.first { $0.name == endGuardName } == endGuard)
    #expect(state.blockingSessions(at: start).count == 1)
    #expect(state.blockingSessions(at: end).isEmpty)
  }

  @Test func onlyTheNextUpcomingPeriodGetsAnEndGuardAheadOfTime() throws {
    var state = try sampleState()
    state.periods.append(
      try LockPeriod(
        start: ClockTime(hour: 15, minute: 0), end: ClockTime(hour: 16, minute: 0),
        weekdays: [.monday]))
    let now = date("2026-11-09T12:50:00+08:00")
    let plans = MonitorPlan.make(for: state, at: now, calendar: shanghai)
    let endGuards = plans.filter { $0.name.hasPrefix("daywell.end.") }
    #expect(endGuards.count == 1)
    let nextEnd = date("2026-11-09T14:00:00+08:00")
    #expect(endGuards.first?.name == MonitorPlan.endGuardName(for: nextEnd))
  }

  @Test func tenMinuteExemptionRegistersLongEnoughWindowBeforeUnlocking() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let pending = try state.reserveExemption(at: now)
    let before = MonitorPlan.make(for: state, at: now, calendar: shanghai).filter {
      $0.name.hasPrefix("daywell.grace.")
    }
    let plan = try #require(before.first)
    #expect(shanghai.date(from: plan.start) == date("2026-11-09T12:46:00+08:00"))
    #expect(shanghai.date(from: plan.end) == date("2026-11-09T13:11:00+08:00"))
    try state.commitExemption(pending.id, at: now)
    let after = MonitorPlan.make(for: state, at: now, calendar: shanghai).filter {
      $0.name.hasPrefix("daywell.grace.")
    }
    #expect(before == after)
  }

  @Test func deletingActivePeriodKeepsItsEndCallbackUntilFinished() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    state.removePeriod(state.periods[0].id, at: now, calendar: shanghai)
    let during = MonitorPlan.make(for: state, at: now, calendar: shanghai)
    #expect(during.count == 2)
    #expect(during.first?.end.hour == 14)
    let after = MonitorPlan.make(
      for: state, at: date("2026-11-09T14:00:00+08:00"), calendar: shanghai)
    #expect(after.isEmpty)
  }

  @Test func fractionalGrantTimeNeverSchedulesWakeupBeforeExpiration() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00").addingTimeInterval(0.75)
    state.refresh(at: now, calendar: shanghai)
    let pending = try state.reserveExemption(at: now)
    let plan = try #require(
      MonitorPlan.make(for: state, at: now, calendar: shanghai).first {
        $0.name.hasPrefix("daywell.grace.")
      })
    let wakeup = try #require(shanghai.date(from: plan.end))
    #expect(wakeup >= pending.grants[0].end)
    #expect(wakeup.timeIntervalSince(now) >= 600)
  }

  @Test func activeSessionHasAnAbsoluteEndGuardAcrossTimeZoneChanges() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    var otherZone = Calendar(identifier: .gregorian)
    otherZone.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let plan = try #require(
      MonitorPlan.make(for: state, at: now, calendar: otherZone).first {
        $0.name.hasPrefix("daywell.end.")
      })
    #expect(otherZone.date(from: plan.end) == date("2026-11-09T14:00:00+08:00"))
    #expect(!plan.repeats)
  }
}
