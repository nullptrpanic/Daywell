import Foundation
import Testing

@testable import DaywellCore

struct ProgressiveExemptionTests {
  @Test func offerDisappearsWhenExhaustedOrAlreadyExempt() throws {
    var state = try sampleState()
    let start = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: start, calendar: shanghai)
    #expect(state.exemptionOffer(at: start)?.duration == 600)
    let first = try state.reserveExemption(at: start)
    try state.commitExemption(first.id, at: start)
    #expect(state.exemptionOffer(at: start) == nil)
    let secondTime = date("2026-11-09T13:11:00+08:00")
    #expect(state.exemptionOffer(at: secondTime)?.duration == 300)
    let second = try state.reserveExemption(at: secondTime)
    try state.commitExemption(second.id, at: secondTime)
    #expect(state.exemptionOffer(at: date("2026-11-09T13:16:00+08:00")) == nil)
    state.periods.append(
      try LockPeriod(start: ClockTime(hour: 13, minute: 15), end: ClockTime(hour: 15, minute: 0)))
    state.refresh(at: date("2026-11-09T13:16:00+08:00"), calendar: shanghai)
    #expect(state.exemptionOffer(at: date("2026-11-09T13:16:00+08:00")) == nil)
  }

  @Test func offerRespectsExistingExemptionAndPeriodEnd() throws {
    var state = try sampleState()
    let start = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: start, calendar: shanghai)
    let first = try state.reserveExemption(at: start)
    try state.commitExemption(first.id, at: start)
    state.periods.append(
      try LockPeriod(start: ClockTime(hour: 13, minute: 5), end: ClockTime(hour: 15, minute: 0)))
    let later = date("2026-11-09T13:06:00+08:00")
    state.refresh(at: later, calendar: shanghai)
    #expect(state.exemptionOffer(at: later)?.duration == 300)
    var short = try sampleState()
    let almostEnd = date("2026-11-09T13:59:30+08:00")
    short.refresh(at: almostEnd, calendar: shanghai)
    #expect(short.exemptionOffer(at: almostEnd)?.duration == 30)
    short.monitoringError = "schedule failed"
    #expect(short.exemptionOffer(at: almostEnd) == nil)
  }

  @Test func legacyStoreLimitsFuturePeriodsWithoutResettingActiveQuota() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    var legacy = try sampleState()
    let start = date("2026-11-09T13:01:00+08:00")
    legacy.refresh(at: start, calendar: shanghai)
    var json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    let oldPolicy: [String: Any] = ["allowedCount": 8, "durationMinutes": 12]
    json["policy"] = oldPolicy
    var sessions = try #require(json["sessions"] as? [[String: Any]])
    sessions[0]["policy"] = oldPolicy
    sessions[0]["usedCount"] = 6
    json["sessions"] = sessions
    try JSONSerialization.data(withJSONObject: json).write(
      to: directory.appendingPathComponent("state.json"))
    var restored = try store.read()
    #expect(restored.policy.allowedCount == 5)
    #expect(restored.activeSessions(at: start).first?.remainingCount == 2)
    let pending = try restored.reserveExemption(at: start)
    try restored.commitExemption(pending.id, at: start)
    #expect(
      restored.activeSessions(at: start).first?.exemption?.end == date("2026-11-09T13:13:00+08:00"))
    restored.refresh(at: date("2026-11-10T13:01:00+08:00"), calendar: shanghai)
    #expect(
      restored.activeSessions(at: date("2026-11-10T13:01:00+08:00")).first?.remainingCount == 5)
  }

  @Test func fiveUsesHaveIndependentDecreasingDurations() throws {
    var state = try sampleState()
    state.policy = try decodedPolicy()
    let moments = [
      ("13:01:00", "13:11:00"), ("13:11:00", "13:16:00"),
      ("13:16:00", "13:19:00"), ("13:19:00", "13:21:00"), ("13:21:00", "13:22:00"),
    ]
    for (start, end) in moments {
      let now = date("2026-11-09T\(start)+08:00")
      state.refresh(at: now, calendar: shanghai)
      let pending = try state.reserveExemption(at: now)
      try state.commitExemption(pending.id, at: now)
      #expect(
        state.activeSessions(at: now).first?.exemption?.end == date("2026-11-09T\(end)+08:00"))
    }
    let exhausted = date("2026-11-09T13:22:00+08:00")
    #expect(throws: DaywellError.allowanceExhausted) { try state.reserveExemption(at: exhausted) }
  }

  @Test func newPoliciesRejectExcessCountsAndInvalidDurations() throws {
    #expect(throws: (any Error).self) { try decodedPolicy(count: 6) }
    #expect(throws: (any Error).self) { try decodedPolicy(count: -1) }
    #expect(throws: (any Error).self) { try decodedPolicy(durations: [10, 5]) }
    #expect(throws: (any Error).self) { try decodedPolicy(durations: [10, 5, 3, 2, 0]) }
    #expect(throws: (any Error).self) { try decodedPolicy(durations: [1441, 5, 3, 2, 1]) }
  }

  @Test func overlappingPeriodsUseTheirOwnAttemptNumber() throws {
    var state = try sampleState()
    state.policy = try decodedPolicy()
    let firstTime = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: firstTime, calendar: shanghai)
    let first = try state.reserveExemption(at: firstTime)
    try state.commitExemption(first.id, at: firstTime)
    state.periods.append(
      try LockPeriod(start: ClockTime(hour: 13, minute: 5), end: ClockTime(hour: 15, minute: 0)))
    let later = date("2026-11-09T13:12:00+08:00")
    state.refresh(at: later, calendar: shanghai)
    let second = try state.reserveExemption(at: later)
    try state.commitExemption(second.id, at: later)
    #expect(
      state.activeSessions(at: later).map(\.exemption?.end) == [
        date("2026-11-09T13:17:00+08:00"), date("2026-11-09T13:22:00+08:00"),
      ])
    #expect(state.activeSessions(at: later).map(\.remainingCount) == [3, 4])
  }

  @Test func savedCustomDurationsAndNextAttemptSurviveReload() throws {
    var state = try sampleState()
    state.policy = try decodedPolicy(count: 2, durations: [8, 4, 3, 2, 1])
    let firstTime = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: firstTime, calendar: shanghai)
    let first = try state.reserveExemption(at: firstTime)
    try state.commitExemption(first.id, at: firstTime)
    var restored = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(state))
    let later = date("2026-11-09T13:09:00+08:00")
    let second = try restored.reserveExemption(at: later)
    try restored.commitExemption(second.id, at: later)
    #expect(
      restored.activeSessions(at: later).first?.exemption?.end == date("2026-11-09T13:13:00+08:00"))
  }
}

private func decodedPolicy(count: Int = 5, durations: [Int] = [10, 5, 3, 2, 1]) throws
  -> ExemptionPolicy
{
  let json: [String: Any] = [
    "allowedCount": count, "durationMinutes": 10, "durationsMinutes": durations,
  ]
  return try JSONDecoder().decode(
    ExemptionPolicy.self, from: JSONSerialization.data(withJSONObject: json))
}
