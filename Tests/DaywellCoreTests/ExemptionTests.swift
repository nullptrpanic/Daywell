import Foundation
import Testing

@testable import DaywellCore

struct ExemptionTests {
  @Test func sleepExemptionRemainsValidWhenWorkoutRestEnds() throws {
    var state = try sampleState()
    state.hadAuthorization = true
    let start = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: start, calendar: shanghai)
    state.updateFitness(initial: FitnessTraining(restEnabled: true)) { $0.completeGroup(at: start) }
    let reservation = try state.reserveExemption(at: start.addingTimeInterval(25))
    let deadline = start.addingTimeInterval(30)
    state.refresh(at: deadline, calendar: shanghai)
    try state.commitExemption(reservation.id, at: deadline)
    #expect(!state.hasFitnessRestriction(at: deadline))
    #expect(state.activeSessions(at: deadline).first?.usedCount == 1)
    #expect(state.blockingSessions(at: deadline).isEmpty)
  }

  @Test func exhaustedLegacyOverlapDoesNotConsumeTheNewOwnerQuota() throws {
    var state = try sampleState()
    state.policy = try ExemptionPolicy(allowedCount: 1, durationMinutes: 10)
    let start = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: start, calendar: shanghai)
    let first = try state.reserveExemption(at: start)
    try state.commitExemption(first.id, at: start)
    state.periods.append(
      try LockPeriod(start: ClockTime(hour: 13, minute: 15), end: ClockTime(hour: 15, minute: 0)))
    let later = date("2026-11-09T13:16:00+08:00")
    state.refresh(at: later, calendar: shanghai)
    let next = try state.reserveExemption(at: later)
    #expect(next.grants.count == 1)
    #expect(state.activeSessions(at: later).map(\.remainingCount) == [1])
    #expect(state.sessions.first?.remainingCount == 0)
  }

  @Test func zeroAllowanceKeepsPeriodLocked() throws {
    var state = try sampleState()
    state.policy = try ExemptionPolicy(allowedCount: 0, durationMinutes: 10)
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    #expect(throws: DaywellError.allowanceExhausted) { try state.reserveExemption(at: now) }
    #expect(state.blockingSessions(at: now).count == 1)
  }

  @Test func abandonedReservationExpiresWithoutConsumingAllowance() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    _ = try state.reserveExemption(at: now)
    var relaunched = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(state))
    let later = now.addingTimeInterval(31)
    relaunched.refresh(at: later, calendar: shanghai)
    #expect(relaunched.reservation == nil)
    #expect(relaunched.blockingSessions(at: later).first?.remainingCount == 2)
    #expect(throws: Never.self) { try relaunched.reserveExemption(at: later) }
  }

  @Test func movingClockBackDoesNotRestoreUsedAllowance() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let pending = try state.reserveExemption(at: now)
    try state.commitExemption(pending.id, at: now)
    state.refresh(at: date("2026-11-09T14:01:00+08:00"), calendar: shanghai)
    let earlier = date("2026-11-09T13:30:00+08:00")
    state.refresh(at: earlier, calendar: shanghai)
    #expect(state.blockingSessions(at: earlier).first?.remainingCount == 1)
  }

  @Test func revokedTokensRequireReselectionWithoutResettingAllowance() throws {
    var state = try sampleState()
    state.hadAuthorization = true
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let pending = try state.reserveExemption(at: now)
    try state.commitExemption(pending.id, at: now)
    state.markAuthorizationRevoked()
    #expect(state.needsApplicationReselection)
    #expect(state.selectionData == nil)
    state.replaceSelectionAfterAuthorization(Data([7]))
    #expect(!state.needsApplicationReselection)
    #expect(state.activeSessions(at: now).first?.selectionData == Data([7]))
    #expect(state.activeSessions(at: now).first?.remainingCount == 1)
  }

  @Test func noSelectionDoesNotCreateAProtectedSession() throws {
    var state = try sampleState()
    state.selectionData = nil
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    #expect(state.activeSessions(at: now).isEmpty)
    #expect(throws: DaywellError.noActivePeriod) { try state.reserveExemption(at: now) }
  }

  @Test func disablingAnActivePeriodRequiresVerification() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    var disabled = state.periods[0]
    disabled.isEnabled = false
    let before = state

    let session = try #require(state.activeSessions(at: now).first)
    #expect(throws: DaywellError.deactivationVerificationRequired(sessionIDs: [session.id])) {
      try state.savePeriod(disabled, at: now, calendar: shanghai)
    }
    #expect(state == before)
  }

  @Test func verifiedDeactivationDoesNotReviveAnOlderCancelledSleep() throws {
    var state = try sampleState()
    let other = try LockPeriod(
      start: ClockTime(hour: 13, minute: 30), end: ClockTime(hour: 15, minute: 0))
    state.periods.append(other)
    let now = date("2026-11-09T13:31:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    _ = try state.reserveExemption(at: now)
    var disabled = other
    disabled.isEnabled = false
    let session = try #require(state.activeSessions(at: now).first)
    #expect(throws: DaywellError.deactivationVerificationRequired(sessionIDs: [session.id])) {
      try state.savePeriod(disabled, at: now, calendar: shanghai, verifiedSessionIDs: ["obsolete"])
    }
    try state.savePeriod(disabled, at: now, calendar: shanghai, verifiedSessionIDs: [session.id])
    #expect(state.activeSessions(at: now).isEmpty)
    #expect(state.reservation == nil)
    try state.validate()
  }

  @Test func defaultAllowsTenThenFiveMinutesAndResetsNextOccurrence() throws {
    var state = try sampleState()
    let start = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: start, calendar: shanghai)
    let first = try state.reserveExemption(at: start)
    // Preparing a system wake-up must not consume the quota or remove shields.
    #expect(state.blockingSessions(at: start).count == 1)
    #expect(state.activeSessions(at: start).first?.remainingCount == 2)
    try state.commitExemption(first.id, at: start)
    #expect(state.blockingSessions(at: start).isEmpty)
    #expect(
      state.activeSessions(at: start).first?.exemption?.end == date("2026-11-09T13:11:00+08:00"))
    let secondTime = date("2026-11-09T13:11:00+08:00")
    #expect(state.blockingSessions(at: secondTime).count == 1)
    let second = try state.reserveExemption(at: secondTime)
    try state.commitExemption(second.id, at: secondTime)
    #expect(
      state.activeSessions(at: secondTime).first?.exemption?.end
        == date("2026-11-09T13:16:00+08:00"))
    #expect(throws: DaywellError.allowanceExhausted) {
      try state.reserveExemption(at: date("2026-11-09T13:16:00+08:00"))
    }
    let nextDay = date("2026-11-10T13:01:00+08:00")
    state.refresh(at: nextDay, calendar: shanghai)
    #expect(state.activeSessions(at: nextDay).first?.remainingCount == 2)
  }

  @Test func legacyOverlapHasOneOwnerAndOldEndDoesNotUnlockIt() throws {
    var state = try sampleState()
    state.periods.append(
      try LockPeriod(start: ClockTime(hour: 13, minute: 30), end: ClockTime(hour: 15, minute: 0)))
    let now = date("2026-11-09T13:31:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let reservation = try state.reserveExemption(at: now)
    try state.commitExemption(reservation.id, at: now)
    #expect(state.activeSessions(at: now).map(\.remainingCount) == [1])
    #expect(state.blockingSessions(at: now).isEmpty)
    let end = date("2026-11-09T14:00:00+08:00")
    state.refresh(at: end, calendar: shanghai)
    #expect(state.blockingSessions(at: end).count == 1)
    #expect(state.activeSessions(at: end).first?.remainingCount == 1)
  }

  @Test func replacementPeriodDuringExemptionUsesOnlyNewQuota() throws {
    var state = try sampleState()
    state.periods.append(
      try LockPeriod(start: ClockTime(hour: 13, minute: 5), end: ClockTime(hour: 15, minute: 0)))
    let firstTime = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: firstTime, calendar: shanghai)
    let first = try state.reserveExemption(at: firstTime)
    try state.commitExemption(first.id, at: firstTime)
    let later = date("2026-11-09T13:06:00+08:00")
    state.refresh(at: later, calendar: shanghai)
    #expect(state.blockingSessions(at: later).count == 1)
    let second = try state.reserveExemption(at: later)
    try state.commitExemption(second.id, at: later)
    #expect(state.activeSessions(at: later).map(\.remainingCount) == [1])
  }

  @Test func canceledReservationAndEarlyRelockDoNotRefundOrConsumeExtra() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let failed = try state.reserveExemption(at: now)
    state.cancelReservation(failed.id)
    #expect(state.activeSessions(at: now).first?.remainingCount == 2)
    #expect(state.blockingSessions(at: now).count == 1)
    let successful = try state.reserveExemption(at: now)
    try state.commitExemption(successful.id, at: now)
    state.endExemptions(at: now.addingTimeInterval(60))
    #expect(state.blockingSessions(at: now.addingTimeInterval(60)).count == 1)
    #expect(state.activeSessions(at: now).first?.remainingCount == 1)
  }

  @Test func staleReservationCannotUnlockChangedState() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let pending = try state.reserveExemption(at: now)
    #expect(throws: DaywellError.staleReservation) {
      try state.commitExemption(pending.id, at: now.addingTimeInterval(31))
    }
    #expect(state.blockingSessions(at: now).count == 1)
    #expect(state.activeSessions(at: now).first?.remainingCount == 2)
  }

  @Test func exemptionCannotOutlastPeriod() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:59:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let reservation = try state.reserveExemption(at: now)
    try state.commitExemption(reservation.id, at: now)
    #expect(
      state.activeSessions(at: now).first?.exemption?.end == date("2026-11-09T14:00:00+08:00"))
  }

  @Test func editingPolicyApplicationsAndPeriodPreservesActiveSnapshot() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let reservation = try state.reserveExemption(at: now)
    try state.commitExemption(reservation.id, at: now)
    state.policy = try ExemptionPolicy(allowedCount: 5, durationsMinutes: [20, 8, 6, 4, 2])
    state.selectionData = Data([9])
    var edited = state.periods[0]
    edited.end = try ClockTime(hour: 15, minute: 0)
    try state.savePeriod(edited, at: now, calendar: shanghai)
    state.refresh(at: now, calendar: shanghai)
    let current = try #require(state.activeSessions(at: now).first)
    #expect(current.remainingCount == 1)
    #expect(current.selectionData == Data([1]))
    #expect(current.occurrence.end == date("2026-11-09T14:00:00+08:00"))
    let afterOriginalEnd = date("2026-11-09T14:01:00+08:00")
    state.refresh(at: afterOriginalEnd, calendar: shanghai)
    #expect(state.activeSessions(at: afterOriginalEnd).isEmpty)
    let tomorrow = date("2026-11-10T13:01:00+08:00")
    state.refresh(at: tomorrow, calendar: shanghai)
    #expect(state.activeSessions(at: tomorrow).first?.remainingCount == 5)
    #expect(state.activeSessions(at: tomorrow).first?.selectionData == Data([9]))
  }

  @Test func deletionDoesNotClearCurrentRestrictionAndRelaunchPreservesCounts() throws {
    var state = try sampleState()
    let now = date("2026-11-09T13:01:00+08:00")
    state.refresh(at: now, calendar: shanghai)
    let reservation = try state.reserveExemption(at: now)
    try state.commitExemption(reservation.id, at: now)
    state.periods.removeAll()
    var restored = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(state))
    let later = date("2026-11-09T13:11:00+08:00")
    restored.refresh(at: later, calendar: shanghai)
    #expect(restored.blockingSessions(at: later).count == 1)
    #expect(restored.activeSessions(at: later).first?.remainingCount == 1)
  }
}

func sampleState() throws -> DaywellState {
  var state = DaywellState()
  state.selectionData = Data([1])
  state.periods = [
    try LockPeriod(start: ClockTime(hour: 13, minute: 0), end: ClockTime(hour: 14, minute: 0))
  ]
  return state
}
