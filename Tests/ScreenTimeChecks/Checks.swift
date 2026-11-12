import Darwin
import Foundation

@main struct Checks {
  @MainActor static func main() async throws {
    let scenario = CommandLine.arguments[1]
    World.directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: World.directory) }
    let store = try StateStore(directory: World.directory)
    if scenario.hasPrefix("interaction-") {
      try await LockInteractionChecks.run(scenario, store: store)
      print("Passed:", scenario)
      return
    }
    let now = Date()
    let calendar = Calendar.current
    func clock(_ date: Date) throws -> ClockTime {
      try ClockTime(
        hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date)
      )
    }
    let period = try LockPeriod(
      start: clock(now.addingTimeInterval(-600)), end: clock(now.addingTimeInterval(3600)))
    let selection = try JSONEncoder().encode(
      FamilyActivitySelection(
        includeEntireCategory: false, applicationTokens: [2],
        categoryTokens: scenario == "sleep-websites" ? [3] : [],
        webDomainTokens: scenario == "sleep-websites" ? [4] : []))
    try store.transaction { state in
      state.hadAuthorization = true
      state.selectionData = selection
      state.alwaysAllowedApplicationsData = try JSONEncoder().encode(Set([1]))
      if scenario != "fitness" && scenario != "fitness-websites"
        && scenario != "oversized-allowlist"
      {
        state.periods = [period]
        state.refresh(at: now, calendar: calendar)
      }
    }
    if scenario == "authorization-revoked" {
      try store.transaction { state in
        state.policy = try ExemptionPolicy(allowedCount: 3, durationsMinutes: [8, 5, 2, 1, 1])
        state.morningPolicy = try MorningPolicy(usageMinutes: 8, lockMinutes: 30)
        var training = FitnessTraining(
          progress: FitnessProgress(targetGroups: 4), restEnabled: true)
        training.setRestSeconds(90)
        training.completeGroup(at: now)
        state.fitness = training
      }
      let model = DaywellModel()
      await model.refresh()
      check(model.isAuthorized, "The initial approval was not reflected in the model")
      await model.beginExemption()
      let before = try store.read()
      check(before.activeSessions(at: now).first?.usedCount == 1, "The exemption was not consumed")
      AuthorizationCenter.shared.authorizationStatus = .notDetermined
      await model.refresh()
      check(!model.isAuthorized, "Revoking authorization retained the approved card")
      let revoked = try store.read()
      check(!revoked.hadAuthorization, "Revocation was not persisted")
      check(revoked.needsApplicationReselection, "Invalidated tokens were treated as usable")
      check(
        revoked.periods == before.periods && revoked.policy == before.policy
          && revoked.morningPolicy == before.morningPolicy && revoked.fitness == before.fitness,
        "Revoking authorization erased the user's rules or fitness progress")
      check(
        revoked.sessions.map(\.usedCount) == before.sessions.map(\.usedCount),
        "Revoking authorization reset the exemption counts")
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      check(shield.applications == nil, "Revoking authorization retained a sleep shield")
      check(DeviceActivityCenter.schedules.isEmpty, "Revoking authorization retained monitors")
      let relaunched = DaywellModel()
      await relaunched.refresh()
      check(!relaunched.isAuthorized, "A new model restored stale authorization")
      check(relaunched.state.periods == before.periods, "Relaunch lost the saved periods")
      check(
        AuthorizationCenter.shared.authorizationRequests == 0,
        "The app requested authorization again after the user revoked it")
      await relaunched.authorize()
      check(relaunched.isAuthorized, "Explicit authorization did not restore the authorized card")
      check(
        relaunched.state.needsApplicationReselection,
        "Reauthorization reused invalidated app selections")
    } else if scenario == "authorization-data-access" {
      AuthorizationCenter.shared.authorizationStatus = .approvedWithDataAccess
      let model = DaywellModel()
      await model.refresh()
      check(model.isAuthorized, "Approval with data access was treated as revoked")
      check(model.state.selectionData == selection, "An approved status invalidated app selections")
    } else if scenario == "authorization-cold-denied" {
      AuthorizationCenter.shared.authorizationStatus = .denied
      let model = DaywellModel()
      await model.refresh()
      check(!model.isAuthorized, "A cold launch ignored an explicit denial")
      check(
        AuthorizationCenter.shared.authorizationRequests == 0,
        "A cold launch prompted for permission despite an explicit denial")
      check(model.state.periods == [period], "A cold denial discarded the saved schedule")
    } else if scenario == "authorization-restore-error"
      || scenario == "authorization-restore-cancelled"
    {
      AuthorizationCenter.shared.authorizationStatus = .notDetermined
      AuthorizationCenter.shared.requestError =
        scenario == "authorization-restore-cancelled"
        ? FamilyControlsError.authorizationCanceled : POSIXError(.EIO)
      let model = DaywellModel()
      await model.refresh()
      check(!model.isAuthorized, "An unconfirmed authorization was shown as approved")
      check(
        model.state.periods == [period] && model.state.selectionData == selection,
        "A temporary authorization error discarded the saved configuration")
      check(
        !model.state.needsApplicationReselection,
        "A temporary error invalidated tokens without a confirmed revocation")
      AuthorizationCenter.shared.requestError = nil
      await model.authorize()
      check(model.isAuthorized, "Retrying authorization did not restore approval")
      check(
        model.state.selectionData == selection && !model.state.needsApplicationReselection,
        "Retrying authorization required reselection despite no revocation")
      check(
        model.alwaysAllowedSelection.applicationTokens == [1],
        "Retrying authorization discarded the exemption list")
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]!.applications == [2],
        "Retrying authorization did not resume the saved restriction")
    } else if scenario == "morning-callback" {
      let sleep = try LockPeriod(
        start: clock(now.addingTimeInterval(-7200)), end: clock(now.addingTimeInterval(-3600)),
        morningEnabled: true)
      try store.transaction { state in
        state.periods = [sleep]
        state.sessions = []
        state.morningWindows = []
        state.morningCancelledThrough = nil
        state.lastEvaluatedAt = nil
        let sleepTime = now.addingTimeInterval(-5400)
        state.refresh(at: sleepTime, calendar: calendar)
        let pending = try state.reserveExemption(at: sleepTime)
        try state.commitExemption(pending.id, at: sleepTime)
      }
      let before = try store.read()
      let window = before.pendingMornings(at: now).first!
      let usage = MonitorPlan.make(for: before, at: now, calendar: calendar).first {
        $0.name == window.monitorName
      }!
      DeviceActivityCenter.schedules[.init(usage.name)] = DeviceActivitySchedule(
        intervalStart: usage.start, intervalEnd: usage.end, repeats: false, warningTime: nil)
      DeviceActivityCenter.registeredEvents[.init(usage.name)] = [
        .init(MonitorPlan.UsageThreshold.eventName): DeviceActivityEvent(
          applications: [2], categories: [], webDomains: [], threshold: DateComponents(minute: 10))
      ]
      World.onStart = {
        do {
          try ScreenTimeService().reachMorningLimit(
            activity: .init(window.monitorName), event: .init(MonitorPlan.UsageThreshold.eventName))
        } catch DaywellError.stateBusy {}
      }
      let service = try ScreenTimeService()
      _ = try service.refresh()
      let after = try store.read()
      check(
        after.blockingSessions(at: Date()).filter(\.isMorning).count == 1,
        "A threshold callback lost its morning lock")
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]!.applications == [2],
        "The outer synchronizer did not apply the callback's new lock")
      check(
        World.reentrantCalls.isEmpty,
        "Morning callback reentered monitoring: \(World.reentrantCalls)")
      check(
        after.exemptionOffer(at: Date())?.remainingCount == 1,
        "The morning callback replenished the sleep allowance")
      World.onStart = nil
      let granted = try service.beginExemption()
      let morning = granted.activeSessions(at: Date()).first { $0.isMorning }!
      let duration = morning.exemption!.end.timeIntervalSince(morning.exemption!.start)
      check(
        (300...301).contains(duration), "Morning did not continue with the second, five-minute use")
      check(morning.remainingCount == 0, "The shared allowance was not exhausted")
      _ = try service.endExemptions()
      do {
        _ = try service.beginExemption()
        check(false, "Morning granted another exemption after the shared allowance was exhausted")
      } catch DaywellError.allowanceExhausted {}
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]!.applications == [2],
        "An exhausted morning allowance released the restriction")
    } else if scenario == "morning-cancel-while-accumulating" {
      var sleep = try LockPeriod(
        start: clock(now.addingTimeInterval(-7200)), end: clock(now.addingTimeInterval(-3600)),
        morningEnabled: true)
      try store.transaction { state in
        state.periods = [sleep]
        state.sessions = []
        state.morningWindows = []
        state.morningCancelledThrough = nil
        state.lastEvaluatedAt = nil
        state.refresh(at: now.addingTimeInterval(-5400), calendar: calendar)
      }
      let service = try ScreenTimeService()
      let before = try service.refresh()
      let window = before.pendingMornings(at: now).first!
      let name = DeviceActivityName(window.monitorName)
      check(
        !DeviceActivityCenter().events(for: name).isEmpty,
        "The accumulating morning was not registered before cancellation")
      World.onStop = {
        do {
          try ScreenTimeService().reachMorningLimit(
            activity: name, event: .init(MonitorPlan.UsageThreshold.eventName))
        } catch DaywellError.stateBusy {
          // The outer cancellation owns monitor coordination and completes the sync.
        }
      }
      sleep.isEnabled = false
      _ = try service.savePeriod(sleep, verifiedSessionIDs: [])
      check(
        DeviceActivityCenter().activities.isEmpty,
        "Disabling the period left its morning monitor registered")
      try ScreenTimeService().reachMorningLimit(
        activity: name, event: .init(MonitorPlan.UsageThreshold.eventName))
      let after = try store.read()
      check(after.pendingMornings(at: Date()).isEmpty, "Cancellation recreated the morning window")
      check(after.blockingSessions(at: Date()).isEmpty, "A late threshold callback relocked apps")
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      check(
        shield.applications == nil && shield.applicationCategories == nil
          && shield.webDomains == nil && shield.webDomainCategories == nil,
        "A cancelled morning applied a shield")
      check(World.callbackErrors.isEmpty, "Cancellation callback failed: \(World.callbackErrors)")
      check(World.reentrantCalls.isEmpty, "Cancellation reentered monitor registration")
      check(World.callsUnderLock.isEmpty, "Cancellation called DeviceActivity under the state lock")
    } else if scenario == "exemption-callback" {
      let service = try ScreenTimeService()
      _ = try service.refresh()
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      World.onStart = {
        do {
          _ = try ScreenTimeService().beginExemption()
          check(false, "A busy monitor coordinator granted an exemption")
        } catch DaywellError.stateBusy {}
        check(
          shield.applications == [2], "A failed concurrent exemption cleared the existing shield")
      }
      try store.transaction { state in
        state.periods.append(
          try LockPeriod(
            start: clock(now.addingTimeInterval(7200)), end: clock(now.addingTimeInterval(10800))))
      }
      _ = try service.refresh()
      let after = try store.read()
      check(after.reservation == nil, "A failed concurrent exemption left a reservation")
      check(
        after.activeSessions(at: now).first?.usedCount == 0,
        "A failed concurrent exemption consumed quota")
      check(shield.applications == [2], "A failed concurrent exemption released sleep")
      check(
        World.reentrantCalls.isEmpty,
        "Exemption callback reentered monitoring: \(World.reentrantCalls)")
    } else if scenario == "start-callback" || scenario == "stop-callback" {
      let callback = {
        do { _ = try ScreenTimeService().refresh() } catch DaywellError.stateBusy {}
      }
      if scenario == "start-callback" {
        World.onStart = callback
      } else {
        DeviceActivityCenter.schedules[.init("daywell.old")] = DeviceActivitySchedule(
          intervalStart: DateComponents(hour: 0), intervalEnd: DateComponents(hour: 23),
          repeats: false, warningTime: nil)
        World.onStop = callback
      }
      let service = try ScreenTimeService()
      _ = try service.refresh()
      check(
        World.reentrantCalls.isEmpty,
        "System monitoring was reentered before its callback returned: \(World.reentrantCalls)")
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      check(shield.applications == [2], "Callback coordination lost the active sleep restriction")
      check(
        try store.read().monitoringError == nil,
        "Expected callback contention was recorded as a monitoring failure")
    } else if scenario == "allowlist-category-selection" {
      let model = DaywellModel()
      await model.refresh()
      // The system picker can check a parent category when its only app is selected.
      // With category expansion enabled, its concrete apps and websites are returned too.
      let picked = FamilyActivitySelection(
        includeEntireCategory: true, applicationTokens: [2], categoryTokens: [3],
        webDomainTokens: [4])
      let saved = await model.saveAlwaysAllowed(picked)
      check(saved, "A selected app was rejected because its parent category was checked")
      check(model.errorMessage == nil, "Saving concrete exempt apps reported an error")
      check(
        try JSONDecoder().decode(
          Set<ApplicationToken>.self, from: store.read().alwaysAllowedApplicationsData!) == [2],
        "The exemption list did not persist exactly the selected concrete apps")
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]!.applications == nil,
        "Saving the exemption list did not release the selected app")
      let relaunched = DaywellModel()
      await relaunched.refresh()
      check(
        relaunched.alwaysAllowedSelection.applicationTokens == [2],
        "Reopening the exemption list lost the saved app")
      check(
        relaunched.alwaysAllowedSelection.includeEntireCategory,
        "The exemption picker would omit concrete apps from a selected category")
      check(
        relaunched.alwaysAllowedSelection.categoryTokens.isEmpty
          && relaunched.alwaysAllowedSelection.webDomainTokens.isEmpty,
        "Categories or websites were saved as exemptions")
      let cleared = await relaunched.saveAlwaysAllowed(
        FamilyActivitySelection(includeEntireCategory: true))
      check(cleared, "Clearing the exemption list was rejected")
      check(
        try store.read().alwaysAllowedApplicationsData == nil, "Clearing left exempt apps saved")
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]!.applications == [2],
        "Clearing the exemption list did not restore the original app restriction")
    } else if scenario == "allowlist-selection-limit" {
      let model = DaywellModel()
      await model.refresh()
      let accepted = await model.saveAlwaysAllowed(
        FamilyActivitySelection(
          includeEntireCategory: true, applicationTokens: Set(1...50), categoryTokens: [3]))
      check(accepted, "Exactly 50 exempt apps were rejected")
      let before = try store.read().alwaysAllowedApplicationsData
      let rejected = await model.saveAlwaysAllowed(
        FamilyActivitySelection(
          includeEntireCategory: true, applicationTokens: Set(1...51), categoryTokens: [3]))
      check(!rejected, "More than 50 exempt apps were accepted")
      check(model.errorMessage != nil, "An oversized selection had no error explanation")
      check(
        try store.read().alwaysAllowedApplicationsData == before,
        "Rejecting an oversized selection changed the saved exemption list")
    } else if scenario == "oversized-allowlist" {
      try store.transaction { state in
        state.alwaysAllowedApplicationsData = try JSONEncoder().encode(Set(1...51))
        var training = FitnessTraining(restEnabled: true)
        training.completeGroup(at: now.addingTimeInterval(-60))
        state.fitness = training
      }
      let service = try ScreenTimeService()
      do {
        _ = try service.refresh()
        check(false, "An oversized persisted exemption list reached the system shield setter")
      } catch ScreenTimeError.invalidAllowedApplications {}
      check(
        try store.read().alwaysAllowedApplicationsData != nil, "Invalid list was silently erased")
      _ = try service.saveAlwaysAllowedApplications(JSONEncoder().encode(Set([1])))
      check(
        service.isFitnessShieldApplied,
        "Correcting the exemption list did not recover fitness locking")
    } else if scenario == "fitness-no-allowlist" {
      try store.transaction { state in
        state.periods = []
        state.sessions = []
        state.alwaysAllowedApplicationsData = nil
        var training = FitnessTraining(restEnabled: true)
        training.completeGroup(at: now)
        state.fitness = training
      }
      let service = try ScreenTimeService()
      _ = try service.refresh()
      let restEnd = try store.read().fitness!.restEndsAt!
      check(
        DeviceActivityCenter.schedules[.init(MonitorPlan.fitnessRestName(for: restEnd))] != nil,
        "An empty exemption list prevented the rest deadline from being registered")
      let shield = ManagedSettingsStore.stores[.init("daywell.fitness")]!
      check(shield.applicationCategories == nil, "Rest was locked before its deadline")
      try store.transaction { state in
        var training = FitnessTraining(restEnabled: true)
        training.completeGroup(at: now.addingTimeInterval(-60))
        state.fitness = training
      }
      let expired = try store.read().fitness!.restEndsAt!
      try service.reachFitnessDeadline(activity: .init(MonitorPlan.fitnessRestName(for: expired)))
      check(shield.applicationCategories == .all(), "An empty exemption list prevented app locking")
      check(
        shield.webDomainCategories == .all(), "An empty exemption list prevented website locking")
      check(try store.read().hasFitnessRestriction(at: Date()), "The core missed the workout lock")
      do {
        _ = try service.beginExemption()
        check(false, "The workout lock granted an exemption")
      } catch DaywellError.fitnessRestrictionActive {}
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: Date()) }
      check(shield.applicationCategories == nil, "The next group did not release apps during rest")
      check(
        shield.webDomainCategories == nil, "The next group did not release websites during rest")
      try service.reachFitnessDeadline(activity: .init(MonitorPlan.fitnessRestName(for: expired)))
      check(shield.applicationCategories == nil, "A stale deadline relocked the new rest")
      try store.transaction { state in
        var training = FitnessTraining(restEnabled: true)
        training.completeGroup(at: now.addingTimeInterval(-60))
        state.fitness = training
      }
      _ = try service.refresh()
      check(shield.applicationCategories == .all(), "Foreground refresh missed an empty-list lock")
      _ = try service.saveAlwaysAllowedApplications(JSONEncoder().encode(Set([1])))
      check(shield.applicationCategories == .all(except: [1]), "The optional exemption was ignored")
      _ = try service.saveAlwaysAllowedApplications(nil)
      check(shield.applicationCategories == .all(), "Clearing the exemption list disabled the lock")
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.reset() }
      check(shield.applicationCategories == nil, "Reset retained the workout lock")
    } else if scenario == "fitness-websites" {
      let service = try ScreenTimeService()
      let shield = ManagedSettingsStore.stores[.init("daywell.fitness")]!
      func expireRest() throws {
        try store.transaction { state in
          var training = FitnessTraining(restEnabled: true)
          training.completeGroup(at: now.addingTimeInterval(-60))
          state.fitness = training
        }
        _ = try service.refresh()
        check(shield.applicationCategories == .all(except: [1]), "Allowed apps were not preserved")
        check(
          shield.webDomainCategories == .all(), "Expired fitness rest left websites unrestricted")
      }
      try expireRest()
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: Date()) }
      check(shield.webDomainCategories == nil, "A new rest did not release websites")
      try expireRest()
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.reset() }
      check(shield.webDomainCategories == nil, "Reset left websites restricted")
      try expireRest()
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.setRestEnabled(false) }
      check(shield.webDomainCategories == nil, "Disabling rest left websites restricted")
      try expireRest()
      _ = try service.updateFitness(initial: FitnessTraining()) { training in
        for _ in 1..<6 { training.completeGroup(at: Date()) }
      }
      check(shield.webDomainCategories == nil, "Completing the round left websites restricted")
      check(shield.applicationCategories == nil, "Completing the round left apps restricted")
    } else if scenario == "fitness" {
      try store.transaction { state in
        var fitness = FitnessTraining(restEnabled: true)
        fitness.completeGroup(at: now.addingTimeInterval(-60))
        state.fitness = fitness
      }
      let restEnd = try store.read().fitness!.restEndsAt!
      DeviceActivityCenter.schedules[.init(MonitorPlan.fitnessRestName(for: restEnd))] =
        DeviceActivitySchedule(
          intervalStart: DateComponents(hour: 0), intervalEnd: DateComponents(hour: 23),
          repeats: false, warningTime: nil)
      World.onStop = { try store.transaction { _ in } }
      let service = try ScreenTimeService()
      _ = try service.refresh()
      check(
        World.callbackErrors.isEmpty,
        "Stopping the rest monitor blocked its callback: \(World.callbackErrors)")
      check(service.isFitnessShieldApplied, "Expired rest did not retain its fitness shield")
      check(
        World.callsUnderLock.isEmpty,
        "DeviceActivity called under the state lock: \(World.callsUnderLock)")
    } else if scenario == "selection-after-empty-reselection" {
      try store.transaction { $0.markAuthorizationRevoked() }
      let service = try ScreenTimeService()
      _ = try service.saveSelection(nil)
      _ = try service.saveSelection(
        JSONEncoder().encode(
          FamilyActivitySelection(includeEntireCategory: false, applicationTokens: [3])))
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]!.applications == [3],
        "Selecting apps after clearing a revoked selection did not restore the lock")
    } else if scenario == "selection-additions" || scenario == "selection-during-exemption" {
      let service = try ScreenTimeService()
      _ = try service.refresh()
      _ = try service.beginExemption()
      if scenario == "selection-additions" { _ = try service.endExemptions() }
      let before = try store.read().activeSessions(at: Date()).first!
      let updated = try service.saveSelection(
        JSONEncoder().encode(
          FamilyActivitySelection(
            includeEntireCategory: false, applicationTokens: [1, 3],
            categoryTokens: [4], webDomainTokens: [5])))
      let active = updated.activeSessions(at: Date()).first!
      let activeSelection = try JSONDecoder().decode(
        FamilyActivitySelection.self, from: active.selectionData)
      check(
        activeSelection.applicationTokens == [2, 3], "New apps were not added to the current lock")
      check(
        activeSelection.categoryTokens == [4] && activeSelection.webDomainTokens == [5],
        "New categories or websites were not added to the current lock")
      check(
        active.id == before.id && active.occurrence == before.occurrence
          && active.policy == before.policy && active.usedCount == before.usedCount
          && active.exemption == before.exemption,
        "Changing app selections changed the current interval, quota or exemption")
      let configured = try JSONDecoder().decode(
        FamilyActivitySelection.self, from: updated.selectionData!)
      check(configured.applicationTokens == [3], "Removed or allowed apps remained in future rules")
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      if scenario == "selection-during-exemption" {
        check(shield.applications == nil, "Adding an app cut short an ongoing exemption")
        _ = try service.endExemptions()
      }
      check(shield.applications == [2, 3], "Current app restrictions were not applied immediately")
      check(
        shield.applicationCategories == .specific([4], except: [1]), "Category shield is missing")
      check(shield.webDomains == [5], "Website shield is missing")
      let relaunched = try ScreenTimeService()
      _ = try relaunched.refresh()
      check(shield.applications == [2, 3], "Relaunch lost the expanded current lock")
      var tomorrow = try store.read()
      let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
      tomorrow.refresh(at: nextDay, calendar: calendar)
      let nextSelection = try JSONDecoder().decode(
        FamilyActivitySelection.self,
        from: tomorrow.activeSessions(at: nextDay).first!.selectionData)
      check(nextSelection == configured, "Removed apps remained locked in the next occurrence")
      _ = try relaunched.saveSelection(nil)
      check(shield.applications == [2, 3], "Clearing the selection released the current lock")
      check(try store.read().selectionData == nil, "Clearing the next selection was not saved")
    } else if scenario == "selection-union-limit" {
      try store.transaction { state in
        state.sessions = []
        state.selectionData = try JSONEncoder().encode(
          FamilyActivitySelection(includeEntireCategory: false, applicationTokens: Set(2...51)))
        state.refresh(at: now, calendar: calendar)
      }
      let service = try ScreenTimeService()
      _ = try service.refresh()
      let before = try store.read()
      let original = try Data(contentsOf: World.directory.appendingPathComponent("state.json"))
      var rejected = false
      do {
        _ = try service.saveSelection(
          JSONEncoder().encode(
            FamilyActivitySelection(includeEntireCategory: false, applicationTokens: [52])))
      } catch is ScreenTimeError { rejected = true }
      check(rejected, "An oversized active union was accepted")
      check(try store.read() == before, "A rejected selection changed the saved state")
      check(
        try Data(contentsOf: World.directory.appendingPathComponent("state.json")) == original,
        "A rejected selection overwrote the state file")
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]!.applications == Set(2...51),
        "A rejected selection released existing restrictions")
    } else if scenario == "sleep-websites" {
      let service = try ScreenTimeService()
      _ = try service.refresh()
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      check(shield.webDomains == [4], "Sleep did not shield the selected website")
      check(
        shield.webDomainCategories == .specific([3]),
        "Sleep did not preserve the selected website categories")
      _ = try service.beginExemption()
      check(
        shield.webDomains == nil && shield.webDomainCategories == nil,
        "A sleep exemption did not release websites")
      _ = try service.endExemptions()
      check(
        shield.webDomains == [4] && shield.webDomainCategories == .specific([3]),
        "Ending an exemption did not restore website restrictions")
      _ = try service.savePeriod(
        LockPeriod(id: period.id, start: period.start, end: period.end, isEnabled: false),
        verifiedSessionIDs: Set(try store.read().activeSessions(at: Date()).map(\.id)))
      check(
        shield.webDomains == nil && shield.webDomainCategories == nil,
        "Ending sleep left websites restricted")
    } else if scenario == "sleep" {
      let service = try ScreenTimeService()
      _ = try service.refresh()
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      check(
        shield.applications == [2], "Active sleep was not shielded after registering its release")
      World.rejectGrace = true
      do {
        _ = try service.beginExemption()
        check(false, "Failed release registration granted an exemption")
      } catch {}
      check(
        try store.read().activeSessions(at: Date()).first?.usedCount == 0,
        "Failed registration consumed a use")
      check(shield.applications == [2], "Failed registration removed the shield")
      World.rejectGrace = false
      _ = try service.beginExemption()
      check(shield.applications == nil, "Successful exemption did not release sleep apps")
      _ = try service.endExemptions()
      check(shield.applications == [2], "Ending exemption did not restore sleep apps")
      check(
        World.callsUnderLock.isEmpty,
        "DeviceActivity called under the state lock: \(World.callsUnderLock)")
    } else if scenario == "retry" {
      World.onStart = {
        try store.transaction { state in
          var second = try LockPeriod(
            start: clock(now.addingTimeInterval(7200)), end: clock(now.addingTimeInterval(10800)))
          second.morningEnabled = false
          state.periods.append(second)
        }
      }
      let service = try ScreenTimeService()
      _ = try service.refresh()
      let state = try store.read()
      check(state.periods.count == 2, "Concurrent schedule update was lost")
      let planned = Set(
        MonitorPlan.make(for: state, at: Date(), calendar: calendar).map {
          DeviceActivityName($0.name)
        })
      check(
        planned.isSubset(of: Set(DeviceActivityCenter.schedules.keys)),
        "Newer schedules were not retried")
      check(
        World.callsUnderLock.isEmpty,
        "DeviceActivity called under the state lock: \(World.callsUnderLock)")
    } else if scenario == "busy" {
      let model = DaywellModel()
      await model.refresh()
      let descriptor = open(World.directory.appendingPathComponent("state.lock").path, O_RDWR)
      guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
      let released = Task.detached {
        try await Task.sleep(for: .milliseconds(1500))
        _ = flock(descriptor, LOCK_UN)
      }
      let saved = await model.updateFitness { $0.completeGroup(at: Date()) }
      try await released.value
      close(descriptor)
      check(
        !saved && !model.isBusy, "A busy store left the model busy or claimed the write succeeded")
      check(
        model.fitness.progress.completedGroups == 0, "A timed-out write changed fitness progress")
      check(model.errorMessage != nil, "A timed-out operation did not report its failure")
      let retry = await model.updateFitness { $0.completeGroup(at: Date()) }
      check(
        retry && model.fitness.progress.completedGroups == 1,
        "A recovered store could not accept the next group")
    } else if scenario == "storage-error" {
      let model = DaywellModel()
      await model.refresh()
      let file = World.directory.appendingPathComponent("state.json")
      let saved = try Data(contentsOf: file)
      try Data("invalid json".utf8).write(to: file, options: .atomic)
      await model.refresh()
      check(
        !model.isBusy && model.startupError != nil, "Unreadable state did not release the busy UI")
      check(
        try Data(contentsOf: file) == Data("invalid json".utf8), "Unreadable state was overwritten")
      try saved.write(to: file, options: .atomic)
      await model.refresh()
      check(!model.isBusy && model.startupError == nil, "Recovery did not clear the startup error")
      check(model.state.selectionData == selection, "Recovery lost the saved selection")
    } else if scenario == "verification" {
      let model = DaywellModel()
      check(
        World.mainThreadInitializations == 0,
        "Screen Time clients were initialized on the UI thread")
      await model.refresh()
      check(
        World.mainThreadInitializations == 0,
        "Screen Time service started on the UI thread during refresh")
      var disabled = period
      disabled.isEnabled = false
      var prompted = false
      let saved = await model.savePeriod(disabled) { prompt in
        if case .verify = prompt {
          prompted = true
          check(!model.isBusy, "Verification was presented during a busy system operation")
        }
      }
      check(prompted && !saved, "The active toggle did not request verification")
      check(
        try store.read().periods.first?.isEnabled == true, "Verification changed the active period")
      check(!model.isBusy, "A rejected toggle left the UI busy")
    } else {
      check(false, "Unknown scenario: \(scenario)")
    }
    print("Passed:", scenario)
  }
  static func check(_ value: Bool, _ message: String) {
    guard value else {
      FileHandle.standardError.write(Data((message + "\n").utf8))
      exit(1)
    }
  }
}
