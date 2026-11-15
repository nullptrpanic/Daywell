import FamilyControls
import SwiftUI

struct ApplicationSelectionView: View {
  enum Purpose: Equatable {
    case restricted
    case alwaysAllowed
    case focus
  }

  @EnvironmentObject private var model: DaywellModel
  @Environment(\.dismiss) private var dismiss
  @State private var selection: FamilyActivitySelection
  @State private var saveError: String?
  @State private var pickerID = UUID()
  private let purpose: Purpose

  init(selection: FamilyActivitySelection, purpose: Purpose = .restricted) {
    _selection = State(initialValue: selection)
    self.purpose = purpose
  }

  private var canSave: Bool {
    if purpose == .focus {
      return selection.focusSelectionError == nil
    }
    if purpose == .restricted { return selection.fitsShieldLimits }
    return selection.applicationTokens.count <= ScreenTimeService.shieldTokenLimit
  }

  private var pickerSelection: Binding<FamilyActivitySelection> {
    // Keep the system picker's draft intact. Rewriting it to emulate radio buttons
    // can diverge from the system UI and flip the saved app on repeated updates.
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
          purpose == .focus
            ? String(localized: "只选择一个具体的 App。更换时，请先取消原来的勾选，再选择新的应用。")
            : purpose == .alwaysAllowed
              ? String(localized: "选择电话、信息等要保留的 App。勾选类别会加入其中的 App，网站不加入豁免名单。")
              : String(localized: "选择要锁定的应用、类别或网站。「豁免名单」中的 App 会跳过。新增项立即加入当前锁定，移除项从下轮生效。")
        )
        .font(.footnote).foregroundStyle(.secondary).padding()
        if purpose == .focus {
          VStack(alignment: .leading, spacing: 8) {
            Text("已选 \(selection.applicationTokens.count) 个 App")
              .accessibilityIdentifier("focus.selectionCount")
            if let error = selection.focusSelectionError {
              Text(error)
                .foregroundStyle(selection.isEmpty ? DaywellTheme.muted : .red)
                .accessibilityIdentifier("focus.selectionError")
              if !selection.isEmpty {
                Button("清空圈选") {
                  selection = FamilyActivitySelection(includeEntireCategory: true)
                  pickerID = UUID()
                }
                .accessibilityIdentifier("focus.clearSelection")
              }
            }
          }
          .font(.footnote)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
        }
        if purpose == .alwaysAllowed {
          Text("已选 \(selection.applicationTokens.count) 个 App，最多 50 个")
            .font(.footnote)
            .foregroundStyle(canSave ? DaywellTheme.muted : .red)
            .padding(.horizontal)
        }
        if !canSave && purpose != .focus {
          Text(
            purpose == .restricted
              ? ScreenTimeError.selectionLimitExceeded.localizedDescription
              : String(localized: "已超过豁免名单上限，请取消部分 App 后再完成。")
          )
          .font(.footnote).foregroundStyle(DaywellTheme.muted).padding(.horizontal)
          Button("清空圈选") {
            selection = FamilyActivitySelection(includeEntireCategory: purpose == .alwaysAllowed)
          }
          .padding(.top, 8)
        }
        FamilyActivityPicker(selection: pickerSelection)
          .id(pickerID)
          .disabled(model.isBusy)
      }
      .navigationTitle(
        purpose == .focus ? String(localized: "选择聚焦应用") : (purpose == .alwaysAllowed ? String(localized: "豁免名单") : String(localized: "选择锁定应用"))
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            if purpose == .focus, let error = selection.focusSelectionError {
              saveError = error
              return
            }
            let submitted = selection
            Task {
              let saved =
                if purpose == .focus {
                  await model.saveFocusSelection(submitted)
                } else if purpose == .alwaysAllowed {
                  await model.saveAlwaysAllowed(submitted)
                } else {
                  await model.saveSelection(submitted)
                }
              if saved {
                dismiss()
              } else if purpose == .focus {
                saveError = model.errorMessage ?? String(localized: "未能保存，请稍后重试。")
                model.errorMessage = nil
              }
            }
          }.bold().disabled(model.isBusy || (purpose != .focus && !canSave))
            .accessibilityIdentifier("selection.done")
        }
      }
    }
    .interactiveDismissDisabled(model.isBusy)
    .alert(
      "无法保存选择",
      isPresented: Binding(
        get: { saveError != nil },
        set: { if !$0 && saveError != nil { saveError = nil } })
    ) {
      Button("知道了", role: .cancel) {}
    } message: {
      Text(saveError ?? "")
    }
  }
}
