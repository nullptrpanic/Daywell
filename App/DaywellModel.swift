import Combine
import DaywellCore
import Foundation

#if !DAYWELL_PREVIEW
  import FamilyControls
  import ManagedSettings
  import OSLog
#endif

struct PeriodDeactivation {
  let period: LockPeriod
  let sessionIDs: Set<String>
  let code = String(Int.random(in: 100_000...999_999))
}

enum PeriodSavePrompt {
  case failure(String)
  case verify(PeriodDeactivation)
}

private actor ScreenTimeClient {
  private var service: ScreenTimeService?

  private func connectedService() throws -> ScreenTimeService {
    if let service { return service }
    let created = try ScreenTimeService()
    service = created
    return created
  }

  func execute(_ action: @Sendable (ScreenTimeService) throws -> DaywellState) throws
    -> (state: DaywellState, fitnessShieldApplied: Bool)
  {
    let service = try connectedService()
    let state = try action(service)
    return (state, service.isFitnessShieldApplied)
  }
  func read() throws -> (state: DaywellState, fitnessShieldApplied: Bool) {
    let service = try connectedService()
    let state = try service.read()
    return (state, service.isFitnessShieldApplied)
  }
}

@MainActor
final class DaywellModel: ObservableObject {
  @Published private(set) var state = DaywellState()
  @Published private(set) var now = Date()
  @Published private(set) var isBusy = false
  @Published private(set) var isAuthorized = false
  @Published private(set) var fitnessShieldApplied = false
  @Published var errorMessage: String?
  @Published private(set) var startupError: String?
  private let client = ScreenTimeClient()
  private let legacyFitness: FitnessTraining
  private var nextRefresh = Date.distantPast
  #if !DAYWELL_PREVIEW
    private var didRestoreAuthorization = false
  #endif

  init() {
    let defaults = UserDefaults.standard
    legacyFitness = FitnessTraining(
      progress: FitnessProgress(
        targetGroups: defaults.object(forKey: "daywell.fitness.targetGroups") as? Int
          ?? FitnessProgress.defaultTargetGroups,
        completedGroups: defaults.integer(forKey: "daywell.fitness.completedGroups")))
  }

  var activeSessions: [LockSession] { state.activeSessions(at: now) }
  var blockingSessions: [LockSession] { state.blockingSessions(at: now) }
  var fitness: FitnessTraining { state.fitness ?? legacyFitness }
  var canExempt: Bool {
    isAuthorized && state.exemptionOffer(at: now) != nil
  }
  #if !DAYWELL_PREVIEW
    var selection: FamilyActivitySelection {
      // Category tokens can be shielded directly. Expanding all their members can
      // exceed the system limit for individually shielded apps and websites.
      var selection = FamilyActivitySelection(includeEntireCategory: false)
      if let data = state.selectionData,
        let saved = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
      {
        if saved.includeEntireCategory {
          selection.applicationTokens = saved.applicationTokens
          selection.categoryTokens = saved.categoryTokens
          selection.webDomainTokens = saved.webDomainTokens
        } else {
          selection = saved
        }
      }
      return selection.excludingApplications(alwaysAllowedSelection.applicationTokens)
    }

