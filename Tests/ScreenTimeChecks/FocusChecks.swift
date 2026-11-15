import Foundation

enum FocusChecks {
  @MainActor static func run(_ scenario: String, store: StateStore) async throws {
    let check = Checks.check
    let now = Date()
    let app = try JSONEncoder().encode(2)
    try store.transaction {
      $0.hadAuthorization = true
      $0.alwaysAllowedApplicationsData = try JSONEncoder().encode(Set([1]))
    }
    let service = try ScreenTimeService()
    _ = try service.saveFocusApplication(app)
    _ = try service.saveFocusMinutes(1)

    switch scenario {
    case "focus-category-selection":
      let model = DaywellModel()
      await model.refresh()
      let selection = FamilyActivitySelection(
        includeEntireCategory: true, applicationTokens: [3], categoryTokens: [7],
        webDomainTokens: [8])
      check(
        await model.saveFocusSelection(selection),
        "A single app was rejected because the picker also selected its parent category")
      let replacement = try JSONEncoder().encode(3)
      check(
        model.state.focusConfiguration.applicationData == replacement,
        "Saving did not update the displayed focus app")
      let reloaded = DaywellModel()
      await reloaded.refresh()
      check(
        reloaded.state.focusConfiguration.applicationData == replacement,
        "Reopening restored the previous app")
      check(await reloaded.beginFocus(), "The saved app could not start focus")
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      check(
        shield.applicationCategories == .all(except: [1, 3]),
        "Focus did not use exactly the newly selected app and the global allowlist")
      check(
        shield.webDomains == nil && shield.webDomainCategories == nil,
        "Picker category or website metadata leaked into focus restrictions")

    case "focus-selection-replacement":
      let model = DaywellModel()
      await model.refresh()
      let replacement = FamilyActivitySelection(includeEntireCategory: true, applicationTokens: [3])
      let replacementData = try JSONEncoder().encode(3)
      // Repeated delivery of the same picker value must never toggle back to the old app.
      for _ in 0..<3 {
        check(await model.saveFocusSelection(replacement), "Could not replace the saved app")
        check(
          model.state.focusConfiguration.applicationData == replacementData,
          "Repeated selection switched back to the previous app")
      }
      let reloaded = DaywellModel()
      await reloaded.refresh()
      check(
        reloaded.state.focusConfiguration.applicationData
          == model.state.focusConfiguration.applicationData,
        "Displayed selection and persisted selection diverged")
      check(await reloaded.beginFocus(), "Could not begin focus with the replacement")
      let session = reloaded.state.focusSession!
      let original = FamilyActivitySelection(includeEntireCategory: true, applicationTokens: [2])
      check(!(await reloaded.saveFocusSelection(original)), "Changed the target during focus")
      let verification = FocusDeactivation(sessionID: session.id)
      check(
        await reloaded.endFocus(verification, enteredCode: verification.code),
        "Could not end focus before changing its app")
      check(
        await reloaded.saveFocusSelection(original), "Could not change the app after focus ended")
      check(
        reloaded.state.focusConfiguration.applicationData == app, "The replacement did not persist")

    case "focus-selection-invalid":
      let model = DaywellModel()
      await model.refresh()
      let before = model.state.focusConfiguration
      let multiple = FamilyActivitySelection(
        includeEntireCategory: true, applicationTokens: [3, 4])
      check(!(await model.saveFocusSelection(multiple)), "Multiple focus apps were accepted")
      check(
        model.errorMessage?.contains("当前已选 2 个") == true,
        "Multiple app selection did not explain how many apps must be reduced to one")
      let category = FamilyActivitySelection(includeEntireCategory: true, categoryTokens: [7])
      let website = FamilyActivitySelection(includeEntireCategory: true, webDomainTokens: [8])
      let empty = FamilyActivitySelection(includeEntireCategory: true)
      for selection in [category, website, empty] {
        check(!(await model.saveFocusSelection(selection)), "Saved focus without a concrete app")
        check(model.errorMessage != nil, "Invalid selection had no user-facing explanation")
        check(
          model.state.focusConfiguration == before, "Invalid selection changed the existing app")
      }
      check(
        await model.saveFocusSelection(
          FamilyActivitySelection(includeEntireCategory: true, applicationTokens: [3])),
        "Correcting the selection could not save")
      check(model.errorMessage == nil, "Successful save kept the previous selection error")

    case "focus-selection":
      do {
        _ = try service.saveFocusApplication(Data([0xff]))
        fatalError("Malformed token accepted")
      } catch is DecodingError {}
      check(
        try store.read().focusConfiguration.applicationData == app,
        "Invalid save replaced the target")

    case "focus-registration-failure", "focus-revoked-during-start":
      if scenario == "focus-registration-failure" {
        World.rejectFocus = true
      } else {
        World.onStart = { try store.transaction { $0.markAuthorizationRevoked() } }
      }
      do {
        _ = try service.beginFocus()
        fatalError("Rejected focus start reported success")
      } catch {}
      let state = try store.read()
      check(state.focusSession == nil, "Failed start persisted a focus round")
      check(state.focusConfiguration.recentApplications.isEmpty, "Failed start changed history")
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]?.applicationCategories == nil,
        "Failed start applied a shield")
      check(
        !DeviceActivityCenter.schedules.keys.contains {
          $0.rawValue.hasPrefix("daywell.focus.end.")
        }, "Failed start leaked a staged monitor")

