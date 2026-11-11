import DaywellCore
import SwiftUI

#if !DAYWELL_PREVIEW
  import FamilyControls
#endif

private struct PeriodEditorRoute: Identifiable {
  let id = UUID()
  let period: LockPeriod?
}

struct SleepView: View {
  let openSettings: () -> Void
  let openAuthorizationSettings: () -> Void
  @EnvironmentObject private var model: DaywellModel
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var editor: PeriodEditorRoute?
  @State private var showingPicker = false
  @State private var showingExemption = false
  @State private var periodSavePrompt: PeriodSavePrompt?

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          PageHeading(tab: .sleep, openSettings: openSettings)
          if let error = model.startupError {
            notice(title: "暂时无法读取配置", message: error, symbol: "exclamationmark.triangle")
          }
          if ScreenTimeService.isFreePreview {
            notice(
              title: "免费预览版", message: "可以体验界面、编辑时段和豁免设置；此版本不会实际锁定应用。",
              symbol: "iphone.gen3")
          } else if ScreenTimeService.isSimulator {
            notice(
              title: "界面预览模式", message: "模拟器可设置时段和豁免规则；应用圈选与实际锁定需在真机上使用。", symbol: "iphone.gen3")
          }
          if let error = model.state.monitoringError {
            VStack(alignment: .leading, spacing: 12) {
              notice(title: "系统限制需要重新安排", message: error, symbol: "exclamationmark.triangle")
              Button("重试") { Task { await model.refresh() } }.disabled(model.isBusy)
            }
          }
          if geometry.size.width >= 760 && !typeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 24) {
              statusCard.frame(maxWidth: .infinity)
              periodsCard.frame(maxWidth: .infinity)
            }
          } else {
            statusCard
            periodsCard
          }
          Text("给自己留一段不被屏幕打扰的时间。")
            .font(.footnote).foregroundStyle(DaywellTheme.muted)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .padding(24).frame(maxWidth: 1080).frame(maxWidth: .infinity)
      }
      .refreshable { await model.refresh() }
    }
    .sheet(item: $editor) { route in PeriodEditorView(period: route.period) }
    .periodSaveAlert($periodSavePrompt) { verification in
      Task { await savePeriod(verification.period, verifiedSessionIDs: verification.sessionIDs) }
    }
    #if !DAYWELL_PREVIEW
      .sheet(isPresented: $showingPicker) { ApplicationSelectionView(selection: model.selection) }
    #endif
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Label(
          statusLabel,
          systemImage: model.isAuthorized && !model.blockingSessions.isEmpty
            ? "lock.fill" : "moon.stars.fill"
        )
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(DaywellTheme.surface.opacity(0.6), in: Capsule())
        Spacer()
        Image(systemName: isMorningStatus ? "sun.horizon.fill" : "moon.zzz.fill").font(
          .system(size: 38, weight: .light)
        )
        .foregroundStyle(DaywellTheme.accent.opacity(0.7)).accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 10) {
        Text(heroTitle).font(.system(.title, design: .rounded, weight: .bold)).fixedSize(
          horizontal: false, vertical: true)
        Text(heroDetail).font(.subheadline).foregroundStyle(DaywellTheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      if ScreenTimeService.isFreePreview {
        Button {
          editor = PeriodEditorRoute(period: nil)
        } label: {
          Label("添加休息时段", systemImage: "plus")
        }.buttonStyle(PrimaryButtonStyle()).disabled(model.isBusy || model.startupError != nil)
      } else if !model.isAuthorized {
        Button(action: openAuthorizationSettings) {
          Label("开启屏幕使用时间授权", systemImage: "checkmark.shield")
        }.buttonStyle(PrimaryButtonStyle())
      } else if !model.state.needsApplicationReselection {
        if !model.blockingSessions.isEmpty {
          if model.canExempt {
            Button {
              showingExemption = true
            } label: {
              Label(model.exemptionLabel, systemImage: "hourglass")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isBusy)
            .confirmationDialog(
              "临时使用一会儿", isPresented: $showingExemption, titleVisibility: .visible
            ) {
              if model.canExempt {
                Button("开始豁免") { Task { await model.beginExemption() } }
              }
              Button("继续休息", role: .cancel) {}
            } message: {
              Text(model.exemptionExplanation)
            }
          } else if model.blockingSessions.contains(where: { $0.remainingCount == 0 }) {
            Text(isMorningStatus ? "本轮豁免已用完，洗漱、喝杯水，稍后再回来。" : "本时段已无可用豁免，等休息结束再回来。")
              .font(.subheadline).foregroundStyle(DaywellTheme.muted)
          }
          allowanceRows
        } else if model.activeSessions.contains(where: { $0.isExempt(at: model.now) }) {
          if let end = model.activeSessions.compactMap(\.exemption?.end).filter({ $0 > model.now })
            .min()
          {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(end, style: .timer).font(
                .system(.largeTitle, design: .rounded, weight: .semibold)
              )
              .monospacedDigit()
              Text("后恢复限制").font(.footnote).foregroundStyle(DaywellTheme.muted)
            }.accessibilityElement(children: .combine)
          }
          Button("提前结束豁免") { Task { await model.endExemptions() } }
            .buttonStyle(PrimaryButtonStyle()).disabled(model.isBusy)
          allowanceRows
        } else if model.state.selectionData != nil {
          Label(
            pendingMorning == nil ? "按设定时间自动开始" : "累计使用，用满后自动休息", systemImage: "checkmark.circle"
          )
          .font(.subheadline.weight(.medium)).foregroundStyle(DaywellTheme.accent)
        }
      }
      #if !DAYWELL_PREVIEW
        if model.isAuthorized { applicationSelectionButton }
      #endif
    }
    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [DaywellTheme.hero, DaywellTheme.soft], startPoint: .topLeading,
        endPoint: .bottomTrailing),
      in: RoundedRectangle(cornerRadius: 28)
    )
    .accessibilityIdentifier("sleep.status")
  }

  private var allowanceRows: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.activeSessions) { session in
        HStack(alignment: .firstTextBaseline) {
          Text(
            session.isMorning ? "清晨 · \(session.period.end.formatted) 后" : session.period.timeLabel)
          Spacer(minLength: 8)
          Text("剩余 \(session.remainingCount) / \(session.policy.allowedCount) 次")
        }
        .font(.caption).foregroundStyle(DaywellTheme.muted)
        .accessibilityElement(children: .combine)
      }
    }
  }

  #if !DAYWELL_PREVIEW
    private var applicationSelectionButton: some View {
      let selection = model.selection
      let needsReselection = model.state.needsApplicationReselection || !selection.fitsShieldLimits
      return Group {
        if selection.isEmpty || needsReselection {
          if !selection.fitsShieldLimits {
            Text("之前的圈选超过了系统上限，请按类别重新圈选。")
              .font(.footnote).foregroundStyle(DaywellTheme.muted)
          }
          Button(needsReselection ? "重新选择应用" : "选择需要锁定的应用") {
            showingPicker = true
          }.buttonStyle(PrimaryButtonStyle())
        } else {
          Button {
            showingPicker = true
          } label: {
            HStack(spacing: 10) {
              Label("修改锁定应用", systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
              Spacer(minLength: 8)
              Text(selectionSummary(for: selection)).font(.caption).foregroundStyle(
                DaywellTheme.muted)
              Image(systemName: "chevron.right").font(.caption.bold()).accessibilityHidden(true)
            }
            .foregroundStyle(DaywellTheme.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
      .disabled(model.isBusy || model.startupError != nil)
      .accessibilityIdentifier("sleep.applications")
    }
  #endif

  private var periodsCard: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text("锁定时段").font(.headline)
          Text("白天或夜晚，都可以安排").font(.caption).foregroundStyle(DaywellTheme.muted)
        }
        Spacer()
        Button {
          editor = PeriodEditorRoute(period: nil)
        } label: {
          Image(systemName: "plus").font(.headline).frame(width: 44, height: 44)
            .background(DaywellTheme.soft, in: Circle())
        }.accessibilityLabel("添加锁定时段").accessibilityIdentifier("sleep.addPeriod")
      }
      if model.state.periods.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "clock.badge.plus").font(.largeTitle).foregroundStyle(
            DaywellTheme.accent)
          Text("安排第一段休息时间").font(.subheadline.weight(.medium))
          Text("可以添加多个时段，按星期重复。")
            .font(.caption).foregroundStyle(DaywellTheme.muted)
          Button("添加时段") { editor = PeriodEditorRoute(period: nil) }.font(
            .subheadline.weight(.semibold))
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
      } else {
        ForEach(model.state.periods) { period in
          if period.id != model.state.periods.first?.id { Divider().overlay(DaywellTheme.border) }
          HStack(spacing: 12) {
            Button {
              editor = PeriodEditorRoute(period: period)
            } label: {
              VStack(alignment: .leading, spacing: 7) {
                Text(period.timeLabel).font(.system(.title3, design: .rounded, weight: .semibold))
                  .monospacedDigit()
                HStack(spacing: 8) {
                  Text(period.repeatLabel)
                  if period.isEnabled, let after = period.effectiveAfter, after > model.now {
                    Text("修改下次生效")
                  } else if model.activeSessions.contains(where: { $0.period.id == period.id }) {
                    Text("进行中")
                  }
                }.font(.caption).foregroundStyle(DaywellTheme.muted)
                if period.morningEnabled {
                  Label(
                    "清晨 · 可用 \(model.state.morningPolicy.usageMinutes) 分钟 → 休息 \(model.state.morningPolicy.lockMinutes) 分钟",
                    systemImage: "sun.horizon"
                  )
                  .font(.caption).foregroundStyle(DaywellTheme.accent)
                  .fixedSize(horizontal: false, vertical: true)
                }
              }.frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).contentShape(
                Rectangle())
            }.buttonStyle(.plain)
            Toggle(
              "启用 \(period.timeLabel)",
              isOn: Binding(
                get: { period.isEnabled },
                set: { enabled in
                  var updated = period
                  updated.isEnabled = enabled
                  Task { await savePeriod(updated) }
                })
            ).labelsHidden().fixedSize()
          }
        }
      }
      Text(
        ScreenTimeService.isFreePreview
          ? "预览版仅保存设置，启用时段不会实际锁定应用。"
          : "每个时段单独计算豁免次数；正在执行的时段保留原定时间与豁免规则。"
      )
      .font(.caption).foregroundStyle(DaywellTheme.muted).fixedSize(
        horizontal: false, vertical: true)
    }
    .daywellCard().disabled(model.isBusy || model.startupError != nil)
  }

  private func savePeriod(_ period: LockPeriod, verifiedSessionIDs: Set<String> = []) async {
    _ = await model.savePeriod(period, verifiedSessionIDs: verifiedSessionIDs) {
      periodSavePrompt = $0
    }
  }

  private var statusLabel: String {
    if ScreenTimeService.isFreePreview { return "预览模式" }
    if !model.isAuthorized { return "尚未开启" }
    if model.state.needsApplicationReselection { return "需要重新圈选" }
    if model.state.monitoringError != nil { return "需要处理" }
    if !model.blockingSessions.isEmpty { return isMorningStatus ? "清晨 · 休息一下" : "正在锁定" }
    if !model.activeSessions.isEmpty { return "临时豁免中" }
    if pendingMorning != nil { return "清晨模式" }
    return "等待开始"
  }

  private var heroTitle: String {
    if ScreenTimeService.isFreePreview { return "把休息，\n留在日程里" }
    if !model.isAuthorized { return "让屏幕，\n也休息一会儿" }
    if model.state.needsApplicationReselection { return "重新选好，\n继续你的节奏" }
    if isMorningStatus && !model.blockingSessions.isEmpty { return "早安，\n先照顾好自己" }
    if !model.blockingSessions.isEmpty { return "让屏幕，\n也休息一会儿" }
    if !model.activeSessions.isEmpty { return "暂时放行，\n记得回来休息" }
    if pendingMorning != nil { return "早安，给自己留一点\n清醒的时间" }
    return "把休息，\n留在日程里"
  }

  private var heroDetail: String {
    if ScreenTimeService.isFreePreview { return "试着安排几段休息时间，再到右上角设置中调整每次豁免的时长。" }
    if !model.isAuthorized { return "开启授权后，在你设定的时间里，帮你暂时放下选中的应用。" }
    if model.state.needsApplicationReselection { return "授权曾被撤销，原来的应用选择已失效。请重新圈选。" }
    if let end = model.activeSessions.map(\.occurrence.end).max() {
      if isMorningStatus {
        return "先去洗漱、喝杯水，慢慢开始今天。\(end.formatted(date: .omitted, time: .shortened)) 结束本轮休息。"
      }
      return "当前时段最晚于 \(end.formatted(date: .omitted, time: .shortened)) 结束，豁免机会按各时段分别计算。"
    }
    if let morning = pendingMorning?.morning {
      return "圈选应用合计可用 \(morning.usageMinutes) 分钟，用满后休息 \(morning.lockMinutes) 分钟。中途退出会保留已用时长。"
    }
    if let next = model.nextOccurrence {
      return "下一段从 \(next.start.formatted(.dateTime.weekday(.wide).hour().minute())) 开始。"
    }
    return "设置多个时间段，给生活留一点安静。"
  }

  private var pendingMorning: MorningWindow? { model.state.pendingMornings(at: model.now).first }
  private var isMorningStatus: Bool {
    guard model.isAuthorized else { return false }
    if !model.activeSessions.isEmpty { return model.activeSessions.allSatisfy(\.isMorning) }
    return pendingMorning != nil
  }

  #if !DAYWELL_PREVIEW
    private func selectionSummary(for selection: FamilyActivitySelection) -> String {
      var parts: [String] = []
      if !selection.categoryTokens.isEmpty { parts.append("\(selection.categoryTokens.count) 类") }
      if !selection.applicationTokens.isEmpty {
        let prefix = selection.categoryTokens.isEmpty ? "" : "另选 "
        parts.append("\(prefix)\(selection.applicationTokens.count) 个 App")
      }
      if !selection.webDomainTokens.isEmpty {
        parts.append("\(selection.webDomainTokens.count) 个网站")
      }
      return parts.joined(separator: " · ")
    }
  #endif

  private func notice(title: String, message: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).foregroundStyle(DaywellTheme.accent)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(message).font(.caption).foregroundStyle(DaywellTheme.muted)
      }
    }.daywellCard(padding: 16)
  }
}
