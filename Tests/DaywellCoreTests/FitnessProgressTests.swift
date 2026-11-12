import Foundation
import Testing

@testable import DaywellCore

struct FitnessProgressTests {
  @Test func eachNonFinalGroupStartsAFullRestAndFinalGroupClearsIt() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var training = FitnessTraining(progress: FitnessProgress(targetGroups: 3), restEnabled: true)
    #expect(training.restSecondsRemaining(at: start) == nil)

    let firstFinished = training.completeGroup(at: start)
    #expect(!firstFinished)
    #expect(training.restSecondsRemaining(at: start) == 30)
    #expect(!training.isLocked(at: start.addingTimeInterval(29.9)))
    #expect(training.isLocked(at: start.addingTimeInterval(30)))

    let second = start.addingTimeInterval(90)
    let secondFinished = training.completeGroup(at: second)
    #expect(!secondFinished)
    #expect(training.progress.completedGroups == 2)
    #expect(training.restSecondsRemaining(at: second) == 30)
    #expect(!training.isLocked(at: second))

    let finalFinished = training.completeGroup(at: second.addingTimeInterval(90))
    #expect(finalFinished)
    #expect(training.progress.completedGroups == 0)
    #expect(training.restEndsAt == nil)
  }

  @Test func disablingRestKeepsProgressAndDoesNotRestartUntilTheNextGroup() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var training = FitnessTraining(restEnabled: true)
    training.completeGroup(at: now)
    training.setRestEnabled(false)
    #expect(training.progress.completedGroups == 1)
    #expect(training.restEndsAt == nil)
    training.setRestEnabled(true)
    #expect(training.restEndsAt == nil)
    training.setRestSeconds(60)
    training.completeGroup(at: now.addingTimeInterval(30))
    #expect(training.restSecondsRemaining(at: now.addingTimeInterval(30)) == 60)
    training.reset()
    #expect(training.progress.completedGroups == 0)
    #expect(training.restEndsAt == nil)
  }

  @Test func completingAGroupDuringRestReplacesTheCountdownAndLockDeadline() throws {
    let firstGroup = date("2026-11-11T13:01:00+08:00")
    let nextGroup = firstGroup.addingTimeInterval(13)
    var training = FitnessTraining(progress: FitnessProgress(targetGroups: 4), restEnabled: true)
    training.setRestSeconds(120)
    training.completeGroup(at: firstGroup)
    let oldDeadline = try #require(training.restEndsAt)
    #expect(training.restSecondsRemaining(at: nextGroup) == 107)

    training.completeGroup(at: nextGroup)
    #expect(training.progress.completedGroups == 2)
    #expect(training.restSecondsRemaining(at: nextGroup) == 120)
    #expect(!training.isLocked(at: oldDeadline))
    #expect(training.isLocked(at: nextGroup.addingTimeInterval(120)))

    var state = DaywellState()
    state.fitness = training
    state.alwaysAllowedApplicationsData = Data([1])
    let plans = MonitorPlan.make(for: state, at: nextGroup, calendar: shanghai)
    #expect(plans.count == 2)
    let plan = try #require(plans.first { $0.name.hasPrefix(MonitorPlan.fitnessRestPrefix) })
    #expect(shanghai.date(from: plan.start) == nextGroup.addingTimeInterval(120))
  }

  @Test func trainingRestAndCounterSurviveReloadAndUseALegalWakeWindow() throws {
    let start = date("2026-11-11T13:01:00+08:00")
    var state = DaywellState()
    var training = FitnessTraining(restEnabled: true)
    training.completeGroup(at: start)
    state.fitness = training
    state.alwaysAllowedApplicationsData = Data([1])
    let restored = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(state))
    #expect(restored.fitness?.progress.completedGroups == 1)
    #expect(restored.fitness?.restSecondsRemaining(at: start.addingTimeInterval(12)) == 18)

    let plans = MonitorPlan.make(for: restored, at: start, calendar: shanghai)
    let wake = try #require(plans.first { $0.name.hasPrefix(MonitorPlan.fitnessRestPrefix) })
    let monitorStart = try #require(shanghai.date(from: wake.start))
    let monitorEnd = try #require(shanghai.date(from: wake.end))
    #expect(plans.count == 2)
    #expect(monitorStart == start.addingTimeInterval(30))
    #expect(monitorEnd.timeIntervalSince(monitorStart) >= 15 * 60)
    #expect(!wake.repeats)
    #expect(
      MonitorPlan.make(for: restored, at: monitorStart, calendar: shanghai).map(\.name) == [
        MonitorPlan.fitnessIdleName(for: start.addingTimeInterval(1800))
      ])
  }

  @Test func pendingAuthorizationDoesNotEraseTheRestOrAllowedApplications() throws {
    let start = date("2026-11-11T13:01:00+08:00")
    let allowed = Data([1, 2])
    var state = DaywellState()
    state.updateAuthorization(true)
    state.alwaysAllowedApplicationsData = allowed
    var training = FitnessTraining(restEnabled: true)
    training.completeGroup(at: start)
    state.fitness = training
    let saved = try JSONDecoder().decode(DaywellState.self, from: JSONEncoder().encode(state))
    state = saved

    state.updateAuthorization(nil)
    #expect(state.hadAuthorization)
    #expect(state.alwaysAllowedApplicationsData == allowed)
    #expect(state.fitness?.restSecondsRemaining(at: start) == 30)
    #expect(MonitorPlan.make(for: state, at: start, calendar: shanghai).count == 2)

    state.updateAuthorization(false)
    #expect(!state.hadAuthorization)
    #expect(state.alwaysAllowedApplicationsData == nil)
    #expect(state.fitness?.progress.completedGroups == 1)
    #expect(state.fitness?.restSecondsRemaining(at: start) == 30)
    #expect(!state.hasFitnessRestriction(at: start.addingTimeInterval(30)))
  }

  @Test func workoutPlansAndLocksWithAnEmptyOptionalExemptionList() {
    let start = date("2026-11-11T13:01:00+08:00")
    var training = FitnessTraining(restEnabled: true)
    training.completeGroup(at: start)
    var state = DaywellState()
    state.hadAuthorization = true
    state.fitness = training

    #expect(state.fitness?.restSecondsRemaining(at: start) == 30)
    #expect(MonitorPlan.make(for: state, at: start, calendar: shanghai).count == 2)
    #expect(!state.hasFitnessRestriction(at: start.addingTimeInterval(29)))
    #expect(state.hasFitnessRestriction(at: start.addingTimeInterval(30)))

    state.alwaysAllowedApplicationsData = Data([1])
    #expect(MonitorPlan.make(for: state, at: start, calendar: shanghai).count == 2)
    #expect(state.hasFitnessRestriction(at: start.addingTimeInterval(30)))
    state.markAuthorizationRevoked()
    #expect(!state.hasFitnessRestriction(at: start.addingTimeInterval(30)))
  }

  @Test func sixthGroupCompletesAndNextGroupStartsANewRound() {
    var progress = FitnessProgress()
    for _ in 0..<5 {
      let finished = progress.completeGroup()
      #expect(!finished)
    }
    #expect(progress.completedGroups == 5)
    let finished = progress.completeGroup()
    #expect(finished)
    #expect(progress.completedGroups == 0)
    let nextRoundFinished = progress.completeGroup()
    #expect(!nextRoundFinished)
    #expect(progress.completedGroups == 1)
  }

  @Test func manualResetKeepsTheChosenTarget() {
    var progress = FitnessProgress(targetGroups: 4, completedGroups: 3)
    progress.reset()
    #expect(progress.completedGroups == 0)
    #expect(progress.targetGroups == 4)
    let finished = progress.completeGroup()
    #expect(!finished)
    #expect(progress.completedGroups == 1)
  }

  @Test func changingTargetStartsAFreshRoundButSavingSameTargetKeepsProgress() {
    var progress = FitnessProgress(targetGroups: 6, completedGroups: 4)
    progress.setTargetGroups(6)
    #expect(progress.completedGroups == 4)
    progress.setTargetGroups(2)
    #expect(progress.completedGroups == 0)
    let first = progress.completeGroup()
    let second = progress.completeGroup()
    #expect(!first)
    #expect(second)
    #expect(progress.completedGroups == 0)
  }

  @Test func invalidSavedProgressCannotProduceAnOutOfRangeCounter() {
    var progress = FitnessProgress(targetGroups: 0, completedGroups: -3)
    #expect(progress.targetGroups == 1)
    #expect(progress.completedGroups == 0)
    let finished = progress.completeGroup()
    #expect(finished)
    #expect(progress.completedGroups == 0)
    let restored = FitnessProgress(targetGroups: 6, completedGroups: 6)
    #expect(restored.completedGroups == 0)
  }
}
