// BLEBridge: CoreBluetooth connection to Xiaomi Mi Bluetooth Remote 2 Pro,
// runs the ATVV voice-stream handshake, and pumps decoded mono Int16 PCM
// into the AudioPipe.
//
// State machine (matches mi-ao's ATVV flow, simplified):
//   disconnected → connect → discoverServices → discoverChars
//   → send getCapabilities → wait for capabilities
//   → on .startSearch (voice-key press from remote): send micOpen
//   → audio frames flow on TX char → ADPCM decode → AudioPipe.feed

import CoreBluetooth
import Foundation

final class BLEBridge: NSObject {
    // ATVV service / characteristic UUIDs (Google Android TV Remote protocol).
    static let serviceUUID  = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    static let commandUUID  = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")  // host writes commands to remote
    static let audioUUID    = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")  // remote sends voice data to host (notify)
    static let controlUUID  = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")  // control events from remote

    // Optional: filter by peripheral name in addition to UUID.
    let nameHint: String? = "小米"

    /// Where we persist a previously-discovered peripheral UUID so the next
    /// launch can attempt `retrievePeripherals` directly without scanning.
    private static let savedUUIDPath: String = {
        let env = ProcessInfo.processInfo.environment["MIA_UUID_FILE"]
        return env ?? NSString(string: "~/Library/Application Support/mi-remote-bridge/uuid.txt").expandingTildeInPath
    }()

    /// Called whenever the bridge produces or stops producing audio (true = streaming).
    var onStreamingChanged: ((Bool, Int /* sampleRate */) -> Void)?
    /// Called when the device connection state changes.
    var onConnectionChanged: ((Bool) -> Void)?
    /// Audio level meter update; arg is dBFS in [-60, 0].
    var onLevel: ((Double, Int /* peak */) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var audioChar: CBCharacteristic?
    private var commandChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?
    private var atvvCharsComplete = false

    private let protocolHandler = ATVVProtocol()
    private var streamID: UInt8 = 0
    private var isStreaming = false
    private var levelSumSq: Int64 = 0
    private var levelCount: Int = 0
    private var levelPeak: Int = 0
    private var levelLogAt = Date.distantPast
    private var diagFrameCount = 0
    private var streamFrameCount = 0
    private var streamSampleCount = 0
    private var streamPeak = 0
    private var streamSumSquares: Int64 = 0
    private var streamClippedSampleCount = 0
    private var pendingAudioSyncCount = 0
    private var streamAudioSyncCount = 0
    private var wavRecorder: WavRecorder?
    // Verbose PCM diagnostics are off unless explicitly requested.
    private static let diagnosticsEnabled =
        ProcessInfo.processInfo.environment["MIA_DIAGNOSTICS"] == "1"
    private var lastStartSearchAt = Date.distantPast

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        if central.state == .poweredOn {
            tryDirectConnect()
        } else {
            print("[BLE] 等待蓝牙就绪…")
        }
    }

    func setRecordingEnabled(_ enabled: Bool) {
        AppStorage.recordingEnabled = enabled
        if enabled, isStreaming, wavRecorder == nil {
            wavRecorder = WavRecorder.createNext(prefix: "mi-voice")
        } else if !enabled, let recorder = wavRecorder {
            recorder.close()
            wavRecorder = nil
        }
    }

    func clearRecordings() {
        if let recorder = wavRecorder {
            recorder.close()
            wavRecorder = nil
        }
        AppStorage.clearFiles(in: AppStorage.recordingsDirectory)
    }

