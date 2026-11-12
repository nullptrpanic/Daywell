import Darwin
import Foundation

// The real service and state store are compiled against these SDK boundaries.
// Synchronous monitor callbacks exercise the real cross-process file-lock contract.
enum World {
  static var directory: URL!
  static var callsUnderLock: [String] = []
  static var monitoringCallInProgress = false
  static var reentrantCalls: [String] = []
  static var callbackErrors: [String] = []
  static var onStart: (() throws -> Void)?
  static var onStop: (() throws -> Void)?
  static var rejectGrace = false
  static var rejectFitness = false
  static var rejectFitnessIdle = false
  static var monitorLimit: Int?
  static var startCounts: [DeviceActivityName: Int] = [:]
  static var onShieldChange: (() -> Void)?
  static var mainThreadInitializations = 0
  static func deviceActivityCall(_ name: String) {
    if monitoringCallInProgress { reentrantCalls.append(name) }
    let fd = open(directory.appendingPathComponent("state.lock").path, O_RDWR)
    guard fd >= 0 else { return }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      _ = flock(fd, LOCK_UN)
    } else {
      callsUnderLock.append(name)
    }
  }
}
typealias ApplicationToken = Int
typealias ActivityCategoryToken = Int
typealias WebDomainToken = Int
struct FamilyActivitySelection: Codable, Equatable {
  let includeEntireCategory: Bool
  var applicationTokens: Set<Int> = []
  var categoryTokens: Set<Int> = []
  var webDomainTokens: Set<Int> = []
}
enum FamilyControlsError: Error { case authorizationCanceled, unauthorized }
enum AuthStatus { case approved, approvedWithDataAccess, denied, notDetermined }
enum FamilyMember { case individual }
@MainActor final class AuthorizationCenter {
  static let shared = AuthorizationCenter()
  var authorizationStatus = AuthStatus.approved
  var requestError: Error?
  var authorizationRequests = 0
  func requestAuthorization(for member: FamilyMember) async throws {
    authorizationRequests += 1
    if let requestError { throw requestError }
    authorizationStatus = .approved
  }
}
struct DeviceActivityName: Hashable {
  let rawValue: String
  init(_ rawValue: String) { self.rawValue = rawValue }
}
struct DeviceActivitySchedule: Equatable {
  let intervalStart: DateComponents
  let intervalEnd: DateComponents
  let repeats: Bool
  let warningTime: DateComponents?
}
struct DeviceActivityEvent: Equatable {
  struct Name: Hashable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
  }
  let applications: Set<Int>
  let categories: Set<Int>
  let webDomains: Set<Int>
  let threshold: DateComponents
}
struct DeviceActivityCenter {
  enum MonitoringError: Error { case excessiveActivities }
  static var schedules: [DeviceActivityName: DeviceActivitySchedule] = [:]
  static var registeredEvents:
    [DeviceActivityName: [DeviceActivityEvent.Name: DeviceActivityEvent]] = [:]
  var activities: [DeviceActivityName] {
    World.deviceActivityCall("activities")
    return Array(Self.schedules.keys)
  }
  func schedule(for name: DeviceActivityName) -> DeviceActivitySchedule? {
    World.deviceActivityCall("schedule")
    return Self.schedules[name]
  }
  func events(for name: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
    World.deviceActivityCall("events")
    return Self.registeredEvents[name] ?? [:]
  }
  func startMonitoring(
    _ name: DeviceActivityName, during schedule: DeviceActivitySchedule,
    events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
  ) throws {
    World.deviceActivityCall("startMonitoring")
    if World.rejectGrace && name.rawValue.contains(".grace.") { throw POSIXError(.EIO) }
    if World.rejectFitness && name.rawValue.hasPrefix(MonitorPlan.fitnessRestPrefix) {
      throw POSIXError(.EIO)
    }
    if World.rejectFitnessIdle && name.rawValue.hasPrefix(MonitorPlan.fitnessIdlePrefix) {
      throw POSIXError(.EIO)
    }
    if let limit = World.monitorLimit, Self.schedules[name] == nil, Self.schedules.count >= limit {
      throw MonitoringError.excessiveActivities
    }
    World.startCounts[name, default: 0] += 1
    Self.schedules[name] = schedule
    Self.registeredEvents[name] = events
    if let callback = World.onStart {
      World.onStart = nil
      World.monitoringCallInProgress = true
      defer { World.monitoringCallInProgress = false }
      try callback()
    }
  }
  func stopMonitoring(_ names: [DeviceActivityName]) {
    World.deviceActivityCall("stopMonitoring")
    for name in names {
      Self.schedules[name] = nil
      Self.registeredEvents[name] = nil
    }
    if let callback = World.onStop {
      World.onStop = nil
      World.monitoringCallInProgress = true
      defer { World.monitoringCallInProgress = false }
      do { try callback() } catch { World.callbackErrors.append(error.localizedDescription) }
    }
  }
}
class DeviceActivityMonitor {
  func intervalDidStart(for activity: DeviceActivityName) {}
  func intervalDidEnd(for activity: DeviceActivityName) {}
  func intervalWillEndWarning(for activity: DeviceActivityName) {}
  func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {}
}
final class FakeShield {
  enum CategoryPolicy: Equatable {
    case all(except: Set<Int> = [])
    case specific(Set<Int>, except: Set<Int> = [])
  }
  var applications: Set<Int>? { didSet { World.onShieldChange?() } }
  var applicationCategories: CategoryPolicy?
  var webDomains: Set<Int>?
  var webDomainCategories: CategoryPolicy?
}
final class ManagedSettingsStore {
  struct Name: Hashable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
  }
  static var stores: [Name: FakeShield] = [:]
  let shield: FakeShield
  init(named name: Name) {
    if Thread.isMainThread { World.mainThreadInitializations += 1 }
    if let existing = Self.stores[name] {
      shield = existing
    } else {
      shield = FakeShield()
      Self.stores[name] = shield
    }
  }
  func clearAllSettings() {
    shield.applications = nil
    shield.applicationCategories = nil
    shield.webDomains = nil
    shield.webDomainCategories = nil
  }
}
