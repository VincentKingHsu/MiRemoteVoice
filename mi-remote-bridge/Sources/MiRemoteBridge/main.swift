// mi-remote-bridge: button + voice bridge for Xiaomi Mi Bluetooth Remote 2 Pro.
//
// 1. Voice key (HID F5) → suppressed → matching Option press semantics
// 2. ATVV voice stream over BLE → decoded ADPCM → MiRemoteV 2ch
//    → macOS audio input → Doubao hears the remote's mic
//
// macOS-only. Requires:
//   * 2 Pro paired in System Settings → Bluetooth
//   * Accessibility permission (System Settings → Privacy & Security →
//     Accessibility) for the CGEvent tap that filters F6
//   * MiRemoteVoice.driver installed and visible as MiRemoteV 2ch in
//     System Settings → Sound → Input/Output
//   * Doubao IME configured for Option-as-voice-mode trigger
//
// Run:   swift run
// Quit:  menu bar icon → 退出, or Ctrl+C

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import IOKit.hid
import Foundation

// MARK: - Virtual key codes

enum VK {
    static let option: CGKeyCode = 0x3A
    static let rightOption: CGKeyCode = 0x3D
    /// The 2 Pro reports voice key as USB HID usage 0x3D which macOS maps
    /// to virtual keyCode 0x60 (F5). Despite being labeled "F6" in some
    /// hardware profiles, the actual delivery is F5. Verified empirically.
    static let voiceKey: CGKeyCode = 0x60
}

// MARK: - Key synthesizer

enum Key {
    /// Lets the event tap distinguish Bridge-generated Option events from
    /// physical keyboards, other Bluetooth buttons, and external remappers.
    static let syntheticMarker: Int64 = 0x4D_49_52_42 // "MIRB"

    /// Walkie-talkie style: Option key down only (no matching up). Pair with `optionUp`.
    static func optionDown() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: src, virtualKey: VK.option, keyDown: true) {
            e.setIntegerValueField(
                .eventSourceUserData,
                value: syntheticMarker
            )
            e.post(tap: .cghidEventTap)
        }
    }
    static func optionUp() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: src, virtualKey: VK.option, keyDown: false) {
            e.setIntegerValueField(
                .eventSourceUserData,
                value: syntheticMarker
            )
            e.post(tap: .cghidEventTap)
        }
    }
    /// A deliberate short Option click for Doubao's toggle mode.
    ///
    /// Posting down and up back-to-back is sometimes too fast for an input
    /// method to classify as a real click, so keep the modifier down briefly.
    static func optionTap(completion: (() -> Void)? = nil) {
        optionDown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            optionUp()
            completion?()
        }
    }
}

// MARK: - Voice-button gesture state machine

/// Separates the remote's one physical voice button into two mutually
/// exclusive Doubao gestures:
///
/// * short press: Option tap + MacBook microphone
/// * long press:  Option hold + remote ATVV microphone
///
/// We cannot know which gesture the user intends on the initial key-down, so
/// the event is held for a short classification window. Crucially, BLE
/// AUDIO_START alone never changes the routed microphone.
final class VoicePressCoordinator {
    private enum Mode {
        case idle
        case pending
        case holding
    }

    private let longPressThreshold: TimeInterval = 0.30
    // The remote sends AUDIO_STOP before the HID key-up, so there is no BLE
    // tail left to wait for here. Keeping this delay near zero makes Doubao
    // leave its recording UI as soon as the user releases the button.
    private let tailDrainDelay: TimeInterval = 0.02
    private var mode: Mode = .idle
    private var holdWorkItem: DispatchWorkItem?
    private var tailWorkItem: DispatchWorkItem?
    private var remoteStreaming = false
    private var remoteRouted = false
    private var optionIsHeld = false
    private var suppressNewPressUntil = Date.distantPast

    func keyDown() {
        guard Date() >= suppressNewPressUntil else {
            print("[PRESS] ignored release bounce")
            return
        }
        guard mode == .idle else { return }
        mode = .pending

        let work = DispatchWorkItem { [weak self] in
            self?.promoteToLongPress()
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + longPressThreshold,
            execute: work
        )
        print("[PRESS] pending; waiting 300 ms to classify tap vs hold")
    }

    func keyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil

