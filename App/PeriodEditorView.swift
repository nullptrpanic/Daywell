import DaywellCore
import SwiftUI

struct PeriodEditorView: View {
  @EnvironmentObject private var model: DaywellModel
  @Environment(\.dismiss) private var dismiss
  private let period: LockPeriod?
  @State private var start: Date
  @State private var end: Date
  @State private var weekdays: Set<Weekday>
  @State private var enabled: Bool
  @State private var morningEnabled: Bool
  @State private var savePrompt: PeriodSavePrompt?
  @State private var showingDelete = false

  init(period: LockPeriod?) {
    self.period = period
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    _start = State(
      initialValue: calendar.date(
        bySettingHour: period?.start.hour ?? 23,
        minute: period?.start.minute ?? 0, second: 0, of: today) ?? today)
    _end = State(
      initialValue: calendar.date(
        bySettingHour: period?.end.hour ?? 7,
        minute: period?.end.minute ?? 0, second: 0, of: today) ?? today)
    _weekdays = State(initialValue: period?.weekdays ?? Set(Weekday.allCases))
    _enabled = State(initialValue: period?.isEnabled ?? true)
    _morningEnabled = State(initialValue: period?.morningEnabled ?? false)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          DatePicker("开始时间", selection: $start, displayedComponents: .hourAndMinute)
          DatePicker("结束时间", selection: $end, displayedComponents: .hourAndMinute)
        } footer: {
          Text("锁定时段不能重叠。结束时间早于开始时间时，自动延续至次日。")
        }
        Section {
          Toggle(isOn: $morningEnabled) {
            Label("清晨模式", systemImage: "sun.horizon.fill")
          }.accessibilityIdentifier("period.morning.enabled")
        } footer: {
          Text(
            morningEnabled
              ? "睡眠结束后，圈选应用合计可用 \(model.state.morningPolicy.usageMinutes) 分钟，用满后锁定 \(model.state.morningPolicy.lockMinutes) 分钟。时长在睡眠页右上角设置中统一调整，沿用睡眠的应用和豁免设置。"
              : "早安，先照顾好自己。给洗漱、喝水和早餐留一点时间。")
        }
        Section("重复") {
          ForEach(Weekday.displayOrder, id: \.self) { weekday in
            Button {
              if weekdays.contains(weekday) {
                weekdays.remove(weekday)
              } else {
                weekdays.insert(weekday)
              }
            } label: {
              HStack {
                Text("星期\(weekday.shortName)").foregroundStyle(DaywellTheme.text)
                Spacer()
                Image(systemName: weekdays.contains(weekday) ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(
                    weekdays.contains(weekday) ? DaywellTheme.accent : DaywellTheme.muted)
              }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(weekdays.contains(weekday) ? .isSelected : [])
          }
        }
        Section {
          Toggle("启用此时段", isOn: $enabled)
        } footer: {
          Text("重复星期以开始日期为准。关闭正在锁定的时段需要验证码，确认后立即结束本轮。其他修改从后续时段生效。")
        }
        if period != nil {
          Section { Button("删除时段", role: .destructive) { showingDelete = true } }
        }
      }
      .scrollContentBackground(.hidden).background(DaywellTheme.background)
      .navigationTitle(period == nil ? "添加时段" : "编辑时段").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") { Task { await save() } }.bold().disabled(model.isBusy)
        }
      }
      .disabled(model.isBusy)
      .periodSaveAlert($savePrompt) { verification in
        Task { await persist(verification.period, verifiedSessionIDs: verification.sessionIDs) }
      }
      .confirmationDialog("删除这个时段？", isPresented: $showingDelete, titleVisibility: .visible) {
        Button("删除", role: .destructive) {
          guard let period else { return }
          Task { if await model.removePeriod(period.id) { dismiss() } }
        }
      } message: {
        Text("如果当前时段正在执行，将继续到原定结束时间。")
      }
    }
    .interactiveDismissDisabled(model.isBusy)
  }

  private func save() async {
    do {
      let calendar = Calendar.current
      var updated = try LockPeriod(
        id: period?.id ?? UUID(),
        start: ClockTime(
          hour: calendar.component(.hour, from: start),
          minute: calendar.component(.minute, from: start)),
        end: ClockTime(
          hour: calendar.component(.hour, from: end), minute: calendar.component(.minute, from: end)
        ),
        weekdays: weekdays, isEnabled: enabled,
        morningEnabled: morningEnabled)
      updated.effectiveAfter = period?.effectiveAfter
      await persist(updated)
    } catch { savePrompt = .failure(error.localizedDescription) }
  }

  private func persist(_ period: LockPeriod, verifiedSessionIDs: Set<String> = []) async {
    if await model.savePeriod(
      period, verifiedSessionIDs: verifiedSessionIDs,
      onPrompt: {
        savePrompt = $0
      })
    {
      dismiss()
    }
  }
}

extension View {
  func periodSaveAlert(
    _ prompt: Binding<PeriodSavePrompt?>, onVerified: @escaping (PeriodDeactivation) -> Void
  ) -> some View {
    modifier(PeriodSaveAlert(prompt: prompt, onVerified: onVerified))
  }
}

private struct PeriodSaveAlert: ViewModifier {
  @Binding var prompt: PeriodSavePrompt?
  let onVerified: (PeriodDeactivation) -> Void
  @State private var enteredCode = ""

  private var verificationCode: String? {
    guard case .verify(let verification)? = prompt else { return nil }
    return verification.code
  }

  func body(content: Content) -> some View {
    content
      .alert(
        verificationCode == nil ? "无法保存时段" : "结束当前锁定？",
        isPresented: Binding(
          get: { prompt != nil },
          set: { if !$0 { prompt = nil } }),
        presenting: prompt
      ) { prompt in
        switch prompt {
        case .failure:
          Button("知道了", role: .cancel) {}
        case .verify(let verification):
          TextField("输入 6 位验证码", text: $enteredCode).keyboardType(.numberPad)
          Button("取消", role: .cancel) {}
          Button("确认关闭", role: .destructive) {
            guard enteredCode == verification.code else { return }
            onVerified(verification)
          }.disabled(enteredCode != verification.code)
        }
      } message: { prompt in
        switch prompt {
        case .failure(let message): Text(message)
        case .verify(let verification):
          Text("请输入验证码 \(verification.code)。确认后将结束本轮锁定，并关闭这个时段的后续重复。")
        }
      }
      .onChange(of: verificationCode) { _, code in
        if code != nil { enteredCode = "" }
      }
  }
}