    /// If we have a saved UUID from a previous scan, ask CoreBluetooth for
    /// the peripheral directly. This works even when the device is HID-paired
    /// (advertisement scan returns nothing in that case).
    private func tryDirectConnect() {
        guard let uuidString = try? String(contentsOfFile: Self.savedUUIDPath, encoding: .utf8),
              let uuid = UUID(uuidString: uuidString.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            print("[BLE] 无已存 UUID，转扫描")
            return beginScan()
        }
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            print("[BLE] 已存 UUID 直接 connect: \(p.identifier)")
            connect(to: p)
        } else {
            print("[BLE] CB 未保留该 UUID，转扫描")
            beginScan()
        }
    }

    private func beginScan() {
        print("[BLE] 扫描中（按名字 \(nameHint ?? "?") + ATVV service 过滤）")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    fileprivate func saveUUID(_ id: UUID) {
        let path = Self.savedUUIDPath
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? id.uuidString.write(to: url, atomically: true, encoding: .utf8)
        print("[BLE] 已保存 UUID: \(id.uuidString)")
    }

    fileprivate func connect(to p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.stopScan()
        central.connect(p, options: nil)
        saveUUID(p.identifier)
        print("[BLE] 连接 \(p.name ?? "(no name)") (\(p.identifier))…")
    }

    private func writeCommand(_ data: Data) {
        guard let p = peripheral, let c = commandChar else { return }
        p.writeValue(data, for: c, type: .withResponse)
    }

    /// Send an ATVV keep-alive. Should be called every ~4 seconds while
    /// streaming to keep the device's audio stream open during long
    /// voice-key holds.
    private func sendKeepAlive() {
        guard isStreaming, let s = protocolHandler.codec else { return }
        do {
            let cmd = try protocolHandler.keepAliveCommand(streamID: streamID)
            writeCommand(cmd)
            // Quiet log; user only needs levels to debug.
        } catch {
            print("[BLE] keep-alive error: \(error.localizedDescription)")
        }
        _ = s
    }

    /// Start a periodic timer that keeps the ATVV voice stream alive while
    /// the remote thinks the user is holding the voice button.
    private var keepAliveTimer: Timer?
    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        keepAliveTimer = Timer.scheduledTimer(
            withTimeInterval: 4.0,
            repeats: true
        ) { [weak self] _ in
            self?.sendKeepAlive()
        }
    }
    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func notifyStreaming(_ on: Bool) {
        let sr = (protocolHandler.codec == .adpcm16k) ? 16_000 : 8_000
        onStreamingChanged?(on, sr)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[BLE] 蓝牙已就绪")
            tryDirectConnect()
        case .poweredOff:
            print("[BLE] 蓝牙未开启")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let n = peripheral.name ?? "(no name)"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
        let hasATVV = services.contains(Self.serviceUUID)
        let short = services.map { String($0.uuidString.prefix(8)) }
        // Don't log every device — just ones that match by name OR advertise ATVV.
        if (nameHint.map { n.contains($0) } ?? false) || hasATVV {
            print("[BLE] 候选: \(n) (\(peripheral.identifier)), services=\(short), rssi=\(RSSI)")
            connect(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLE] 已连接")
        onConnectionChanged?(true)
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        print("[BLE] 连接失败: \(error?.localizedDescription ?? "unknown")")
        onConnectionChanged?(false)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        print("[BLE] 断开: \(error?.localizedDescription ?? "ok")")
        onConnectionChanged?(false)
        notifyStreaming(false)
        isStreaming = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.beginScan()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            print("[BLE] 服务发现失败: \(error?.localizedDescription ?? "?")")
            return
        }
        print("[BLE] 发现 \(services.count) 个 service")
        for s in services {
            let tag = s.uuid == Self.serviceUUID ? " ←ATVV" : ""
            print("[BLE]   svc \(s.uuid.uuidString.prefix(8))…\(tag)")
            // Discover ALL characteristics on every service so we can also
            // see HOGP (HID-over-GATT) button channels if they exist.
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        for c in chars {
            let props = describeProperties(c.properties)
            let isATVV = service.uuid == Self.serviceUUID
            print("[BLE]   char \(c.uuid.uuidString.prefix(8)) [\(props)]")
            switch c.uuid {
            case Self.audioUUID:
                audioChar = c
                peripheral.setNotifyValue(true, for: c)
                print("[BLE]   → audio subscribed; isNotifying=\(c.isNotifying)")
                if isATVV { atvvCharsComplete = true }
            case Self.commandUUID:
                commandChar = c
                print("[BLE]   → command stored")
            case Self.controlUUID:
                controlChar = c
                peripheral.setNotifyValue(true, for: c)
                print("[BLE]   → control subscribed; isNotifying=\(c.isNotifying)")
                if isATVV { atvvCharsComplete = true }
            default:
                // Auto-subscribe to any notify-capable characteristic on this
                // service — we may find button events on HOGP here.
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                    print("[BLE]   → auto-subscribed (notify); isNotifying=\(c.isNotifying)")
                }
            }
        }
        if atvvCharsComplete {
            // All three ATVV chars found: kick off capabilities handshake.
            writeCommand(protocolHandler.getCapabilitiesCommand)
            print("[BLE] TX getCapabilities")
            atvvCharsComplete = false
        }
    }

    private func describeProperties(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            print("[BLE] char update error: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let len = data.count
        switch characteristic.uuid {
        case Self.controlUUID:
            handleControl(data)
        case Self.audioUUID:
            handleAudio(data)
        default:
            print("[BLE] unexpected char update \(characteristic.uuid.uuidString.prefix(8)), \(len)B")
        }
    }

    private func handleControl(_ data: Data) {
        let ev = protocolHandler.parseControl(data)
        switch ev {
        case .startSearch:
            // Debounce: the 2 Pro re-sends START_SEARCH during long holds.
            // If we're already streaming OR we just opened within the last
            // 500ms, ignore the duplicate.
            let now = Date()
            if isStreaming { return }
            if now.timeIntervalSince(lastStartSearchAt) < 0.5 { return }
            lastStartSearchAt = now
            do {
                // Reset before MIC_OPEN so a subsequent AUDIO_SYNC remains
                // authoritative even when it arrives before AUDIO_START.
                protocolHandler.prepareForAudioStream()
                pendingAudioSyncCount = 0
                writeCommand(try protocolHandler.micOpenCommand())
                print("[BLE] TX micOpen (debounced)")
            } catch {
                print("[BLE] micOpen error: \(error.localizedDescription)")
            }
        case .capabilities(let caps):
            do {
                try protocolHandler.acceptCapabilities(caps)
                print("[BLE] caps ok v\(caps.version) codec=\(protocolHandler.codec!)")
            } catch {
                print("[BLE] caps error: \(error.localizedDescription)")
            }
        case .audioStart(_, let codec, let sid):
            protocolHandler.beginAudioStream(codec: codec)
            streamID = sid
            isStreaming = true
            notifyStreaming(true)
            diagFrameCount = 0
            streamFrameCount = 0
            streamSampleCount = 0
            streamPeak = 0
            streamSumSquares = 0
            streamClippedSampleCount = 0
            streamAudioSyncCount = pendingAudioSyncCount
            pendingAudioSyncCount = 0
            wavRecorder = AppStorage.recordingEnabled
                ? WavRecorder.createNext(prefix: "mi-voice")
                : nil
            startKeepAliveTimer()
            print("[BLE] AUDIO_START streamID=\(sid)")
        case .audioStop(let reason):
            isStreaming = false
            protocolHandler.endAudioStream()
            notifyStreaming(false)
            levelSumSq = 0
            levelCount = 0
            levelPeak = 0
            onLevel?(-120, 0)
            diagFrameCount = 0
            stopKeepAliveTimer()
            if let w = wavRecorder {
                w.close()
                print("[WAV] closed \(w.filename)")
                wavRecorder = nil
            }
            let streamRMS = streamSampleCount > 0
                ? sqrt(Double(streamSumSquares) / Double(streamSampleCount))
                : 0
            let streamDB = streamRMS > 0
                ? 20.0 * log10(streamRMS / 32768.0)
                : -120
            print(
                "[BLE] AUDIO_SUMMARY streamID=\(streamID) " +
                "frames=\(streamFrameCount) samples=\(streamSampleCount) " +
                "peak=\(streamPeak) rms=\(Int(streamRMS.rounded())) " +
                "db=\(String(format: "%.1f", streamDB)) " +
                "clipped=\(streamClippedSampleCount) syncs=\(streamAudioSyncCount)"
            )
            print("[BLE] AUDIO_STOP reason=0x\(String(format: "%02x", reason))")
        case .audioSync(let codec, let sequence, let pred, let stepIndex):
            protocolHandler.applyAudioSync(
                codec: codec,
                sequence: sequence,
                predictor: pred,
                stepIndex: stepIndex
            )
            if isStreaming {
                streamAudioSyncCount += 1
            } else {
                pendingAudioSyncCount += 1
            }
            print(
                "[BLE] AUDIO_SYNC codec=\(codec) sequence=\(sequence) " +
                "predictor=\(pred) step=\(stepIndex) " +
                "phase=\(isStreaming ? "streaming" : "opening")"
            )
        case .micOpenError(let code):
            print("[BLE] MIC_OPEN 错误: 0x\(String(format: "%04x", code))")
        case .unknown(let d):
            // Capabilities-handshake uses 0x0B on the control char sometimes;
            // absorb instead of failing noisily.
            if data.first == 0x0B {
                if let caps = ATVVProtocol.parseCapabilities(data) {
                    do {
                        try protocolHandler.acceptCapabilities(caps)
                        print("[BLE] caps (fallback) v\(caps.version) codec=\(protocolHandler.codec!)")
                    } catch {
                        print("[BLE] caps fallback error: \(error.localizedDescription)")
                    }
                }
            }
            // Silently ignore other unknown events.
            _ = d
        }
    }

    private func handleAudio(_ data: Data) {
        guard isStreaming, let frame = protocolHandler.decodeAudio(data) else { return }
        if frame.samples.isEmpty { return }
        streamFrameCount += 1
        streamSampleCount += frame.samples.count
        streamPeak = max(
            streamPeak,
            frame.samples.map { Int(abs(Int($0))) }.max() ?? 0
        )
        streamSumSquares += frame.samples.reduce(into: Int64(0)) {
            $0 += Int64($1) * Int64($1)
        }
        streamClippedSampleCount += frame.samples.reduce(into: 0) {
            if abs(Int($1)) >= 32_760 { $0 += 1 }
        }

        // Diagnostic: dump first few raw bytes & first few decoded samples
        if Self.diagnosticsEnabled, diagFrameCount < 5 {
            let rawHex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            let samHex = frame.samples.prefix(8).map { String($0) }.joined(separator: ",")
            print("[AUDIO-DIAG] frame#\(diagFrameCount) raw[\(rawHex)] decoded[\(samHex)]")
            diagFrameCount += 1
        }

        // Optional developer-only recording. Production builds never create
        // a WAV because `recordingEnabled` is false.
        if let w = wavRecorder {
            w.appendSamples(frame.samples)
            w.appendRawBytes(data)
        }

        AudioPipe.shared.feed(samples: frame.samples)
        let needsLevel = onLevel != nil || Self.diagnosticsEnabled
        if needsLevel {
            levelSumSq += frame.samples.reduce(into: 0) {
                $0 += Int64($1) * Int64($1)
            }
            levelCount += frame.samples.count
            levelPeak = max(
                levelPeak,
                frame.samples.map { Int(abs(Int($0))) }.max() ?? 0
            )
        }
        if needsLevel, Date().timeIntervalSince(levelLogAt) >= 0.5 {
            let rms = levelCount > 0 ? sqrt(Double(levelSumSq) / Double(levelCount)) : 0
            let peak = levelPeak
            let db = rms > 0 ? 20.0 * log10(rms / 32768.0) : -120
            let bar = meterBar(level: db)
            if Self.diagnosticsEnabled {
                print(String(format: "[LVL] %@ ATVV rms=%.0f peak=%d  %.0f dBFS",
                             bar, rms, peak, db))
            }
            onLevel?(db, peak)
            levelSumSq = 0
            levelCount = 0
            levelPeak = 0
            levelLogAt = Date()
        }
    }

    /// Convert dBFS to a tiny ASCII bar for at-a-glance logs.
    private func meterBar(level: Double) -> String {
        let clamped = max(-60, min(0, level))
        let n = (clamped + 60) / 6   // 0..10 segments
        return "[" + String(repeating: "▓", count: Int(n)) +
                     String(repeating: "░", count: 10 - Int(n)) + "]"
    }
}
