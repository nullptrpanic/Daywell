# Daywell

面向 iPhone 和 iPad 的生活管理应用。睡眠模块支持多个锁定时段、系统应用圈选，以及每个时段独立计算的临时豁免。默认 2 次，分别 10、5 分钟；最多 5 次，预设时长为 10、5、3、2、1 分钟，每次可单独调整。底栏提供睡眠、用机、健身和设置，各功能页右上角进入对应设置。用机目前仍为说明页，独立 App 周期限制处于界面设计与技术验证阶段。

保存睡眠时段时会检查重复星期和时间，跨午夜计入次日，首尾相接可以保存。遇到已保存的重叠时段会提示冲突并拒绝保存。停用正在锁定的时段需要手动输入 App 生成的 6 位验证码，确认后立即结束本轮并停用后续重复。

新增或重新开启时段时，如果包含当前时间就立即开始；今天还没开始的时段在今天执行，已经结束的才安排到下一个符合重复星期的日期。重新开启不会沿用停用前遗留的延后标记。

修改应用圈选时，新增项立即加入当前锁定，移除项从下一轮生效；正在进行的豁免时长和已用次数保持不变。系统圈选器中的类别全选不代表每个系统 App 都被选中，Safari 等未被包含的应用需要搜索后单独勾选。首页分别展示类别数量与单选 App 数量。

「健身」默认 6 组，长按大圆按钮 1 秒完成一组。按住时显示倒计时进度环，提前松手取消，成功记组时进度环合拢。达到目标后播放鼓励动画并自动归零。下方按钮可以重置本轮。「健身 → 右上角设置」可修改目标组数，修改目标会清空本轮，计数与设置在本机保存。

健身设置可开启「组间休息」，默认 30 秒，每次加减 30 秒。每次完成非最后一组，健身页从完整时长重新倒计时。在已授权的完整版真机上，休息结束即限制应用与网站，不需要先配置豁免名单。底栏「设置 → 豁免名单」可选填电话、信息等要保留的应用，睡眠与健身锁定会放行这些应用。健身使用系统全部应用及全部网站策略，Daywell 本身可继续打开。完成本轮、重置或关闭功能时解除训练限制。应用豁免名单不自动豁免网页。

「清晨模式」在每个睡眠时段中单独开启，在「睡眠 → 右上角设置 → 清晨模式」统一调整累计可用时间和用满后锁定时长，默认 10 / 30 分钟。睡眠结束后累计使用圈选应用，中途退出不清空；用满后锁一次，未用满的额度到该睡眠下一次开始时失效。复用应用范围和豁免设置，清晨锁定独立计算次数，并使用洗漱、喝水的提示文案。旧数据自动迁移，保留进行中的锁定和豁免；已开始的睡眠及其清晨轮次保留原规则。

底栏「设置」集中显示外观、屏幕使用时间授权、豁免名单和 Daywell 说明。外观支持跟随系统、浅色、深色，选择自动保存。各功能右上角的设置以弹出页展示，完成后回到原功能页。

系统撤销屏幕使用时间授权后，返回应用会恢复需要授权的状态卡，保留时段、豁免规则和已用次数、清晨设置以及健身进度。Apple 会使撤权前的应用选择令牌失效；重新授权后需再次圈选锁定应用和豁免名单。仅在冷启动确认授权时取消弹窗或遇到临时错误，不清空原圈选，之后授权成功可沿用名单。

系统锁定页与首页均在没有可用次数时隐藏豁免按钮。有次数时可直接在系统锁定页申请临时豁免。已保存的旧时长会保留，可在设置调整；活动时段继续使用开始时的规则。

## 打开工程

使用 **Xcode 16 或更新版本**打开 `Daywell.xcodeproj`。完整功能选择 **Daywell** scheme，免费账号真机预览选择 **DaywellPreview**。最低部署版本 iOS / iPadOS 17。项目不依赖第三方库，不需要额外生成工程。

