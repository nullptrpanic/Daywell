import Darwin
import Foundation
import Testing

@testable import DaywellCore

struct StateStoreTests {
  @Test(.enabled(if: getuid() != 0))
  func inaccessibleStateIsReportedInsteadOfLoadingAnEmptyConfiguration() throws {
    let directory = temporaryDirectory()
    let store = try StateStore(directory: directory)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: directory)
    }
    try store.transaction { $0.selectionData = Data([7]) }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)

    #expect(throws: (any Error).self) { try store.read() }

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #expect(try store.read().selectionData == Data([7]))
    #expect(try store.read().revision == 1)
  }

  @Test func monitoringCoordinationNeverWaitsAndLeavesStateAvailableToCallbacks() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = try StateStore(directory: directory)
    let callback = try StateStore(directory: directory)
    try owner.coordinateMonitoring {
      let start = ContinuousClock.now
      #expect(throws: DaywellError.stateBusy) {
        try callback.coordinateMonitoring { Issue.record("Reentered monitor scheduling") }
      }
      #expect(start.duration(to: .now) < .milliseconds(500))
      try callback.transaction { $0.selectionData = Data([7]) }
      #expect(try owner.read().selectionData == Data([7]))
    }
    #expect(throws: DaywellError.invalidState) {
      try callback.coordinateMonitoring { throw DaywellError.invalidState }
    }
    let result = try owner.coordinateMonitoring { try owner.read().selectionData }
    #expect(result == Data([7]))
  }

  @Test func readingCommittedStateDoesNotWaitForAShieldWriter() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    try store.transaction { $0.selectionData = Data([7]) }
    try withContendedStateLock(in: directory) {
      let start = ContinuousClock.now
      let snapshot = try store.read()
      #expect(start.duration(to: .now) < .seconds(1))
      #expect(snapshot.selectionData == Data([7]))
      #expect(snapshot.revision == 1)
    }
  }

  @Test func aBusyWriterFailsPromptlyWithoutChangingCommittedState() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    try store.transaction { $0.selectionData = Data([7]) }
    try withContendedStateLock(in: directory) {
      let start = ContinuousClock.now
      #expect(throws: (any Error).self) {
        try store.transaction { $0.selectionData = nil }
      }
      #expect(start.duration(to: .now) < .milliseconds(1800))
    }
    #expect(try store.read().selectionData == Data([7]))
    try store.transaction { $0.selectionData = Data([8]) }
    #expect(try store.read().selectionData == Data([8]))
  }

  @Test func simultaneousExemptionRequestsConsumeOnlyOneUse() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    let now = date("2026-11-09T13:01:00+08:00")
    try store.transaction { state in
      state = try sampleState()
      state.refresh(at: now, calendar: shanghai)
    }
    let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
      for _ in 0..<2 {
        group.addTask {
          let client = try StateStore(directory: directory)
          do {
            let reservation = try client.transaction { try $0.reserveExemption(at: now) }.value
            try client.transaction { try $0.commitExemption(reservation.id, at: now) }
            return true
          } catch DaywellError.reservationInProgress { return false } catch DaywellError
            .noActivePeriod
          { return false }
        }
      }
      var count = 0
      for try await success in group where success { count += 1 }
      return count
    }
    #expect(successes == 1)
    #expect(try store.read().activeSessions(at: now).first?.remainingCount == 1)
  }

  @Test func persistedExemptionSurvivesASecondStoreInstance() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    let now = date("2026-11-09T13:01:00+08:00")
    try store.transaction { state in
      state = try sampleState()
      state.refresh(at: now, calendar: shanghai)
      let pending = try state.reserveExemption(at: now)
      try state.commitExemption(pending.id, at: now)
    }
    let restored = try StateStore(directory: directory).read()
    #expect(restored.activeSessions(at: now).first?.remainingCount == 1)
    #expect(restored.blockingSessions(at: now).isEmpty)
  }

  @Test func concurrentTransactionsDoNotLoseChanges() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for minute in 0..<30 {
        group.addTask {
          let independent = try StateStore(directory: directory)
          try independent.transaction { state in
            state.periods.append(
              try LockPeriod(
                start: ClockTime(hour: 12, minute: minute),
                end: ClockTime(hour: 14, minute: 0)))
          }
        }
      }
      try await group.waitForAll()
    }
    let result = try store.read()
    #expect(result.periods.count == 30)
    #expect(result.revision == 30)
  }

  @Test func failedTransactionDoesNotPersistOrApplyEffects() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    var applied = false
    #expect(throws: DaywellError.invalidState) {
      try store.transaction(
        { state in
          state.policy = try ExemptionPolicy(allowedCount: 9, durationMinutes: 15)
          throw DaywellError.invalidState
        }, afterSave: { _ in applied = true })
    }
    #expect(try store.read().policy.allowedCount == 2)
    #expect(!applied)
  }

  @Test func corruptFileIsNotSilentlyReset() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    let file = directory.appendingPathComponent("state.json")
    let damaged = Data("broken json".utf8)
    try damaged.write(to: file)
    #expect(throws: (any Error).self) { try store.read() }
    #expect(throws: (any Error).self) { try store.transaction { $0.selectionData = nil } }
    #expect(try Data(contentsOf: file) == damaged)
  }

  @Test func outOfRangeSavedDatesAreRejectedWithoutOverwritingTheFile() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    var state = try sampleState()
    state.refresh(at: date("2026-11-09T13:01:00+08:00"), calendar: shanghai)
    var document = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    var sessions = try #require(document["sessions"] as? [[String: Any]])
    var occurrence = try #require(sessions.first?["occurrence"] as? [String: Any])
    occurrence["start"] = 1e30
    occurrence["end"] = 2e30
    sessions[0]["occurrence"] = occurrence
    document["sessions"] = sessions
    let damaged = try JSONSerialization.data(withJSONObject: document)
    let file = directory.appendingPathComponent("state.json")
    try damaged.write(to: file, options: .atomic)

    #expect(throws: DaywellError.invalidState) { try store.read() }
    #expect(throws: DaywellError.invalidState) { try store.transaction { $0.selectionData = nil } }
    #expect(try Data(contentsOf: file) == damaged)
  }
}

private func withContendedStateLock(in directory: URL, _ operation: () throws -> Void) throws {
  let descriptor = open(directory.appendingPathComponent("state.lock").path, O_RDWR)
  guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
  let released = DispatchSemaphore(value: 0)
  DispatchQueue.global().asyncAfter(deadline: .now() + 2.2) {
    _ = flock(descriptor, LOCK_UN)
    released.signal()
  }
  defer {
    released.wait()
    close(descriptor)
  }
  try operation()
}

func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "DaywellTests-\(UUID().uuidString)", isDirectory: true)
}
