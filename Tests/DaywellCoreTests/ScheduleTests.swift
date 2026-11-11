import Foundation
import Testing

@testable import DaywellCore

struct ScheduleTests {
  private let saveTime = date("2026-11-09T12:00:00+08:00")

  @Test func reenablingAnOvernightPeriodStartsTheCurrentOccurrenceImmediately() throws {
    let now = date("2026-11-11T17:45:00+08:00")
    var state = DaywellState()
    state.selectionData = Data([1])
    let period = try LockPeriod(
      start: ClockTime(hour: 17, minute: 40), end: ClockTime(hour: 10, minute: 0))
    try state.savePeriod(period, at: now, calendar: shanghai)
    let session = try #require(state.activeSessions(at: now).first)
    var disabled = period
    disabled.isEnabled = false
    try state.savePeriod(
      disabled, at: now, calendar: shanghai, verifiedSessionIDs: [session.id])
    #expect(state.activeSessions(at: now).isEmpty)

    var enabled = try #require(state.periods.first)
    enabled.isEnabled = true
    try state.savePeriod(enabled, at: now, calendar: shanghai)
    let restarted = try #require(state.activeSessions(at: now).first)
    #expect(restarted.occurrence.start == date("2026-11-11T17:40:00+08:00"))
    #expect(restarted.occurrence.end == date("2026-11-12T10:00:00+08:00"))
  }

