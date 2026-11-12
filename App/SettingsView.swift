import DaywellCore
import SwiftUI

private enum DaywellWebsite {
  static let support = URL(string: "https://nullptrpanic.github.io/Daywell/")!
  static let privacy = support.appendingPathComponent("privacy.html")
}

struct GlobalSettingsView: View {
  @EnvironmentObject private var model: DaywellModel
  @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
  #if !DAYWELL_PREVIEW
    @State private var showingExemptionList = false
  #endif

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeading(tab: .settings, openSettings: nil)
        VStack(alignment: .leading, spacing: 16) {
          Label("外观", systemImage: "circle.lefthalf.filled").font(.headline)
          Picker("外观模式", selection: $appearance) {
            ForEach(AppAppearance.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("settings.appearance")
        }.daywellCard()
        authorizationCard
        #if !DAYWELL_PREVIEW
          exemptionListCard
        #endif
        VStack(alignment: .leading, spacing: 8) {
          Text(ScreenTimeService.isFreePreview ? "Daywell 预览" : "Daywell").font(.headline)
          Text(
            ScreenTimeService.isFreePreview
              ? "配置仅保存在当前预览应用，不会同步到完整版本。不测量实际睡眠。"
              : "配置仅保存在当前设备。Daywell 提供时段限制，不测量实际睡眠。"
          )
          .font(.footnote).foregroundStyle(DaywellTheme.muted)
          Divider().padding(.top, 8)
          VStack(spacing: 0) {
            Link(destination: DaywellWebsite.privacy) {
              Label("隐私政策", systemImage: "hand.raised")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("settings.privacy")
            Link(destination: DaywellWebsite.support) {
              Label("帮助与反馈", systemImage: "questionmark.circle")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("settings.support")
          }
          .foregroundStyle(DaywellTheme.accent)
        }.daywellCard()
      }
      .padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
    }
    #if !DAYWELL_PREVIEW
      .sheet(isPresented: $showingExemptionList) {
        ApplicationSelectionView(selection: model.alwaysAllowedSelection, purpose: .alwaysAllowed)
      }
    #endif
  }

  private var authorizationCard: some View {
    let status: String
    let detail: String
    if ScreenTimeService.isFreePreview {
      status = "预览版"
      detail = "预览版可保存设置并体验倒计时，应用锁定需要完整版。"
    } else if ScreenTimeService.isSimulator {
      status = "模拟器"
      detail = "在 iPhone 或 iPad 上开启授权，即可使用应用圈选和自动锁定。"
    } else {
      status = model.isAuthorized ? "已授权" : "未授权"
      detail = "睡眠时段和组间休息共用这项授权。你可以在 iOS 设置中撤销授权。"
    }
    return VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("屏幕使用时间", systemImage: "checkmark.shield").font(.headline)
        Spacer()
        Text(status).font(.caption.weight(.medium)).foregroundStyle(DaywellTheme.muted)
      }
      Text(detail).font(.footnote).foregroundStyle(DaywellTheme.muted)
      if !ScreenTimeService.isFreePreview && !ScreenTimeService.isSimulator && !model.isAuthorized {
        Button("开启授权") { Task { await model.authorize() } }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(model.isBusy || model.startupError != nil)
      }
    }.daywellCard()
  }

  #if !DAYWELL_PREVIEW
    private var exemptionListCard: some View {
      let count = model.alwaysAllowedSelection.applicationTokens.count
      return VStack(alignment: .leading, spacing: 12) {
        Label("豁免名单", systemImage: "checkmark.shield").font(.headline)
        Text("名单里的 App 在睡眠和健身锁定时仍可使用。请加入电话、信息等需要保留的 App。")
          .font(.footnote).foregroundStyle(DaywellTheme.muted)
        Button(count == 0 ? "选择要豁免的 App" : "已选 \(count) 个 App，修改") {
          showingExemptionList = true
        }
        .disabled(!model.isAuthorized || model.isBusy || model.startupError != nil)
        .accessibilityIdentifier("settings.alwaysAllowed")
      }.daywellCard()
    }
  #endif
}

