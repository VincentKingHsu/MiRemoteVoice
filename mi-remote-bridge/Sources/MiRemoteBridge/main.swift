// mi-remote-bridge: button + voice bridge for Xiaomi Mi Bluetooth Remote 2 Pro.
//
// 1. Voice key (HID F5) → suppressed → matching Option down/up (Doubao push-to-talk)
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

// MARK: - Logger that writes to a file (NSApplication detaches stdout)

enum Log {
    private static let path: String = {
        let env = ProcessInfo.processInfo.environment["MIA_LOG"] ?? "/tmp/mi-bridge.log"
        let url = URL(fileURLWithPath: env)
        // truncate on start
        try? Data().write(to: url)
        return env
    }()
    private static let handle: FileHandle? = {
        FileHandle(forWritingAtPath: path)
    }()

    static func write(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        // also try stdout for any pre-NSApplication prints
        FileHandle.standardOutput.write(Data(line.utf8))
        if let h = handle {
            h.write(Data(line.utf8))
        }
    }
}

func print(_ s: String) {
    Log.write(s)
}

// MARK: - Virtual key codes

enum VK {
    static let option: CGKeyCode = 0x3A
    /// The 2 Pro reports voice key as USB HID usage 0x3D which macOS maps
    /// to virtual keyCode 0x60 (F5). Despite being labeled "F6" in some
    /// hardware profiles, the actual delivery is F5. Verified empirically.
    static let voiceKey: CGKeyCode = 0x60
}

// MARK: - Key synthesizer

enum Key {
    /// Walkie-talkie style: Option key down only (no matching up). Pair with `optionUp`.
    static func optionDown() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: src, virtualKey: VK.option, keyDown: true) {
            e.post(tap: .cghidEventTap)
        }
    }
    static func optionUp() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: src, virtualKey: VK.option, keyDown: false) {
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
    private var mode: Mode = .idle
    private var holdWorkItem: DispatchWorkItem?
    private var remoteStreaming = false
    private var remoteRouted = false
    /// Doubao treats a short Option click as a toggle. Remember only the
    /// toggle state created by this bridge so a later hold can cancel it
    /// before starting push-to-talk.
    private var shortToggleActive = false
    private var longToggleStarted = false
    private var longToggleStartInFlight = false
    private var longReleasePending = false
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
            shortToggleActive.toggle()
            print(
                "[PRESS] SHORT → Option tap; source=MacBook; toggle=" +
                (shortToggleActive ? "on" : "off")
            )
            Key.optionTap()
        case .holding:
            mode = .idle
            suppressNewPressUntil = Date().addingTimeInterval(0.25)
            print("[PRESS] LONG end → Option tap OFF; source=MacBook")
            if longToggleStartInFlight {
                longReleasePending = true
            } else {
                finishLongToggle()
            }
            setRemoteRouted(false)
        }
    }

    func setRemoteStreaming(_ streaming: Bool) {
        remoteStreaming = streaming
        // Short presses may make the remote advertise a very brief ATVV
        // stream. Route it only after the key gesture has become a hold.
        setRemoteRouted(mode == .holding && streaming)
        print(
            "[PRESS] ATVV streaming=\(streaming); " +
            "gesture=\(modeName); routed=\(remoteRouted)"
        )
    }

    func stop() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        if longToggleStarted {
            longToggleStarted = false
            Key.optionTap()
        }
        longReleasePending = false
        mode = .idle
        setRemoteRouted(false)
    }

    private func promoteToLongPress() {
        guard mode == .pending else { return }
        holdWorkItem = nil
        mode = .holding

        // If our previous short press left Doubao's toggle recording on,
        // switch that mode off first. Otherwise a normal Option hold/release
        // returns Doubao to the already-on toggle state and appears "stuck".
        if shortToggleActive {
            shortToggleActive = false
            print("[PRESS] LONG preparing → cancel previous short-toggle")
            Key.optionTap { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    self?.startOptionHold()
                }
            }
            return
        }

        startOptionHold()
    }

    private func startOptionHold() {
        guard mode == .holding,
              !longToggleStarted,
              !longToggleStartInFlight
        else { return }

        // Put the desired source in place before opening Doubao so its first
        // captured frame already comes from the remote when ATVV is ready.
        setRemoteRouted(remoteStreaming)
        print(
            "[PRESS] LONG start → Option tap ON; source=" +
            (remoteRouted ? "remote" : "MacBook fallback")
        )
        longToggleStartInFlight = true
        Key.optionTap { [weak self] in
            guard let self else { return }
            self.longToggleStartInFlight = false
            self.longToggleStarted = true
            if self.longReleasePending {
                // Keep the two complete clicks distinct even if the physical
                // button was released immediately after long-press promotion.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    self.finishLongToggle()
                }
            }
        }
    }

    private func finishLongToggle() {
        guard longToggleStarted else { return }
        longToggleStarted = false
        longReleasePending = false
        Key.optionTap()
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

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { (_, type, event, userInfo) -> Unmanaged<CGEvent>? in
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let filter = Unmanaged<VoiceKeyFilter>.fromOpaque(userInfo).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let descr = type == .keyDown ? "down" : (type == .keyUp ? "up" : "other")
            print("[KEY] \(descr) keyCode=0x\(String(keyCode, radix: 16))")
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

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var headerLabel: NSMenuItem!
    private var audioLabel: NSMenuItem!
    private var levelLabel: NSMenuItem!

    private let watcher = HIDWatcher()
    private let filter = VoiceKeyFilter()
    private let voicePress = VoicePressCoordinator()
    private let ble = BLEBridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚠️"

        let menu = NSMenu()
        let header = NSMenuItem(title: "米遥桥 · 启动中", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        headerLabel = header

        let audio = NSMenuItem(title: "ATVV · 等连接", action: nil, keyEquivalent: "")
        audio.isEnabled = false
        menu.addItem(audio)
        audioLabel = audio

        let level = NSMenuItem(title: "电平: 等待", action: nil, keyEquivalent: "")
        level.isEnabled = false
        menu.addItem(level)
        levelLabel = level

        menu.addItem(.separator())
        let hint = NSMenuItem(title: "语音键 (F5) → Option 长按", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        // HID connection (status icon).
        watcher.onConnect = { [weak self] name in
            self?.headerLabel.title = "HID · 已连接: \(name)"
            self?.statusItem.button?.title = "🎤"
        }
        watcher.onDisconnect = { [weak self] _ in
            self?.headerLabel.title = "HID · 等连接"
            self?.statusItem.button?.title = "⚠️"
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
            self?.audioLabel.title = connected
                ? "ATVV · 已连 (语音流可用)"
                : "ATVV · 等待/重连"
            if !connected { self?.levelLabel.title = "电平: 等待连接" }
        }
        ble.onStreamingChanged = { [weak self] streaming, _ in
            self?.voicePress.setRemoteStreaming(streaming)
            self?.audioLabel.title = streaming
                ? "ATVV · 🎙️ 正在录音"
                : "ATVV · 已连"
        }
        ble.onLevel = { [weak self] db, peak in
            let n = max(0, min(10, Int((db + 60) / 6)))
            let bar = String(repeating: "▓", count: n) + String(repeating: "░", count: 10 - n)
            self?.levelLabel.title = String(format: "电平: [%@] %.0f dB  peak %d",
                                              bar, db, peak)
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
            audioLabel.title = "ERR · \(msg)"
            print("[ERR] filter: \(msg)")
        }
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
