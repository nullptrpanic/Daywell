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
  public static let restStepSeconds = 30
  public static let restSecondsRange = 30...3600

  public private(set) var progress: FitnessProgress
  public private(set) var restEnabled: Bool
  public private(set) var restSeconds: Int
  public private(set) var restEndsAt: Date?

  public init(progress: FitnessProgress = FitnessProgress(), restEnabled: Bool = false) {
    self.progress = progress
    self.restEnabled = restEnabled
    self.restSeconds = Self.restSecondsRange.lowerBound
  }

  @discardableResult
  public mutating func completeGroup(at date: Date) -> Bool {
    let finished = progress.completeGroup()
    restEndsAt = restEnabled && !finished ? date.addingTimeInterval(Double(restSeconds)) : nil
    return finished
  }

  public mutating func reset() {
    progress.reset()
    restEndsAt = nil
  }

  public mutating func setTargetGroups(_ value: Int) {
    let previous = progress.targetGroups
    progress.setTargetGroups(value)
    if progress.targetGroups != previous { restEndsAt = nil }
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
    restEndsAt.map { $0 <= date } ?? false
  }

  func validate() throws {
    guard
      FitnessProgress(
        targetGroups: progress.targetGroups, completedGroups: progress.completedGroups) == progress,
      Self.restSecondsRange.contains(restSeconds), restSeconds.isMultiple(of: Self.restStepSeconds)
    else { throw DaywellError.invalidState }
    if let restEndsAt {
      guard restEnabled, progress.completedGroups > 0,
        restEndsAt > .distantPast, restEndsAt < .distantFuture
      else { throw DaywellError.invalidState }
    }
  }
}
