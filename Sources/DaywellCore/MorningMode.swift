import Foundation

public struct MorningPolicy: Codable, Equatable, Sendable {
  public let usageMinutes: Int
  public let lockMinutes: Int
  public static let standard = try! Self(usageMinutes: 10, lockMinutes: 30)

  public init(usageMinutes: Int, lockMinutes: Int) throws {
    guard (1...1440).contains(usageMinutes), (1...1440).contains(lockMinutes) else {
      throw DaywellError.invalidMorningPolicy
    }
    self.usageMinutes = usageMinutes
    self.lockMinutes = lockMinutes
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      usageMinutes: values.decode(Int.self, forKey: .usageMinutes),
      lockMinutes: values.decode(Int.self, forKey: .lockMinutes))
  }
}

/// Prepared before sleep ends, so the OS can accumulate usage without launching Daywell.
/// Timing and policies stay stable after sleep begins; selection additions are allowed until usage starts.
public struct MorningWindow: Codable, Equatable, Sendable, Identifiable {
  public let period: LockPeriod
  public let sleep: PeriodOccurrence
  public let end: Date
  public internal(set) var selectionData: Data
  public let policy: ExemptionPolicy
  public let morning: MorningPolicy
  public var id: String { sleep.id }
  public var start: Date { sleep.end }
  public var monitorName: String { MonitorPlan.prefix + "morning." + id }
  public func contains(_ date: Date) -> Bool { start <= date && date < end }
}

extension DaywellState {
  public func pendingMornings(at date: Date) -> [MorningWindow] {
    morningWindows.filter { window in
      window.contains(date) && !sessions.contains { $0.morningSourceID == window.id }
    }
  }

  public mutating func reachMorningLimit(monitorName: String, at date: Date, calendar: Calendar) {
    refresh(at: date, calendar: calendar)
    guard !needsApplicationReselection,
      let window = morningWindows.first(where: { $0.monitorName == monitorName }),
      !window.selectionData.isEmpty,
      window.contains(date),
      date >= window.start.addingTimeInterval(Double(window.morning.usageMinutes) * 60),
      !sessions.contains(where: { $0.morningSourceID == window.id })
    else { return }
    // Repeated or delayed callbacks must never restart this lock or replenish exemptions.
    let end = Date(
      timeIntervalSince1970: ceil(
        date.timeIntervalSince1970 + Double(window.morning.lockMinutes) * 60))
    sessions.append(
      LockSession(
        period: window.period,
        occurrence: PeriodOccurrence(periodID: window.period.id, start: date, end: end),
        selectionData: window.selectionData, policy: window.policy, morningSourceID: window.id))
  }

  mutating func prepareMornings(at date: Date, calendar: Calendar) {
    let retention = date.addingTimeInterval(-8 * 24 * 60 * 60)
    morningWindows.removeAll { window in
      (window.end < retention && !sessions.contains { $0.morningSourceID == window.id })
        || (window.sleep.start > date && !sessions.contains { $0.morningSourceID == window.id })
    }
    guard let selectionData, !needsApplicationReselection else { return }

    func window(
      period: LockPeriod, sleep: PeriodOccurrence, selection: Data, policy: ExemptionPolicy
    ) -> MorningWindow? {
      guard period.morningEnabled,
        let next = period.nextOccurrence(after: sleep.end, calendar: calendar), next.start > date
      else { return nil }
      return MorningWindow(
        period: period, sleep: sleep, end: next.start,
        selectionData: selection, policy: policy, morning: morningPolicy)
    }

    var candidates = sessions.filter { !$0.isMorning }.compactMap { session in
      window(
        period: session.period, sleep: session.occurrence,
        selection: session.selectionData, policy: session.policy)
    }
    candidates += periods.compactMap { period in
      guard let sleep = period.nextOccurrence(after: date, calendar: calendar) else { return nil }
      return window(
        period: period, sleep: sleep, selection: selectionData,
        policy: policy.normalizedForConfiguration)
    }
    for candidate in candidates where !morningWindows.contains(where: { $0.id == candidate.id }) {
      morningWindows.append(candidate)
    }
    morningWindows.sort { $0.id < $1.id }
  }
}