模拟器可以运行界面、编辑时段与设置，不能验证实际 Screen Time 限制。编写代码和模拟器编译不需要在 Xcode 中登录 Apple 账号。

如果命令行仍指向 Command Line Tools，可仅为当前命令指定完整 Xcode，不必修改全局设置：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Daywell.xcodeproj -scheme Daywell \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

项目构建产物统一放在根目录 `build/` 下，整个目录由 Git 忽略。Xcode 命令行构建使用 `-derivedDataPath build/DerivedData`，归档使用 `-archivePath build/archives/Daywell.xcarchive`，导出使用 `-exportPath build/export`；核心测试脚本通过 `--scratch-path build/swiftpm` 指定测试产物目录。构建日志放在 `build/logs/`。

## 免费账号安装预览版

**DaywellPreview** 使用普通 Apple 账号的 Personal Team 签名，桌面名称为「Daywell 预览」。可以体验健身计数、多个时段的增删改与启停、清晨模式配置、逐次豁免设置和深浅外观。此版本不申请屏幕使用时间授权，不提供应用圈选、实际锁定或临时解锁；界面会明确显示预览状态。

1. 打开 Xcode → Settings → Apple Accounts，登录自己的普通 Apple 账号。无需购买开发者会员。
2. 选择工程 → TARGETS → **DaywellPreview** → Signing & Capabilities，启用 Automatically manage signing，Team 选择自己的 **Personal Team**。
3. 默认预览版 Bundle ID 为 `com.nullptrpanic.Daywell.preview`，可通过 `Config/Daywell.xcconfig` 中的 `DAYWELL_PREVIEW_BUNDLE_ID` 修改。如果 Xcode 提示标识已被占用，换成自己独有的标识。
4. 将手机与 Mac 配对，按提示启用开发者模式。Xcode 顶部 scheme 选 **DaywellPreview**，运行设备选自己的 iPhone，然后按 **⌘R** 安装并启动。

Xcode 27 搭配 iOS / iPadOS 27 或更新版本支持**首次无线配对**：两台设备接入同一 Wi‑Fi，在 Xcode → Open Developer Tool → Device Hub 中点「+」→ Pair Nearby Device…，选择设备类型，按提示开启开发者模式、输入配对码并确认信任。首次配对时，手机上的开发者模式入口可能在 Mac 发起配对后才出现。较旧系统首次配对需要数据线，配对完成后可以通过网络运行。

Personal Team 的安装描述文件在签发 **7 天后到期**，届时需再次用 Xcode 编译安装。预览版不嵌入三个 Screen Time 扩展，也不包含 Family Controls 或 App Groups entitlement；配置保存在独立应用沙盒中，不与完整版互通。