  @Test func restoredDeferralWithoutAnOriginalSessionDoesNotSkipToday() throws {
    let now = date("2026-11-11T17:45:00+08:00")
    var state = DaywellState()
    state.selectionData = Data([1])
    var period = try LockPeriod(
      start: ClockTime(hour: 17, minute: 40), end: ClockTime(hour: 10, minute: 0))
    period.effectiveAfter = date("2026-11-12T10:00:00+08:00")
    state.periods = [period]
    var restored = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(state))
    restored.refresh(at: now, calendar: shanghai)
    #expect(restored.blockingSessions(at: now).count == 1)
    #expect(restored.periods.first?.effectiveAfter == nil)
  }

  @Test func newPeriodUsesTodayOrTheCurrentOvernightOccurrence() throws {
    let now = date("2026-11-11T17:45:00+08:00")
    var state = DaywellState()
    state.selectionData = Data([1])
    let active = try LockPeriod(
      start: ClockTime(hour: 17, minute: 40), end: ClockTime(hour: 18, minute: 0))
    try state.savePeriod(active, at: now, calendar: shanghai)
    #expect(state.blockingSessions(at: now).count == 1)
    let laterToday = try LockPeriod(
      start: ClockTime(hour: 19, minute: 0), end: ClockTime(hour: 20, minute: 0))
    try state.savePeriod(laterToday, at: now, calendar: shanghai)
    #expect(
      laterToday.nextOccurrence(after: now, calendar: shanghai)?.start
        == date("2026-11-11T19:00:00+08:00"))
    #expect(
      laterToday.nextOccurrence(after: date("2026-11-11T20:00:00+08:00"), calendar: shanghai)?.start
        == date("2026-11-12T19:00:00+08:00"))
  }

  @Test func testRejectsNewPeriodWhenAnyRepeatDayOverlaps() throws {
    let saved = try LockPeriod(
      start: ClockTime(hour: 13, minute: 0), end: ClockTime(hour: 14, minute: 0),
      weekdays: [.monday, .tuesday])
    let overlapping = try LockPeriod(
      start: ClockTime(hour: 13, minute: 30), end: ClockTime(hour: 14, minute: 30),
      weekdays: [.tuesday, .wednesday])
    var state = DaywellState()
    try state.savePeriod(saved, at: saveTime, calendar: shanghai)
    let before = state

    #expect(throws: (any Error).self) {
      try state.savePeriod(overlapping, at: saveTime, calendar: shanghai)
    }
    #expect(state == before)
  }

  @Test func testRejectsOvernightOverlapAcrossTheEndOfTheWeek() throws {
    let overnight = try LockPeriod(
      start: ClockTime(hour: 23, minute: 0), end: ClockTime(hour: 7, minute: 0),
      weekdays: [.saturday])
    let sunday = try LockPeriod(
      start: ClockTime(hour: 6, minute: 59), end: ClockTime(hour: 7, minute: 30),
      weekdays: [.sunday])

    for (saved, overlapping) in [(overnight, sunday), (sunday, overnight)] {
      var state = DaywellState()
      try state.savePeriod(saved, at: saveTime, calendar: shanghai)
      #expect(throws: (any Error).self) {
        try state.savePeriod(overlapping, at: saveTime, calendar: shanghai)
      }
    }
  }

  @Test func testAcceptsAdjacentTimesAndSeparateRepeatDays() throws {
    let overnight = try LockPeriod(
      start: ClockTime(hour: 23, minute: 0), end: ClockTime(hour: 7, minute: 0),
      weekdays: [.saturday])
    let sunday = try LockPeriod(
      start: ClockTime(hour: 7, minute: 0), end: ClockTime(hour: 8, minute: 0),
      weekdays: [.sunday])
    let saturday = try LockPeriod(
      start: ClockTime(hour: 7, minute: 0), end: ClockTime(hour: 8, minute: 0),
      weekdays: [.saturday])
    var state = DaywellState()

    for period in [overnight, sunday, saturday] {
      try state.savePeriod(period, at: saveTime, calendar: shanghai)
    }
    #expect(state.periods == [overnight, sunday, saturday])
  }

  @Test func testEditingChecksOtherPeriodsButNotTheOriginalSchedule() throws {
    let first = try LockPeriod(
      start: ClockTime(hour: 13, minute: 0), end: ClockTime(hour: 14, minute: 0))
    let second = try LockPeriod(
      start: ClockTime(hour: 14, minute: 0), end: ClockTime(hour: 15, minute: 0))
    var state = DaywellState()
    try state.savePeriod(first, at: saveTime, calendar: shanghai)
    try state.savePeriod(second, at: saveTime, calendar: shanghai)

    var edited = first
    edited.end = try ClockTime(hour: 14, minute: 1)
    #expect(throws: (any Error).self) {
      try state.savePeriod(edited, at: saveTime, calendar: shanghai)
    }
    #expect(state.periods == [first, second])

    edited.end = try ClockTime(hour: 13, minute: 45)
    try state.savePeriod(edited, at: saveTime, calendar: shanghai)
    #expect(state.periods == [edited, second])
  }

  @Test func testDisabledPeriodsAreCheckedForOverlap() throws {
    let start = try ClockTime(hour: 13, minute: 0)
    let end = try ClockTime(hour: 14, minute: 0)
    var state = DaywellState()
    try state.savePeriod(
      LockPeriod(start: start, end: end, isEnabled: false), at: saveTime, calendar: shanghai)

    let duplicate = try LockPeriod(start: start, end: end, isEnabled: false)
    #expect(throws: (any Error).self) {
      try state.savePeriod(duplicate, at: saveTime, calendar: shanghai)
    }
    #expect(state.periods.count == 1)
  }

  @Test func testLegacyConflictCanBeDisabledButCannotBeReenabled() throws {
    var period = try LockPeriod(
      start: ClockTime(hour: 13, minute: 0), end: ClockTime(hour: 14, minute: 0))
    let conflicting = try LockPeriod(
      start: ClockTime(hour: 13, minute: 30), end: ClockTime(hour: 14, minute: 30))
    var state = DaywellState()
    state.periods = [period, conflicting]
    try state.validate()

    period.isEnabled = false
    try state.savePeriod(period, at: saveTime, calendar: shanghai)
    #expect(state.periods.first?.isEnabled == false)

    period.isEnabled = true
    #expect(throws: (any Error).self) {
      try state.savePeriod(period, at: saveTime, calendar: shanghai)
    }
    #expect(state.periods.first?.isEnabled == false)
  }

  @Test
  func testOvernightBelongsToStartWeekdayAndEndIsExclusive() throws {
    let period = try LockPeriod(
      start: ClockTime(hour: 23, minute: 0),
      end: ClockTime(hour: 7, minute: 0), weekdays: [.monday])
    #expect(
      period.occurrence(containing: date("2026-11-09T22:59:59+08:00"), calendar: shanghai) == nil)
    let occurrence = try #require(
      period.occurrence(containing: date("2026-11-10T06:59:59+08:00"), calendar: shanghai))
    #expect(occurrence.start == date("2026-11-09T23:00:00+08:00"))
    #expect(occurrence.end == date("2026-11-10T07:00:00+08:00"))
    #expect(
      period.occurrence(containing: date("2026-11-10T07:00:00+08:00"), calendar: shanghai) == nil)
    #expect(
      period.occurrence(containing: date("2026-11-10T23:30:00+08:00"), calendar: shanghai) == nil)
  }

  @Test func testDaytimeAndNextStart() throws {
    let period = try LockPeriod(
      start: ClockTime(hour: 13, minute: 0),
      end: ClockTime(hour: 14, minute: 0), weekdays: [.monday, .wednesday])
    #expect(
      period.occurrence(containing: date("2026-11-09T13:00:00+08:00"), calendar: shanghai) != nil)
    #expect(
      period.nextOccurrence(after: date("2026-11-09T14:00:00+08:00"), calendar: shanghai)?.start
        == date("2026-11-11T13:00:00+08:00"))
  }

  @Test func testInvalidConfigurationsAreRejected() throws {
    #expect(throws: (any Error).self) { try ClockTime(hour: 24, minute: 0) }
    #expect(throws: (any Error).self) { try ClockTime(hour: 12, minute: 60) }
    let time = try ClockTime(hour: 12, minute: 0)
    #expect(throws: (any Error).self) { try LockPeriod(start: time, end: time) }
    #expect(throws: (any Error).self) {
      try LockPeriod(start: time, end: ClockTime(hour: 13, minute: 0), weekdays: [])
    }
    #expect(throws: (any Error).self) { try ExemptionPolicy(allowedCount: -1, durationMinutes: 10) }
    #expect(throws: (any Error).self) { try ExemptionPolicy(allowedCount: 2, durationMinutes: 0) }
  }

  @Test func testDaylightSavingUsesWallClockAndPreservesSmallerComponents() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let spring = try LockPeriod(
      start: ClockTime(hour: 2, minute: 30), end: ClockTime(hour: 4, minute: 0))
    let occurrence = try #require(
      spring.occurrence(containing: date("2026-03-08T03:45:00-07:00"), calendar: calendar))
    #expect(occurrence.start == date("2026-03-08T03:30:00-07:00"))
    #expect(occurrence.end.timeIntervalSince(occurrence.start) == 30 * 60)
    let fall = try LockPeriod(
      start: ClockTime(hour: 1, minute: 0), end: ClockTime(hour: 2, minute: 0))
    let repeated = try #require(
      fall.occurrence(containing: date("2026-11-01T01:30:00-08:00"), calendar: calendar))
    #expect(repeated.end.timeIntervalSince(repeated.start) == 2 * 60 * 60)
  }
}

let shanghai: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
  return calendar
}()

func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
