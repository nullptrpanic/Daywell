import DaywellCore
import SwiftUI

#if !DAYWELL_PREVIEW
  import FamilyControls
  import ManagedSettings
#endif

struct FocusView: View {
  let openSettings: () -> Void
  let openAuthorizationSettings: () -> Void
  @EnvironmentObject private var model: DaywellModel
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var showingPicker = false
  @State private var verification: FocusDeactivation?
  @State private var enteredCode = ""

  private var session: FocusSession? { model.state.focusSession }
  private var unavailable: Bool {
    model.isAuthorized
      && (!model.activeSessions.isEmpty || model.state.hasFitnessRestriction(at: model.now))
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          PageHeading(tab: .focus, openSettings: openSettings)
          if let error = model.startupError {
            Text(error).font(.footnote).foregroundStyle(DaywellTheme.muted).daywellCard()
          }
          if geometry.size.width >= 760 && !typeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 24) {
              hero.frame(maxWidth: .infinity)
              applicationCards.frame(maxWidth: .infinity)
            }
          } else {
            hero
            applicationCards
          }
          Text("把注意力，留给此刻想做的事。")
            .font(.footnote).foregroundStyle(DaywellTheme.muted)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .padding(24).frame(maxWidth: 1080).frame(maxWidth: .infinity)
      }
      .refreshable { await model.refresh() }
    }
    .alert(
      "结束当前聚焦？",
      isPresented: Binding(
        get: { verification != nil }, set: { if !$0 { verification = nil } }),
      presenting: verification
    ) { verification in
      TextField("输入 6 位验证码", text: $enteredCode).keyboardType(.numberPad)
        .accessibilityIdentifier("focus.verificationInput")
      Button("取消", role: .cancel) {}
      Button("确认关闭", role: .destructive) {
        let input = enteredCode
        Task { _ = await model.endFocus(verification, enteredCode: input) }
      }
      .disabled(verification.code != enteredCode || model.isBusy)
    } message: { verification in
      Text("请输入验证码 \(verification.code)。确认后将结束本轮聚焦。")
    }
    .onChange(of: session?.id) { _, _ in verification = nil }
    #if !DAYWELL_PREVIEW
      .sheet(isPresented: $showingPicker) {
        ApplicationSelectionView(selection: pickerSelection, purpose: .focus)
      }
    #endif
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Label(
          session == nil ? String(localized: "准备开始") : String(localized: "正在聚焦"),
          systemImage: "scope"
        )
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(DaywellTheme.surface.opacity(0.6), in: Capsule())
        Spacer()
        Image(systemName: "scope").font(.system(size: 38, weight: .light))
          .foregroundStyle(DaywellTheme.accent.opacity(0.7)).accessibilityHidden(true)
      }
      if let session {
        VStack(alignment: .leading, spacing: 14) {
          Text("聚焦模式还剩余").font(.headline)
          countdown(session.secondsRemaining(at: model.now))
          Text("这段时间，专注使用你选择的应用。")
            .font(.subheadline).foregroundStyle(DaywellTheme.muted)
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("一次，\n只专注一件事。")
            .font(.system(.title, design: .rounded, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
          Text("选一个应用，给自己一段专注的时间。")
            .font(.subheadline).foregroundStyle(DaywellTheme.muted)
          Label("本次聚焦 \(model.state.focusConfiguration.minutes) 分钟", systemImage: "clock")
            .font(.subheadline.weight(.medium)).foregroundStyle(DaywellTheme.accent)
        }
      }
      Button(action: toggleFocus) {
        if session != nil {
          Label("关闭聚焦", systemImage: "stop.fill")
        } else if !model.isAuthorized {
          Label("前往设置", systemImage: "checkmark.shield")
        } else {
          Label("开启聚焦", systemImage: "play.fill")
        }
      }
      .buttonStyle(PrimaryButtonStyle())
      .disabled(model.isBusy || model.startupError != nil)
      .accessibilityIdentifier("focus.toggle")
      Text(footer)
        .font(.footnote).foregroundStyle(DaywellTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [DaywellTheme.hero, DaywellTheme.soft], startPoint: .topLeading,
        endPoint: .bottomTrailing),
      in: RoundedRectangle(cornerRadius: 28)
    )
  }

  private func countdown(_ seconds: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      timePart(seconds / 3600, unit: String(localized: "小时"))
      timePart(seconds / 60 % 60, unit: String(localized: "分"))
      timePart(seconds % 60, unit: String(localized: "秒"))
    }
    .minimumScaleFactor(0.65).lineLimit(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("聚焦模式还剩余 \(seconds / 3600) 小时 \(seconds / 60 % 60) 分 \(seconds % 60) 秒")
    .accessibilityIdentifier("focus.countdown")
  }

  private func timePart(_ number: Int, unit: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(String(format: "%02d", number))
        .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
      Text(unit).font(.caption).foregroundStyle(DaywellTheme.muted)
    }
  }

  private var footer: String {
    if ScreenTimeService.isFreePreview || ScreenTimeService.isSimulator {
      return String(localized: "应用圈选与实际锁定需要在已授权的 iPhone 或 iPad 上使用。")
    }
    if !model.isAuthorized { return String(localized: "开启前需要授权屏幕使用时间。") }
    if unavailable { return String(localized: "其他锁定正在执行，结束后可开启聚焦。临时豁免不会改变这一状态。") }
    return session == nil
      ? String(localized: "开启后，请自行打开所选应用。") : String(localized: "提前关闭需要输入验证码；时间结束后自动恢复。")
  }

  private var applicationCards: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 16) {
        Label("聚焦应用", systemImage: "app.dashed").font(.headline)
        Button {
          if prepareFocusAccess() { showingPicker = true }
        } label: {
          HStack(spacing: 12) {
            applicationLabel(
              session?.applicationData ?? model.state.focusConfiguration.applicationData)
            Spacer(minLength: 8)
            Image(systemName: session == nil ? "chevron.right" : "lock.fill")
              .font(.footnote).foregroundStyle(DaywellTheme.muted)
          }.frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session != nil || model.isBusy || model.startupError != nil)
        .accessibilityIdentifier("focus.chooseApp")
        Text(
          session == nil
            ? String(localized: "只选择一个 App，开启前可以更换。") : String(localized: "本轮应用已固定，结束后可以更换。")
        )
          .font(.footnote).foregroundStyle(DaywellTheme.muted)
      }.daywellCard()
      if !model.state.focusConfiguration.recentApplications.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label("最近聚焦", systemImage: "clock.arrow.circlepath").font(.headline)
            Spacer()
            Text("最多 5 个").font(.caption).foregroundStyle(DaywellTheme.muted)
          }
          #if !DAYWELL_PREVIEW
            ForEach(model.state.focusConfiguration.recentApplications, id: \.self) { data in
              Button {
                Task { _ = await model.selectRecentFocusApplication(data) }
              } label: {
                HStack(spacing: 12) {
                  applicationLabel(data)
                  Spacer(minLength: 8)
                  Image(
                    systemName: data == model.state.focusConfiguration.applicationData
                      ? "largecircle.fill.circle" : "circle"
                  )
                  .font(.title3).foregroundStyle(DaywellTheme.accent)
                }.frame(minHeight: 48).contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(session != nil || model.isBusy || !model.isAuthorized)
              .accessibilityAddTraits(
                data == model.state.focusConfiguration.applicationData ? .isSelected : [])
            }
          #endif
        }.daywellCard()
      }
      Text("聚焦期间保留全局豁免名单。睡眠、清晨或健身开始锁定时，会结束聚焦。")
        .font(.footnote).foregroundStyle(DaywellTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private func applicationLabel(_ data: Data?) -> some View {
    #if !DAYWELL_PREVIEW
      if let data, let token = try? JSONDecoder().decode(ApplicationToken.self, from: data) {
        Label(token).labelStyle(.titleAndIcon).id(token)
      } else {
        Label("选择聚焦应用", systemImage: "plus.app")
          .foregroundStyle(DaywellTheme.accent)
      }
    #else
      Label("选择聚焦应用", systemImage: "plus.app").foregroundStyle(DaywellTheme.accent)
    #endif
  }

  #if !DAYWELL_PREVIEW
    private var pickerSelection: FamilyActivitySelection {
      var selection = FamilyActivitySelection(includeEntireCategory: true)
      if let data = model.state.focusConfiguration.applicationData,
        let token = try? JSONDecoder().decode(ApplicationToken.self, from: data)
      {
        selection.applicationTokens = [token]
      }
      return selection
    }
  #endif

  private func prepareFocusAccess() -> Bool {
    if ScreenTimeService.isFreePreview || ScreenTimeService.isSimulator {
      model.errorMessage =
        ScreenTimeService.isFreePreview
        ? String(localized: "预览版不支持应用圈选或聚焦锁定。请在已授权的 iPhone 或 iPad 上使用 Daywell 完整版。")
        : String(localized: "模拟器无法圈选或锁定真实应用。请在 iPhone 或 iPad 真机上运行 Daywell，授权屏幕使用时间后使用聚焦。")
      return false
    }
    guard model.isAuthorized else {
      openAuthorizationSettings()
      return false
    }
    return true
  }

  private func toggleFocus() {
    if let session {
      enteredCode = ""
      verification = FocusDeactivation(sessionID: session.id)
    } else if !model.isAuthorized {
      openAuthorizationSettings()
    } else if prepareFocusAccess() {
      guard !unavailable else {
        model.errorMessage = DaywellError.focusUnavailable.localizedDescription
        return
      }
      if model.state.focusConfiguration.applicationData == nil {
        showingPicker = true
      } else {
        Task { _ = await model.beginFocus() }
      }
    }
  }
}

