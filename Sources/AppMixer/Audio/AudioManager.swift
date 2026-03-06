import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation

final class AudioManager: ObservableObject {
    static let shared = AudioManager()

    @Published var masterVolume: Float = 0.5
    @Published var audioApps: [AudioApp] = []
    @Published var isMasterMuted: Bool = false

    private var pollTimer: Timer?
    private var fadeTimer: Timer?
    private let fadeOutDelay: TimeInterval = 5.0
    private var pinnedBundleIDs: Set<String> = []
    private var appVolumes: [String: Float] = [:]
    private lazy var audioTapManager = AudioTapManager()

    private static let audioBundleIDs: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.apple.QuickTimePlayerX",
        "com.apple.TV",
        "com.apple.podcasts",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.valvesoftware.steam",
        "tv.twitch.studio",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.arc.browser",
        "com.linear.Linear",
        "com.figma.Desktop",
        "com.loom.desktop",
        "com.amazon.aiv.AIVApp",
        "com.freetube.FreeTube",
        "com.apple.FaceTime",
        "com.webex.meetingmanager",
        "com.plexapp.plexamp",
        "com.roon.Roon",
        "com.audacityteam.audacity",
        "org.mozilla.thunderbird",
        "com.apple.iWork.Keynote",
    ]

    private init() {
        loadMasterVolume()
        loadPinnedApps()
        loadAppVolumes()
    }

    func startMonitoring() {
        let startMsg = "[AppMixer] startMonitoring called at \(Date())\n"
        try? startMsg.write(toFile: "/tmp/appmixer.log", atomically: false, encoding: .utf8)

        // Activate the HAL driver (set as default output, start audio forwarding)
        audioTapManager.activate()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateAudioApps()
        }
        updateAudioApps()

        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.removeStaleApps()
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        audioTapManager.deactivate()
    }

    // MARK: - Master Volume

    func setMasterVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        masterVolume = clamped
        setSystemVolume(clamped)
        // Keep AppMixer's volume control in sync so F10/F11/F12 HUD matches
        audioTapManager.syncVolume(clamped)
    }

    func toggleMasterMute() {
        isMasterMuted.toggle()
        setSystemMute(isMasterMuted)
        audioTapManager.syncMute(isMasterMuted)
    }

    private func loadMasterVolume() {
        masterVolume = getSystemVolume()
        isMasterMuted = getSystemMute()
    }

    // MARK: - Per-App Volume

    func setAppVolume(_ app: AudioApp, volume: Float) {
        let clamped = max(0, min(1, volume))
        if let idx = audioApps.firstIndex(where: { $0.id == app.id }) {
            audioApps[idx].volume = clamped
        }
        if let bundleID = app.bundleIdentifier {
            appVolumes[bundleID] = clamped
            saveAppVolumes()
        }

        if clamped >= 0.99 {
            audioTapManager.removeTap(for: app.id)
        } else {
            audioTapManager.ensureTap(for: app.id, volume: clamped)
        }
    }

    // MARK: - Pinned Apps

    func isPinned(_ app: AudioApp) -> Bool {
        guard let bid = app.bundleIdentifier else { return false }
        return pinnedBundleIDs.contains(bid)
    }

    func togglePin(_ app: AudioApp) {
        guard let bid = app.bundleIdentifier else { return }
        if pinnedBundleIDs.contains(bid) {
            pinnedBundleIDs.remove(bid)
        } else {
            pinnedBundleIDs.insert(bid)
        }
        savePinnedApps()
    }

    var pinnedApps: Set<String> {
        pinnedBundleIDs
    }

    func setPinnedApps(_ apps: Set<String>) {
        pinnedBundleIDs = apps
        savePinnedApps()
    }

    // MARK: - Audio App Detection

    private func updateAudioApps() {
        let runningApps = NSWorkspace.shared.runningApplications
        var detectedApps = detectUsingCoreAudioProcesses(runningApps: runningApps)

        if detectedApps.isEmpty {
            detectedApps = detectUsingKnownBundleIDs(runningApps: runningApps)
        }

        DispatchQueue.main.async { [weak self] in
            self?.mergeApps(detectedApps)
            self?.syncTaps()
        }
    }

    private func detectUsingCoreAudioProcesses(runningApps: [NSRunningApplication]) -> [AudioApp] {
        var result: [AudioApp] = []
        let processObjectListSelector = AudioObjectPropertySelector(0x70727323)
        let processPIDSelector = AudioObjectPropertySelector(0x70706964)
        let processIsRunningOutputSelector = AudioObjectPropertySelector(0x7069726F)

        var address = AudioObjectPropertyAddress(
            mSelector: processObjectListSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs
        )
        guard status == noErr else { return [] }

        for processObjectID in processIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: processPIDSelector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let pidStatus = AudioObjectGetPropertyData(
                processObjectID, &pidAddress, 0, nil, &pidSize, &pid
            )
            guard pidStatus == noErr, pid > 0 else { continue }

            var isRunningAddress = AudioObjectPropertyAddress(
                mSelector: processIsRunningOutputSelector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(
                processObjectID, &isRunningAddress, 0, nil, &isRunningSize, &isRunning
            )

            guard let app = runningApps.first(where: { $0.processIdentifier == pid }),
                  let name = app.localizedName,
                  app.activationPolicy == .regular
            else { continue }

            let bundleID = app.bundleIdentifier
            let isPinned = bundleID.map { pinnedBundleIDs.contains($0) } ?? false

            // Only show apps actively outputting audio, or pinned apps
            guard isRunning != 0 || isPinned else { continue }

            let icon = app.icon ?? NSImage(
                systemSymbolName: "app.fill",
                accessibilityDescription: name
            ) ?? NSImage()
            icon.size = NSSize(width: 20, height: 20)

            let volume = bundleID.flatMap { appVolumes[$0] } ?? 1.0

            result.append(AudioApp(
                id: pid,
                name: name,
                bundleIdentifier: bundleID,
                icon: icon,
                volume: volume,
                isActive: isRunning != 0,
                lastSeenActive: isRunning != 0 ? Date() : Date.distantPast
            ))
        }

        return result
    }

    private func detectUsingKnownBundleIDs(runningApps: [NSRunningApplication]) -> [AudioApp] {
        var result: [AudioApp] = []

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  let name = app.localizedName,
                  Self.audioBundleIDs.contains(bundleID) || pinnedBundleIDs.contains(bundleID)
            else { continue }

            let icon = app.icon ?? NSImage(
                systemSymbolName: "app.fill",
                accessibilityDescription: name
            ) ?? NSImage()
            icon.size = NSSize(width: 20, height: 20)

            let volume = appVolumes[bundleID] ?? 1.0

            result.append(AudioApp(
                id: app.processIdentifier,
                name: name,
                bundleIdentifier: bundleID,
                icon: icon,
                volume: volume,
                isActive: true,
                lastSeenActive: Date()
            ))
        }

        return result
    }

    private func mergeApps(_ detected: [AudioApp]) {
        var merged = audioApps

        for newApp in detected {
            if let idx = merged.firstIndex(where: { $0.bundleIdentifier == newApp.bundleIdentifier }) {
                merged[idx].isActive = newApp.isActive
                if newApp.isActive {
                    merged[idx].lastSeenActive = Date()
                }
                merged[idx].id = newApp.id
            } else {
                merged.append(newApp)
            }
        }

        let detectedBundleIDs = Set(detected.compactMap(\.bundleIdentifier))
        for idx in merged.indices {
            if let bid = merged[idx].bundleIdentifier,
               !detectedBundleIDs.contains(bid),
               !pinnedBundleIDs.contains(bid) {
                merged[idx].isActive = false
            }
        }

        audioApps = merged
    }

    private func removeStaleApps() {
        let now = Date()
        audioApps.removeAll { app in
            guard !app.isActive else { return false }
            if let bid = app.bundleIdentifier, pinnedBundleIDs.contains(bid) {
                return false
            }
            let isStale = now.timeIntervalSince(app.lastSeenActive) > fadeOutDelay
            if isStale {
                audioTapManager.removeTap(for: app.id)
            }
            return isStale
        }
    }

    /// Create taps for active audio apps that have non-default volume
    private func syncTaps() {
        let activePIDs = audioTapManager.activePIDs
        for app in audioApps where app.isActive {
            if app.volume < 0.99 {
                audioTapManager.ensureTap(for: app.id, volume: app.volume)
            } else if activePIDs.contains(app.id) {
                // Volume back to 100%, remove tap to restore normal audio
                audioTapManager.removeTap(for: app.id)
            }
        }

        // Remove taps for apps no longer in the list
        let currentPIDs = Set(audioApps.map(\.id))
        for pid in activePIDs where !currentPIDs.contains(pid) {
            audioTapManager.removeTap(for: pid)
        }
    }

    // MARK: - CoreAudio System Volume

    /// Returns the real hardware output device (bypasses AppMixer virtual device)
    private func getRealOutputDevice() -> AudioDeviceID {
        let real = audioTapManager.realOutputDevice
        if real != 0 { return real }
        // Fallback: query system default
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

    private func getSystemVolume() -> Float {
        let device = getRealOutputDevice()
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(device, &address) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
            return volume
        }

        address.mSelector = kAudioDevicePropertyVolumeScalar
        address.mElement = 1
        if AudioObjectHasProperty(device, &address) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        }
        return volume
    }

    private func setSystemVolume(_ volume: Float) {
        let device = getRealOutputDevice()
        var vol = volume
        let size = UInt32(MemoryLayout<Float>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(device, &address) {
            AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol)
            return
        }

        address.mSelector = kAudioDevicePropertyVolumeScalar
        for channel: UInt32 in [1, 2] {
            address.mElement = channel
            if AudioObjectHasProperty(device, &address) {
                AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol)
            }
        }
    }

    private func getSystemMute() -> Bool {
        let device = getRealOutputDevice()
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &address) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        }
        return muted != 0
    }

    private func setSystemMute(_ mute: Bool) {
        let device = getRealOutputDevice()
        var muted: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &address) {
            AudioObjectSetPropertyData(device, &address, 0, nil, size, &muted)
        }
    }

    // MARK: - Persistence

    private func savePinnedApps() {
        UserDefaults.standard.set(Array(pinnedBundleIDs), forKey: "pinnedBundleIDs")
    }

    private func loadPinnedApps() {
        if let saved = UserDefaults.standard.stringArray(forKey: "pinnedBundleIDs") {
            pinnedBundleIDs = Set(saved)
        }
    }

    private func saveAppVolumes() {
        UserDefaults.standard.set(appVolumes, forKey: "appVolumes")
    }

    private func loadAppVolumes() {
        if let saved = UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: Float] {
            appVolumes = saved
        }
    }
}
