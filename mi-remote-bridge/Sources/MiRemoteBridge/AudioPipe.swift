// AudioPipe: selects the Mac's built-in mic or decoded ATVV PCM and plays
// that source into MiRemoteV 2ch. Doubao sees one stable USB microphone.
//
// Built-in mic → AVCaptureSession ─┐
//                                  ├→ CoreAudio IOProc → MiRemoteV 2ch
// ATVV Int16 PCM ──────────────────┘   (remote wins while key is held)

import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

final class AudioPipe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = AudioPipe()

    private static let targetDeviceName = "MiRemoteV 2ch"
    private static let outputSampleRate: Double = 48_000
    private static let outputChannels: AVAudioChannelCount = 2
    /// The remote's decoded ATVV signal is intentionally very quiet. mi-ao,
    /// the proven reference implementation, applies +20 dB before speech
    /// recognition; use the same gain only for the remote source.
    private static let remoteGain: Float = 10.0

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(
        label: "local.simaqingfeng.MiRemoteBridge.capture",
        qos: .userInteractive
    )

    private let stateLock = NSLock()
    private var remoteActive = false
    private var outputDeviceID: AudioDeviceID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var pendingOutput: [Float] = []
    private var pendingOutputIndex = 0
    private var scheduledMacBuffers = 0
    private var scheduledRemoteBuffers = 0
    private var scheduledPeak: Float = 0
    private var renderCallbackCount = 0
    private var diagnosticsTimer: Timer?

    private override init() {
        super.init()

        if let deviceID = Self.findOutputDevice(named: Self.targetDeviceName) {
            startOutputDevice(deviceID)
        } else {
            print("[AUDIO] ⚠️ 找不到 \(Self.targetDeviceName)，请确认 MiRemoteVoice.driver 已安装")
        }

        if ProcessInfo.processInfo.environment["MIA_DIAGNOSTICS"] == "1" {
            startDiagnosticsTimer()
        }
        requestBuiltInMicAccess()
    }

    // MARK: - public

    func feed(samples: [Int16], inputSampleRate: Double = 16_000) {
        guard !samples.isEmpty, isRemoteActive else { return }
        let floatSamples = samples.map { sample -> Float in
            let amplified = Float(sample) / 32768.0 * Self.remoteGain
            return max(-1.0, min(1.0, amplified))
        }
        schedule(
            monoSamples: floatSamples,
            sampleRate: inputSampleRate,
            expectedRemoteMode: true
        )
    }

    func setRemoteActive(_ active: Bool) {
        stateLock.lock()
        remoteActive = active
        pendingOutput.removeAll(keepingCapacity: true)
        pendingOutputIndex = 0
        stateLock.unlock()
        print(active
            ? "[AUDIO] 输入切换 → 遥控器麦克风"
            : "[AUDIO] 输入切换 → MacBook 麦克风")
    }

    /// Release the HAL callback before the process exits. BlackHole-derived
    /// drivers can leave coreaudiod waiting on a stale client when the process
    /// is killed while an IOProc is still registered.
    func stop() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil

        if let deviceID = outputDeviceID, let ioProcID = outputIOProcID {
            let stopStatus = AudioDeviceStop(deviceID, ioProcID)
            let destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            print(
                "[AUDIO] MiRemote IOProc 已释放: " +
                "stop=\(stopStatus), destroy=\(destroyStatus)"
            )
        }
        outputIOProcID = nil
        outputDeviceID = nil
    }

    // MARK: - built-in microphone capture

    private func requestBuiltInMicAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startBuiltInMicCapture()
        case .notDetermined:
            print("[AUDIO] 请求 MacBook 麦克风权限…")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startBuiltInMicCapture()
                    } else {
                        print("[AUDIO] ⚠️ MacBook 麦克风权限被拒绝")
                    }
                }
            }
        default:
            print("[AUDIO] ⚠️ 没有 MacBook 麦克风权限；遥控器麦克风仍可使用")
        }
    }

    private func startBuiltInMicCapture() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        )
        // On current macOS versions, this discovery type returns every
        // CoreAudio input. Choosing `.first` can therefore pick
        // RØDE Connect, BlackHole, or another virtual input. The built-in mic
        // has the stable CoreAudio/AVFoundation UID below.
        let device = discovery.devices.first {
            $0.uniqueID == "BuiltInMicrophoneDevice"
        } ?? discovery.devices.first {
            $0.localizedName.localizedCaseInsensitiveContains("MacBook")
        }
        guard let device else {
            print("[AUDIO] ⚠️ 找不到内置麦克风")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
            ]
            output.setSampleBufferDelegate(self, queue: captureQueue)

            captureSession.beginConfiguration()
            guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
                captureSession.commitConfiguration()
                print("[AUDIO] ⚠️ 无法建立内置麦克风采集会话")
                return
            }
            captureSession.addInput(input)
            captureSession.addOutput(output)
            captureSession.commitConfiguration()

            captureQueue.async { [weak self] in
                guard let self else { return }
                self.captureSession.startRunning()
                print(
                    "[AUDIO] MacBook 麦克风采集已启动: " +
                    "\(device.localizedName), running=\(self.captureSession.isRunning)"
                )
            }
        } catch {
            print("[AUDIO] ⚠️ MacBook 麦克风采集失败: \(error.localizedDescription)")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isRemoteActive,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              ),
              streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
              streamDescription.pointee.mBitsPerChannel == 32,
              streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount >= MemoryLayout<Float>.size else { return }
        var data = Data(count: byteCount)
        let copyStatus = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: bytes.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        let channels = max(1, Int(streamDescription.pointee.mChannelsPerFrame))
        let floats: [Float] = data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float.self)
            if channels == 1 {
                return Array(values)
            }
            let frameCount = values.count / channels
            return (0..<frameCount).map { frame in
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += values[frame * channels + channel]
                }
                return sum / Float(channels)
            }
        }

        schedule(
            monoSamples: floats,
            sampleRate: streamDescription.pointee.mSampleRate,
            expectedRemoteMode: false
        )
    }

    // MARK: - playback

    private var isRemoteActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return remoteActive
    }

    private func schedule(
        monoSamples: [Float],
        sampleRate: Double,
        expectedRemoteMode: Bool
    ) {
        guard !monoSamples.isEmpty, sampleRate > 0 else { return }
        let resampled = Self.resample(
            monoSamples,
            from: sampleRate,
            to: Self.outputSampleRate
        )
        guard !resampled.isEmpty else { return }

        stateLock.lock()
        guard remoteActive == expectedRemoteMode else {
            stateLock.unlock()
            return
        }
        compactOutputBufferIfNeeded()
        pendingOutput.append(contentsOf: resampled)
        if expectedRemoteMode {
            scheduledRemoteBuffers += 1
        } else {
            scheduledMacBuffers += 1
        }
        scheduledPeak = max(
            scheduledPeak,
            resampled.reduce(0) { max($0, abs($1)) }
        )
        stateLock.unlock()
    }

    private static func resample(
        _ input: [Float],
        from inputRate: Double,
        to outputRate: Double
    ) -> [Float] {
        if abs(inputRate - outputRate) < 1 {
            return input
        }
        let ratio = outputRate / inputRate
        let outputCount = max(1, Int((Double(input.count) * ratio).rounded(.down)))
        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) / ratio
            let lower = min(Int(position), input.count - 1)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = input[lower] + (input[upper] - input[lower]) * fraction
        }
        return output
    }

    // MARK: - CoreAudio direct output

    private func startOutputDevice(_ deviceID: AudioDeviceID) {
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            deviceID,
            nil
        ) { [weak self] _, _, _, outputData, _ in
            self?.render(outputData)
        }
        guard createStatus == noErr, let ioProcID else {
            print("[AUDIO] ⚠️ 创建 MiRemote IOProc 失败: OSStatus=\(createStatus)")
            return
        }

        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            print("[AUDIO] ⚠️ 启动 MiRemote IOProc 失败: OSStatus=\(startStatus)")
            return
        }

        outputDeviceID = deviceID
        outputIOProcID = ioProcID
        print("[AUDIO] MiRemote IOProc 已启动: id=\(deviceID), 48000 Hz stereo")
    }

    private func render(_ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard let first = buffers.first else { return }
        let firstChannels = max(1, Int(first.mNumberChannels))
        let frameCount = Int(first.mDataByteSize) /
            MemoryLayout<Float>.size /
            firstChannels
        guard frameCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        stateLock.lock()
        let available = pendingOutput.count - pendingOutputIndex
        if available > 0 {
            let take = min(frameCount, available)
            mono.replaceSubrange(
                0..<take,
                with: pendingOutput[pendingOutputIndex..<(pendingOutputIndex + take)]
            )
            pendingOutputIndex += take
            compactOutputBufferIfNeeded()
        }
        renderCallbackCount += 1
        stateLock.unlock()

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let writableFrames = min(
                frameCount,
                Int(buffer.mDataByteSize) /
                    MemoryLayout<Float>.size /
                    channelCount
            )
            let output = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<writableFrames {
                for channel in 0..<channelCount {
                    output[frame * channelCount + channel] = mono[frame]
                }
            }
        }
    }

    private func compactOutputBufferIfNeeded() {
        if pendingOutputIndex > 4_096 {
            pendingOutput.removeFirst(pendingOutputIndex)
            pendingOutputIndex = 0
        }
        let maximumQueuedFrames = Int(Self.outputSampleRate * 2)
        let available = pendingOutput.count - pendingOutputIndex
        if available > maximumQueuedFrames {
            pendingOutputIndex += available - maximumQueuedFrames
        }
    }

    private static func findOutputDevice(named targetName: String) -> AudioDeviceID? {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &propertySize
        ) == noErr else { return nil }

        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &propertySize, &devices
        ) == noErr else { return nil }

        for id in devices where id != 0 {
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                id, &nameAddress, 0, nil, &nameSize, &nameRef
            ) == noErr else { continue }
            guard let name = nameRef?.takeRetainedValue() as String? else { continue }
            if name.caseInsensitiveCompare(targetName) == .orderedSame {
                return id
            }
        }
        return nil
    }

    // MARK: - diagnostics

    private func startDiagnosticsTimer() {
        diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let mode = self.remoteActive ? "remote" : "mac"
            let macBuffers = self.scheduledMacBuffers
            let remoteBuffers = self.scheduledRemoteBuffers
            let peak = self.scheduledPeak
            let renders = self.renderCallbackCount
            self.scheduledMacBuffers = 0
            self.scheduledRemoteBuffers = 0
            self.scheduledPeak = 0
            self.renderCallbackCount = 0
            self.stateLock.unlock()
            print(String(
                format: "[AUDIO-METER] mode=%@ macBuffers=%d remoteBuffers=%d scheduledPeak=%.4f renders=%d",
                mode,
                macBuffers,
                remoteBuffers,
                peak,
                renders
            ))
        }
    }
}