    var alwaysAllowedSelection: FamilyActivitySelection {
      // Selecting the last app in a category can also check its parent. Keep the
      // concrete apps in the picker result; the exemption list stores only those.
      var selection = FamilyActivitySelection(includeEntireCategory: true)
      if let data = state.alwaysAllowedApplicationsData {
        selection.applicationTokens =
          (try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data)) ?? []
      }
      return selection
    }
  #endif
  var nextOccurrence: PeriodOccurrence? {
    state.periods.compactMap { $0.nextOccurrence(after: now, calendar: .current) }.min {
      $0.start < $1.start
    }
  }
  var exemptionLabel: String { "临时豁免" }
  var exemptionExplanation: String {
    let count = blockingSessions.count
    return count > 1
      ? "当前有 \(count) 个重叠的锁定时段，将从各时段扣除 1 次机会，并按各自设置计时。到期后自动恢复限制。"
      : "将使用本时段的 1 次豁免机会。到期后自动恢复限制，提前结束也不会退还次数。"
  }

  func tick(_ date: Date) {
    now = date
    let authorized = authorizationGranted
    if date >= nextRefresh || authorized != isAuthorized {
      Task { await refresh() }
    }
  }

  func refresh() async {
    _ = await perform(showError: false) { try $0.refresh() }
  }

  func authorize() async {
    #if DAYWELL_PREVIEW
      errorMessage = ScreenTimeError.previewUnavailable.localizedDescription
    #else
      guard !ScreenTimeService.isSimulator else {
        errorMessage = ScreenTimeError.simulator.localizedDescription
        return
      }
      guard !isBusy else { return }
      isBusy = true
      do {
        try await ScreenTimeService.requestAuthorization()
      } catch { errorMessage = error.localizedDescription }
      didRestoreAuthorization = true
      isBusy = false
      await refresh()
    #endif
  }

  func savePeriod(
    _ period: LockPeriod, verifiedSessionIDs: Set<String> = [],
    onPrompt: @escaping (PeriodSavePrompt) -> Void
  ) async -> Bool {
    guard !isBusy else { return false }
    if !period.isEnabled {
      let runningIDs = Set(
        state.activeSessions(at: Date()).filter { $0.period.id == period.id }.map(\.id))
      if !runningIDs.isEmpty, !runningIDs.isSubset(of: verifiedSessionIDs) {
        onPrompt(.verify(PeriodDeactivation(period: period, sessionIDs: runningIDs)))
        return false
      }
    }
    // The service repeats verification against durable state before any change.
    return await perform(
      onError: { error in
        if case .deactivationVerificationRequired(let sessionIDs)? = error as? DaywellError {
          onPrompt(.verify(PeriodDeactivation(period: period, sessionIDs: sessionIDs)))
        } else {
          onPrompt(.failure(error.localizedDescription))
        }
      },
      { try $0.savePeriod(period, verifiedSessionIDs: verifiedSessionIDs) })
  }

  func removePeriod(_ id: UUID) async -> Bool {
    await perform { try $0.removePeriod(id) }
  }

  #if !DAYWELL_PREVIEW
    func saveSelection(_ selection: FamilyActivitySelection) async -> Bool {
      do {
        let data = selection.isEmpty ? nil : try JSONEncoder().encode(selection)
        return await perform { try $0.saveSelection(data) }
      } catch {
        errorMessage = error.localizedDescription
        return false
      }
    }

    func saveAlwaysAllowed(_ selection: FamilyActivitySelection) async -> Bool {
      guard selection.applicationTokens.count <= ScreenTimeService.shieldTokenLimit
      else {
        errorMessage = ScreenTimeError.invalidAllowedApplications.localizedDescription
        return false
      }
      do {
        let applications = selection.applicationTokens
        let data = applications.isEmpty ? nil : try JSONEncoder().encode(applications)
        return await perform { try $0.saveAlwaysAllowedApplications(data) }
      } catch {
        errorMessage = error.localizedDescription
        return false
      }
    }
  #endif

  func savePolicy(count: Int, durationsMinutes: [Int]) async -> Bool {
    do {
      let policy = try ExemptionPolicy(allowedCount: count, durationsMinutes: durationsMinutes)
      return await perform { try $0.savePolicy(policy) }
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func beginExemption() async { _ = await perform { try $0.beginExemption() } }
  func endExemptions() async { _ = await perform { try $0.endExemptions() } }

  func saveMorningPolicy(usageMinutes: Int, lockMinutes: Int) async -> Bool {
    do {
      let policy = try MorningPolicy(usageMinutes: usageMinutes, lockMinutes: lockMinutes)
      return await perform { try $0.saveMorningPolicy(policy) }
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func updateFitness(_ change: @escaping @Sendable (inout FitnessTraining) -> Void) async -> Bool {
    let initial = legacyFitness
    return await perform { try $0.updateFitness(initial: initial, change) }
  }

  private var authorizationGranted: Bool {
    #if DAYWELL_PREVIEW
      false
    #else
      ScreenTimeService.reportedAuthorization == true
    #endif
  }

  #if !DAYWELL_PREVIEW
    private func restoreAuthorizationIfNeeded(using client: ScreenTimeClient) async throws {
      guard !didRestoreAuthorization, !ScreenTimeService.isSimulator else { return }
      let stored = try await client.read()
      state = stored.state
      fitnessShieldApplied = stored.fitnessShieldApplied
      if state.hadAuthorization, ScreenTimeService.reportedAuthorization == nil {
        do {
          try await ScreenTimeService.requestAuthorization()
        } catch {
          Logger(subsystem: "com.nullptrpanic.Daywell", category: "ScreenTime")
            .notice("Could not restore authorization on launch: \(error.localizedDescription)")
        }
      }
      isAuthorized = authorizationGranted
      didRestoreAuthorization = true
    }
  #endif

  private func perform(
    showError: Bool = true,
    onError: ((Error) -> Void)? = nil,
    _ action: @escaping @Sendable (ScreenTimeService) throws -> DaywellState
  ) async -> Bool {
    guard !isBusy else { return false }
    let startedAt = Date()
    isBusy = true
    defer {
      isBusy = false
      now = Date()
      isAuthorized = authorizationGranted
      // A deadline crossed during the operation still needs a refresh on the next tick.
      let boundaries =
        state.activeSessions(at: startedAt).flatMap { session in
          [session.occurrence.end, session.exemption?.end].compactMap { $0 }
        }
        + state.periods.compactMap {
          $0.nextOccurrence(after: startedAt, calendar: .current)?.start
        }
        + [fitness.restEndsAt, fitness.inactivityEndsAt].compactMap { $0 }
      nextRefresh = boundaries.filter { $0 > startedAt }.min() ?? now.addingTimeInterval(60)
      nextRefresh = min(nextRefresh, now.addingTimeInterval(60))
    }
    do {
      #if !DAYWELL_PREVIEW
        try await restoreAuthorizationIfNeeded(using: client)
      #endif
      let updated = try await client.execute(action)
      state = updated.state
      fitnessShieldApplied = updated.fitnessShieldApplied
      startupError = nil
      return true
    } catch {
      if let stored = try? await client.read() {
        state = stored.state
        fitnessShieldApplied = stored.fitnessShieldApplied
      } else {
        startupError = error.localizedDescription
      }
      if let onError {
        onError(error)
      } else if showError {
        errorMessage = error.localizedDescription
      }
      return false
    }
  }
}
