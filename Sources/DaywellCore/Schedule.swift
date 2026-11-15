import Foundation

public enum DaywellError: LocalizedError, Equatable {
  case invalidTime
  case invalidPeriod
  case overlappingPeriods(candidate: LockPeriod, existing: LockPeriod)
  case deactivationVerificationRequired(sessionIDs: Set<String>)
  case invalidPolicy
  case invalidMorningPolicy
  case noActivePeriod
  case allowanceExhausted
  case fitnessRestrictionActive
  case reservationInProgress
  case staleReservation
  case invalidState
  case stateBusy
  case monitoringCapacityExceeded
  case unsupportedSchema
  case invalidFocusDuration
  case focusApplicationRequired
  case focusUnavailable
  case focusAlreadyActive
  case staleFocusSession

  public var errorDescription: String? {
    switch self {
    case .invalidTime: return String(localized: "时间格式无效。")
    case .invalidPeriod: return String(localized: "请设置不同的开始与结束时间，并至少选择一天。")
    case .overlappingPeriods(let candidate, let existing):
      return
        String(
          localized:
            "「\(candidate.repeatLabel) \(candidate.timeLabel)」与已保存的「\(existing.repeatLabel) \(existing.timeLabel)」重叠。请调整时间或重复星期。"
        )
    case .deactivationVerificationRequired: return String(localized: "此时段正在锁定，请输入验证码后再关闭。")
    case .invalidPolicy: return String(localized: "每个时段可设置 0–5 次豁免，每次时长需为 1–1440 分钟。")
    case .invalidMorningPolicy: return String(localized: "清晨模式的可用时长和锁定时长需为 1–1440 分钟。")
    case .noActivePeriod: return String(localized: "当前没有需要豁免的锁定时段。")
    case .allowanceExhausted: return String(localized: "当前至少有一个时段的豁免机会已用完。")
    case .fitnessRestrictionActive: return String(localized: "组间休息已结束。完成下一组后会开始新的休息。")
    case .reservationInProgress: return String(localized: "正在准备豁免，请稍后重试。")
    case .staleReservation: return String(localized: "锁定状态已变化，请重新发起豁免。")
    case .invalidState: return String(localized: "本地数据无效，已保留原文件，请勿清除数据后重试。")
    case .stateBusy: return String(localized: "锁定状态正在更新，请稍后重试。已保存的设置不会丢失。")
    case .monitoringCapacityExceeded:
      return String(localized: "同时安排的锁定任务过多，无法保证按时恢复。请先关闭部分时段后重试，原有设置已保留。")
    case .unsupportedSchema: return String(localized: "本地数据来自更新版本，请更新 Daywell。")
    case .invalidFocusDuration: return String(localized: "聚焦时长需为 1–1440 的整数分钟。")
    case .focusApplicationRequired: return String(localized: "请先选择一个聚焦应用。")
    case .focusUnavailable: return String(localized: "当前有其他锁定正在执行，结束后可开启聚焦。临时豁免期间也不能开启。")
    case .focusAlreadyActive: return String(localized: "聚焦正在进行，请先结束当前这一轮。")
    case .staleFocusSession: return String(localized: "这轮聚焦已结束，请查看当前状态。")
    }
  }
}

public struct ClockTime: Codable, Hashable, Sendable, Comparable {
  public let hour: Int
  public let minute: Int

  public init(hour: Int, minute: Int) throws {
    guard (0..<24).contains(hour), (0..<60).contains(minute) else {
      throw DaywellError.invalidTime
    }
    self.hour = hour
    self.minute = minute
  }

  public var minutes: Int { hour * 60 + minute }
  public var formatted: String { String(format: "%02d:%02d", hour, minute) }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.minutes < rhs.minutes }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      hour: values.decode(Int.self, forKey: .hour),
      minute: values.decode(Int.self, forKey: .minute))
  }
}

public enum Weekday: Int, CaseIterable, Codable, Sendable {
  case sunday = 1
  case monday, tuesday, wednesday, thursday, friday, saturday
  public static let displayOrder: [Self] = [
    .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
  ]
  public var shortName: String {
    switch self {
    case .sunday: String(localized: "日")
    case .monday: String(localized: "一")
    case .tuesday: String(localized: "二")
    case .wednesday: String(localized: "三")
    case .thursday: String(localized: "四")
    case .friday: String(localized: "五")
    case .saturday: String(localized: "六")
    }
  }
}

