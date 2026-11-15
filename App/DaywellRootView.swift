import Combine
import SwiftUI
import UIKit

enum DaywellTab: String, CaseIterable, Identifiable {
  case sleep = "睡眠"
  case focus = "聚焦"
  case fitness = "健身"
  case settings = "设置"
  var id: Self { self }
  var title: String {
    switch self {
    case .sleep: String(localized: "睡眠")
    case .focus: String(localized: "聚焦")
    case .fitness: String(localized: "健身")
    case .settings: String(localized: "设置")
    }
  }
  var settingsTitle: String { String(localized: "\(title)设置") }
  var icon: String {
    switch self {
    case .sleep: return "moon.zzz.fill"
    case .focus: return "scope"
    case .fitness: return "figure.strengthtraining.traditional"
    case .settings: return "gearshape"
    }
  }
}

struct DaywellRootView: View {
  @EnvironmentObject private var model: DaywellModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var tab = DaywellTab.sleep
  @State private var settingsTab: DaywellTab?
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    Group {
      switch tab {
      case .sleep:
        SleepView(
          openSettings: { settingsTab = .sleep },
          openAuthorizationSettings: openAuthorizationSettings)
      case .fitness: FitnessView { settingsTab = .fitness }
      case .focus:
        FocusView(
          openSettings: { settingsTab = .focus },
          openAuthorizationSettings: openAuthorizationSettings)
      case .settings: GlobalSettingsView()
      }
    }
    .foregroundStyle(DaywellTheme.text)
    .background(DaywellTheme.background)
    .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
    .sheet(item: $settingsTab) { SettingsView(tab: $0) }
    .task { await refreshOnActivation() }
    .onReceive(
      NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
    ) { _ in
      Task { await refreshOnActivation() }
    }
    .onReceive(timer) { if scenePhase == .active { model.tick($0) } }
    .onReceive(
      NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
    ) { _ in
      Task { await model.refresh() }
    }
    .alert(
      "需要处理一下",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 && model.errorMessage != nil { model.errorMessage = nil } })
    ) {
      Button("知道了") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private func openAuthorizationSettings() {
    tab = .settings
  }

  private func refreshOnActivation() async {
    if await model.consumeFitnessNavigation() {
      settingsTab = nil
      tab = .fitness
    }
    await model.refresh()
  }

  private var tabBar: some View {
    HStack(spacing: 4) {
      ForEach(DaywellTab.allCases, id: \.self) { item in
        Button {
          tab = item
        } label: {
          VStack(spacing: 6) {
            Image(systemName: item.icon).font(.system(size: 20, weight: .medium))
            Text(item.title).font(.caption.weight(.medium))
          }
          .foregroundStyle(tab == item ? DaywellTheme.accent : DaywellTheme.muted)
          .frame(maxWidth: .infinity, minHeight: 58)
          .background(
            tab == item ? DaywellTheme.soft : .clear, in: RoundedRectangle(cornerRadius: 18)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == item ? .isSelected : [])
        .accessibilityIdentifier("tab.\(item)")
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
    .frame(maxWidth: 600)
    .frame(maxWidth: .infinity)
    .background(DaywellTheme.surface)
    .overlay(alignment: .top) { Rectangle().fill(DaywellTheme.border).frame(height: 1) }
  }
}

struct PageHeading: View {
  let tab: DaywellTab
  let openSettings: (() -> Void)?
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 7) {
        Text("DAYWELL").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(
          DaywellTheme.muted)
        Text(tab.title).font(.largeTitle.bold())
      }
      Spacer()
      if let openSettings {
        Button(action: openSettings) {
          Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(
            DaywellTheme.accent
          )
          .frame(width: 48, height: 48).background(
            DaywellTheme.soft, in: RoundedRectangle(cornerRadius: 18)
          )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.settingsTitle)
        .accessibilityIdentifier("\(tab).settings")
      }
    }
  }
}
