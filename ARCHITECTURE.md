# FaradayCage 架构与开发者指南

这份文档记录了本项目在调用 macOS 底层 API (辅助功能、屏幕录制、窗口管理) 时的核心架构设计和“踩坑”经验。如果你计划修改本项目的源码，或者想开发类似的 macOS 系统级工具，强烈建议先阅读本文档。

## ⚙️ 构建与运行机制
- **纯 Swift 构建**: 本项目没有 `.xcodeproj` 工程文件。应用直接由 `engineering/app/main.swift` 源码，通过 `swiftc` 和 `lipo` 命令编译为通用二进制文件 (Universal Binary, x86_64 + arm64)。
- **TCC 权限稳定性**: 构建脚本 (`build.sh`) 推荐使用名为 `FaradayCage Developer` 的本地自签名证书对应用进行签名。这是为了稳定 macOS 的 TCC 权限（辅助功能和屏幕录制权限）不被频繁重置。如果你在本地没有这张证书，脚本会退级使用临时签名（`-`），但这会导致你每次重新编译后都需要重新去“系统设置”中勾选权限。
- **一键运行流程**: 构建脚本会自动杀死已有的进程，编译新的包，并将其安装到 `/Applications/FaradayCage.app` 然后启动它。

## ⚠️ API 避坑指南 (The Gotchas)

### 1. 坐标系转换 (左上角 vs 左下角)
`AXUIElement` (辅助功能 API) 和 `ScreenCaptureKit` 使用的是 **左上角坐标系**（原点在主屏幕左上角）。而底层的 AppKit (`NSWindow`) 使用的是 **左下角坐标系**。在设置 `NSWindow.setFrame` 之前，**必须**使用以下公式进行坐标转换，否则悬浮窗口会发生严重的垂直偏移：
`bottomY = 主屏幕高度 - topY - 窗口高度`

### 2. ScreenCaptureKit 与原生 Tab 切换的“假死”
macOS 的原生多标签页（例如系统自带的“终端”、“访达”等 App）在底层实际上是拥有不同 Window ID 的**独立 `SCWindow`**。
如果你的录屏滤镜 (`SCContentFilter`) 只死锁在用户最初置顶的那个单一窗口上，当用户在这个应用内切换原生 Tab 时，录屏画面就会彻底冻结（因为底层被捕获的那个 Window ID 已经不可见了）。
**解决方案**: 代码中必须使用 `streamUpdateTimer` 定时检测原生 Tab 窗口的前台变化，并在发现 Window ID 改变时，动态调用 `updateContentFilter` 热更新录屏源。

### 3. 拖动窗口的“零残影”实现
绝对不要使用轮询定时器（Timer）来同步原窗口和透明浮窗的位置，那会导致在拖动时出现严重的延迟和残影，体验极差。
**解决方案**: 必须使用辅助功能底层的 `AXObserver`，监听 `kAXMovedNotification` 和 `kAXResizedNotification` 事件，实现纯底层事件驱动的零延迟位置同步。

### 4. 实时调整大小的“防抖热更新”
当用户拖拽改变被置顶窗口的大小时，如果不更新 `SCStreamConfiguration` 的分辨率，录屏画面会被拉伸变得模糊失真。
但在拖拽过程中每一帧都去更新底层录屏流会导致严重的性能卡顿。
**解决方案**: 引入了 `100ms` 的防抖（Debounce）机制。拖拽过程中仅改变窗口大小（允许极短暂的拉伸），当用户停止拖动 100 毫秒后，瞬间重新抓取高清 Retina 分辨率并热更新给 `ScreenCaptureKit`，画面瞬间恢复极致清晰。

## 🔄 交互模型：完美的视觉置顶

为了实现毫无破绽的“窗口置顶”体验，我们必须精细化管理透明覆盖层（Overlay Window）的前后台状态：

- **当目标应用在后台（未激活）时**：
  浮窗必须设置 `ignoresMouseEvents = false` 并保持可见。用户点击浮窗时，这实际上是在点击我们的 FaradayCage。此时 FaradayCage 会通过底层 API 瞬间激活目标应用（`activateIgnoringOtherApps`），让目标应用跳到前台。
  
- **当目标应用在前台（已激活）时**：
  浮窗必须在 `.floating` 层级保持可见（`alphaValue = 1`），以确保它能悬浮在同应用的其他窗口之上。此时必须设置 `ignoresMouseEvents = true`（鼠标穿透）。因为此时用户想要的是操作那个真实的窗口，我们的浮窗必须让所有的鼠标点击、滚动、拖拽直接穿透下去，落在背后的真实窗口上。

> **切记**：无论如何，**绝对不要**试图使用死循环定时器去调用 `CGSSetWindowLevel` 来强行维持真实窗口的层级，在现代 macOS 中这会导致极其严重的焦点抢夺和闪屏。老老实实地使用透明 `.floating` 浮窗 + ScreenCaptureKit 录屏投影，是实现置顶的唯一稳定优雅方案。
