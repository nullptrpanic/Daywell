import ManagedSettings

final class ShieldActionExtension: ShieldActionDelegate {
  override func handle(
    action: ShieldAction, for application: ApplicationToken,
    completionHandler: @escaping (ShieldActionResponse) -> Void
  ) {
    handle(action, completionHandler: completionHandler)
  }

  override func handle(
    action: ShieldAction, for webDomain: WebDomainToken,
    completionHandler: @escaping (ShieldActionResponse) -> Void
  ) {
    handle(action, completionHandler: completionHandler)
  }

  override func handle(
    action: ShieldAction, for category: ActivityCategoryToken,
    completionHandler: @escaping (ShieldActionResponse) -> Void
  ) {
    handle(action, completionHandler: completionHandler)
  }

  private func handle(
    _ action: ShieldAction, completionHandler: @escaping (ShieldActionResponse) -> Void
  ) {
    if #available(iOS 26.5, *), action == .primaryButtonPressed,
      (try? ScreenTimeService().requestFitnessNavigation()) == true
    {
      completionHandler(.openParentalControlsApp)
      return
    }
    guard action == .secondaryButtonPressed else {
      completionHandler(.close)
      return
    }
    do {
      // Use the same durable quota transaction and background recovery as the main app.
      // Revalidating here also handles stale shield UI and repeated taps safely.
      _ = try ScreenTimeService().beginExemption()
    } catch {
      // Keep restrictions on failure. A deferred response asks the system to refresh the shield.
    }
    completionHandler(.defer)
  }
}
