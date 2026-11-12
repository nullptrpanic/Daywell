import DaywellCore
import DeviceActivity
import Foundation
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
    reconcileWithRetry {
      try ScreenTimeService().reachMorningLimit(activity: activity, event: event)
    }
  }

  private func reconcile(_ activity: DeviceActivityName) {
    logger.debug("Received activity callback \(activity.rawValue, privacy: .private(mask: .hash))")
    reconcileWithRetry {
      let service = try ScreenTimeService()
      if activity.rawValue.hasPrefix(MonitorPlan.fitnessRestPrefix) {
        try service.reachFitnessDeadline(activity: activity)
      } else {
        try service.refresh()
      }
    }
  }

  private func reconcileWithRetry(_ operation: () throws -> Void) {
    // Complete retries while the extension callback is alive. A detached timer can
    // be suspended immediately after returning. The state lock itself has a 1 s
    // timeout, so retries remain bounded and never wait indefinitely for the app.
    for attempt in 0..<3 {
      do {
        try operation()
        return
      } catch {
        switch error {
        case DaywellError.stateBusy, ScreenTimeError.configurationChanged:
          if attempt < 2 {
            Thread.sleep(forTimeInterval: 0.05)
            continue
          }
        default: break
        }
        // Recompute and remove only expired restrictions on a successful retry;
        // never clear another feature's valid lock just because this call failed.
        logger.error(
          "Unable to reconcile Screen Time: \(error.localizedDescription, privacy: .public)")
        return
      }
    }
  }
}
