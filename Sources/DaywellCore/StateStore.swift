import Darwin
import Foundation

/// A shared file lock protects the complete read-modify-write transaction across app processes.
public final class StateStore: @unchecked Sendable {
  private let directory: URL
  private var stateURL: URL { directory.appendingPathComponent("state.json") }

  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  // Atomic replacement exposes either the previous or the next complete file.
  // Shield UI callbacks must be able to read it while a writer applies restrictions.
  public func read() throws -> DaywellState { try load() }

  /// A system monitor call may call the extension before returning. Reentrant
  /// callbacks save their state but must not wait for, or reenter, that call.
  public func coordinateMonitoring<Value>(_ operation: () throws -> Value) throws -> Value {
    try withLock(name: "monitoring.lock", timeout: .zero, operation)
  }

  @discardableResult
  public func transaction<Value>(
    _ update: (inout DaywellState) throws -> Value,
    afterSave: (DaywellState) throws -> Void = { _ in }
  ) throws -> (state: DaywellState, value: Value) {
    try withLock {
      var state = try load()
      let original = state
      let value = try update(&state)
      try state.validate()
      if state != original {
        guard original.revision < UInt64.max else { throw DaywellError.invalidState }
        state.revision = original.revision + 1
        let data = try JSONEncoder().encode(state)
        #if os(iOS)
          try data.write(
            to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
          try data.write(to: stateURL, options: .atomic)
        #endif
      }
      // Apply shields only after durable state, while the same lock prevents stale writers.
      try afterSave(state)
      return (state, value)
    }
  }

  private func load() throws -> DaywellState {
    let data: Data
    do {
      data = try Data(contentsOf: stateURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return DaywellState()
    }
    var state = try JSONDecoder().decode(DaywellState.self, from: data)
    try state.validate()
    state.policy = state.policy.normalizedForConfiguration
    return state
  }

  private func withLock<Value>(
    name: String = "state.lock", timeout: Duration = .seconds(1), _ body: () throws -> Value
  ) throws -> Value {
    let descriptor = open(
      directory.appendingPathComponent(name).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let failure = errno
      if failure != EINTR && failure != EWOULDBLOCK && failure != EAGAIN {
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
      }
      guard ContinuousClock.now < deadline else { throw DaywellError.stateBusy }
      usleep(10_000)
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }
}