struct FocusSettingsCard: View {
  @EnvironmentObject private var model: DaywellModel
  @State private var minutes = ""

  private var parsed: Int? { Int(minutes.trimmingCharacters(in: .whitespacesAndNewlines)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("聚焦时长", systemImage: "clock").font(.headline)
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        TextField("90", text: $minutes)
          .keyboardType(.numberPad)
          .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
          .foregroundStyle(DaywellTheme.accent)
          .accessibilityLabel("聚焦时长，分钟")
          .accessibilityIdentifier("focus.minutes")
        Text("分钟").foregroundStyle(DaywellTheme.muted)
      }
      .padding(16).background(DaywellTheme.soft, in: RoundedRectangle(cornerRadius: 16))
      Text("输入 1–1440 的整数分钟。修改从下一轮聚焦开始生效。")
        .font(.footnote).foregroundStyle(DaywellTheme.muted)
      if parsed != model.state.focusConfiguration.minutes {
        Button("保存聚焦时长") {
          if let parsed { Task { _ = await model.saveFocusMinutes(parsed) } }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(
          model.isBusy || model.startupError != nil
            || !FocusConfiguration.minutesRange.contains(parsed ?? 0)
        )
        .accessibilityIdentifier("focus.saveMinutes")
      }
    }
    .daywellCard()
    .onAppear { minutes = String(model.state.focusConfiguration.minutes) }
    .onChange(of: model.state.focusConfiguration.minutes) { _, value in minutes = String(value) }
  }
}