        switch mode {
        case .idle:
            return
        case .pending:
            mode = .idle
            setRemoteRouted(false)
            print("[PRESS] SHORT → Option tap; source=MacBook")
            Key.optionTap()
        case .holding:
            mode = .idle
            suppressNewPressUntil = Date().addingTimeInterval(
                tailDrainDelay + 0.10
            )
            print("[PRESS] LONG release → finish immediately")
            scheduleLongFinish()
        }
    }

    func setRemoteStreaming(_ streaming: Bool) {
        remoteStreaming = streaming
        // BLE availability is informational only. HID owns gesture lifetime
        // and routing policy; transient ATVV stop/start events must never
        // toggle Doubao or fall back to the MacBook mic during a hold.
        print(
            "[PRESS] ATVV streaming=\(streaming); " +
            "gesture=\(modeName); routed=\(remoteRouted)"
        )
    }

    func stop() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        tailWorkItem?.cancel()
        tailWorkItem = nil
        if optionIsHeld {
            optionIsHeld = false
            Key.optionUp()
        }
        mode = .idle
        setRemoteRouted(false)
    }

    private func promoteToLongPress() {
        guard mode == .pending else { return }
        holdWorkItem = nil
        mode = .holding

        // Route selection follows the physical HID hold, not BLE notifications.
        // If ATVV is late or briefly drops, emit silence rather than leaking
        // the MacBook microphone into a remote-only gesture.
        setRemoteRouted(true)
        print(
            "[PRESS] LONG start → Option DOWN; source=" +
            (remoteStreaming ? "remote ready" : "remote waiting")
        )
        optionIsHeld = true
        Key.optionDown()
    }

    private func scheduleLongFinish() {
        guard optionIsHeld else {
            setRemoteRouted(false)
            return
        }
        tailWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.tailWorkItem = nil
            self?.finishLongToggle()
        }
        tailWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + tailDrainDelay,
            execute: work
        )
    }

    private func finishLongToggle() {
        guard optionIsHeld else { return }
        optionIsHeld = false
        print("[PRESS] LONG end → Option UP + closing tap")
        Key.optionUp()
        // macOS releases the modifier state correctly, but Doubao's input
        // method sometimes keeps its recording UI latched after a synthetic
        // modifier-up. A complete follow-up Option click is the same action
        // the user currently has to perform manually to close that latch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            Key.optionTap {
                self?.setRemoteRouted(false)
            }
        }
    }

    private func setRemoteRouted(_ active: Bool) {
        guard remoteRouted != active else { return }
        remoteRouted = active
        AudioPipe.shared.setRemoteActive(active)
    }

    private var modeName: String {
        switch mode {
        case .idle: return "idle"
        case .pending: return "pending"
        case .holding: return "holding"
        }
    }
}

// MARK: - HID watcher (2 Pro as keyboard, for connection status only)

final class HIDWatcher {
    static let vendorID  = 0x2717
    static let productID = 0x32B8

    var onConnect: ((String) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private var manager: IOHIDManager?

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
        ] as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, HIDWatcher.deviceMatched, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, HIDWatcher.deviceRemoved, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            print("[HID] IOHIDManagerOpen failed: \(r)")
            return
        }
        manager = m
    }

    func stop() {
        if let m = manager {
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    fileprivate func matched(_ device: IOHIDDevice) {
        let n = nameOf(device)
        print("[HID] 已连接: \(n)")
        onConnect?(n)
    }

    fileprivate func removed(_ device: IOHIDDevice) {
        let n = nameOf(device)
        print("[HID] 断开: \(n)")
        onDisconnect?(n)
    }

    private func nameOf(_ device: IOHIDDevice) -> String {
        if let n = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String { return n }
        return "(unknown)"
    }

    private static let deviceMatched: IOHIDDeviceCallback = { ctx, _, _, device in
        guard let ctx else { return }
        let me = Unmanaged<HIDWatcher>.fromOpaque(ctx).takeUnretainedValue()
        DispatchQueue.main.async { me.matched(device) }
    }
    private static let deviceRemoved: IOHIDDeviceCallback = { ctx, _, _, device in
        guard let ctx else { return }
        let me = Unmanaged<HIDWatcher>.fromOpaque(ctx).takeUnretainedValue()
        DispatchQueue.main.async { me.removed(device) }
    }
}

// MARK: - F5 → Option hold filter (CGEvent tap)

final class VoiceKeyFilter {
    enum FilterError: LocalizedError {
        case accessibilityDenied
        case tapCreationFailed
        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "需要辅助功能权限"
            case .tapCreationFailed:
                return "无法创建 CGEvent tap（通常因辅助功能权限未授予）"
            }
        }
    }

    private var tapPort: CFMachPort?
    private var voiceKeyIsDown = false
    var onVoiceKeyDown: (() -> Void)?
    var onVoiceKeyUp: (() -> Void)?

    func start() throws {
        // Don't prompt user each time — check if already trusted.
        let trusted = AXIsProcessTrusted()
        let opts: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as CFString: !trusted
        ] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(opts)
        print("[FILTER] AX trusted=\(granted) (was \(trusted))")
        if !granted {
            // mtime on the binary changes when SwiftPM rebuilds; we exit
            // and the user re-runs after granting once.
            throw FilterError.accessibilityDenied
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let filter = Unmanaged<VoiceKeyFilter>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = filter.tapPort {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    print("[FILTER] event tap was disabled; re-enabled")
                }
                return Unmanaged.passRetained(event)
            }
            let keyCode = CGKeyCode(
                event.getIntegerValueField(.keyboardEventKeycode)
            )

            if keyCode == VK.voiceKey {
                if type == .keyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if filter.voiceKeyIsDown || isRepeat {
                        return nil
                    }
                    filter.voiceKeyIsDown = true
                    print("[KEY] voice-key DOWN → gesture pending")
                    filter.onVoiceKeyDown?()
                    return nil
                } else if type == .keyUp {
                    guard filter.voiceKeyIsDown else { return nil }
                    filter.voiceKeyIsDown = false
                    print("[KEY] voice-key UP   → finish gesture")
                    filter.onVoiceKeyUp?()
                    return nil
                }
            }
            return Unmanaged.passRetained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw FilterError.tapCreationFailed
        }
        tapPort = tap
        guard let src = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw FilterError.tapCreationFailed
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[FILTER] tap enabled; voice key 0x60 (F5) will be mapped to an Option hold")
    }

    func stop() {
        if voiceKeyIsDown {
            voiceKeyIsDown = false
            onVoiceKeyUp?()
        }
        if let t = tapPort { CGEvent.tapEnable(tap: t, enable: false) }
        tapPort = nil
    }
}

