import DaywellCore
import SwiftUI
import UIKit

struct FitnessView: View {
  let openSettings: () -> Void
  @EnvironmentObject private var model: DaywellModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var holdStartedAt: ContinuousClock.Instant?
  @State private var holdRecognized = false
  @State private var confirmingGroup = false
  @State private var cancelledPress = false
  @State private var celebrating = false
  @State private var completedTarget = 0
  fileprivate static let holdSeconds = 1

  private var progress: FitnessProgress { model.fitness.progress }

  var body: some View {
    GeometryReader { geometry in
      let diameter = min(320, max(210, min(geometry.size.width - 56, geometry.size.height - 355)))
      ScrollView {
        VStack(spacing: 20) {
          PageHeading(tab: .fitness) {
            cancelInteraction()
            openSettings()
          }
          VStack(spacing: 8) {
            Text(celebrating ? "这一轮，完成得很棒！" : "一组一组，慢慢变强。")
              .font(.title3.weight(.semibold))
            Text(
              celebrating ? "\(completedTarget) 组已完成，准备好再开始。" : "本轮目标 \(progress.targetGroups) 组"
            )
            .font(.subheadline).foregroundStyle(DaywellTheme.muted)
          }
          .multilineTextAlignment(.center)
          .padding(.top, 8)
          if model.fitness.restEnabled { restStatus }
          counter(diameter: diameter)
          Button(action: reset) {
            VStack(spacing: 8) {
              Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 23, weight: .medium))
                .frame(width: 62, height: 62)
                .background(DaywellTheme.surface, in: Circle())
                .overlay(Circle().stroke(DaywellTheme.border, lineWidth: 1))
              Text("重置本轮").font(.footnote)
            }
            .foregroundStyle(DaywellTheme.muted)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(progress.completedGroups == 0 || celebrating || model.isBusy)
          .accessibilityLabel("重置本轮")
          .accessibilityIdentifier("fitness.reset")
          Text("目标组数可在右上角设置中调整")
            .font(.footnote).foregroundStyle(DaywellTheme.muted)
        }
        .padding(24)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
      }
      .scrollIndicators(.hidden)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { cancelInteraction() }
    }
    .onDisappear { cancelInteraction() }
    .task(id: holdRecognized) {
      guard holdRecognized, let startedAt = holdStartedAt else { return }
      do {
        try await ContinuousClock().sleep(until: startedAt.advanced(by: .seconds(Self.holdSeconds)))
      } catch { return }
      guard !Task.isCancelled, holdStartedAt == startedAt else { return }
      completeGroup()
    }
    .task(id: celebrating) {
      guard celebrating else { return }
      try? await Task.sleep(for: .seconds(1.8))
      guard !Task.isCancelled else { return }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { celebrating = false }
    }
  }

  private var restStatus: some View {
    let remaining = model.fitness.restSecondsRemaining(at: model.now)
    let canLock = model.isAuthorized
    let needsRetry = remaining != nil && canLock && model.state.monitoringError != nil
    let locked = remaining == 0 && model.fitnessShieldApplied
    let title = locked ? "训练锁定中" : (remaining == 0 ? "休息结束" : "组间休息")
    let statusMessage: String
    if let remaining {
      statusMessage =
        remaining == 0 ? "休息时间到。完成下一组后重新计时。" : "记下一组后，从完整时长重新计时。"
    } else if progress.targetGroups == 1 {
      statusMessage = "本轮只有 1 组。设置至少 2 组可使用组间休息。"
    } else {
      statusMessage = "长按圆形按钮 \(Self.holdSeconds) 秒，记下一组后开始倒计时。"
    }
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(title, systemImage: locked ? "lock.fill" : "timer")
          .font(.headline)
        Spacer()
        if let remaining, remaining > 0 {
          Text(
            Duration.seconds(remaining), format: .time(pattern: .minuteSecond(padMinuteToLength: 2))
          )
          .font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(DaywellTheme.accent)
          .accessibilityIdentifier("fitness.rest.countdown")
        }
      }
      Text(statusMessage)
        .font(.footnote).foregroundStyle(DaywellTheme.muted)
      if needsRetry {
        HStack {
          Text("系统限制尚未同步").font(.footnote).foregroundStyle(DaywellTheme.muted)
          Spacer()
          Button("重试") { Task { await model.refresh() } }.disabled(model.isBusy)
        }
      } else if canLock && remaining == 0 && !locked {
        Button("同步锁定") { Task { await model.refresh() } }.disabled(model.isBusy)
      } else if !model.isAuthorized {
        Text(
          ScreenTimeService.isSimulator || ScreenTimeService.isFreePreview
            ? "可预览倒计时。应用锁定需要在已授权的真机上运行完整版。"
            : "在底栏「设置」开启屏幕使用时间授权。"
        )
        .font(.footnote).foregroundStyle(DaywellTheme.muted)
      }
    }
    .daywellCard()
  }

  private func counter(diameter: CGFloat) -> some View {
    let holdDuration = TimeInterval(Self.holdSeconds)
    return TimelineView(.animation(paused: holdStartedAt == nil)) { _ in
      let elapsed = holdStartedAt.map { $0.duration(to: .now) / .seconds(1) } ?? 0
      let fraction = min(elapsed / holdDuration, 1)
      ZStack {
        Circle().fill(DaywellTheme.soft.gradient)
        Circle().stroke(DaywellTheme.accent.opacity(0.12), lineWidth: 8)
        if celebrating || confirmingGroup {
          Circle().stroke(DaywellTheme.accent, lineWidth: 8)
            .transition(.opacity)
        } else {
          Circle().trim(from: 0, to: fraction)
            .stroke(DaywellTheme.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        VStack(spacing: 12) {
          if celebrating {
            Image(systemName: "checkmark.seal.fill")
              .font(.system(size: diameter * 0.25, weight: .regular))
              .transition(.scale(scale: 0.8).combined(with: .opacity))
            Text("完成 \(completedTarget) 组").font(.headline)
          } else if holdStartedAt != nil {
            Text(max(0, holdDuration - elapsed), format: .number.precision(.fractionLength(1)))
              .font(.system(size: diameter * 0.25, weight: .medium, design: .rounded))
              .monospacedDigit()
            Text("秒后完成一组").font(.subheadline)
          } else {
            Text("\(progress.completedGroups)")
              .font(.system(size: diameter * 0.28, weight: .medium, design: .rounded))
              .contentTransition(.numericText())
            Text("/ \(progress.targetGroups) 组").font(.title3)
          }
          Text(
            celebrating
              ? "下一轮，从 0 开始"
              : (holdStartedAt == nil ? "长按 \(Self.holdSeconds) 秒，完成一组" : "保持按住 · 松手取消")
          )
          .font(.footnote).foregroundStyle(DaywellTheme.muted)
          .multilineTextAlignment(.center)
        }
        .padding(24)
        if celebrating && !reduceMotion {
          ForEach(0..<4) { index in
            Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "star.fill")
              .font(.system(size: index.isMultiple(of: 2) ? 19 : 10))
              .offset(
                x: cos(Double(index) * .pi / 2) * diameter * 0.4,
                y: sin(Double(index) * .pi / 2) * diameter * 0.4
              )
              .transition(.scale(scale: 0.2).combined(with: .opacity))
          }
        }
      }
      .foregroundStyle(DaywellTheme.accent)
      .frame(width: diameter, height: diameter)
      .contentShape(Circle())
    }
    .onLongPressGesture(
      minimumDuration: holdDuration, maximumDistance: 30,
      pressing: { pressing in
        if pressing {
          guard !celebrating, !confirmingGroup, !holdRecognized,
            scenePhase == .active, !model.isBusy
          else { return }
          cancelledPress = false
          holdStartedAt = .now
        } else if !holdRecognized {
          holdStartedAt = nil
        }
      },
      perform: {
        // Recognition can precede the final animation frame because the pressing
        // callback is delayed in a scroll view. Finish that same clock before recording.
        if holdStartedAt != nil && !cancelledPress { holdRecognized = true }
      }
    )
    .disabled(
      celebrating || scenePhase != .active || (model.isBusy && !confirmingGroup)
        || model.startupError != nil
    )
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel("完成一组")
    .accessibilityValue("已完成 \(progress.completedGroups) 组，共 \(progress.targetGroups) 组")
    .accessibilityHint("长按 \(Self.holdSeconds) 秒完成一组，提前松手取消。")
    .accessibilityAction {
      cancelledPress = false
      completeGroup()
    }
    .accessibilityIdentifier("fitness.completeGroup")
  }

  private func completeGroup() {
    defer {
      holdStartedAt = nil
      holdRecognized = false
    }
    guard !celebrating, !confirmingGroup, !cancelledPress, scenePhase == .active, !model.isBusy
    else { return }
    let target = progress.targetGroups
    let finished = progress.completedGroups + 1 == target
    let recordedAt = Date()
    cancelledPress = true
    confirmingGroup = true
    Task {
      if await model.updateFitness({ $0.completeGroup(at: recordedAt) }), scenePhase == .active {
        completedTarget = target
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.65)) {
          celebrating = finished
        }
        if finished {
          UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
          UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
      }
      try? await Task.sleep(for: .milliseconds(160))
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { confirmingGroup = false }
    }
  }

  private func reset() {
    cancelledPress = true
    holdStartedAt = nil
    holdRecognized = false
    Task { _ = await model.updateFitness { $0.reset() } }
  }

  private func cancelInteraction() {
    cancelledPress = true
    holdStartedAt = nil
    holdRecognized = false
    celebrating = false
  }
}

