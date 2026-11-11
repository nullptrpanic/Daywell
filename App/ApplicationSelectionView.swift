import FamilyControls
import SwiftUI

struct ApplicationSelectionView: View {
  enum Purpose: Equatable {
    case restricted
    case alwaysAllowed
  }

  @EnvironmentObject private var model: DaywellModel
  @Environment(\.dismiss) private var dismiss
  @State private var selection: FamilyActivitySelection
  private let purpose: Purpose

  init(selection: FamilyActivitySelection, purpose: Purpose = .restricted) {
    _selection = State(initialValue: selection)
    self.purpose = purpose
  }

  private var canSave: Bool {
    if purpose == .restricted { return selection.fitsShieldLimits }
    return selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
      && selection.applicationTokens.count <= ScreenTimeService.shieldTokenLimit
  }

  private var pickerSelection: Binding<FamilyActivitySelection> {
    guard purpose == .restricted else { return $selection }
    let exempt = model.alwaysAllowedSelection.applicationTokens
    return Binding(
      get: { selection.excludingApplications(exempt) },
      set: { selection = $0.excludingApplications(exempt) })
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Text(
          purpose == .alwaysAllowed
            ? "展开类别，逐个勾选电话、信息等要保留的 App。如果列表中有 Daywell，也可以一并选上。"
            : "选择要锁定的应用、类别或网站。「豁免名单」中的 App 会跳过。新增项立即加入当前锁定，移除项从下轮生效。"
        )
        .font(.footnote).foregroundStyle(.secondary).padding()
        if !canSave {
          Text(
            purpose == .restricted
              ? ScreenTimeError.selectionLimitExceeded.localizedDescription
              : "请只选择具体的 App，最多 50 个。"
          )
          .font(.footnote).foregroundStyle(DaywellTheme.muted).padding(.horizontal)
          if purpose == .restricted {
            Button("清空圈选") { selection = FamilyActivitySelection(includeEntireCategory: false) }
              .padding(.top, 8)
          }
        }
        FamilyActivityPicker(selection: pickerSelection)
      }
      .navigationTitle(purpose == .alwaysAllowed ? "豁免名单" : "选择锁定应用")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            Task {
              let saved =
                if purpose == .alwaysAllowed { await model.saveAlwaysAllowed(selection) } else {
                  await model.saveSelection(selection)
                }
              if saved { dismiss() }
            }
          }.bold().disabled(model.isBusy || !canSave)
        }
      }
    }.interactiveDismissDisabled(model.isBusy)
  }
}
