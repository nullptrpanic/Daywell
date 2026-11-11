import DaywellCore
import Foundation

enum ScreenTimeError: LocalizedError {
  case previewUnavailable

  var errorDescription: String? {
    "免费预览版可编辑时段和豁免设置，不支持应用圈选、实际锁定或临时解锁。"
  }
}

/// The free target stores settings locally without creating Screen Time clients or extensions.
final class ScreenTimeService: @unchecked Sendable {
  static let isFreePreview = true
  static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      true
    #else
      false
    #endif
  }

  private let storage: StateStore
  var isFitnessShieldApplied: Bool { false }

  init() throws {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).appendingPathComponent("DaywellPreview", isDirectory: true)
    storage = try StateStore(directory: directory)
  }

  func read() throws -> DaywellState { try storage.read() }
  func refresh() throws -> DaywellState { try read() }

  func savePeriod(_ period: LockPeriod, verifiedSessionIDs: Set<String>) throws -> DaywellState {
    try storage.transaction {
      try $0.savePeriod(
        period, at: Date(), calendar: .current, verifiedSessionIDs: verifiedSessionIDs)
    }.state
  }

  func removePeriod(_ id: UUID) throws -> DaywellState {
    try storage.transaction {
      $0.removePeriod(id, at: Date(), calendar: .current)
    }.state
  }

  func savePolicy(_ policy: ExemptionPolicy) throws -> DaywellState {
    try storage.transaction { $0.policy = policy.normalizedForConfiguration }.state
  }

  func saveMorningPolicy(_ policy: MorningPolicy) throws -> DaywellState {
    try storage.transaction { $0.morningPolicy = policy }.state
  }

  func updateFitness(
    initial: FitnessTraining, _ change: (inout FitnessTraining) -> Void
  ) throws -> DaywellState {
    try storage.transaction { $0.updateFitness(initial: initial, change) }.state
  }

  func beginExemption() throws -> DaywellState { throw ScreenTimeError.previewUnavailable }
  func endExemptions() throws -> DaywellState { throw ScreenTimeError.previewUnavailable }
}
