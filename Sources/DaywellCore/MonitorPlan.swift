import Foundation

/// Describes system schedules without importing DeviceActivity, so boundaries can be tested on macOS.
public struct MonitorPlan: Equatable, Sendable {
  public struct UsageThreshold: Equatable, Sendable {
    public static let eventName = "daywell.morning.limit"
    public let selectionData: Data
    public let minutes: Int
  }
  public static let prefix = "daywell."
  public static let fitnessRestPrefix = prefix + "fitness.rest."
  public let name: String
  public let start: DateComponents
  public let end: DateComponents
  public let repeats: Bool
  public let warning: DateComponents?
  public var usage: UsageThreshold? = nil

  public static func endGuardName(for end: Date) -> String {
    prefix + "end." + String(Int64(end.timeIntervalSince1970))
  }

  public static func fitnessRestName(for end: Date) -> String {
    fitnessRestPrefix + String(Int64(ceil(end.timeIntervalSince1970)))
  }

  public static func make(for state: DaywellState, at date: Date, calendar: Calendar) -> [Self] {
    var periods = Dictionary(
      uniqueKeysWithValues: state.periods.filter(\.isEnabled).map { ($0.id, $0) })
    for session in state.activeSessions(at: date) where !session.isMorning {
      periods[session.period.id] = session.period
    }
    var plans = periods.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { period in
      // Keep the start callback at the actual start, including for short periods.
      // Their independent end guard releases the shield before the padded window ends.
      let endMinute = (period.start.minutes + max(period.durationMinutes, 15)) % 1440
      return Self(
        name: prefix + "period." + period.id.uuidString,
        start: DateComponents(hour: period.start.hour, minute: period.start.minute, second: 0),
        end: DateComponents(hour: endMinute / 60, minute: endMinute % 60, second: 0),
        repeats: true, warning: nil)
    }
    var deadlines: [String: Self] = [:]
    func addDeadline(name: String, start: Date, end: Date, startPadding: TimeInterval = 15 * 60) {
      guard end > date else { return }
      var startComponents = calendar.dateComponents(
        [.era, .year, .month, .day, .hour, .minute, .second],
        from: start.addingTimeInterval(-startPadding))
      var endComponents = calendar.dateComponents(
        [.era, .year, .month, .day, .hour, .minute, .second], from: end)
      startComponents.timeZone = calendar.timeZone
      endComponents.timeZone = calendar.timeZone
      deadlines[name] = Self(
        name: name, start: startComponents, end: endComponents,
        repeats: false, warning: nil)
    }
    if state.selectionData != nil, !state.needsApplicationReselection,
      let next = state.periods.compactMap({ $0.nextOccurrence(after: date, calendar: calendar) })
        .min(by: { $0.start < $1.start })
    {
      // Prepare the release before the start callback needs to apply the shield.
      addDeadline(name: endGuardName(for: next.end), start: next.end, end: next.end)
    }
    for session in state.activeSessions(at: date) {
      // A floating daily schedule can move with the device's time zone; this absolute
      // guard preserves the original end even while the app is not running.
      let end = session.occurrence.end
      addDeadline(name: endGuardName(for: end), start: end, end: end)
      if let exemption = session.exemption {
        let name =
          prefix + "grace." + exemption.requestID.uuidString + "."
          + String(Int64(exemption.end.timeIntervalSince1970))
        addDeadline(name: name, start: exemption.start, end: exemption.end)
      }
    }
    if let pending = state.reservation, date < pending.validUntil {
      for grant in pending.grants {
        let name =
          prefix + "grace." + pending.id.uuidString + "."
          + String(Int64(grant.end.timeIntervalSince1970))
        addDeadline(name: name, start: pending.createdAt, end: grant.end)
      }
    }
    if let restEnd = state.fitness?.restEndsAt {
      let boundary = Date(timeIntervalSince1970: ceil(restEnd.timeIntervalSince1970))
      if boundary > date {
        // Start at the deadline so the first use after an idle rest can wake the monitor.
        addDeadline(
          name: fitnessRestName(for: restEnd), start: boundary,
          end: boundary.addingTimeInterval(24 * 60 * 60), startPadding: 0)
      }
    }
    plans.append(contentsOf: deadlines.values.sorted { $0.name < $1.name })
    var usageCalendar = Calendar(identifier: .gregorian)
    usageCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    for window in state.morningWindows where window.end > date {
      guard !state.needsApplicationReselection, !window.selectionData.isEmpty,
        !state.sessions.contains(where: { $0.morningSourceID == window.id })
      else { continue }
      // Keep the registration identical across device time-zone changes, otherwise
      // startMonitoring would replace the event and lose accumulated usage.
      var start = usageCalendar.dateComponents(
        [.era, .year, .month, .day, .hour, .minute, .second], from: window.start)
      // Pad only the end of short windows: usage must never include the preceding sleep.
      var end = usageCalendar.dateComponents(
        [.era, .year, .month, .day, .hour, .minute, .second],
        from: max(window.end, window.start.addingTimeInterval(15 * 60)))
      start.timeZone = usageCalendar.timeZone
      end.timeZone = usageCalendar.timeZone
      plans.append(
        Self(
          name: window.monitorName, start: start, end: end, repeats: false,
          warning: nil,
          usage: UsageThreshold(
            selectionData: window.selectionData, minutes: window.morning.usageMinutes))
      )
    }
    return plans
  }
}
