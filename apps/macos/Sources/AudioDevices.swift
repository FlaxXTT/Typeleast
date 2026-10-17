import AVFoundation
import CoreAudio
import AudioToolbox
import Combine

// AudioDevices.swift - microphone list, a live level meter for Settings and
// onboarding, and "mute other audio while dictating".

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    /// Every device with at least one input channel.
    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Resolve a stored UID to a live device id; empty or unknown means "system default".
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return inputs().first(where: { $0.uid == uid })?.id
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let result = value?.takeRetainedValue() else { return nil }
        return result as String
    }
}

/// Point an engine's input node at a specific device before it starts.
enum AudioInputSelector {
    @discardableResult
    static func apply(deviceID: AudioDeviceID?, to engine: AVAudioEngine) -> Bool {
        guard var id = deviceID, let unit = engine.inputNode.audioUnit else { return false }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr
    }
}

/// A short-lived meter for "speak to test your microphone" (Reference turns its bars
/// blue when it hears you). Runs only after the user presses a test button, at most
/// `maxSeconds`, and stops when its page goes away.
final class MicMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var running = false
    @Published private(set) var heardVoice = false

    private var engine: AVAudioEngine?
    private var autoStop: Timer?

    /// The test closes the microphone on its own after this long, so a Settings page
    /// left open (even behind other windows) can never keep listening.
    static let maxSeconds: TimeInterval = 15

    /// Opens the microphone. Call ONLY from an explicit user action (a "test" button):
    /// never from onAppear, so showing a page alone never turns the microphone on.
    func start(deviceUID: String) {
        stop()
        heardVoice = false
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let engine = AVAudioEngine()
        AudioInputSelector.apply(deviceID: AudioDevices.deviceID(forUID: deviceUID), to: engine)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let rms = Recorder.rms(of: buffer)
            DispatchQueue.main.async {
                guard let self = self, self.running else { return }
                self.level = Recorder.smoothLevel(previous: self.level, sample: Recorder.loudness(rms: rms))
                if rms > 0.02 { self.heardVoice = true }
            }
        }
        do {
            try engine.start()
            self.engine = engine
            running = true
            autoStop = Timer.scheduledTimer(withTimeInterval: MicMeter.maxSeconds, repeats: false) { [weak self] _ in
                self?.stop()
            }
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        autoStop?.invalidate()
        autoStop = nil
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        running = false
        level = 0
    }
}

/// Mute the default output device for the length of a dictation, then put it back
/// exactly as it was. Never unmutes something the user had muted themselves.
final class OutputMuter {
    static let shared = OutputMuter()
    private var mutedDevice: AudioDeviceID?

    func muteIfNeeded() {
        guard mutedDevice == nil, let device = defaultOutput(), let muted = isMuted(device), !muted else { return }
        if setMuted(device, true) { mutedDevice = device }
    }

    func restore() {
        guard let device = mutedDevice else { return }
        _ = setMuted(device, false)
        mutedDevice = nil
    }

    private func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
