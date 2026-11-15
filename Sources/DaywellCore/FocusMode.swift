import Foundation

public struct FocusConfiguration: Codable, Equatable, Sendable {
  public static let minutesRange = 1...1440
  public private(set) var minutes = 90
  public var applicationData: Data?
  public internal(set) var recentApplications: [Data] = []

  public init() {}

  public mutating func setMinutes(_ minutes: Int) throws {
    guard Self.minutesRange.contains(minutes) else { throw DaywellError.invalidFocusDuration }
    self.minutes = minutes
  }

  func validate() throws {
    guard Self.minutesRange.contains(minutes), applicationData?.isEmpty != true,
      recentApplications.count <= 5,
      Set(recentApplications).count == recentApplications.count,
      recentApplications.allSatisfy({ !$0.isEmpty })
    else { throw DaywellError.invalidState }
  }
}

public struct FocusSession: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let applicationData: Data
  public let start: Date
  public let end: Date
  public var monitorName: String { MonitorPlan.prefix + "focus.end." + id.uuidString }

  public func contains(_ date: Date) -> Bool { start <= date && date < end }

  public func secondsRemaining(at date: Date) -> Int {
    // The UI's last clock tick may precede this round's start.
    Int(min(86400, max(0, ceil(end.timeIntervalSince(max(date, start))))))
  }

  func validate() throws {
    guard !applicationData.isEmpty, start > .distantPast, end < .distantFuture,
      start < end, end.timeIntervalSince(start) <= 86401
    else { throw DaywellError.invalidState }
  }
}

extension DaywellState {
  public func hasFocusRestriction(at date: Date) -> Bool {
    hadAuthorization && focusSession?.contains(date) == true
      && activeSessions(at: date).isEmpty && !hasFitnessRestriction(at: date)
  }

  public mutating func startFocus(at date: Date, calendar: Calendar) throws {
    guard let applicationData = focusConfiguration.applicationData else {
      throw DaywellError.focusApplicationRequired
    }
    let end = date.addingTimeInterval(Double(focusConfiguration.minutes) * 60)
    try commitFocus(
      FocusSession(id: UUID(), applicationData: applicationData, start: date, end: end),
      at: date, calendar: calendar)
  }

  /// Commit exactly the round whose release monitor the platform has already installed.
  public mutating func commitFocus(_ session: FocusSession, at date: Date, calendar: Calendar)
    throws
  {
    refresh(at: date, calendar: calendar)
    guard focusSession == nil else { throw DaywellError.focusAlreadyActive }
    guard activeSessions(at: date).isEmpty, fitness?.isLocked(at: date) != true else {
      throw DaywellError.focusUnavailable
    }
    try focusConfiguration.validate()
    try session.validate()
    guard session.applicationData == focusConfiguration.applicationData, session.contains(date),
      session.end.timeIntervalSince(session.start) >= Double(focusConfiguration.minutes * 60),
      session.end.timeIntervalSince(session.start) < Double(focusConfiguration.minutes * 60 + 1)
    else { throw DaywellError.staleFocusSession }
    focusSession = session
    let applicationData = session.applicationData
    focusConfiguration.recentApplications.removeAll { $0 == applicationData }
    focusConfiguration.recentApplications.insert(applicationData, at: 0)
    focusConfiguration.recentApplications = Array(focusConfiguration.recentApplications.prefix(5))
  }

  public mutating func endFocus(id: UUID) throws {
    guard focusSession?.id == id else { throw DaywellError.staleFocusSession }
    focusSession = nil
  }

  /// Evaluate before pruning an expired workout and after catching up missed sleep intervals.
  /// Temporary exemptions do not change ownership. A cancelled focus is never restored.
  mutating func reconcileFocus(at date: Date) {
    guard let focus = focusSession else { return }
    let higherSessionOccurred = sessions.contains {
      $0.occurrence.start <= date && $0.occurrence.start < focus.end
        && min($0.cancelledAt ?? $0.occurrence.end, $0.occurrence.end) > focus.start
    }
    let workoutOccurred: Bool
    if let training = fitness, training.locksAfterRest,
      let restEnd = training.restEndsAt, let idleEnd = training.inactivityEndsAt
    {
      workoutOccurred =
        restEnd < idleEnd && restEnd <= date
        && restEnd < focus.end && idleEnd > focus.start
    } else {
      workoutOccurred = false
    }
    if date >= focus.end || higherSessionOccurred || workoutOccurred {
      focusSession = nil
    }
  }
}
