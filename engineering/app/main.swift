import Cocoa
import Carbon
import ApplicationServices
import ScreenCaptureKit
import AVFoundation
import CoreMedia

// MARK: - 日志
private func logToFile(_ msg: String) {
    let path = "/tmp/faradaycage_debug.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - 全局常量
private let kBundleID = "com.faradaycage"
private let kHotKeySignature: UInt32 = 0x4D494E // "MINI"
private let kHotKeySignatureOther: UInt32 = 0x4D494F // "MINO"

// MARK: - 浮窗面板（不抢键盘焦点）
class PinnableWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 覆盖层点击视图（支持悬停激活）
class OverlayClickView: NSView {
    var onActivate: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea {
            removeTrackingArea(ta)
        }
        // 监听鼠标进入事件
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        if let ta = trackingArea {
            addTrackingArea(ta)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // 鼠标进入浮窗时，立刻激活目标应用
        // 这样可以实现“悬停激活”，用户点击的第一下就能直接穿透并生效
        onActivate?()
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - 窗口置顶管理器（ScreenCaptureKit + 点击激活，对标 Topit）
@available(macOS 12.3, *)
class WindowPinner: NSObject {

    // MARK: 属性
    private var stream: SCStream?
    private var overlayWindow: PinnableWindow?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var targetAXWindow: AXUIElement?
    private var syncTimer: Timer?          // 位置同步定时器
    private var streamUpdateTimer: Timer?  // Tab 切换检测定时器
    private var axObserver: AXObserver?    // AX 观察者（实时监听窗口移动）
    private var scFrameOffset: CGRect = .zero // SCWindow 与 AXWindow 的 frame 差异（包含阴影等）
    private var currentSCWindowID: CGWindowID = 0
    private var resizeDebounceWorkItem: DispatchWorkItem? // 防抖用的任务
    
    var targetPID: pid_t = 0
    var targetTitle: String = ""
    private(set) var isPinned = false

    // MARK: 公开方法

    /// 置顶指定窗口
    func pin(axWindow: AXUIElement, app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        targetAXWindow = axWindow
        targetPID = app.processIdentifier

        // 获取窗口标题
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
        targetTitle = (titleRef as? String) ?? app.localizedName ?? ""

        logToFile("[Pinner] 开始置顶 pid=\(targetPID) title=\(targetTitle)")

        // 获取原窗口位置
        guard let origFrame = getAXWindowFrame(axWindow) else {
            logToFile("[Pinner] 无法获取窗口位置")
            completion(false)
            return
        }
        logToFile("[Pinner] 原窗口位置 frame=\(origFrame)")

        // 获取可共享内容
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    logToFile("[Pinner] 获取窗口列表失败: \(error.localizedDescription)")
                    completion(false)
                    return
                }

                guard let content = content else {
                    logToFile("[Pinner] 窗口列表为空")
                    completion(false)
                    return
                }

                // 按 PID 匹配窗口
                let candidates = content.windows.filter { $0.owningApplication?.processID == self.targetPID }

                // 优先按 frame 匹配（最可靠，不受标题变化影响），然后取最大窗口
                let scWindow = candidates.first(where: {
                    abs($0.frame.origin.x - origFrame.origin.x) < 5 &&
                    abs($0.frame.origin.y - origFrame.origin.y) < 5 &&
                    abs($0.frame.width - origFrame.width) < 5 &&
                    abs($0.frame.height - origFrame.height) < 5
                }) ?? candidates.max(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                })

                guard let scWindow = scWindow else {
                    logToFile("[Pinner] 未找到匹配窗口")
                    completion(false)
                    return
                }

                // 记录 SCWindow 包含阴影的 frame 与实际窗口 frame 的差异
                self.scFrameOffset = CGRect(
                    x: scWindow.frame.origin.x - origFrame.origin.x,
                    y: scWindow.frame.origin.y - origFrame.origin.y,
                    width: scWindow.frame.width - origFrame.width,
                    height: scWindow.frame.height - origFrame.height
                )

                logToFile("[Pinner] 匹配窗口: \(scWindow.title ?? "?") axFrame=\(origFrame) scFrame=\(scWindow.frame)")

                self.currentSCWindowID = scWindow.windowID

                // 创建覆盖层（使用包含阴影的 scWindow.frame） + 启动捕获
                self.createOverlay(frame: scWindow.frame)
                self.setupCapture(scWindow: scWindow)
                self.setupAXObserver(pid: self.targetPID, axWindow: axWindow)
                self.startStreamUpdateTimer()
                completion(true)
            }
        }
    }

    /// 取消置顶
    func unpin() {
        syncTimer?.invalidate()
        syncTimer = nil
        streamUpdateTimer?.invalidate()
        streamUpdateTimer = nil
        
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            axObserver = nil
        }

        if let stream = stream {
            stream.stopCapture { _ in
                logToFile("[Pinner] 捕获已停止")
            }
            self.stream = nil
        }

        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        displayLayer = nil

        targetAXWindow = nil
        targetPID = 0
        targetTitle = ""
        isPinned = false

        logToFile("[Pinner] 已取消置顶")
    }

    // MARK: - 创建覆盖层

    private func createOverlay(frame: CGRect) {
        let bottomLeftFrame = convertToBottomLeft(frame: frame)
        let overlay = PinnableWindow(
            contentRect: bottomLeftFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        overlay.level = .floating
        overlay.isOpaque = false
        overlay.backgroundColor = NSColor.clear
        // 关闭浮窗自身的阴影，因为 SCWindow 的画面已经自带了原窗口的阴影
        overlay.hasShadow = false
        // ★ 点击捕获：点击浮窗 → 激活目标应用（对标 Topit）
        // 当目标应用已在前台时，syncState() 会自动切换为鼠标穿透
        overlay.ignoresMouseEvents = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        overlay.isMovableByWindowBackground = false

        // 点击视图：单击激活目标应用
        let view = OverlayClickView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.onActivate = { [weak self] in
            self?.activateTargetApp()
        }

        // 视频显示层
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // 改为 .resize，因为 view 和视频画面大小已经完全匹配（都包含了阴影尺寸）
        layer.videoGravity = .resize
        view.layer?.addSublayer(layer)

        overlay.contentView = view
        self.displayLayer = layer
        self.overlayWindow = overlay
        self.isPinned = true

        overlay.orderFront(nil)

        // 开始位置同步
        startSyncTimer()

        logToFile("[Pinner] 覆盖层已创建 frame=\(frame) ignoresMouseEvents=false (点击激活模式)")
    }

    private func setupAXObserver(pid: pid_t, axWindow: AXUIElement) {
        if axObserver != nil {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver!), .defaultMode)
            axObserver = nil
        }

        let callback: AXObserverCallback = { observer, element, notification, refcon in
            guard let refcon = refcon else { return }
            let pinner = Unmanaged<WindowPinner>.fromOpaque(refcon).takeUnretainedValue()
            // 收到移动/大小改变通知时，立刻同步位置
            DispatchQueue.main.async {
                pinner.syncState()
            }
        }

        var observer: AXObserver?
        let err = AXObserverCreate(pid, callback, &observer)
        if err == .success, let obs = observer {
            self.axObserver = obs
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            
            AXObserverAddNotification(obs, axWindow, kAXMovedNotification as CFString, selfPtr)
            AXObserverAddNotification(obs, axWindow, kAXResizedNotification as CFString, selfPtr)
            
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            logToFile("[Pinner] 实时监听 (AXObserver) 已启动")
        } else {
            logToFile("[Pinner] 实时监听 (AXObserver) 启动失败: \(err.rawValue)")
        }
    }

    // MARK: - ScreenCaptureKit 设置

    private func setupCapture(scWindow: SCWindow) {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = false

        // Retina 分辨率
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)

        do {
            try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            self.stream = scStream
            scStream.startCapture { error in
                if let error = error {
                    logToFile("[Pinner] 启动捕获失败: \(error.localizedDescription)")
                } else {
                    logToFile("[Pinner] 捕获已启动")
                }
            }
        } catch {
            logToFile("[Pinner] 设置捕获输出失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 点击激活目标应用

    /// 点击浮窗时调用：激活目标应用
    private func activateTargetApp() {
        guard targetPID != 0 else { return }
        
        // 1. 强制赋予该窗口键盘焦点 (关键！解决“无法输入”问题)
        if let axWindow = targetAXWindow {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        
        // 2. 激活应用本身
        let app = NSRunningApplication(processIdentifier: targetPID)
        app?.activate(options: .activateIgnoringOtherApps)
        
        // 3. 瞬间穿透
        if let overlay = overlayWindow {
            overlay.ignoresMouseEvents = true
        }
        
        logToFile("[Pinner] 点击激活目标应用 pid=\(targetPID) (已执行 AXRaise 强制焦点 + 瞬间穿透)")
    }

    // MARK: - Tab 切换检测定时器 (解决原生 Tab 切换导致画面冻结)
    private func startStreamUpdateTimer() {
        streamUpdateTimer?.invalidate()
        streamUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkAndUpdateStream()
        }
    }

    private func checkAndUpdateStream() {
        guard let axWindow = targetAXWindow, let origFrame = getAXWindowFrame(axWindow) else { return }
        
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self, let content = content else { return }
            
            let candidates = content.windows.filter { $0.owningApplication?.processID == self.targetPID }
            let scWindow = candidates.first(where: {
                abs($0.frame.origin.x - origFrame.origin.x) < 5 &&
                abs($0.frame.origin.y - origFrame.origin.y) < 5 &&
                abs($0.frame.width - origFrame.width) < 5 &&
                abs($0.frame.height - origFrame.height) < 5
            }) ?? candidates.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            })
            
            if let scWindow = scWindow, scWindow.windowID != self.currentSCWindowID {
                logToFile("[Pinner] 检测到 SCWindow 变化 (原生 Tab 切换): \(self.currentSCWindowID) -> \(scWindow.windowID)")
                self.currentSCWindowID = scWindow.windowID
                
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                if #available(macOS 13.0, *) {
                    do {
                        try self.stream?.updateContentFilter(filter)
                    } catch {
                        logToFile("[Pinner] updateContentFilter 失败: \(error)")
                    }
                } else {
                    self.stream?.stopCapture(completionHandler: nil)
                    self.setupCapture(scWindow: scWindow)
                }
            }
        }
    }

    // MARK: - 位置同步定时器

    private func startSyncTimer() {
        syncTimer?.invalidate()
        // 改为 0.02 秒（50fps），彻底消除拖动窗口时的残影和延迟
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.syncState()
        }
    }

    /// 定期检查原窗口状态 + 同步浮窗位置
    private func syncState() {
        guard let axWindow = targetAXWindow else { return }

        // 检查窗口是否已最小化
        var minRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef)
        if let isMin = minRef as? Bool, isMin {
            logToFile("[Pinner] 原窗口已最小化")
            NotificationCenter.default.post(name: .unpinOverlay, object: nil)
            return
        }

        // 检查窗口是否还存在 + 获取位置
        guard let axFrame = getAXWindowFrame(axWindow) else {
            logToFile("[Pinner] 原窗口已关闭")
            NotificationCenter.default.post(name: .unpinOverlay, object: nil)
            return
        }

        // 同步浮窗位置和大小到原窗口（需要加上 SCWindow 自带的阴影偏移）
        let targetFrameTopLeft = CGRect(
            x: axFrame.origin.x + scFrameOffset.origin.x,
            y: axFrame.origin.y + scFrameOffset.origin.y,
            width: axFrame.width + scFrameOffset.width,
            height: axFrame.height + scFrameOffset.height
        )
        let targetFrameBottomLeft = convertToBottomLeft(frame: targetFrameTopLeft)

        if let overlay = overlayWindow {
            let current = overlay.frame
            if abs(current.origin.x - targetFrameBottomLeft.origin.x) > 1 ||
               abs(current.origin.y - targetFrameBottomLeft.origin.y) > 1 ||
               abs(current.width - targetFrameBottomLeft.width) > 1 ||
               abs(current.height - targetFrameBottomLeft.height) > 1 {
               
                let sizeChanged = abs(current.width - targetFrameBottomLeft.width) > 1 || abs(current.height - targetFrameBottomLeft.height) > 1
                overlay.setFrame(targetFrameBottomLeft, display: false)
                
                // 如果尺寸发生了改变，触发防抖更新录屏分辨率
                if sizeChanged {
                    triggerResizeDebounce(newWidth: targetFrameTopLeft.width, newHeight: targetFrameTopLeft.height)
                }
            }

            // 目标应用在前台时：鼠标穿透，用户可直接操作原窗口
            // 目标应用不在前台时：捕获点击，单击激活目标应用
            let isTargetFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
            if overlay.ignoresMouseEvents != isTargetFrontmost {
                overlay.ignoresMouseEvents = isTargetFrontmost
                logToFile("[Pinner] ignoresMouseEvents → \(isTargetFrontmost) (目标\(isTargetFrontmost ? "在前台" : "不在前台"))")
            }
        }
    }
    
    // MARK: - 录屏配置防抖更新
    private func triggerResizeDebounce(newWidth: CGFloat, newHeight: CGFloat) {
        resizeDebounceWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let stream = self.stream else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            
            let config = SCStreamConfiguration()
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 5
            config.showsCursor = false
            config.width = Int(newWidth * scale)
            config.height = Int(newHeight * scale)
            
            stream.updateConfiguration(config) { error in
                if let err = error {
                    logToFile("[Pinner] 尺寸更新配置失败: \(err.localizedDescription)")
                } else {
                    logToFile("[Pinner] 尺寸热更新成功: \(config.width)x\(config.height)")
                }
            }
        }
        
        resizeDebounceWorkItem = workItem
        // 防抖时间 100 毫秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    // MARK: - 辅助

    /// 将 Top-Left 坐标系（AX/SCWindow）的 CGRect 转换为 Bottom-Left 坐标系（NSWindow）的 NSRect
    private func convertToBottomLeft(frame: CGRect) -> NSRect {
        // macOS 全局坐标系：Top-Left 以主屏幕左上角为(0,0)，Bottom-Left 以主屏幕左下角为(0,0)
        // 转换公式：bottomY = 主屏幕高度 - topY - 窗口高度
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let flippedY = primaryScreenHeight - frame.origin.y - frame.height
        return NSRect(x: frame.origin.x, y: flippedY, width: frame.width, height: frame.height)
    }

    /// 从 AXUIElement 获取窗口 frame (返回 Top-Left 坐标)
    private func getAXWindowFrame(_ axWindow: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)

        guard let posRef = posRef, let sizeRef = sizeRef else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        return CGRect(origin: point, size: size)
    }
}

