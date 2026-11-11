import DaywellCore
import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
  override func configuration(shielding application: Application) -> ShieldConfiguration {
    configuration(name: application.localizedDisplayName ?? "这个应用")
  }

  override func configuration(shielding application: Application, in category: ActivityCategory)
    -> ShieldConfiguration
  {
    configuration(name: application.localizedDisplayName ?? "这个应用")
  }

  override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
    configuration(name: "这个网站")
  }

  override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory)
    -> ShieldConfiguration
  {
    configuration(name: "这个网站")
  }

  private func configuration(name: String) -> ShieldConfiguration {
    let now = Date()
    let service = try? ScreenTimeService()
    var state = try? service?.read()
    state?.refresh(at: now, calendar: .current)
    let isFitness =
      service?.isFitnessShieldApplied == true || state?.hasFitnessRestriction(at: now) == true
    let offer = service?.isAuthorized == true && !isFitness ? state?.exemptionOffer(at: now) : nil
    let exhausted = state?.blockingSessions(at: now).contains { $0.remainingCount == 0 } ?? false
    let blocking = state?.blockingSessions(at: now) ?? []
    let isMorning = !blocking.isEmpty && blocking.allSatisfy(\.isMorning)
    let detail: String
    if isFitness {
      detail = "练完回 Daywell 记一组，下一轮休息就会开始。"
    } else if isMorning {
      let end = blocking.map(\.occurrence.end).max()!
      let time = end.formatted(date: .omitted, time: .shortened)
      let allowance: String
      if let offer {
        allowance = "还可临时豁免 \(offer.remainingCount) 次，本次\(offer.durationLabel)。"
      } else if exhausted {
        allowance = "本轮豁免已用完，洗漱、喝杯水，稍后再回来。"
      } else {
        allowance = "如需检查限制状态，请打开 Daywell。"
      }
      detail = "先去洗漱、喝杯水，慢慢开始今天。\n本轮休息到 \(time)，之后可再使用\(name)。\n\(allowance)"
    } else if let offer {
      detail =
        "\(name)正在 Daywell 的锁定时段内。\n还可临时豁免 \(offer.remainingCount) 次，本次\(offer.durationLabel)。"
    } else if exhausted {
      detail = "\(name)正在 Daywell 的锁定时段内。\n本时段已无可用豁免，等休息结束再回来。"
    } else {
      detail = "\(name)正在 Daywell 的锁定时段内。\n如需检查限制状态，请打开 Daywell。"
    }
    let title = isFitness ? "休息好了，该下一组了" : (isMorning ? "早安，先照顾好自己" : "让屏幕，也休息一会儿")
    let symbol = isFitness ? "dumbbell.fill" : (isMorning ? "sun.horizon.fill" : "moon.zzz.fill")
    let primaryLabel = isFitness ? "好，去练下一组" : (isMorning ? "好的，先去洗漱" : "好的，继续休息")
    let accent = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.77, green: 0.72, blue: 1, alpha: 1)
        : UIColor(red: 0.40, green: 0.33, blue: 0.71, alpha: 1)
    }
    let buttonText = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.16, green: 0.13, blue: 0.25, alpha: 1) : .white
    }
    return ShieldConfiguration(
      backgroundBlurStyle: .systemMaterial,
      backgroundColor: .systemBackground,
      icon: UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .regular))?
        .withTintColor(
          accent, renderingMode: .alwaysOriginal),
      title: .init(text: title, color: .label),
      subtitle: .init(text: detail, color: .secondaryLabel),
      primaryButtonLabel: .init(text: primaryLabel, color: buttonText),
      primaryButtonBackgroundColor: accent,
      secondaryButtonLabel: offer.map { _ in
        .init(text: "临时豁免", color: accent)
      }
    )
  }

}
