import Darwin
import Foundation

@MainActor enum LockInteractionChecks {
  static func run(_ scenario: String, store: StateStore) async throws {
    let now = Date()
    let calendar = Calendar.current
    func check(_ value: Bool, _ message: String) { Checks.check(value, message) }
    func data(_ apps: Set<Int>, domains: Set<Int> = []) throws -> Data {
      try JSONEncoder().encode(
        FamilyActivitySelection(
          includeEntireCategory: false, applicationTokens: apps, webDomainTokens: domains))
    }
    func period(_ start: TimeInterval, _ end: TimeInterval, morning: Bool = false) throws
      -> LockPeriod
    {
      func clock(_ offset: TimeInterval) throws -> ClockTime {
        let date = now.addingTimeInterval(offset)
        return try ClockTime(
          hour: calendar.component(.hour, from: date),
          minute: calendar.component(.minute, from: date))
      }
      return try LockPeriod(start: clock(start), end: clock(end), morningEnabled: morning)
    }
    func sleepStores() -> [FakeShield] {
      ManagedSettingsStore.stores.filter { $0.key.rawValue.hasPrefix("daywell.sleep") }.map(\.value)
    }
    func sleepApps() -> Set<Int> {
      sleepStores().reduce(into: []) { $0.formUnion($1.applications ?? []) }
    }
    func sleepDomains() -> Set<Int> {
      sleepStores().reduce(into: []) { $0.formUnion($1.webDomains ?? []) }
    }
    try store.transaction { $0.hadAuthorization = true }
    let service = try ScreenTimeService()
    let fitnessShield = ManagedSettingsStore.stores[.init("daywell.fitness")]!

    switch scenario {
    case "interaction-overflow-no-release-gap":
      let original = try period(-600, 3600)
      try store.transaction {
        $0.selectionData = try data(Set(11...60))
        $0.sessions = [
          LockSession(
            period: original,
            occurrence: PeriodOccurrence(
              periodID: original.id, start: now.addingTimeInterval(-60),
              end: now.addingTimeInterval(3600)),
            selectionData: try data(Set(11...60)), policy: .standard, morningSourceID: nil)
        ]
      }
      _ = try service.refresh()
      var releasedExistingApps = false
      World.onShieldChange = {
        if !sleepApps().isSuperset(of: Set(11...60)) { releasedExistingApps = true }
      }
      try store.transaction {
        $0.sessions[0].selectionData = try data(Set(1...60))
      }
      _ = try service.refresh()
      World.onShieldChange = nil
      check(
        !releasedExistingApps, "Adding a shield batch temporarily released previously locked apps")
      check(sleepApps() == Set(1...60), "Missing apps after batch expansion")

    case "interaction-selection-overflow", "interaction-overflow-revoke",
      "interaction-overflow-allowlist":
      let active = try period(-600, 3600)
      // Legacy oversized snapshot still needs batched cleanup after migration.
      try store.transaction {
        $0.selectionData = try data(Set(31...60), domains: Set(31...60))
        $0.periods = [active]
        $0.refresh(at: now, calendar: calendar)
        $0.sessions[0].selectionData = try data(Set(1...60), domains: Set(1...60))
      }
      _ = try service.refresh()
      check(sleepApps() == Set(1...60), "Combined sleep/morning lost app shields above 50")
      check(sleepDomains() == Set(1...60), "Combined sleep/morning lost website shields above 50")
      check(
        sleepStores().allSatisfy {
          ($0.applications?.count ?? 0) <= 50 && ($0.webDomains?.count ?? 0) <= 50
        }, "A store exceeded SDK token capacity")
      let relaunched = try ScreenTimeService()
      var expectedApps = Set(1...60)
      if scenario == "interaction-overflow-allowlist" {
        _ = try relaunched.saveAlwaysAllowedApplications(JSONEncoder().encode(Set([1, 60])))
        expectedApps.subtract([1, 60])
        check(sleepApps() == expectedApps, "Allowlist did not apply to every sleep batch")
      }
      if scenario == "interaction-overflow-revoke" {
        AuthorizationCenter.shared.authorizationStatus = .denied
        _ = try relaunched.refresh()
      } else {
        _ = try relaunched.beginExemption()
        check(sleepApps().isEmpty && sleepDomains().isEmpty, "Exemption left overflow restrictions")
        _ = try relaunched.endExemptions()
        check(sleepApps() == expectedApps, "Ending exemption failed to restore overflow")
        _ = try relaunched.updateFitness(initial: FitnessTraining(restEnabled: true)) {
          $0.completeGroup(at: now.addingTimeInterval(-120))
        }
        for original in [active] {
          var disabled = original
          disabled.isEnabled = false
          let ids = Set(
            try store.read().activeSessions(at: Date()).filter { $0.period.id == original.id }.map(
              \.id))
          _ = try relaunched.savePeriod(disabled, verifiedSessionIDs: ids)
        }
        check(
          fitnessShield.applicationCategories == nil,
          "Sleep-suppressed workout revived after disable")
        _ = try relaunched.updateFitness(initial: FitnessTraining()) {
          $0.completeGroup(at: Date().addingTimeInterval(-31))
        }
        let allowed: Set<Int> = scenario == "interaction-overflow-allowlist" ? [1, 60] : []
        check(
          fitnessShield.applicationCategories == .all(except: allowed),
          "Sleep cleanup changed fitness or its allowlist")
      }
      check(
        sleepApps().isEmpty && sleepDomains().isEmpty, "Relaunch cleanup left overflow restrictions"
      )

    case "interaction-selection-boundaries":
      for count in [50, 51, 100, 101, 1] {
        try store.transaction { state in
          state.selectionData = try data([1])
          let source = try period(-600, 3600)
          state.sessions = [
            LockSession(
              period: source,
              occurrence: PeriodOccurrence(
                periodID: source.id, start: now.addingTimeInterval(-60),
                end: now.addingTimeInterval(3600)),
              selectionData: try data(Set(1...count)), policy: .standard, morningSourceID: nil)
          ]
        }
        _ = try ScreenTimeService().refresh()
        check(sleepApps() == Set(1...count), "Batch boundary lost or retained apps at \(count)")
        check(sleepStores().allSatisfy { ($0.applications?.count ?? 0) <= 50 }, "Batch exceeded 50")
      }

    case "interaction-monitor-admission":
      World.monitorLimit = 20
      _ = try service.saveSelection(data([2]))
      for index in 0..<12 {
        _ = try service.savePeriod(
          period(Double(index + 1) * 3600, Double(index + 1) * 3600 + 1800, morning: true),
          verifiedSessionIDs: [])
      }
      let before = try store.read()
      do {
        _ = try service.savePeriod(
          period(13 * 3600, 13 * 3600 + 1800, morning: true), verifiedSessionIDs: [])
        check(
          false,
          "Accepted a configuration without capacity for its upcoming mornings and exemptions")
      } catch DaywellError.monitoringCapacityExceeded {}
      check(try store.read() == before, "Rejected schedule changed saved state")
      check(DeviceActivityCenter.schedules.count <= 20, "Admission exceeded system capacity")

    case "interaction-monitor-budget":
      World.monitorLimit = 20
      try store.transaction { state in
        state.selectionData = try data([2])
        state.periods = try (0..<6).map { i in
          try period(Double(i - 8) * 3600, Double(i - 8) * 3600 + 1800, morning: true)
        }
        for i in 0..<6 {
          state.refresh(at: now.addingTimeInterval(Double(i - 8) * 3600 + 900), calendar: calendar)
        }
        state.refresh(at: now, calendar: calendar)
        var fitness = FitnessTraining(restEnabled: true)
        fitness.setRestSeconds(3600)
        fitness.completeGroup(at: now)
        state.fitness = fitness
      }
      _ = try service.refresh()
      let windows = try store.read().pendingMornings(at: now)
      let retained = try store.read().morningWindows.first { $0.start > now }!
      let registrations = World.startCounts[.init(retained.monitorName)]
      try service.reachMorningLimit(
        activity: .init(windows.first!.monitorName),
        event: .init(MonitorPlan.UsageThreshold.eventName))
      do { _ = try service.beginExemption() } catch {
        check(false, "Individually valid features exhausted monitors during exemption: \(error)")
      }
      check(sleepApps().isEmpty, "Successful exemption did not release sleep")
      check(DeviceActivityCenter.schedules.count <= 20, "Monitoring capacity exceeded")
      check(
        World.startCounts[.init(retained.monitorName)] == registrations,
        "Budget reset an accumulating morning event")

    case "interaction-fitness-registration-failure":
      _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
        $0.completeGroup(at: now.addingTimeInterval(-120))
      }
      let before = try store.read().fitness
      World.rejectFitness = true
      do {
        _ = try service.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: Date()) }
        check(false, "Expected fitness registration rejection")
      } catch {}
      check(try store.read().fitness == before, "Failed registration committed a new group/rest")
      check(
        fitnessShield.applicationCategories == .all(), "Failed update changed the original lock")
      World.rejectFitness = false
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: Date()) }
      check(
        try store.read().fitness?.progress.completedGroups == 2,
        "Retry did not complete exactly one new group")
      check(
        try store.read().fitness?.restSecondsRemaining(at: Date()) == 30,
        "Retry did not grant the full rest")
      check(
        fitnessShield.applicationCategories == nil, "Registered new rest retained old fitness lock")

    case "interaction-fitness-concurrent-reset", "interaction-fitness-revoke":
      _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
        $0.completeGroup(at: now.addingTimeInterval(-120))
      }
      World.onStart = {
        if scenario == "interaction-fitness-revoke" {
          AuthorizationCenter.shared.authorizationStatus = .denied
          try store.transaction { $0.markAuthorizationRevoked() }
        } else {
          try store.transaction { $0.fitness?.reset() }
        }
      }
      do {
        _ = try service.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: Date()) }
        check(false, "Staged workout overwrote a concurrent reset or revocation")
      } catch ScreenTimeError.configurationChanged {}
      let after = try store.read()
      check(
        fitnessShield.applicationCategories == nil, "Abandoned workout retained a fitness shield")
      if scenario == "interaction-fitness-revoke" {
        check(
          !after.hadAuthorization && after.needsApplicationReselection,
          "Staged workout restored revoked authorization")
        check(DeviceActivityCenter.schedules.isEmpty, "Revocation left staged monitors")
      } else {
        check(
          after.fitness?.progress.completedGroups == 0, "Staged workout replaced the newer reset")
        check(
          !DeviceActivityCenter.schedules.keys.contains {
            $0.rawValue.hasPrefix(MonitorPlan.fitnessRestPrefix)
          }, "Abandoned workout left a rest monitor")
      }

    case "interaction-end-contention":
      let end = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970) + 1)
      let expiredPeriod = try period(-600, 3600)
      let otherPeriod = try period(7200, 10800)
      try store.transaction {
        $0.selectionData = try data([2])
        $0.sessions = [
          LockSession(
            period: expiredPeriod,
            occurrence: PeriodOccurrence(
              periodID: expiredPeriod.id, start: now.addingTimeInterval(-60), end: end),
            selectionData: try data([2]), policy: .standard, morningSourceID: nil),
          LockSession(
            period: otherPeriod,
            occurrence: PeriodOccurrence(
              periodID: otherPeriod.id, start: end,
              end: now.addingTimeInterval(3600)), selectionData: try data([3]), policy: .standard,
            morningSourceID: nil),
        ]
      }
      _ = try service.refresh()
      _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
        $0.completeGroup(at: now.addingTimeInterval(-120))
      }
      check(sleepApps() == [2], "Contention setup failed")
      try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow) + 0.05))
      let descriptor = open(World.directory.appendingPathComponent("state.lock").path, O_RDWR)
      guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
      let release = Task.detached {
        try await Task.sleep(for: .milliseconds(1300))
        _ = flock(descriptor, LOCK_UN)
      }
      ActivityMonitor().intervalDidEnd(for: .init(MonitorPlan.endGuardName(for: end)))
      try await release.value
      close(descriptor)
      check(
        sleepApps() == [3], "End callback left expired restriction after temporary state contention"
      )
      check(fitnessShield.applicationCategories == nil, "Old fitness timer overrode the new sleep")
    case "interaction-v2-sleep-takeover":
      _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
        $0.completeGroup(at: now.addingTimeInterval(-120))
      }
      let originalEnd = try store.read().fitness!.restEndsAt!
      check(fitnessShield.applicationCategories == .all(), "Workout did not initially lock")
      _ = try service.saveSelection(data([2]))
      var gap = false
      World.onShieldChange = {
        if fitnessShield.applicationCategories == nil && !sleepApps().contains(2) { gap = true }
      }
      var sleep = try period(-600, 3600)
      _ = try service.savePeriod(sleep, verifiedSessionIDs: [])
      World.onShieldChange = nil
      check(!gap, "Sleep takeover briefly released both owners")
      check(
        fitnessShield.applicationCategories == nil && sleepApps() == [2], "Sleep did not take over")
      _ = try service.beginExemption()
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: now) }
      check(
        try store.read().fitness?.locksAfterRest == false, "Sleep exemption allowed workout locking"
      )
      check(try store.read().fitness?.progress.completedGroups == 2, "Takeover lost group count")
      sleep.isEnabled = false
      let ids = Set(try store.read().activeSessions(at: Date()).map(\.id))
      _ = try service.savePeriod(sleep, verifiedSessionIDs: ids)
      try service.reachFitnessDeadline(
        activity: .init(MonitorPlan.fitnessRestName(for: originalEnd)))
      check(fitnessShield.applicationCategories == nil, "Old workout revived after sleep stopped")
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: Date()) }
      check(try store.read().fitness?.locksAfterRest == true, "New group after sleep cannot lock")

    case "interaction-v2-failed-group-keeps-morning", "interaction-v2-morning-takeover":
      let sleep = try period(-7200, -3600, morning: true)
      try store.transaction {
        $0.selectionData = try data([2])
        $0.periods = [sleep]
        $0.refresh(at: now.addingTimeInterval(-5400), calendar: calendar)
        $0.refresh(at: now, calendar: calendar)
      }
      _ = try service.refresh()
      let window = try store.read().pendingMornings(at: now).first!
      if scenario == "interaction-v2-failed-group-keeps-morning" {
        World.rejectFitnessIdle = true
        do {
          _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
            $0.completeGroup(at: now)
          }
          check(false, "A workout was committed without its inactivity monitor")
        } catch {}
        check(try store.read().fitness == nil, "A failed group changed the counter")
        check(
          try store.read().pendingMornings(at: now).first?.id == window.id,
          "Failed group cancelled morning")
        check(
          DeviceActivityCenter.schedules[.init(window.monitorName)] != nil,
          "Failed group removed morning usage")
        check(
          !DeviceActivityCenter.schedules.keys.contains {
            $0.rawValue.hasPrefix(MonitorPlan.fitnessRestPrefix)
          }, "Failed group left a staged rest")
        World.rejectFitnessIdle = false
      } else {
        try service.reachMorningLimit(
          activity: .init(window.monitorName), event: .init(MonitorPlan.UsageThreshold.eventName))
        _ = try service.beginExemption()
      }
      _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
        $0.completeGroup(at: Date())
      }
      try service.reachMorningLimit(
        activity: .init(window.monitorName), event: .init(MonitorPlan.UsageThreshold.eventName))
      check(
        try store.read().activeSessions(at: Date()).isEmpty, "Old morning callback revived its lock"
      )
      check(
        sleepApps().isEmpty && fitnessShield.applicationCategories == nil,
        "New rest retained morning lock")
      check(
        DeviceActivityCenter.schedules[.init(window.monitorName)] == nil,
        "Cancelled morning usage was not removed")
      check(
        !DeviceActivityCenter.schedules.keys.contains { $0.rawValue.contains(".grace.") },
        "Cancelled morning retained exemption monitors")

    case "interaction-v2-idle-clears-fitness", "interaction-v2-idle-keeps-sleep":
      _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
        $0.completeGroup(at: now.addingTimeInterval(-120))
      }
      let oldIdle = try store.read().fitness!.inactivityEndsAt!
      if scenario == "interaction-v2-idle-keeps-sleep" {
        _ = try service.saveSelection(data([2]))
        _ = try service.savePeriod(period(-600, 3600), verifiedSessionIDs: [])
      }
      try store.transaction {
        var expired = FitnessTraining(restEnabled: true)
        expired.completeGroup(at: now.addingTimeInterval(-1801))
        $0.fitness = expired
      }
      ActivityMonitor().intervalDidEnd(for: .init(MonitorPlan.fitnessIdleName(for: oldIdle)))
      check(
        try store.read().fitness?.progress.completedGroups == 0,
        "Idle callback did not reset groups")
      check(fitnessShield.applicationCategories == nil, "Idle callback retained workout lock")
      check(
        !DeviceActivityCenter.schedules.keys.contains { $0.rawValue.contains(".fitness.") },
        "Idle callback retained workout monitors")
      check(
        sleepApps() == (scenario == "interaction-v2-idle-keeps-sleep" ? [2] : []),
        "Idle cleanup affected sleep")

    case "interaction-v2-stale-idle-keeps-new-group":
      _ = try service.updateFitness(initial: FitnessTraining(restEnabled: true)) {
        $0.completeGroup(at: now.addingTimeInterval(-120))
      }
      let oldIdle = try store.read().fitness!.inactivityEndsAt!
      _ = try service.updateFitness(initial: FitnessTraining()) { $0.completeGroup(at: Date()) }
      let current = try store.read().fitness
      ActivityMonitor().intervalDidEnd(for: .init(MonitorPlan.fitnessIdleName(for: oldIdle)))
      check(try store.read().fitness == current, "Old inactivity callback reset a newer group")
      check(fitnessShield.applicationCategories == nil, "Old inactivity callback locked a new rest")

    default:
      check(false, "Unknown interaction scenario")
    }
    check(World.callsUnderLock.isEmpty, "DeviceActivity called with state lock held")
    check(World.reentrantCalls.isEmpty, "DeviceActivity was reentered synchronously")
  }
}