struct FitnessSettingsCard: View {
  @EnvironmentObject private var model: DaywellModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("健身计数", systemImage: "figure.strengthtraining.traditional").font(.headline)
      Stepper(
        value: Binding(
          get: { model.fitness.progress.targetGroups },
          set: { value in
            Task { _ = await model.updateFitness { $0.setTargetGroups(value) } }
          }),
        in: FitnessProgress.targetRange
      ) {
        VStack(alignment: .leading, spacing: 5) {
          Text("每轮目标组数").font(.subheadline)
          Text("\(model.fitness.progress.targetGroups) 组")
            .font(.headline).foregroundStyle(DaywellTheme.accent)
        }
      }
      .accessibilityIdentifier("settings.fitness.targetGroups")
      Text("长按 \(FitnessView.holdSeconds) 秒完成一组，达到目标后自动归零。修改目标组数会重置本轮计数，设置自动保存。")
        .font(.footnote).foregroundStyle(DaywellTheme.muted)
    }
    .daywellCard()
    .disabled(model.isBusy || model.startupError != nil)
  }
}

struct FitnessRestSettingsCard: View {
  @EnvironmentObject private var model: DaywellModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Toggle(
        isOn: Binding(
          get: { model.fitness.restEnabled },
          set: { enabled in
            Task { _ = await model.updateFitness { $0.setRestEnabled(enabled) } }
          }
        )
      ) {
        Label("组间休息", systemImage: "timer").font(.headline)
      }
      .accessibilityIdentifier("settings.fitness.rest.enabled")
      if model.fitness.restEnabled {
        Stepper(
          value: Binding(
            get: { model.fitness.restSeconds },
            set: { seconds in
              Task { _ = await model.updateFitness { $0.setRestSeconds(seconds) } }
            }),
          in: FitnessTraining.restSecondsRange, step: FitnessTraining.restStepSeconds
        ) {
          VStack(alignment: .leading, spacing: 5) {
            Text("每组休息时长").font(.subheadline)
            Text("\(model.fitness.restSeconds) 秒")
              .font(.headline).foregroundStyle(DaywellTheme.accent)
          }
        }
        .accessibilityIdentifier("settings.fitness.rest.duration")
      }
      Text("每组完成后重新计时，休息结束会锁定应用。完成下一组开始新的休息，完成本轮后解除锁定。")
        .font(.footnote).foregroundStyle(DaywellTheme.muted)
    }
    .daywellCard()
    .disabled(model.isBusy || model.startupError != nil)
  }
}
