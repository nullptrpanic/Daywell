import SwiftUI

@main
struct DaywellApp: App {
  @StateObject private var model = DaywellModel()
  @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

  var body: some Scene {
    WindowGroup {
      DaywellRootView()
        .environmentObject(model)
        .tint(DaywellTheme.accent)
        .preferredColorScheme(appearance.colorScheme)
    }
  }
}
