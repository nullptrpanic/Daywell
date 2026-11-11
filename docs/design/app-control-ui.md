# 用机模块界面提案

本次只提供可交互界面提案，没有把未经验证的自动统计规则接入原生用机模块。

每个 App 独立设置周期、周期内累计额度和逐次豁免。例：每 3 小时可用 1 小时，从首次打开时刻 x 开始统计；关闭、重开保留已用时长；x+3 后未使用则等下次首次使用再开新周期，持续在前台使用则 x+3 立即开始下一周期。

列表展示各 App 的独立规则、当前周期和额度状态，点击卡片修改。设置页提供周期、额度、0–5 次豁免，逐次分钟数默认 10、5、3、2、1。修改下个周期生效，当前统计保留。锁定页显示本轮结束时间，有剩余次数时可以临时豁免，没有次数时隐藏按钮。

用机页右上角提供设置入口，与睡眠、健身一致。原生用机设置目前说明功能尚未开放。底栏「设置」提供共用的外观、屏幕使用时间授权和 Daywell 说明。

视觉布局复用现有的页标题、主题和内容卡片。用机提案沿用睡眠页的状态卡和规则列表层级。功能设置采用带「完成」的弹出页面，共用外观使用分段选择。后续预览与实现以现有原生布局为准。

## 平台限制

Apple `DeviceActivityEvent` 支持圈选 App 的累计前台使用、阈值回调与屏蔽；它没有直接提供任意第三方 App 的首次前台时间或每次离开前台的生命周期回调。`intervalDidStart` 是监控窗口内的设备使用回调，不能当作指定 App 的首次打开。

因此，精确实现用户要求的首次打开锚定周期和连续跨周期行为仍需真机技术验证。没有把固定整点窗口伪装成这套规则。快捷指令打开/关闭 App 触发器可作为后续探索路径，需要用户配置；本次不接入、不要求用户配置。

参考：[DeviceActivityEvent](https://developer.apple.com/documentation/deviceactivity/deviceactivityevent)、[DeviceActivityCenter](https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter)、[快捷指令 App 触发器](https://support.apple.com/en-ie/guide/shortcuts/apde31e9638b/ios)。
