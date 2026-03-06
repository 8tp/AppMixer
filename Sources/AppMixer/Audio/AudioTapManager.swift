import AudioToolbox
import CoreAudio
import Foundation

private func tapLog(_ message: String) {
    let msg = "[AppMixer] \(message)\n"
    let logPath = "/tmp/appmixer.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(msg.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: msg.data(using: .utf8))
    }
}

// Shared memory layout - must match Driver/AppMixerDriver.c
private let kShmName = "/appmixer_volumes"
private let kMaxVolEntries = 64

private struct VolEntry {
    var pid: Int32
    var volume: Float
}

private struct ShmVolumes {
    var count: UInt32
    var entries: (
        VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry,
        VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry,
        VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry,
        VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry,
        VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry,
        VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry,
        VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry,
        VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry, VolEntry
    )
}

final class AudioTapManager {
    private var volumes: [pid_t: Float] = [:]
    private let lock = NSLock()

    // Shared memory
    private var shmFd: Int32 = -1
    private var shmPtr: UnsafeMutableRawPointer?

    // Audio forwarding via aggregate device (handles clock sync automatically)
    private var forwardIOProc: AudioDeviceIOProcID?
    private var aggregateDeviceID: AudioDeviceID = 0
    private var originalDefaultDevice: AudioDeviceID = 0
    private var appMixerDeviceID: AudioDeviceID = 0
    private var realOutputDeviceID: AudioDeviceID = 0
    private var isForwarding = false

    private static let appMixerDeviceUID = "AppMixerDevice_UID" as CFString

    init() {
        openSharedMemory()
    }

    deinit {
        deactivate()
        closeSharedMemory()
    }

    /// The real hardware output device (not AppMixer)
    var realOutputDevice: AudioDeviceID { realOutputDeviceID }

    /// Sync the AppMixer volume control to match a UI slider change
    func syncVolume(_ volume: Float) {
        guard volumeControlID != 0 else { return }
        var vol = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(volumeControlID, &addr, 0, nil, size, &vol)
    }

    /// Sync the AppMixer mute control to match a UI toggle
    func syncMute(_ muted: Bool) {
        guard muteControlID != 0 else { return }
        var val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioBooleanControlPropertyValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(muteControlID, &addr, 0, nil, size, &val)
    }

    // MARK: - Public API

    func ensureTap(for pid: pid_t, volume: Float) {
        lock.lock()
        volumes[pid] = max(0, min(1, volume))
        lock.unlock()
        writeShmVolumes()
        tapLog("Set volume for PID \(pid) to \(volume)")
    }

    func removeTap(for pid: pid_t) {
        lock.lock()
        volumes.removeValue(forKey: pid)
        lock.unlock()
        writeShmVolumes()
        tapLog("Removed volume entry for PID \(pid)")
    }

    func removeAllTaps() {
        lock.lock()
        volumes.removeAll()
        lock.unlock()
        writeShmVolumes()
    }

    func hasTap(for pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return volumes[pid] != nil
    }

