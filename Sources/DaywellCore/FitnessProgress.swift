import Foundation

public struct FitnessProgress: Codable, Equatable, Sendable {
  public static let defaultTargetGroups = 6
  public static let targetRange = 1...99

  public private(set) var targetGroups: Int
  public private(set) var completedGroups: Int

  public init(targetGroups: Int = defaultTargetGroups, completedGroups: Int = 0) {
    self.targetGroups = min(
      max(targetGroups, Self.targetRange.lowerBound), Self.targetRange.upperBound)
    self.completedGroups = (0..<self.targetGroups).contains(completedGroups) ? completedGroups : 0
  }

  /// Returns true exactly when this group finishes a round. The next round starts at zero.
  @discardableResult
  public mutating func completeGroup() -> Bool {
    completedGroups += 1
    guard completedGroups == targetGroups else { return false }
    completedGroups = 0
    return true
  }

  public mutating func reset() {
    completedGroups = 0
  }

  public mutating func setTargetGroups(_ value: Int) {
    let target = min(max(value, Self.targetRange.lowerBound), Self.targetRange.upperBound)
    guard target != targetGroups else { return }
    targetGroups = target
    reset()
  }
}

public struct FitnessTraining: Codable, Equatable, Sendable {
  public static let inactivitySeconds: TimeInterval = 30 * 60
  public static let restStepSeconds = 30
  public static let restSecondsRange = 30...3600

  public private(set) var progress: FitnessProgress
  public private(set) var restEnabled: Bool
  public private(set) var restSeconds: Int
  public private(set) var restEndsAt: Date?
  public private(set) var lastCompletedAt: Date?
  public private(set) var locksAfterRest = true
  public var inactivityEndsAt: Date? {
    progress.completedGroups > 0 ? lastCompletedAt?.addingTimeInterval(Self.inactivitySeconds) : nil
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    progress = try values.decode(FitnessProgress.self, forKey: .progress)
    restEnabled = try values.decode(Bool.self, forKey: .restEnabled)
    restSeconds = try values.decode(Int.self, forKey: .restSeconds)
    restEndsAt = try values.decodeIfPresent(Date.self, forKey: .restEndsAt)
    lastCompletedAt =
      try values.decodeIfPresent(Date.self, forKey: .lastCompletedAt)
      ?? restEndsAt?.addingTimeInterval(-Double(restSeconds))
    locksAfterRest = try values.decodeIfPresent(Bool.self, forKey: .locksAfterRest) ?? true
  }

  public init(progress: FitnessProgress = FitnessProgress(), restEnabled: Bool = false) {
    self.progress = progress
    self.restEnabled = restEnabled
    self.restSeconds = Self.restSecondsRange.lowerBound
  }

  @discardableResult
  public mutating func completeGroup(at date: Date) -> Bool {
    lastCompletedAt = date
    locksAfterRest = true
    let finished = progress.completeGroup()
    restEndsAt = restEnabled && !finished ? date.addingTimeInterval(Double(restSeconds)) : nil
    return finished
  }

  public mutating func reset() {
    progress.reset()
    restEndsAt = nil
    lastCompletedAt = nil
    locksAfterRest = true
  }

  public mutating func setTargetGroups(_ value: Int) {
    let previous = progress.targetGroups
    progress.setTargetGroups(value)
    if progress.targetGroups != previous { reset() }
  }

  public mutating func setRestEnabled(_ enabled: Bool) {
    restEnabled = enabled
    if !enabled { restEndsAt = nil }
  }

  public mutating func setRestSeconds(_ seconds: Int) {
    let bounded = min(
      max(seconds, Self.restSecondsRange.lowerBound), Self.restSecondsRange.upperBound)
    restSeconds = bounded - bounded % Self.restStepSeconds
  }

  public func restSecondsRemaining(at date: Date) -> Int? {
    restEndsAt.map { Int(max(0, ceil($0.timeIntervalSince(date)))) }
  }

  public func isLocked(at date: Date) -> Bool {
    guard locksAfterRest, let restEndsAt, let inactivityEndsAt else { return false }
    return restEndsAt <= date && date < inactivityEndsAt
  }

  public mutating func refresh(at date: Date) {
    // Old versions did not save a timestamp for counters with rest disabled.
    if progress.completedGroups > 0, lastCompletedAt == nil { lastCompletedAt = date }
    if let inactivityEndsAt, date >= inactivityEndsAt { reset() }
  }

  mutating func suppressLocking() { locksAfterRest = false }

  func validate() throws {
    guard
      FitnessProgress(
        targetGroups: progress.targetGroups, completedGroups: progress.completedGroups) == progress,
      Self.restSecondsRange.contains(restSeconds), restSeconds.isMultiple(of: Self.restStepSeconds)
    else { throw DaywellError.invalidState }
    if let lastCompletedAt {
      guard lastCompletedAt > .distantPast, lastCompletedAt < .distantFuture else {
        throw DaywellError.invalidState
      }
    }
    if let restEndsAt {
      guard restEnabled, progress.completedGroups > 0,
        restEndsAt > .distantPast, restEndsAt < .distantFuture
      else { throw DaywellError.invalidState }
    }
  }
}