struct SettingsView: View {
  let tab: DaywellTab
  @EnvironmentObject private var model: DaywellModel
  @Environment(\.dismiss) private var dismiss
  @State private var count = 2
  @State private var minutes = ExemptionPolicy.defaultDurations

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          if tab == .fitness {
            FitnessSettingsCard()
            FitnessRestSettingsCard()
          }
          if tab == .sleep {
            MorningSettingsCard()
              .disabled(model.isBusy || model.startupError != nil)
            exemptionCard
              .disabled(model.isBusy || model.startupError != nil)
          }
        }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
      }
      .foregroundStyle(DaywellTheme.text)
      .background(DaywellTheme.background)
      .navigationTitle("\(tab.rawValue)设置")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
            .accessibilityIdentifier("settings.done")
            .disabled(tab == .sleep && model.isBusy)
        }
      }
    }
    .interactiveDismissDisabled(tab == .sleep && model.isBusy)
    .onAppear { loadPolicy() }
    .onChange(of: model.state.policy) { _, _ in loadPolicy() }
  }

  private var exemptionCard: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("临时豁免", systemImage: "hourglass").font(.headline)
      Text("偶尔需要使用，也给自己留一点余地。")
        .font(.subheadline).foregroundStyle(DaywellTheme.muted)
      Stepper(value: $count, in: 0...5) {
        settingValue(title: "每个时段可豁免", value: "\(count) 次")
      }
      ForEach(0..<count, id: \.self) { index in
        Divider()
        Stepper(value: $minutes[index], in: 1...1440) {
          settingValue(title: "第 \(index + 1) 次豁免", value: "\(minutes[index]) 分钟")
        }
        .accessibilityIdentifier("settings.exemption.\(index + 1)")
      }
      Text(
        count == 0
          ? "此设置下不提供临时豁免，锁定页不会显示豁免按钮。修改会在后续时段生效。"
          : "每轮睡眠与随后的清晨模式共用次数，最多 5 次。默认 2 次，时长依次为 10、5、3、2、1 分钟，可分别调整。修改会在后续时段生效。"
      )
      .font(.footnote).foregroundStyle(DaywellTheme.muted)
      if hasChanges {
        Button("保存豁免设置") {
          Task { _ = await model.savePolicy(count: count, durationsMinutes: minutes) }
        }.buttonStyle(PrimaryButtonStyle())
      }
    }.daywellCard()
  }

  private var hasChanges: Bool {
    count != model.state.policy.allowedCount || minutes != model.state.policy.configuredDurations
  }
  private func loadPolicy() {
    count = min(model.state.policy.allowedCount, 5)
    minutes = model.state.policy.configuredDurations
  }
  private func settingValue(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.subheadline)
      Text(value).font(.headline).foregroundStyle(DaywellTheme.accent)
    }.padding(.vertical, 4)
  }
}

private struct MorningSettingsCard: View {
  @EnvironmentObject private var model: DaywellModel
  @State private var usageMinutes = MorningPolicy.standard.usageMinutes
  @State private var lockMinutes = MorningPolicy.standard.lockMinutes

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("清晨模式", systemImage: "sun.horizon.fill").font(.headline)
      Stepper(value: $usageMinutes, in: 1...1440) {
        settingValue("累计可用时长", minutes: usageMinutes)
      }.accessibilityIdentifier("settings.morning.usage")
      Divider()
      Stepper(value: $lockMinutes, in: 1...1440) {
        settingValue("用满后锁定", minutes: lockMinutes)
      }.accessibilityIdentifier("settings.morning.lock")
      Text("在睡眠时段里开启清晨模式后，使用这些统一设置。累计使用圈选应用，用满后锁定一次。豁免次数与对应睡眠时段共用，时长接着睡眠期间的使用顺序计算。修改从后续睡眠生效。")
        .font(.footnote).foregroundStyle(DaywellTheme.muted)
      if usageMinutes != model.state.morningPolicy.usageMinutes
        || lockMinutes != model.state.morningPolicy.lockMinutes
      {
        Button("保存清晨设置") {
          Task {
            _ = await model.saveMorningPolicy(usageMinutes: usageMinutes, lockMinutes: lockMinutes)
          }
        }.buttonStyle(PrimaryButtonStyle())
          .accessibilityIdentifier("settings.morning.save")
      }
    }.daywellCard()
      .onAppear { load() }
      .onChange(of: model.state.morningPolicy) { _, _ in load() }
  }

  private func settingValue(_ title: String, minutes: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.subheadline)
      Text("\(minutes) 分钟").font(.headline).foregroundStyle(DaywellTheme.accent)
    }
  }

  private func load() {
    usageMinutes = model.state.morningPolicy.usageMinutes
    lockMinutes = model.state.morningPolicy.lockMinutes
  }
}