    var activePIDs: Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return Set(volumes.keys)
    }

    /// Activate the driver: set AppMixer as default output, start forwarding audio to real output
    func activate() {
        guard !isForwarding else { return }

        guard let deviceID = findAppMixerDevice() else {
            tapLog("ERROR: AppMixer driver not found. Is it installed?")
            return
        }
        appMixerDeviceID = deviceID
        tapLog("Found AppMixer device: \(appMixerDeviceID)")

        // Remember the current default output
        originalDefaultDevice = getDefaultOutputDevice()

        if originalDefaultDevice == appMixerDeviceID {
            // AppMixer is already default (e.g. previous crash). Find a real device.
            if let realDevice = findRealOutputDevice() {
                originalDefaultDevice = realDevice
                tapLog("AppMixer was already default. Using real device: \(realDevice)")
            } else {
                tapLog("ERROR: Cannot find a real output device.")
                return
            }
        }

        realOutputDeviceID = originalDefaultDevice

        // Set AppMixer as the default output device
        setDefaultOutputDevice(appMixerDeviceID)
        tapLog("Set AppMixer as default output device")

        // Sync initial volume from real device to AppMixer
        syncVolumeToAppMixer()

        // Start forwarding from AppMixer input to real output
        startForwarding()

        // Listen for volume/mute changes on AppMixer (from F10/F11/F12 keys)
        installVolumeListeners()

        isForwarding = true
        tapLog("Audio forwarding active")
    }

    /// Find a real (non-AppMixer) output device
    private func findRealOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices
        ) == noErr else { return nil }

        for dev in devices {
            guard dev != appMixerDeviceID else { continue }
            guard let uid = getDeviceUID(dev) else { continue }

            // Skip virtual/zoom devices, prefer real hardware
            if uid.contains("zoom") { continue }

            // Check it has output streams
            var stAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var stSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(dev, &stAddr, 0, nil, &stSize)
            if stSize > 0 {
                return dev
            }
        }
        return nil
    }

    /// Deactivate: stop forwarding, restore original default device
    func deactivate() {
        guard isForwarding else { return }
        isForwarding = false

        stopForwarding()

        // Restore original default device
        if originalDefaultDevice != 0 && originalDefaultDevice != appMixerDeviceID {
            setDefaultOutputDevice(originalDefaultDevice)
            tapLog("Restored default output device to \(originalDefaultDevice)")
        }

        removeAllTaps()
    }

    // MARK: - Shared Memory (via file-backed mmap)

    private static let shmFilePath = "/tmp/appmixer_volumes"

    private func openSharedMemory() {
        let size = MemoryLayout<ShmVolumes>.size
        let path = Self.shmFilePath

        // Create the file if it doesn't exist
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data(count: size))
        }

        shmFd = open(path, O_RDWR)
        guard shmFd >= 0 else {
            tapLog("ERROR: open failed: \(String(cString: strerror(errno)))")
            return
        }

        ftruncate(shmFd, off_t(size))

        shmPtr = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, shmFd, 0)
        if shmPtr == MAP_FAILED {
            shmPtr = nil
            tapLog("ERROR: mmap failed")
            return
        }

        memset(shmPtr!, 0, size)
        tapLog("Shared memory opened at \(path)")
    }

    private func closeSharedMemory() {
        if let ptr = shmPtr {
            munmap(ptr, MemoryLayout<ShmVolumes>.size)
            shmPtr = nil
        }
        if shmFd >= 0 {
            close(shmFd)
            shmFd = -1
        }
        unlink(Self.shmFilePath)
    }

    private func writeShmVolumes() {
        guard let ptr = shmPtr else { return }

        lock.lock()
        let currentVolumes = volumes
        lock.unlock()

        let shm = ptr.assumingMemoryBound(to: ShmVolumes.self)

        // Write entries via raw pointer arithmetic to handle the tuple
        let countPtr = ptr.assumingMemoryBound(to: UInt32.self)
        let entriesPtr = ptr.advanced(by: MemoryLayout<UInt32>.size).assumingMemoryBound(to: VolEntry.self)

        var i = 0
        for (pid, vol) in currentVolumes {
            guard i < kMaxVolEntries else { break }
            entriesPtr[i] = VolEntry(pid: pid, volume: vol)
            i += 1
        }

        // Write count last (acts as a memory fence for the driver reading it)
        _ = shm // suppress unused warning
        countPtr.pointee = UInt32(i)
    }

    // MARK: - Device Management

    private func findAppMixerDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices
        ) == noErr else { return nil }

        for dev in devices {
            if let uid = getDeviceUID(dev), uid == Self.appMixerDeviceUID as String {
                return dev
            }
        }
        return nil
    }

    private func getDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var devID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &devID
        )

        // Also set system output device
        address.mSelector = kAudioHardwarePropertyDefaultSystemOutputDevice
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &devID
        )
    }

    private func getDeviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uidRef)
        guard status == noErr, let uid = uidRef?.takeUnretainedValue() else { return nil }
        return uid as String
    }

    // MARK: - Audio Forwarding via Aggregate Device

    private func startForwarding() {
        // Get UIDs for both devices
        guard let appMixerUID = getDeviceUID(appMixerDeviceID),
              let realOutputUID = getDeviceUID(realOutputDeviceID) else {
            tapLog("ERROR: Could not get device UIDs")
            return
        }

        // Create an aggregate device combining AppMixer (input) + real output (output)
        // with drift correction on AppMixer to sync clocks
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: "com.appmixer.forward",
            kAudioAggregateDeviceNameKey as String: "AppMixer Forward",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceMainSubDeviceKey as String: realOutputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: realOutputUID,
                ],
                [
                    kAudioSubDeviceUIDKey as String: appMixerUID,
                    kAudioSubDeviceDriftCompensationKey as String: true,
                ],
            ],
        ]

        var aggID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard status == noErr else {
            tapLog("ERROR: Failed to create aggregate device: \(status)")
            return
        }
        aggregateDeviceID = aggID
        tapLog("Created forwarding aggregate device: \(aggID)")

        // IO proc on aggregate: copy input (AppMixer) to output (real speakers)
        let proc: AudioDeviceIOProc = { (
            device, now, inputData, inputTime, outputData, outputTime, clientData
        ) -> OSStatus in
            let inList = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            let outList = UnsafeMutableAudioBufferListPointer(outputData)

            for i in 0..<min(inList.count, outList.count) {
                if let src = inList[i].mData, let dst = outList[i].mData {
                    let bytes = min(inList[i].mDataByteSize, outList[i].mDataByteSize)
                    memcpy(dst, src, Int(bytes))
                }
            }
            return noErr
        }

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(aggID, proc, nil, &procID)
        guard createStatus == noErr, let id = procID else {
            tapLog("ERROR: Failed to create IO proc on aggregate: \(createStatus)")
            return
        }
        forwardIOProc = id

        let startStatus = AudioDeviceStart(aggID, id)
        if startStatus != noErr {
            tapLog("ERROR: Failed to start aggregate IO: \(startStatus)")
        } else {
            tapLog("Forwarding IO started on aggregate device")
        }
    }

    private func stopForwarding() {
        if let procID = forwardIOProc {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            forwardIOProc = nil
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        removeVolumeListeners()
        tapLog("Audio forwarding stopped")
    }

    // MARK: - Volume/Mute Forwarding (F10/F11/F12)

    private func syncVolumeToAppMixer() {
        // Read current volume from real device and set it on AppMixer
        // so the volume HUD shows the correct level
        let realVol = getDeviceScalarVolume(realOutputDeviceID)
        setDeviceScalarVolume(appMixerDeviceID, volume: realVol)

        let realMute = getDeviceMute(realOutputDeviceID)
        setDeviceMute(appMixerDeviceID, muted: realMute)
    }

    private var volumeControlID: AudioObjectID = 0
    private var muteControlID: AudioObjectID = 0

    private func installVolumeListeners() {
        // Get the control object IDs from the device's control list
        var ctrlAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyControlList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ctrlSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(appMixerDeviceID, &ctrlAddr, 0, nil, &ctrlSize) == noErr,
              ctrlSize > 0 else {
            tapLog("ERROR: No controls found on AppMixer device")
            return
        }
        let ctrlCount = Int(ctrlSize) / MemoryLayout<AudioObjectID>.size
        var controls = [AudioObjectID](repeating: 0, count: ctrlCount)
        guard AudioObjectGetPropertyData(appMixerDeviceID, &ctrlAddr, 0, nil, &ctrlSize, &controls) == noErr else {
            tapLog("ERROR: Failed to get control list")
            return
        }

        // Identify which control is volume vs mute by checking their class
        var classAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for ctrl in controls {
            var classID: AudioClassID = 0
            var classSize = UInt32(MemoryLayout<AudioClassID>.size)
            if AudioObjectGetPropertyData(ctrl, &classAddr, 0, nil, &classSize, &classID) == noErr {
                if classID == kAudioVolumeControlClassID {
                    volumeControlID = ctrl
                    tapLog("Found volume control: \(ctrl)")
                } else if classID == kAudioMuteControlClassID {
                    muteControlID = ctrl
                    tapLog("Found mute control: \(ctrl)")
                }
            }
        }

        // Listen on the volume control object
        if volumeControlID != 0 {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioLevelControlPropertyScalarValue,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(volumeControlID, &volAddr, DispatchQueue.main) {
                [weak self] _, _ in
                self?.onAppMixerVolumeChanged()
            }
        }

        // Listen on the mute control object
        if muteControlID != 0 {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioBooleanControlPropertyValue,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(muteControlID, &muteAddr, DispatchQueue.main) {
                [weak self] _, _ in
                self?.onAppMixerMuteChanged()
            }
        }

        tapLog("Volume/mute listeners installed on controls")
    }

    private func removeVolumeListeners() {
        // Listeners are removed when objects are destroyed
    }

    private func onAppMixerVolumeChanged() {
        // Read volume from the control object
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(volumeControlID, &addr, 0, nil, &size, &vol)

        tapLog("Volume changed: \(vol)")
        setDeviceScalarVolume(realOutputDeviceID, volume: vol)
        DispatchQueue.main.async {
            AudioManager.shared.masterVolume = vol
        }
    }

    private func onAppMixerMuteChanged() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioBooleanControlPropertyValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(muteControlID, &addr, 0, nil, &size, &val)

        let muted = val != 0
        tapLog("Mute changed: \(muted)")
        setDeviceMute(realOutputDeviceID, muted: muted)
        DispatchQueue.main.async {
            AudioManager.shared.isMasterMuted = muted
        }
    }

    // MARK: - Device Volume Helpers

    private func getDeviceScalarVolume(_ deviceID: AudioDeviceID) -> Float {
        // Try the volume control object first
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(deviceID, &addr) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume)
            return volume
        }
        addr.mSelector = kAudioDevicePropertyVolumeScalar
        addr.mElement = 1
        if AudioObjectHasProperty(deviceID, &addr) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &volume)
        }
        return volume
    }

    private func setDeviceScalarVolume(_ deviceID: AudioDeviceID, volume: Float) {
        var vol = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
            return
        }
        addr.mSelector = kAudioDevicePropertyVolumeScalar
        for ch: UInt32 in [1, 2] {
            addr.mElement = ch
            if AudioObjectHasProperty(deviceID, &addr) {
                AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
            }
        }
    }

    private func getDeviceMute(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(deviceID, &addr) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted)
        }
        return muted != 0
    }

    private func setDeviceMute(_ deviceID: AudioDeviceID, muted: Bool) {
        var val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &val)
        }
    }
}
