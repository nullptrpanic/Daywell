import DaywellCore
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import OSLog

enum ScreenTimeError: LocalizedError {
  case appGroupUnavailable
  case authorizationRequired
  case simulator
  case configurationChanged
  case emptySelection
  case selectionLimitExceeded
  case activeSelectionLimitExceeded
  case invalidAllowedApplications
  case combinedSelectionLimitExceeded

  var errorDescription: String? {
    switch self {
    case .appGroupUnavailable: return "无法访问共享数据，请检查应用及扩展的 App Groups 签名配置。"
    case .authorizationRequired: return "请先授权屏幕使用时间，并重新选择需要限制的应用。"
    case .simulator: return "模拟器可预览界面；应用圈选和实际锁定需要在 iPhone 或 iPad 真机上验证。"
    case .configurationChanged: return "配置正在更新，请稍后重试。当前限制会保留。"
    case .emptySelection: return "清晨模式需要先圈选应用，请重新选择需要限制的应用。"
    case .selectionLimitExceeded: return "应用、类别和网站各可单独选择最多 50 个。需要限制更多应用时，请按类别圈选。"
    case .activeSelectionLimitExceeded:
      return "本轮仍保留原来的锁定范围，加入后会超过系统的 50 个上限。请减少新增项，或在本轮结束后修改。"
    case .invalidAllowedApplications: return "豁免名单最多支持 50 个 App，请减少圈选。"
    case .combinedSelectionLimitExceeded: return "同时执行的锁定范围过多，请先结束部分时段后重试。"
    }
  }
}

