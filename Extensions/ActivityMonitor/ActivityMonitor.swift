import DaywellCore
import DeviceActivity
import OSLog

final class ActivityMonitor: DeviceActivityMonitor {
  private let logger = Logger(subsystem: "com.nullptrpanic.Daywell", category: "ActivityMonitor")

  override func intervalDidStart(for activity: DeviceActivityName) {
    super.intervalDidStart(for: activity)
    reconcile(activity)
  }

  override func intervalDidEnd(for activity: DeviceActivityName) {
    super.intervalDidEnd(for: activity)
    reconcile(activity)
  }

  override func intervalWillEndWarning(for activity: DeviceActivityName) {
    super.intervalWillEndWarning(for: activity)
    reconcile(activity)
  }

  override func eventDidReachThreshold(
    _ event: DeviceActivityEvent.Name, activity: DeviceActivityName
  ) {
    super.eventDidReachThreshold(event, activity: activity)
    do {
      try ScreenTimeService().reachMorningLimit(activity: activity, event: event)
    } catch {
      logger.error("Unable to start morning break: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func reconcile(_ activity: DeviceActivityName) {
    logger.debug("Received activity callback \(activity.rawValue, privacy: .private(mask: .hash))")
    do {
      let service = try ScreenTimeService()
      if activity.rawValue.hasPrefix(MonitorPlan.fitnessRestPrefix) {
        try service.reachFitnessDeadline(activity: activity)
      } else {
        try service.refresh()
      }
    } catch {
      // Retain existing shields on failure. Never clear all restrictions on a single period's end.
      logger.error(
        "Unable to reconcile Screen Time: \(error.localizedDescription, privacy: .public)")
    }
  }
}
