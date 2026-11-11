import Combine
import SwiftUI
import UIKit

enum DaywellTab: String, CaseIterable, Identifiable {
  case sleep = "睡眠"
  case screen = "用机"
  case fitness = "健身"
  case settings = "设置"
  var id: Self { self }
  var icon: String {
    switch self {
    case .sleep: return "moon.zzz.fill"
    case .screen: return "iphone"
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
      case .screen:
        FutureModuleView(
          message: "把时间，留给更重要的事。", detail: "设备使用管理将在后续版本加入。",
          openSettings: { settingsTab = .screen })
      case .fitness: FitnessView { settingsTab = .fitness }
      case .settings: GlobalSettingsView()
      }
    }
    .foregroundStyle(DaywellTheme.text)
    .background(DaywellTheme.background)
    .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
    .sheet(item: $settingsTab) { SettingsView(tab: $0) }
    .task { await model.refresh() }
    .onReceive(timer) { if scenePhase == .active { model.tick($0) } }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.refresh() } }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
    ) { _ in
      Task { await model.refresh() }
    }
    .alert(
      "需要处理一下",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("知道了") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private func openAuthorizationSettings() {
    tab = .settings
  }

  private var tabBar: some View {
    HStack(spacing: 4) {
      ForEach(DaywellTab.allCases, id: \.self) { item in
        Button {
          tab = item
        } label: {
          VStack(spacing: 6) {
            Image(systemName: item.icon).font(.system(size: 20, weight: .medium))
            Text(item.rawValue).font(.caption.weight(.medium))
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

private struct FutureModuleView: View {
  let message: String
  let detail: String
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      PageHeading(tab: .screen, openSettings: openSettings)
      Spacer()
      VStack(spacing: 18) {
        Image(systemName: "iphone").font(.system(size: 52, weight: .light)).foregroundStyle(
          DaywellTheme.accent)
        Text(message).font(.title2.bold()).multilineTextAlignment(.center)
        Text(detail).font(.subheadline).foregroundStyle(DaywellTheme.muted)
        Text("敬请期待").font(.caption.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 8)
          .background(DaywellTheme.soft, in: Capsule())
      }.frame(maxWidth: .infinity)
      Spacer()
      Spacer()
    }.padding(24).frame(maxWidth: 1080).frame(maxWidth: .infinity)
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
        Text(tab.rawValue).font(.largeTitle.bold())
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
        .accessibilityLabel("\(tab.rawValue)设置")
        .accessibilityIdentifier("\(tab).settings")
      }
    }
  }
}