/// Shared by the app and Screen Time extensions. Starting monitors happens outside file transactions.
final class ScreenTimeService: @unchecked Sendable {
  static let isFreePreview = false
  static let shieldTokenLimit = 50
  static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      true
    #else
      false
    #endif
  }

  private let storage: StateStore
  private let logger = Logger(subsystem: "com.nullptrpanic.Daywell", category: "ScreenTime")
  private let center = DeviceActivityCenter()
  private let settings = ManagedSettingsStore(named: .init("daywell.sleep"))
  private let fitnessSettings = ManagedSettingsStore(named: .init("daywell.fitness"))
  private var registeredActivities: Set<DeviceActivityName> = []

  @MainActor private static var confirmedAuthorization: Bool?

  @MainActor static var reportedAuthorization: Bool? {
    guard !isSimulator else { return false }
    let status = AuthorizationCenter.shared.authorizationStatus
    if status == .approved {
      confirmedAuthorization = true
    } else if #available(iOS 26.4, *), status == .approvedWithDataAccess {
      confirmedAuthorization = true
    } else if status == .denied || confirmedAuthorization != nil {
      confirmedAuthorization = false
    }
    // Initial notDetermined is unknown, so it must not invalidate saved tokens.
    // After approval, a return to notDetermined means the approval is no longer current.
    return confirmedAuthorization
  }

  @MainActor static func requestAuthorization() async throws {
    do {
      try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
      confirmedAuthorization = true
    } catch let error as FamilyControlsError {
      // Cancelling a request is not a revocation of previously saved selections.
      // Keep an unresolved launch status unknown; explicit denial still invalidates tokens.
      if #available(iOS 26.4, *), error == .unauthorized { confirmedAuthorization = false }
      throw error
    }
  }

  private func readAuthorization() -> Bool? {
    guard !Self.isSimulator else { return false }
    // The main app owns the authorization request. Extensions use its last confirmed
    // state, while iOS still checks authorization when accepting restrictions.
    guard Bundle.main.bundleURL.pathExtension != "appex" else { return nil }
    // Family Controls requires the app to read this property on the main queue.
    if Thread.isMainThread { return MainActor.assumeIsolated { Self.reportedAuthorization } }
    return DispatchQueue.main.sync { Self.reportedAuthorization }
  }

  var isAuthorized: Bool {
    readAuthorization() ?? ((try? storage.read().hadAuthorization) == true)
  }
  var isFitnessShieldApplied: Bool {
    guard !Self.isSimulator, case .all? = fitnessSettings.shield.applicationCategories else {
      return false
    }
    return true
  }

  init() throws {
    let directory: URL
    #if targetEnvironment(simulator)
      directory = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      ).appendingPathComponent("Daywell")
    #else
      guard let group = Bundle.main.object(forInfoDictionaryKey: "DaywellAppGroup") as? String,
        let container = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: group)
      else {
        throw ScreenTimeError.appGroupUnavailable
      }
      directory = container.appendingPathComponent("Daywell", isDirectory: true)
    #endif
    storage = try StateStore(directory: directory)
  }

  func read() throws -> DaywellState { try storage.read() }

  @discardableResult
  func refresh() throws -> DaywellState {
    try update { _ in }
  }

  @discardableResult
  func savePeriod(_ period: LockPeriod, verifiedSessionIDs: Set<String>) throws -> DaywellState {
    try update { state in
      try state.savePeriod(
        period, at: Date(), calendar: .current, verifiedSessionIDs: verifiedSessionIDs)
    }
  }

  @discardableResult
  func removePeriod(_ id: UUID) throws -> DaywellState {
    try update { state in state.removePeriod(id, at: Date(), calendar: .current) }
  }

  @discardableResult
  func savePolicy(_ policy: ExemptionPolicy) throws -> DaywellState {
    try update { $0.policy = policy.normalizedForConfiguration }
  }

  func saveMorningPolicy(_ policy: MorningPolicy) throws -> DaywellState {
    try update { $0.morningPolicy = policy }
  }

  func updateFitness(
    initial: FitnessTraining, _ change: (inout FitnessTraining) -> Void
  ) throws -> DaywellState {
    if Self.isSimulator { return try update { $0.updateFitness(initial: initial, change) } }
    let authorization = readAuthorization()
    do {
      return try storage.coordinateMonitoring {
        let before = try storage.read()
        var proposed = before
        proposed.updateAuthorization(authorization)
        proposed.refresh(at: Date(), calendar: .current)
        proposed.updateFitness(initial: initial, change)
        proposed.refresh(at: Date(), calendar: .current)
        try validateCapacity(of: proposed, replacing: before)
        let plans =
          proposed.hadAuthorization
          ? MonitorPlan.make(for: proposed, at: Date(), calendar: .current) : []
        // Keep the original rest wake-up until the replacement is installed and
        // committed. An SDK rejection must not consume a group or promise a rest.
        let previousPlans = MonitorPlan.make(for: before, at: Date(), calendar: .current)
        do {
          pruneMonitors(keeping: plans + previousPlans)
          for plan in plans
          where plan.name.hasPrefix(MonitorPlan.fitnessRestPrefix)
            || plan.name.hasPrefix(MonitorPlan.fitnessIdlePrefix)
          {
            try register(plan)
          }
          let latestAuthorization = readAuthorization()
          _ = try storage.transaction(
            { state in
              guard state.fitness == before.fitness,
                (latestAuthorization ?? state.hadAuthorization) == proposed.hadAuthorization
              else { throw ScreenTimeError.configurationChanged }
              let original = state
              state.updateAuthorization(latestAuthorization)
              state.refresh(at: Date(), calendar: .current)
              if let training = proposed.fitness {
                state.updateFitness(initial: initial) { $0 = training }
              }
              state.refresh(at: Date(), calendar: .current)
              try validateCapacity(of: state, replacing: original)
            }, afterSave: applyShields)
          return try synchronizeCoordinatedSchedules()
        } catch {
          // A concurrent reset/revocation wins. Reconcile its latest state and
          // remove any staged wake-up that no longer belongs to the saved workout.
          _ = try? synchronizeCoordinatedSchedules()
          throw error
        }
      }
    } catch {
      if !(error is DaywellError) && !(error is ScreenTimeError) { recordMonitoringError(error) }
      throw error
    }
  }

  private func validateCapacity(of state: DaywellState, replacing previous: DaywellState) throws {
    let now = Date()
    let capacity = MonitorPlan.requiredCapacity(for: state, at: now, calendar: .current)
    guard
      capacity <= MonitorPlan.activityLimit
        || capacity <= MonitorPlan.requiredCapacity(for: previous, at: now, calendar: .current)
    else { throw DaywellError.monitoringCapacityExceeded }
  }

  @discardableResult
  func saveSelection(_ data: Data?) throws -> DaywellState {
    let selection = try data.map {
      try JSONDecoder().decode(FamilyActivitySelection.self, from: $0)
    }
    if let selection, !selection.fitsShieldLimits {
      throw ScreenTimeError.selectionLimitExceeded
    }
    return try update { state in
      guard state.hadAuthorization else { throw ScreenTimeError.authorizationRequired }
      var selectionData = data
      if let selection {
        let restricted = selection.excludingApplications(try allowedApplications(in: state))
        if restricted.isEmpty {
          selectionData = nil
        } else if restricted.applicationTokens != selection.applicationTokens {
          selectionData = try JSONEncoder().encode(restricted)
        }
      }
      let now = Date()
      try state.updateSelection(selectionData, at: now) { existing, added in
        let merged = try Self.mergedSelection(existing, added)
        guard merged.fitsShieldLimits else { throw ScreenTimeError.activeSelectionLimitExceeded }
        return try JSONEncoder().encode(merged)
      }
    }
  }

  private static func mergedSelection(_ existing: Data, _ added: Data) throws
    -> FamilyActivitySelection
  {
    var merged =
      existing.isEmpty
      ? FamilyActivitySelection(includeEntireCategory: false)
      : try JSONDecoder().decode(FamilyActivitySelection.self, from: existing)
    let added = try JSONDecoder().decode(FamilyActivitySelection.self, from: added)
    merged.applicationTokens.formUnion(added.applicationTokens)
    merged.categoryTokens.formUnion(added.categoryTokens)
    merged.webDomainTokens.formUnion(added.webDomainTokens)
    return merged
  }

  func saveAlwaysAllowedApplications(_ data: Data?) throws -> DaywellState {
    if let data {
      let applications = try JSONDecoder().decode(Set<ApplicationToken>.self, from: data)
      guard (1...Self.shieldTokenLimit).contains(applications.count) else {
        throw ScreenTimeError.invalidAllowedApplications
      }
    }
    return try update { state in
      guard state.hadAuthorization else { throw ScreenTimeError.authorizationRequired }
      state.alwaysAllowedApplicationsData = data
    }
  }

  @discardableResult
  func endExemptions() throws -> DaywellState {
    try update { $0.endExemptions(at: Date()) }
  }

  func reachMorningLimit(activity: DeviceActivityName, event: DeviceActivityEvent.Name) throws {
    guard isAuthorized, event.rawValue == MonitorPlan.UsageThreshold.eventName else { return }
    _ = try update {
      $0.reachMorningLimit(monitorName: activity.rawValue, at: Date(), calendar: .current)
    }
  }

  func reachFitnessDeadline(activity: DeviceActivityName) throws {
    guard !Self.isSimulator else { return }
    let authorization = readAuthorization()
    _ = try storage.transaction {
      $0.updateAuthorization(authorization)
      $0.refresh(at: Date(), calendar: .current)
    }
    // Starting/stopping a monitor can call us synchronously. The outer reconciler
    // then owns registration and shields; never reenter DeviceActivity from here.
    do { _ = try synchronizeSchedules() } catch DaywellError.stateBusy {}
  }

  func beginExemption() throws -> DaywellState {
    guard !Self.isSimulator else { throw ScreenTimeError.simulator }
    let authorization = readAuthorization()
    var pendingID: UUID?
    do {
      let pending = try storage.transaction(
        { state in
          state.refresh(at: Date(), calendar: .current)
          guard authorization ?? state.hadAuthorization, !state.needsApplicationReselection else {
            throw ScreenTimeError.authorizationRequired
          }
          guard !isFitnessShieldApplied else { throw DaywellError.fitnessRestrictionActive }
          return try state.reserveExemption(at: Date())
        }
      ).value
      pendingID = pending.id
      // A durable reservation keeps cleanup in another process from removing this timer.
      // Failure here leaves both quota and shields unchanged.
      _ = try synchronizeSchedules()
      let currentAuthorization = readAuthorization()
      return try storage.transaction(
        { state in
          guard currentAuthorization ?? state.hadAuthorization, !state.needsApplicationReselection
          else {
            throw ScreenTimeError.authorizationRequired
          }
          guard !isFitnessShieldApplied else { throw DaywellError.fitnessRestrictionActive }
          state.refresh(at: Date(), calendar: .current)
          try state.commitExemption(pending.id, at: Date())
        }, afterSave: applyShields
      ).state
    } catch {
      if let pendingID {
        _ = try? storage.transaction { $0.cancelReservation(pendingID) }
      }
      // A stale shield button or a second tap must not mark healthy monitors as failed.
      if !(error is DaywellError) && !(error is ScreenTimeError) {
        recordMonitoringError(error)
      }
      throw error
    }
  }

  private func update(_ change: (inout DaywellState) throws -> Void) throws -> DaywellState {
    let authorization = readAuthorization()
    do {
      _ = try storage.transaction(
        { state in
          if !Self.isSimulator { state.updateAuthorization(authorization) }
          state.refresh(at: Date(), calendar: .current)
          let previous = state
          try change(&state)
          state.refresh(at: Date(), calendar: .current)
          try validateCapacity(of: state, replacing: previous)
        })
      return try synchronizeSchedules()
    } catch {
      // A rejected edit never reached the monitor registration step.
      switch error as? DaywellError {
      case .overlappingPeriods?, .deactivationVerificationRequired?, .stateBusy?,
        .monitoringCapacityExceeded?:
        break
      default:
        switch error as? ScreenTimeError {
        case .authorizationRequired?, .activeSelectionLimitExceeded?: break
        default: recordMonitoringError(error)
        }
      }
      throw error
    }
  }

  private func synchronizeSchedules() throws -> DaywellState {
    if Self.isSimulator { return try storage.read() }
    return try storage.coordinateMonitoring {
      try synchronizeCoordinatedSchedules()
    }
  }

  private func synchronizeCoordinatedSchedules() throws -> DaywellState {
    for _ in 0..<4 {
      let snapshot = try storage.read()
      let plans =
        snapshot.hadAuthorization
        ? MonitorPlan.make(for: snapshot, at: Date(), calendar: .current) : []
      let live = try storage.read()
      let latest =
        live.hadAuthorization ? MonitorPlan.make(for: live, at: Date(), calendar: .current) : []
      guard live.revision == snapshot.revision, latest == plans else { continue }
      // Stopping an ongoing monitor can synchronously invoke the extension, which
      // needs the state file. Like registration, cleanup must run without its lock.
      pruneMonitors(keeping: plans)
      var registrationError: Error?
      // Install one-shot release guards before registering starts that can call back immediately.
      for plan in plans.sorted(by: { !$0.repeats && $1.repeats }) {
        do {
          try register(plan)
        } catch {
          if registrationError == nil { registrationError = error }
          logger.error(
            "Activity registration failed: \(error.localizedDescription, privacy: .public)")
        }
      }
      var confirmed = false
      let result = try storage.transaction(
        { live in
          guard live.revision == snapshot.revision else { return }
          let latest =
            live.hadAuthorization ? MonitorPlan.make(for: live, at: Date(), calendar: .current) : []
          guard latest == plans else { return }
          live.sleepShieldStoreCount = max(
            live.sleepShieldStoreCount, try sleepShieldBatches(live).count)
          live.monitoringError = registrationError?.localizedDescription
          confirmed = true
        },
        afterSave: { live in
          guard confirmed else { return }
          try applyShields(live)
        })
      if confirmed {
        if let registrationError { throw registrationError }
        return result.state
      }
    }
    throw ScreenTimeError.configurationChanged
  }

  private func pruneMonitors(keeping plans: [MonitorPlan]) {
    let names = Set(plans.map(\.name))
    registeredActivities = Set(center.activities)
    let obsolete = registeredActivities.filter {
      $0.rawValue.hasPrefix(MonitorPlan.prefix) && !names.contains($0.rawValue)
    }
    if !obsolete.isEmpty {
      center.stopMonitoring(Array(obsolete))
      registeredActivities.subtract(obsolete)
    }
  }

  private func register(_ plan: MonitorPlan) throws {
    let name = DeviceActivityName(plan.name)
    let schedule = DeviceActivitySchedule(
      intervalStart: plan.start, intervalEnd: plan.end,
      repeats: plan.repeats, warningTime: plan.warning)
    let events = try usageEvents(for: plan)
    if center.schedule(for: name) != schedule || center.events(for: name) != events {
      try center.startMonitoring(name, during: schedule, events: events)
      logger.info("Registered activity \(plan.name, privacy: .private(mask: .hash))")
    }
    registeredActivities.insert(name)
  }

  private func usageEvents(for plan: MonitorPlan) throws -> [DeviceActivityEvent.Name:
    DeviceActivityEvent]
  {
    guard let usage = plan.usage else { return [:] }
    let selection = try JSONDecoder().decode(
      FamilyActivitySelection.self, from: usage.selectionData)
    // An empty DeviceActivityEvent means ALL activity, not none.
    guard
      !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty
        || !selection.webDomainTokens.isEmpty
    else { throw ScreenTimeError.emptySelection }
    // Register upcoming windows ahead of time. Do not include usage before registration
    // when authorization is restored halfway through a window.
    let event = DeviceActivityEvent(
      applications: selection.applicationTokens,
      categories: selection.categoryTokens, webDomains: selection.webDomainTokens,
      threshold: DateComponents(minute: usage.minutes))
    return [.init(MonitorPlan.UsageThreshold.eventName): event]
  }

  private func applyShields(_ state: DaywellState) throws {
    guard !Self.isSimulator else { return }
    guard state.hadAuthorization else {
      clearSleepShields(state)
      fitnessSettings.clearAllSettings()
      return
    }
    let now = Date()
    let alwaysAllowed = try allowedApplications(in: state)
    let fitnessOwnsLock = state.hasFitnessRestriction(at: now)
    if fitnessOwnsLock { applyFitnessShield(state.fitness, except: alwaysAllowed, at: now) }
    // Install the incoming owner's restriction before removing the outgoing store.
    let batches = try sleepShieldBatches(state)
    for index in 0..<state.sleepShieldStoreCount {
      let store = sleepStore(at: index)
      guard index < batches.count else {
        store.clearAllSettings()
        continue
      }
      let batch = batches[index]
      store.shield.applications = batch.applicationTokens.isEmpty ? nil : batch.applicationTokens
      store.shield.applicationCategories =
        batch.categoryTokens.isEmpty
        ? nil : .specific(batch.categoryTokens, except: alwaysAllowed)
      store.shield.webDomains = batch.webDomainTokens.isEmpty ? nil : batch.webDomainTokens
      store.shield.webDomainCategories =
        batch.categoryTokens.isEmpty ? nil : .specific(batch.categoryTokens)
    }
    if !fitnessOwnsLock { fitnessSettings.clearAllSettings() }
  }

  private func sleepStore(at index: Int) -> ManagedSettingsStore {
    index == 0 ? settings : ManagedSettingsStore(named: .init("daywell.sleep.part.\(index)"))
  }

  private func clearSleepShields(_ state: DaywellState) {
    for index in 0..<state.sleepShieldStoreCount { sleepStore(at: index).clearAllSettings() }
  }

  private func sleepShieldBatches(_ state: DaywellState) throws -> [FamilyActivitySelection] {
    guard state.hadAuthorization, !state.needsApplicationReselection else { return [] }
    let now = Date()
    let alwaysAllowed = try allowedApplications(in: state)
    var applications: Set<ApplicationToken> = []
    var categories: Set<ActivityCategoryToken> = []
    var domains: Set<WebDomainToken> = []
    for session in state.blockingSessions(at: now) where !session.selectionData.isEmpty {
      // Never introduce a restriction before its automatic end has been registered.
      let guardName = DeviceActivityName(MonitorPlan.endGuardName(for: session.occurrence.end))
      guard registeredActivities.contains(guardName) else {
        logger.debug("Sleep shield waiting for its release monitor")
        continue
      }
      let selection = try JSONDecoder().decode(
        FamilyActivitySelection.self, from: session.selectionData)
      applications.formUnion(selection.applicationTokens)
      categories.formUnion(selection.categoryTokens)
      domains.formUnion(selection.webDomainTokens)
    }
    applications.subtract(alwaysAllowed)
    // Each named store has its own token capacity. Never turn an oversized union
    // into nil: valid snapshots can contain different selections across sessions.
    let stores = (0..<state.sleepShieldStoreCount).map { sleepStore(at: $0) }
    let appBatches = try tokenBatches(
      applications, keeping: stores.map { $0.shield.applications ?? [] })
    let categoryBatches = try tokenBatches(
      categories,
      keeping: stores.map {
        if case .specific(let tokens, _)? = $0.shield.applicationCategories { return tokens }
        return []
      })
    let domainBatches = try tokenBatches(
      domains, keeping: stores.map { $0.shield.webDomains ?? [] })
    let count = max(appBatches.count, categoryBatches.count, domainBatches.count)
    // iOS supports 50 named stores; reserve one for fitness and reuse fixed names.
    guard count <= 49 else { throw ScreenTimeError.combinedSelectionLimitExceeded }
    return (0..<count).map { index in
      var batch = FamilyActivitySelection(includeEntireCategory: false)
      if index < appBatches.count { batch.applicationTokens = appBatches[index] }
      if index < categoryBatches.count { batch.categoryTokens = categoryBatches[index] }
      if index < domainBatches.count { batch.webDomainTokens = domainBatches[index] }
      return batch
    }
  }

  private func tokenBatches<Token: Hashable & Encodable>(
    _ tokens: Set<Token>, keeping existing: [Set<Token>]
  ) throws -> [Set<Token>] {
    // Keep live tokens in their existing store. Re-sorting the entire union could
    // remove an app from one store before another receives it, briefly releasing it.
    var remaining = tokens
    var batches = existing.map { previous in
      let retained = previous.intersection(remaining)
      remaining.subtract(retained)
      return retained
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var added = try remaining.map { (token: $0, key: try encoder.encode($0).base64EncodedString()) }
      .sorted { $0.key < $1.key }.map(\.token)
    for index in batches.indices where !added.isEmpty {
      let count = min(Self.shieldTokenLimit - batches[index].count, added.count)
      batches[index].formUnion(added.prefix(count))
      added.removeFirst(count)
    }
    for index in stride(from: 0, to: added.count, by: Self.shieldTokenLimit) {
      batches.append(Set(added[index..<min(index + Self.shieldTokenLimit, added.count)]))
    }
    while batches.last?.isEmpty == true { batches.removeLast() }
    return batches
  }

  private func allowedApplications(in state: DaywellState) throws -> Set<ApplicationToken> {
    guard let data = state.alwaysAllowedApplicationsData else { return [] }
    let applications = try JSONDecoder().decode(Set<ApplicationToken>.self, from: data)
    guard applications.count <= Self.shieldTokenLimit else {
      throw ScreenTimeError.invalidAllowedApplications
    }
    return applications
  }

  private func applyFitnessShield(
    _ training: FitnessTraining?, except alwaysAllowed: Set<ApplicationToken>, at date: Date
  ) {
    guard let training, training.isLocked(at: date), let idle = training.inactivityEndsAt,
      registeredActivities.contains(.init(MonitorPlan.fitnessIdleName(for: idle)))
    else {
      // Do not create an indefinite restriction if its automatic cleanup failed.
      fitnessSettings.clearAllSettings()
      return
    }
    fitnessSettings.shield.applicationCategories = .all(except: alwaysAllowed)
    fitnessSettings.shield.webDomainCategories = .all()
    logger.debug("Fitness shield submitted after the rest deadline")
  }

  private func recordMonitoringError(_ error: Error) {
    _ = try? storage.transaction { $0.monitoringError = error.localizedDescription }
  }
}

extension FamilyActivitySelection {
  var isEmpty: Bool {
    applicationTokens.isEmpty && categoryTokens.isEmpty && webDomainTokens.isEmpty
  }

  func excludingApplications(_ applications: Set<ApplicationToken>) -> FamilyActivitySelection {
    var selection = self
    selection.applicationTokens.subtract(applications)
    return selection
  }

  var fitsShieldLimits: Bool {
    let limit = ScreenTimeService.shieldTokenLimit
    return applicationTokens.count <= limit && categoryTokens.count <= limit
      && webDomainTokens.count <= limit
  }
}