    case "focus-allowlist-limit":
      _ = try service.saveAlwaysAllowedApplications(JSONEncoder().encode(Set(10..<60)))
      do {
        _ = try service.beginFocus()
        fatalError("51 application exceptions were accepted")
      } catch ScreenTimeError.focusExceptionLimitExceeded {}
      check(try store.read().focusSession == nil, "An oversized exception list started focus")
      _ = try service.saveAlwaysAllowedApplications(JSONEncoder().encode(Set(10..<59)))
      _ = try service.beginFocus()
      do {
        _ = try service.saveAlwaysAllowedApplications(JSONEncoder().encode(Set(10..<60)))
        fatalError("Changing the allowlist silently exceeded the running focus limit")
      } catch ScreenTimeError.focusExceptionLimitExceeded {}
      check(try store.read().focusSession != nil, "Rejected allowlist edit stopped focus")

    case "focus-expiry":
      try store.transaction {
        try $0.startFocus(at: now.addingTimeInterval(-120), calendar: .current)
      }
      _ = try service.refresh()
      check(try store.read().focusSession == nil, "Expired focus survived relaunch")
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]?.applicationCategories == nil,
        "Expired focus applied a shield")

    case "focus-blocked-sleep", "focus-blocked-sleep-exemption", "focus-blocked-morning",
      "focus-blocked-morning-exemption", "focus-blocked-fitness":
      if scenario == "focus-blocked-fitness" {
        _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
          $0.completeGroup(at: now.addingTimeInterval(-60))
        }
      } else {
        let calendar = Calendar.current
        func clock(_ date: Date) throws -> ClockTime {
          try ClockTime(
            hour: calendar.component(.hour, from: date),
            minute: calendar.component(.minute, from: date))
        }
        _ = try service.saveSelection(
          JSONEncoder().encode(
            FamilyActivitySelection(includeEntireCategory: false, applicationTokens: [9])))
        if scenario.contains("morning") {
          let period = try LockPeriod(
            start: clock(now.addingTimeInterval(-1800)),
            end: clock(now.addingTimeInterval(-900)), morningEnabled: true)
          try store.transaction {
            $0.periods = [period]
            $0.lastEvaluatedAt = nil
            $0.refresh(at: now.addingTimeInterval(-1200), calendar: calendar)
          }
          let state = try service.refresh()
          let window = state.pendingMornings(at: Date()).first!
          try service.reachMorningLimit(
            activity: .init(window.monitorName), event: .init(MonitorPlan.UsageThreshold.eventName))
        } else {
          _ = try service.savePeriod(
            LockPeriod(
              start: clock(now.addingTimeInterval(-600)),
              end: clock(now.addingTimeInterval(1200))), verifiedSessionIDs: [])
        }
        if scenario.hasSuffix("exemption") { _ = try service.beginExemption() }
      }
      let model = DaywellModel()
      await model.refresh()
      let before = model.state
      let sessions = before.activeSessions(at: model.now)
      if scenario == "focus-blocked-fitness" {
        check(before.hasFitnessRestriction(at: model.now), "Fitness fixture is not locked")
      } else {
        check(sessions.count == 1, "Expected one higher-priority lock")
        check(sessions[0].isMorning == scenario.contains("morning"), "Wrong lock owner")
        check(
          sessions[0].isExempt(at: model.now) == scenario.hasSuffix("exemption"),
          "Wrong exemption state")
      }
      check(!(await model.beginFocus()), "Focus started during a higher-priority lock")
      check(
        model.errorMessage == DaywellError.focusUnavailable.localizedDescription,
        "Rejected start did not expose the lock error")
      check(model.state.focusSession == nil, "Rejected start left a running focus")
      check(
        model.state.sessions == before.sessions && model.state.fitness == before.fitness,
        "Rejected start changed the existing lock or its exemption")
      check(
        model.state.focusConfiguration == before.focusConfiguration,
        "Rejected start changed focus settings or history")
      check(
        !DeviceActivityCenter.schedules.keys.contains {
          $0.rawValue.hasPrefix("daywell.focus.end.")
        },
        "Rejected start registered a focus monitor")

    case "focus-model-close":
      let model = DaywellModel()
      await model.refresh()
      check(await model.beginFocus(), "Model could not start focus")
      let id = model.state.focusSession!.id
      let verification = FocusDeactivation(sessionID: id)
      check(
        !(await model.endFocus(verification, enteredCode: "000000")),
        "Wrong verification code ended focus")
      check(model.state.focusSession?.id == id, "Wrong code changed the round")
      check(
        await model.endFocus(verification, enteredCode: verification.code),
        "Correct verification code did not end focus")
      check(model.state.focusSession == nil, "Closing did not return the model to the idle state")
      check(
        model.state.focusConfiguration.applicationData == app
          && model.state.focusConfiguration.minutes == 1
          && model.state.focusConfiguration.recentApplications == [app],
        "Closing discarded the selection, duration or recent applications")
      check(
        ManagedSettingsStore.stores[.init("daywell.sleep")]?.applicationCategories == nil,
        "Closing through the model left focus restrictions applied")
      check(await model.beginFocus(), "Model could not start a second focus")
      check(
        !(await model.endFocus(verification, enteredCode: verification.code)),
        "Old verification closed a new round")
      check(model.state.focusSession != nil, "A stale code ended the latest round")

    default:
      if scenario == "focus-start" {
        World.onStart = {
          check(
            try store.read().focusSession == nil, "Focus was committed before registering recovery")
          check(
            ManagedSettingsStore.stores[.init("daywell.sleep")]?.applicationCategories == nil,
            "Focus shield was installed before its release guard")
          ActivityMonitor().intervalDidStart(for: .init("daywell.focus.end.immediate-callback"))
        }
      }
      let started = try service.beginFocus()
      let session = started.focusSession!
      let shield = ManagedSettingsStore.stores[.init("daywell.sleep")]!
      check(
        shield.applicationCategories == .all(except: [1, 2]),
        "Focus did not preserve target + global allowlist")
      check(
        shield.webDomainCategories == nil && shield.webDomains == nil,
        "Focus blocked the selected browser's websites")
      check(
        DeviceActivityCenter.schedules[.init(session.monitorName)] != nil,
        "Focus shield lacks a release guard")
      check(started.focusConfiguration.recentApplications == [app], "Successful start not recorded")
      check(!service.isFitnessShieldApplied, "Focus was mistaken for a fitness lock")

      if scenario == "focus-sleep-takeover" {
        let calendar = Calendar.current
        func clock(_ date: Date) throws -> ClockTime {
          try ClockTime(
            hour: calendar.component(.hour, from: date),
            minute: calendar.component(.minute, from: date))
        }
        _ = try service.saveSelection(
          JSONEncoder().encode(
            FamilyActivitySelection(includeEntireCategory: false, applicationTokens: [9])))
        _ = try service.savePeriod(
          LockPeriod(
            start: clock(now.addingTimeInterval(-600)), end: clock(now.addingTimeInterval(600))),
          verifiedSessionIDs: [])
        ActivityMonitor().intervalDidEnd(for: .init(session.monitorName))
        check(try store.read().focusSession == nil, "Sleep did not permanently cancel focus")
        check(
          shield.applications == [9] && shield.applicationCategories == nil,
          "Old focus callback cleared or broadened sleep")
      } else if scenario == "focus-fitness-takeover" {
        _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
          $0.completeGroup(at: now.addingTimeInterval(-60))
        }
        check(try store.read().focusSession == nil, "Fitness did not cancel focus")
        check(service.isFitnessShieldApplied, "Fitness was not installed after takeover")
        ActivityMonitor().intervalDidEnd(for: .init(session.monitorName))
        check(service.isFitnessShieldApplied, "Old focus end cleared fitness")
      } else if scenario == "focus-settings" {
        _ = try service.saveFocusMinutes(120)
        check(try store.read().focusSession == session, "Settings changed the running deadline")
        do {
          _ = try service.saveFocusApplication(JSONEncoder().encode(3))
          fatalError("Target could change during a running focus")
        } catch DaywellError.focusAlreadyActive {}
        check(try store.read().focusSession == session, "Rejected target edit changed focus")
      } else {
        let reloaded = try ScreenTimeService().refresh()
        check(reloaded.focusSession == session, "Relaunch reset focus")
        _ = try service.endFocus(id: session.id)
        check(shield.applicationCategories == nil, "Closing left focus restrictions applied")
        let next = try service.beginFocus().focusSession!
        ActivityMonitor().intervalDidEnd(for: .init(session.monitorName))
        check(try store.read().focusSession?.id == next.id, "Old callback closed a new focus")
        check(
          shield.applicationCategories == .all(except: [1, 2]),
          "Old callback released the new shield")
      }
    }
    check(World.callsUnderLock.isEmpty, "Focus called DeviceActivity under the state lock")
    check(World.reentrantCalls.isEmpty, "Focus reentered monitor registration")
  }
}