// MARK: - Menu bar UI

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var headerLabel: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var loggingToggleItem: NSMenuItem!
    private var logSizeItem: NSMenuItem!
    private var recordingToggleItem: NSMenuItem!
    private var recordingSizeItem: NSMenuItem!

    private var hidConnected = false
    private var bleConnected = false
    private var remoteStreaming = false

    private let watcher = HIDWatcher()
    private let filter = VoiceKeyFilter()
    private let voicePress = VoicePressCoordinator()
    private let ble = BLEBridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppStorage.prepare()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚠️"

        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem(title: "状态 · 启动中", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        headerLabel = header

        let launch = NSMenuItem(
            title: "登录时自动启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        menu.addItem(launch)
        launchAtLoginItem = launch

        menu.addItem(.separator())
        menu.addItem(makeLogMenu())
        menu.addItem(makeRecordingMenu())

        menu.addItem(.separator())
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "未知"
        let versionItem = NSMenuItem(
            title: "版本 · \(version)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        refreshMenuState()

        // HID connection (status icon).
        watcher.onConnect = { [weak self] _ in
            self?.hidConnected = true
            self?.updateStatus()
        }
        watcher.onDisconnect = { [weak self] _ in
            self?.hidConnected = false
            self?.updateStatus()
        }
        watcher.start()

        // ATVV audio connection.
        filter.onVoiceKeyDown = { [weak self] in
            self?.voicePress.keyDown()
        }
        filter.onVoiceKeyUp = { [weak self] in
            self?.voicePress.keyUp()
        }
        ble.onConnectionChanged = { [weak self] connected in
            self?.bleConnected = connected
            if !connected { self?.remoteStreaming = false }
            self?.updateStatus()
        }
        ble.onStreamingChanged = { [weak self] streaming, _ in
            self?.voicePress.setRemoteStreaming(streaming)
            self?.remoteStreaming = streaming
            self?.updateStatus()
        }
        ble.start()

        // Start the loopback engine eagerly so device binding is verified
        // before the first BLE audio packet arrives.
        _ = AudioPipe.shared

        // F6 filter (may prompt for Accessibility).
        do {
            try filter.start()
        } catch {
            let msg = error.localizedDescription
            headerLabel.title = "状态 · \(msg)"
            statusItem.button?.title = "⚠️"
            print("[ERR] filter: \(msg)")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func makeLogMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "日志", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "日志")

        let toggle = NSMenuItem(
            title: "记录日志",
            action: #selector(toggleLogging),
            keyEquivalent: ""
        )
        toggle.target = self
        submenu.addItem(toggle)
        loggingToggleItem = toggle

        let size = NSMenuItem(title: "占用 · 0 字节", action: nil, keyEquivalent: "")
        size.isEnabled = false
        submenu.addItem(size)
        logSizeItem = size

        let refresh = NSMenuItem(
            title: "刷新占用大小",
            action: #selector(refreshStorageSizes),
            keyEquivalent: ""
        )
        refresh.target = self
        submenu.addItem(refresh)

        let open = NSMenuItem(
            title: "打开日志文件夹",
            action: #selector(openLogFolder),
            keyEquivalent: ""
        )
        open.target = self
        submenu.addItem(open)

        let clear = NSMenuItem(
            title: "清空日志",
            action: #selector(clearLog),
            keyEquivalent: ""
        )
        clear.target = self
        submenu.addItem(clear)

        root.submenu = submenu
        return root
    }

    private func makeRecordingMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "调试录音", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "调试录音")

        let toggle = NSMenuItem(
            title: "保存 WAV 与原始数据",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        toggle.target = self
        submenu.addItem(toggle)
        recordingToggleItem = toggle

        let size = NSMenuItem(title: "占用 · 0 字节", action: nil, keyEquivalent: "")
        size.isEnabled = false
        submenu.addItem(size)
        recordingSizeItem = size

        let refresh = NSMenuItem(
            title: "刷新占用大小",
            action: #selector(refreshStorageSizes),
            keyEquivalent: ""
        )
        refresh.target = self
        submenu.addItem(refresh)

        let open = NSMenuItem(
            title: "打开录音文件夹",
            action: #selector(openRecordingFolder),
            keyEquivalent: ""
        )
        open.target = self
        submenu.addItem(open)

        let clear = NSMenuItem(
            title: "清空录音文件",
            action: #selector(clearRecordings),
            keyEquivalent: ""
        )
        clear.target = self
        submenu.addItem(clear)

        root.submenu = submenu
        return root
    }

    private func updateStatus() {
        if remoteStreaming {
            headerLabel.title = "状态 · 遥控器录音中"
            statusItem.button?.title = "🎙️"
        } else if hidConnected && bleConnected {
            headerLabel.title = "状态 · 已就绪"
            statusItem.button?.title = "🎤"
        } else if hidConnected || bleConnected {
            headerLabel.title = "状态 · 正在连接语音服务"
            statusItem.button?.title = "⏳"
        } else {
            headerLabel.title = "状态 · 等待遥控器"
            statusItem.button?.title = "⚠️"
        }
    }

    private func refreshMenuState() {
        launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
        loggingToggleItem?.state = Log.isEnabled ? .on : .off
        recordingToggleItem?.state = AppStorage.recordingEnabled ? .on : .off
        refreshSizeLabels()
    }

    private func refreshSizeLabels() {
        logSizeItem?.title = "占用 · \(AppStorage.formattedSize(Log.byteSize))"
        let recordingBytes = AppStorage.byteSize(
            of: AppStorage.recordingsDirectory
        )
        recordingSizeItem?.title =
            "占用 · \(AppStorage.formattedSize(recordingBytes))"
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
        } catch {
            headerLabel.title = "状态 · 登录启动设置失败"
        }
        refreshMenuState()
    }

    @objc private func toggleLogging() {
        Log.setEnabled(!Log.isEnabled)
        if Log.isEnabled {
            print("[APP] 日志已由用户开启")
        }
        refreshMenuState()
    }

    @objc private func toggleRecording() {
        let enabled = !AppStorage.recordingEnabled
        AppStorage.recordingEnabled = enabled
        ble.setRecordingEnabled(enabled)
        refreshMenuState()
    }

    @objc private func refreshStorageSizes() {
        refreshSizeLabels()
    }

    @objc private func openLogFolder() {
        AppStorage.ensureDirectory(AppStorage.logsDirectory)
        NSWorkspace.shared.open(AppStorage.logsDirectory)
    }

    @objc private func openRecordingFolder() {
        AppStorage.ensureDirectory(AppStorage.recordingsDirectory)
        NSWorkspace.shared.open(AppStorage.recordingsDirectory)
    }

    @objc private func clearLog() {
        Log.clear()
        refreshSizeLabels()
    }

    @objc private func clearRecordings() {
        ble.clearRecordings()
        refreshSizeLabels()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        voicePress.stop()
        filter.stop()
        AudioPipe.shared.stop()
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate

// Convert SIGTERM (including `kill`/`pkill`) into a normal AppKit
// termination so Option and the CoreAudio IOProc are always released.
signal(SIGTERM, SIG_IGN)
let terminationSignal = DispatchSource.makeSignalSource(
    signal: SIGTERM,
    queue: .main
)
terminationSignal.setEventHandler {
    NSApp.terminate(nil)
}
terminationSignal.resume()

app.run()