public struct PeriodOccurrence: Codable, Equatable, Sendable, Identifiable {
  public let periodID: UUID
  public let start: Date
  public let end: Date
  public var id: String { "\(periodID.uuidString).\(Int64(start.timeIntervalSince1970))" }
  public func contains(_ date: Date) -> Bool { start <= date && date < end }
}

extension PeriodOccurrence {
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let start = try values.decode(Date.self, forKey: .start)
    let end = try values.decode(Date.self, forKey: .end)
    // Validate persisted dates before generating identifiers or system monitor names.
    guard start > .distantPast, end < .distantFuture, start < end else {
      throw DaywellError.invalidState
    }
    self.init(periodID: try values.decode(UUID.self, forKey: .periodID), start: start, end: end)
  }
}

public struct LockPeriod: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var start: ClockTime
  public var end: ClockTime
  public var weekdays: Set<Weekday>
  public var isEnabled: Bool
  public var effectiveAfter: Date?
  public var morningEnabled: Bool

  public init(
    id: UUID = UUID(), start: ClockTime, end: ClockTime,
    weekdays: Set<Weekday> = Set(Weekday.allCases), isEnabled: Bool = true,
    morningEnabled: Bool = false
  ) throws {
    self.id = id
    self.start = start
    self.end = end
    self.weekdays = weekdays
    self.isEnabled = isEnabled
    self.morningEnabled = morningEnabled
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(UUID.self, forKey: .id),
      start: values.decode(ClockTime.self, forKey: .start),
      end: values.decode(ClockTime.self, forKey: .end),
      weekdays: values.decode(Set<Weekday>.self, forKey: .weekdays),
      isEnabled: values.decode(Bool.self, forKey: .isEnabled),
      morningEnabled: values.decodeIfPresent(Bool.self, forKey: .morningEnabled) ?? false)
    effectiveAfter = try values.decodeIfPresent(Date.self, forKey: .effectiveAfter)
  }

  public var crossesMidnight: Bool { end < start }
  public var durationMinutes: Int { (end.minutes - start.minutes + 1440) % 1440 }
  public var timeLabel: String {
    if crossesMidnight {
      return String(localized: "\(start.formatted) – \(end.formatted) 次日")
    }
    return "\(start.formatted) – \(end.formatted)"
  }
  public var repeatLabel: String {
    if weekdays.count == 7 { return String(localized: "每天") }
    if weekdays == Set([.monday, .tuesday, .wednesday, .thursday, .friday]) {
      return String(localized: "工作日")
    }
    if weekdays == Set([.saturday, .sunday]) { return String(localized: "周末") }
    let days = Weekday.displayOrder.filter { weekdays.contains($0) }.map(\.shortName)
    let list = days.joined(separator: String(localized: "、"))
    return String(localized: "周\(list)")
  }

  public func validate() throws {
    guard start != end, !weekdays.isEmpty else { throw DaywellError.invalidPeriod }
  }

  /// Compares recurring wall-clock times, including periods that are disabled.
  func overlaps(_ other: LockPeriod) -> Bool {
    let otherRanges = other.weeklyRanges
    return weeklyRanges.contains { range in
      otherRanges.contains { range.overlaps($0) }
    }
  }

  private var weeklyRanges: [Range<Int>] {
    let minutesPerDay = 24 * 60
    let minutesPerWeek = 7 * minutesPerDay
    return weekdays.flatMap { weekday in
      let lower = (weekday.rawValue - 1) * minutesPerDay + start.minutes
      let upper = lower + durationMinutes
      if upper <= minutesPerWeek { return [lower..<upper] }
      // Saturday nights can extend into the following Sunday.
      return [lower..<minutesPerWeek, 0..<(upper - minutesPerWeek)]
    }
  }

  public func occurrence(containing date: Date, calendar: Calendar) -> PeriodOccurrence? {
    guard isEnabled else { return nil }
    let today = calendar.startOfDay(for: date)
    for offset in [-1, 0] {
      guard let day = calendar.date(byAdding: .day, value: offset, to: today),
        let occurrence = occurrence(startingOn: day, calendar: calendar),
        occurrence.contains(date)
      else { continue }
      return occurrence
    }
    return nil
  }

  public func nextOccurrence(after date: Date, calendar: Calendar) -> PeriodOccurrence? {
    guard isEnabled else { return nil }
    let today = calendar.startOfDay(for: max(date, effectiveAfter ?? date))
    for offset in 0...7 {
      guard let day = calendar.date(byAdding: .day, value: offset, to: today),
        let occurrence = occurrence(startingOn: day, calendar: calendar),
        occurrence.start > date
      else { continue }
      return occurrence
    }
    return nil
  }

  private func occurrence(startingOn day: Date, calendar: Calendar) -> PeriodOccurrence? {
    guard let weekday = Weekday(rawValue: calendar.component(.weekday, from: day)),
      weekdays.contains(weekday),
      let startDate = resolve(start, on: day, calendar: calendar),
      startDate >= (effectiveAfter ?? .distantPast),
      let endDay = calendar.date(byAdding: .day, value: crossesMidnight ? 1 : 0, to: day),
      let endDate = resolve(end, on: endDay, calendar: calendar), endDate > startDate
    else { return nil }
    return PeriodOccurrence(periodID: id, start: startDate, end: endDate)
  }

  private func resolve(_ time: ClockTime, on day: Date, calendar: Calendar) -> Date? {
    // Match DeviceActivity's wall-clock policy, including spring-forward gaps.
    let result = calendar.nextDate(
      after: day.addingTimeInterval(-1),
      matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
      matchingPolicy: .nextTimePreservingSmallerComponents,
      repeatedTimePolicy: .first, direction: .forward)
    guard let result, calendar.isDate(result, inSameDayAs: day) else { return nil }
    return result
  }
}