extension Notification.Name {
    static let unpinOverlay = Notification.Name("unpinOverlay")
}

// MARK: - SCStreamDelegate
@available(macOS 12.3, *)
extension WindowPinner: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logToFile("[Pinner] 流停止错误: \(error.localizedDescription)")
        DispatchQueue.main.async { self.unpin() }
    }
}

// MARK: - SCStreamOutput
@available(macOS 12.3, *)
extension WindowPinner: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let layer = displayLayer else { return }

        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: 属性
    private var statusItem: NSStatusItem!
    private var autoStartMenuItem: NSMenuItem!
    private var pinMenuItem: NSMenuItem!
    private var unpinMenuItem: NSMenuItem!

    // 窗口置顶管理（ScreenCaptureKit + 点击激活方案）
    private var windowPinner = WindowPinner()
    // 最小化排除用：记录置顶窗口的 PID 和标题
    private var pinnedAppPID: pid_t? { windowPinner.targetPID != 0 ? windowPinner.targetPID : nil }
    private var pinnedWindowTitle: String? { windowPinner.isPinned ? windowPinner.targetTitle : nil }
    // 菜单打开时缓存的前台 app
    private var cachedFrontApp: NSRunningApplication?
    // 持续追踪上一个非 FaradayCage 的前台 app
    private var lastRealFrontApp: NSRunningApplication?

    var isPinned: Bool { windowPinner.isPinned }

    // MARK: - 应用生命周期
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        registerGlobalHotkey()
        // 监听前台应用变化
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // 监听覆盖层取消置顶通知（原窗口关闭/最小化时自动取消）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUnpinFromOverlay),
            name: .unpinOverlay,
            object: nil
        )
    }

    @objc private func handleUnpinFromOverlay() {
        unpinCurrentWindow()
    }

    @objc private func frontAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastRealFrontApp = app
            logToFile("[追踪] frontApp → \(app.localizedName ?? "?") pid=\(app.processIdentifier)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unpinCurrentWindow()
    }

    /// 检查当前进程是否已获得辅助功能权限
    private func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// 检查当前进程是否已获得屏幕录制权限
    private func checkScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    // MARK: - 菜单栏设置
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // 设置状态栏按钮图标
        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(
                    systemSymbolName: "minus.circle",
                    accessibilityDescription: "最小化所有窗口"
                )
            }
            // 如果 SF Symbol 不可用，使用程序绘制图标
            if button.image == nil {
                button.image = createMenuBarIcon()
            }
        }

        // 构建菜单
        let menu = NSMenu()
        menu.delegate = self

        // ── 最小化所有窗口 ──
        let minimizeItem = NSMenuItem(
            title: "最小化所有窗口    ⌘⇧M",
            action: #selector(minimizeAllWindows),
            keyEquivalent: ""
        )
        menu.addItem(minimizeItem)

        // ── 最小化其他窗口 ──
        let minimizeOtherItem = NSMenuItem(
            title: "最小化其他窗口    ⌘⌥M",
            action: #selector(minimizeOtherWindows),
            keyEquivalent: ""
        )
        menu.addItem(minimizeOtherItem)

        menu.addItem(NSMenuItem.separator())

        // ── 窗口置顶 ──
        pinMenuItem = NSMenuItem(
            title: "📌 置顶当前窗口",
            action: #selector(pinFrontWindow),
            keyEquivalent: ""
        )
        menu.addItem(pinMenuItem)

        unpinMenuItem = NSMenuItem(
            title: "📌 取消置顶",
            action: #selector(unpinAndRestoreAction),
            keyEquivalent: ""
        )
        menu.addItem(unpinMenuItem)
        updatePinMenuState()

        menu.addItem(NSMenuItem.separator())

        // ── 开机自启动 ──
        autoStartMenuItem = NSMenuItem(
            title: "开机自启动",
            action: #selector(toggleAutoStart),
            keyEquivalent: ""
        )
        updateAutoStartState()
        menu.addItem(autoStartMenuItem)

        menu.addItem(NSMenuItem.separator())

        // ── 权限状态 ──
        let axPermStatusItem = NSMenuItem(
            title: "辅助功能权限: 检查中...",
            action: #selector(requestAXPermission),
            keyEquivalent: ""
        )
        axPermStatusItem.tag = 101 // Tag 用于后续查找更新
        menu.addItem(axPermStatusItem)

        let scPermStatusItem = NSMenuItem(
            title: "屏幕录制权限: 检查中...",
            action: #selector(requestSCPermission),
            keyEquivalent: ""
        )
        scPermStatusItem.tag = 102
        menu.addItem(scPermStatusItem)

        // 初始刷新权限状态显示
        refreshAllPermissionStatus()

        menu.addItem(NSMenuItem.separator())

        // ── 关于 / 退出 ──
        menu.addItem(NSMenuItem(
            title: "关于 法拉第笼 (FaradayCage)",
            action: #selector(showAbout),
            keyEquivalent: ""
        ))

        menu.addItem(NSMenuItem(
            title: "退出",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    // MARK: - 菜单栏图标
    /// 程序绘制图标（SF Symbol 不可用时的备选方案）
    private func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()

        // 绘制圆角矩形窗口
        let rect = NSRect(x: 2, y: 4, width: 14, height: 10)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.lineWidth = 1.5
        path.stroke()

        // 绘制减号（最小化标志）
        let minus = NSBezierPath()
        minus.move(to: NSPoint(x: 5, y: 9))
        minus.line(to: NSPoint(x: 13, y: 9))
        minus.lineWidth = 2
        minus.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - 核心操作：最小化所有窗口
    @objc func minimizeAllWindows() {
        // 检查 AX 权限
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
        logToFile("[最小化] AXIsProcessTrusted=\(trusted) pid=\(ProcessInfo.processInfo.processIdentifier)")

        // 有置顶窗口：精确跳过
        if isPinned {
            let n = minimizeAllExceptPinned()
            logToFile("[最小化] 跳过置顶模式, 最小化 \(n) 个")
            return
        }

        // 常规：AX API 最小化每个应用的所有窗口
        let count = minimizeAllWindowsAX()
        logToFile("[最小化] AX 返回 \(count)")
        if count == -1 {
            showPermissionAlert()
        }
    }

    // MARK: - 核心操作：最小化其他窗口
    @objc func minimizeOtherWindows() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
        logToFile("[最小化其他] AXIsProcessTrusted=\(trusted)")
        if !trusted {
            showPermissionAlert()
            return
        }

        var count = 0
        
        // 1. 获取当前正在交互的窗口 (Frontmost App 的 Focused Window)
        var activeAXWindow: AXUIElement? = nil
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
            var focusedWinRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWinRef) == .success {
                activeAXWindow = (focusedWinRef as! AXUIElement)
            }
        }

        // 2. 遍历所有应用
        let pinnedPID = pinnedAppPID
        let pinnedTitle = pinnedWindowTitle
        
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular &&
                      $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                  let wins = winsRef as? [AXUIElement] else { continue }

            for win in wins {
                // 判断 A: 是否是当前正在操作的活跃窗口？
                if let activeWin = activeAXWindow, CFEqual(win, activeWin) {
                    continue // 跳过保留它
                }

                // 判断 B: 是否是已被置顶的窗口？
                if app.processIdentifier == pinnedPID {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                    if (titleRef as? String) == pinnedTitle {
                        continue // 跳过保留置顶窗口
                    }
                }

                // 最小化其他所有窗口
                var isMin: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &isMin)
                if let m = isMin as? Bool, !m {
                    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    count += 1
                }
            }
        }
        
        logToFile("[最小化其他] 完成，共最小化 \(count) 个窗口")
    }

    /// AX API 最小化所有窗口（每个应用的全部窗口）
    private func minimizeAllWindowsAX() -> Int {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular &&
                      $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        var total = 0
        var permissionError = false
        var firstErr: String = ""

        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var winsRef: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)

            if r != .success {
                if r == .apiDisabled { permissionError = true }
                if firstErr.isEmpty {
                    firstErr = "\(app.localizedName ?? "?"): \(r.rawValue)"
                }
                continue
            }

            guard let wins = winsRef as? [AXUIElement] else { continue }

            for win in wins {
                var isMin: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &isMin)
                if let m = isMin as? Bool, !m {
                    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    total += 1
                }
            }
        }

        if permissionError { logToFile("[AX] 第一个错误: \(firstErr)") }
        return permissionError ? -1 : total
    }

    /// 最小化所有窗口，但跳过置顶窗口
    private func minimizeAllExceptPinned() -> Int {
        guard let pinnedPID = pinnedAppPID, let pinnedTitle = pinnedWindowTitle else { return 0 }

        var count = 0
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular &&
                      $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var winsRef: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)
            guard r == .success, let wins = winsRef as? [AXUIElement] else { continue }

            for win in wins {
                // 检查是否为置顶窗口
                if app.processIdentifier == pinnedPID {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                    if (titleRef as? String) == pinnedTitle {
                        continue  // 跳过置顶窗口
                    }
                }

                var isMin: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &isMin)
                if let m = isMin as? Bool, !m {
                    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                    count += 1
                }
            }
        }
        return count
    }

    /// 菜单栏图标短暂显示文字
    private func flashStatusIcon(text: String) {
        guard let button = statusItem?.button else { return }
        let savedImage = button.image
        button.image = nil
        button.title = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            button.title = ""
            button.image = savedImage
        }
    }

    /// 权限提示对话框
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        法拉第笼 需要「辅助功能」权限才能控制窗口。

        ⚠️ 授权后必须退出应用重新打开！

        ── 操作步骤 ──
        ① 点击「打开系统设置」
        ② 隐私与安全性 → 辅助功能（往下滚）
        ③ 勾选 FaradayCage ✓
        ④ 退出应用（菜单选「退出」）
        ⑤ 重新启动 FaradayCage

        重启后即可使用。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn { openPrivacyAccessibility() }
    }

    private func openPrivacyAccessibility() {
        let urlString: String
        if #available(macOS 13.0, *) {
            // macOS 13 (Ventura) 及以上，使用新的 Settings URL
            urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        } else {
            // macOS 12 及以下，使用旧的 Preferences URL
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 窗口置顶（CGS 私有 API 方案）
    private func showFeedback(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    @objc private func pinFrontWindow() {
        logToFile("[置顶] 开始...")

        // 检查屏幕录制权限
        if !checkScreenRecordingPermission() {
            logToFile("[置顶] 缺少屏幕录制权限，尝试请求")
            CGRequestScreenCaptureAccess()
            
            // 兜底跳转录屏设置
            let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        unpinCurrentWindow()

        var frontApp = cachedFrontApp
        logToFile("[置顶] cachedFrontApp=\(cachedFrontApp?.localizedName ?? "nil") lastRealFrontApp=\(lastRealFrontApp?.localizedName ?? "nil")")
        if frontApp == nil || frontApp!.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            frontApp = lastRealFrontApp
        }

        guard let frontApp = frontApp else {
            logToFile("[置顶] 失败: frontApp 为 nil")
            showFeedback(title: "无法置顶", text: "找不到前台应用。请先点击目标窗口后重试。")
            return
        }
        guard frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            logToFile("[置顶] 失败: frontApp 是自身")
            showFeedback(title: "无法置顶", text: "不能置顶 法拉第笼 自身的窗口。")
            return
        }
        logToFile("[置顶] 目标: \(frontApp.localizedName ?? "?") pid=\(frontApp.processIdentifier)")

        // 获取 AX 窗口
        guard let targetWindow = getTargetWindow(for: frontApp) else {
            showFeedback(title: "无法置顶", text: "无法获取窗口信息。该应用可能不支持辅助功能 API。")
            return
        }

        // 启动 ScreenCaptureKit 覆盖层
        windowPinner.pin(axWindow: targetWindow, app: frontApp) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.updatePinMenuState()
                logToFile("[置顶] 成功")
            } else {
                self.showFeedback(
                    title: "置顶失败",
                    text: "可能原因：\n1. 未授予屏幕录制权限（系统设置 → 隐私与安全 → 屏幕录制）\n2. 找不到目标窗口\n\n请检查权限后重试。"
                )
                logToFile("[置顶] 失败")
            }
        }
    }

    /// 多级回退获取目标窗口
    private func getTargetWindow(for app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // 1. 试 kAXFocusedWindowAttribute
        var ref: CFTypeRef?
        var r = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref)
        if r == .success, let win = ref as! AXUIElement? { return win }

        // 2. 试 kAXMainWindowAttribute
        r = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref)
        if r == .success, let win = ref as! AXUIElement? { return win }

        // 3. 试第一个 AXWindow
        r = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref)
        if r == .success, let wins = ref as? [AXUIElement], let win = wins.first { return win }

        return nil
    }

    /// 取消置顶
    @objc private func unpinAndRestoreAction() { unpinCurrentWindow() }

    private func unpinCurrentWindow() {
        windowPinner.unpin()
        updatePinMenuState()
        logToFile("[置顶] 已取消")
    }

    /// 更新菜单置顶状态
    private func updatePinMenuState() {
        let hasPinned = isPinned
        pinMenuItem?.isHidden = hasPinned
        unpinMenuItem?.isHidden = !hasPinned
        if hasPinned, let t = pinnedWindowTitle, !t.isEmpty {
            unpinMenuItem?.title = "📌 取消置顶「\(String(t.prefix(30)))」"
        } else {
            unpinMenuItem?.title = "📌 取消置顶"
        }
    }
    @objc private func toggleAutoStart() {
        if isAutoStartEnabled() {
            disableAutoStart()
        } else {
            enableAutoStart()
        }
        updateAutoStartState()
    }

    private func isAutoStartEnabled() -> Bool {
        let path = autoStartPlistPath()
        return FileManager.default.fileExists(atPath: path.path)
    }

    private func autoStartPlistPath() -> URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(kBundleID).plist")
    }

    private func enableAutoStart() {
        guard let execPath = Bundle.main.executablePath else { return }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(kBundleID)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(execPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """

        let path = autoStartPlistPath()
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plistContent.write(to: path, atomically: true, encoding: .utf8)

            // 加载 LaunchAgent
            let task = Process()
            task.launchPath = "/bin/launchctl"
            task.arguments = ["load", path.path]
            try task.run()
            task.waitUntilExit()
        } catch {
            print("启用开机自启动失败: \(error)")
        }
    }

    private func disableAutoStart() {
        let path = autoStartPlistPath()
        guard FileManager.default.fileExists(atPath: path.path) else { return }

        do {
            // 卸载 LaunchAgent
            let task = Process()
            task.launchPath = "/bin/launchctl"
            task.arguments = ["unload", path.path]
            try task.run()
            task.waitUntilExit()

            try FileManager.default.removeItem(at: path)
        } catch {
            print("禁用开机自启动失败: \(error)")
        }
    }

    private func updateAutoStartState() {
        autoStartMenuItem?.state = isAutoStartEnabled() ? .on : .off
    }

    /// 更新菜单中权限状态的显示
    private func updatePermissionStatus(menuItem: NSMenuItem) {
        DispatchQueue.main.async {
            if menuItem.tag == 101 {
                menuItem.title = self.checkAccessibilityPermission()
                    ? "✅ 辅助功能权限: 已授权"
                    : "❌ 辅助功能权限: 未授权 — 点击授权"
            } else if menuItem.tag == 102 {
                menuItem.title = self.checkScreenRecordingPermission()
                    ? "✅ 屏幕录制权限: 已授权"
                    : "❌ 屏幕录制权限: 未授权 — 点击授权"
            }
        }
    }

    /// 在所有菜单中同步权限状态
    private func refreshAllPermissionStatus() {
        if let menu = statusItem?.menu {
            for item in menu.items {
                if item.tag == 101 || item.tag == 102 {
                    updatePermissionStatus(menuItem: item)
                }
            }
        }
    }

    // MARK: - 权限请求
    
    @objc private func requestAXPermission() {
        if checkAccessibilityPermission() {
            showFeedback(title: "权限已就绪", text: "法拉第笼 (FaradayCage) 已获得辅助功能权限，最小化功能可正常使用。")
            return
        }
        showPermissionAlert()
    }
    
    @objc private func requestSCPermission() {
        if checkScreenRecordingPermission() {
            showFeedback(title: "权限已就绪", text: "法拉第笼 (FaradayCage) 已获得屏幕录制权限，窗口置顶功能可正常使用。")
            return
        }
        // 确保应用出现在录屏列表中
        CGRequestScreenCaptureAccess()
        
        // 兜底跳转：无论系统是否弹窗，直接打开录屏设置页
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 关于
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "法拉第笼 (FaradayCage)"
        alert.informativeText = """
        一键屏蔽外界干扰，专注当前任务。

        全局快捷键: 
        ⌘⇧M - 最小化所有窗口
        ⌘⌥M - 最小化其他窗口（保留当前）
        
        开源主页: https://github.com/offcv/FaradayCage
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "访问 GitHub")
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "https://github.com/offcv/FaradayCage") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - 退出
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 全局快捷键
    private func registerGlobalHotkey() {
        let keyCode: UInt32 = 46   // kVK_ANSI_M
        
        // 1. 注册 ⌘⇧M (最小化所有)
        let modifiersAll: UInt32 = UInt32(cmdKey) | UInt32(shiftKey)
        let idAll = EventHotKeyID(signature: kHotKeySignature, id: 1)
        var refAll: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiersAll, idAll, GetEventDispatcherTarget(), 0, &refAll)

        // 2. 注册 ⌘⌥M (最小化其他)
        let modifiersOther: UInt32 = UInt32(cmdKey) | UInt32(optionKey)
        let idOther = EventHotKeyID(signature: kHotKeySignatureOther, id: 2)
        var refOther: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiersOther, idOther, GetEventDispatcherTarget(), 0, &refOther)

        // 注册事件处理器
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        typealias EventHandlerProc = @convention(c) (
            EventHandlerCallRef?,
            EventRef?,
            UnsafeMutableRawPointer?
        ) -> OSStatus

        let callback: EventHandlerProc = { _, eventRef, userData in
            guard let event = eventRef, let userData = userData else { return noErr }
            
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )
            
            if status == noErr {
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                if hotkeyID.signature == kHotKeySignature {
                    delegate.minimizeAllWindows()
                } else if hotkeyID.signature == kHotKeySignatureOther {
                    delegate.minimizeOtherWindows()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }
}

// MARK: - NSMenuDelegate
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // 菜单打开时捕捉当前前台应用（此时 FaradayCage 还没变成前台）
        cachedFrontApp = NSWorkspace.shared.frontmostApplication
        updateAutoStartState()
        refreshAllPermissionStatus()
        updatePinMenuState()
    }
}

// MARK: - 入口

// 防止多开 (单例检测)
let runningApps = NSWorkspace.shared.runningApplications
let isAlreadyRunning = runningApps.contains { app in
    app.bundleIdentifier == kBundleID && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
}

if isAlreadyRunning {
    logToFile("检测到已有实例在运行，当前实例退出。")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 隐藏 Dock 图标，作为纯菜单栏应用运行
app.run()
