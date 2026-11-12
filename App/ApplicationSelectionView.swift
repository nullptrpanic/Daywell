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
    return selection.applicationTokens.count <= ScreenTimeService.shieldTokenLimit
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
            ? "选择电话、信息等要保留的 App。勾选类别会加入其中的 App，网站不加入豁免名单。"
            : "选择要锁定的应用、类别或网站。「豁免名单」中的 App 会跳过。新增项立即加入当前锁定，移除项从下轮生效。"
        )
        .font(.footnote).foregroundStyle(.secondary).padding()
        if purpose == .alwaysAllowed {
          Text("已选 \(selection.applicationTokens.count) 个 App，最多 50 个")
            .font(.footnote)
            .foregroundStyle(canSave ? DaywellTheme.muted : .red)
            .padding(.horizontal)
        }
        if !canSave {
          Text(
            purpose == .restricted
              ? ScreenTimeError.selectionLimitExceeded.localizedDescription
              : "已超过豁免名单上限，请取消部分 App 后再完成。"
          )
          .font(.footnote).foregroundStyle(DaywellTheme.muted).padding(.horizontal)
          Button("清空圈选") {
            selection = FamilyActivitySelection(includeEntireCategory: purpose == .alwaysAllowed)
          }
          .padding(.top, 8)
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