public struct ExemptionPolicy: Codable, Equatable, Sendable {
  public let allowedCount: Int
  public let durationMinutes: Int
  public let durationsMinutes: [Int]?
  public static let defaultDurations = [10, 5, 3, 2, 1]
  public static let standard = try! ExemptionPolicy(
    allowedCount: 2, durationsMinutes: defaultDurations)

  public init(allowedCount: Int, durationsMinutes: [Int]) throws {
    guard (0...5).contains(allowedCount), durationsMinutes.count == 5,
      durationsMinutes.allSatisfy({ (1...1440).contains($0) })
    else { throw DaywellError.invalidPolicy }
    self.allowedCount = allowedCount
    self.durationMinutes = durationsMinutes[0]
    self.durationsMinutes = durationsMinutes
  }

  // Keep legacy snapshots readable, including active periods with more than five uses.
  public init(allowedCount: Int, durationMinutes: Int) throws {
    guard allowedCount >= 0, (1...1440).contains(durationMinutes) else {
      throw DaywellError.invalidPolicy
    }
    self.allowedCount = allowedCount
    self.durationMinutes = durationMinutes
    self.durationsMinutes = nil
  }

  public func durationMinutes(forUseAt index: Int) -> Int? {
    guard index >= 0, index < allowedCount else { return nil }
    return durationsMinutes?[index] ?? durationMinutes
  }

  public var configuredDurations: [Int] {
    durationsMinutes
      ?? Self.defaultDurations.enumerated().map { index, fallback in
        index < allowedCount ? durationMinutes : fallback
      }
  }

  public var normalizedForConfiguration: Self {
    // Saved custom timings stay intact; only future periods adopt the new five-use cap.
    try! Self(allowedCount: min(allowedCount, 5), durationsMinutes: configuredDurations)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let count = try values.decode(Int.self, forKey: .allowedCount)
    if let durations = try values.decodeIfPresent([Int].self, forKey: .durationsMinutes) {
      try self.init(allowedCount: count, durationsMinutes: durations)
    } else {
      try self.init(
        allowedCount: count, durationMinutes: values.decode(Int.self, forKey: .durationMinutes))
    }
  }
}