参考：[Apple 个人团队与免费账号限制](https://developer.apple.com/help/account/basics/about-your-developer-account)、[Device Hub 配对说明](https://developer.apple.com/documentation/xcode/pairing-your-devices-with-your-mac)。

## 完整版真机签名与授权

1. 在四个 target 的 Signing & Capabilities 中选择自己的开发团队。Family Controls 属于 Apple Developer Program 提供的能力，不能把普通应用的免费 Personal Team 调试能力等同于可使用本项目所有 entitlement。
2. `Config/Daywell.xcconfig` 集中定义 Bundle ID 前缀和 App Group。需要更换标识时同步修改该配置；四个 target 的 Bundle ID 应在同一团队下。
3. 四个 target 均需 Family Controls entitlement，并配置相同 App Group。Shield Configuration 读取剩余次数，Shield Action 使用共享事务直接发起临时豁免。
4. 在真实 iPhone/iPad 上运行，进入底栏「设置」开启屏幕使用时间授权。回到睡眠页，从上方状态卡圈选应用、类别或网站。批量限制应用可直接圈选类别。
5. 通过 TestFlight / App Store 分发前，需要分别为主应用及 Screen Time 扩展申请 Family Controls 分发权限。

参考：[Apple 配置 Family Controls](https://developer.apple.com/documentation/xcode/configuring-family-controls)、[申请分发 entitlement](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement)。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `App/` | 原生 SwiftUI 页面、四 Tab、授权与交互状态 |
| `Sources/DaywellCore/` | 日历时段、豁免状态机、共享文件事务、系统监测计划 |
| `Platform/` | FamilyControls / DeviceActivity / ManagedSettings 适配 |
| `Extensions/` | 后台监测、锁定页外观、锁定页按钮处理 |
| `Tests/DaywellCoreTests/` | 可在 macOS 运行的核心行为测试 |
| `docs/design/` | 随代码保存的设计文档 |
| `docs/plan/` | 已忽略的本地计划，不提交到 Git |

`Platform/PreviewScreenTimeService.swift` 仅属于 DaywellPreview target，使用现有 StateStore 保存本地配置；完整版与扩展继续使用 ScreenTimeService.swift。预览 target 的 `DAYWELL_PREVIEW` 编译条件排除 FamilyControls 导入和应用选择器。

## 验证

上架所需的隐私政策与技术支持网页源码位于 `website/`，App 的全局设置页提供相应入口。发布步骤和 App Store Connect 填写位置见[网站发布说明](docs/distribution/website.md)。正式分发包含这些入口的构建前，需先发布并验证公网链接。

```bash
bash scripts/test-core.sh
bash scripts/test-platform.sh
xcrun swift-format lint --recursive --strict App Platform Extensions Sources Tests Package.swift
```

测试脚本使用当前 Xcode 工具链。若只有近期 Command Line Tools，会为其附带的 Swift Testing framework 和宏插件显式设置路径；该工具链下使用 native builder，会出现 SwiftPM 自身的弃用提示，不是应用编译诊断。

`test-platform.sh` 在 macOS 上将真实的系统适配器、应用模型和共享状态编译到同一测试程序，仅替换 Apple SDK 边界。检查监测即时回调、并发清晨与豁免、失败恢复、启动线程、豁免名单上限、网页限制释放和权限撤销后的配置保留；不能替代真机授权、系统回调时机和实际锁定的验证。可在脚本后传入单个场景名运行，例如 `bash scripts/test-platform.sh authorization-revoked`。

核心测试不替代 iOS SDK 编译、模拟器布局检查或 Screen Time 真机测试。真机验收至少包括：

- 单时段、跨午夜、重复星期和时段重叠时的保存拦截。
- 小于 15 分钟的时段开始和结束；默认 10 分钟豁免到期。
- 前后台切换、强退主应用、锁屏和重新开机后的限制恢复。
- 用完机会、提前恢复、期间修改规则或删除时段，以及验证码确认后立即停用当前时段。
- 旧配置中的重叠时段和清晨锁定同时执行时，各自的结束与豁免到期行为。
- 系统锁定页有次数/无次数的按钮显示、直接豁免、两入口连续点击、5/3/2/1 分钟短豁免到期恢复。
- 撤销并重新授权后的重新圈选、时区及夏令时变化。
- 系统监测数量限制、安排回调失败时不解除限制。
- 清晨统计窗口的累计使用、跨 App 使用、阈值触发一次锁定、自动结束、与其他睡眠重叠；前后台、强退与重启后的回调，以及时区切换不重置累计值。

系统 DeviceActivity 回调与设备使用相关，不能承诺精确到秒。个人授权也允许用户主动撤销；本期不包含防卸载或不可绕过模式。数据仅保存在当前设备，不记录实际睡眠时长。完整行为见 [设计文档](docs/design/sleep-management.md)。

新增模块说明：[清晨模式](docs/design/morning-mode.md)、[健身计数](docs/design/fitness-counter.md)、[用机界面提案与待验证能力](docs/design/app-control-ui.md)。
