import AppKit
import CoreAudio
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioManager.shared.stopMonitoring()
        Self.clearSavedRealDevice()
    }

    /// Install signal handlers so we restore audio even on SIGTERM/SIGINT
    private func installSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { _ in
            AppDelegate.restoreSavedRealDevice()
            exit(0)
        }
        signal(SIGTERM, handler)
        signal(SIGINT, handler)
        signal(SIGHUP, handler)
    }

    // MARK: - Persisted real device recovery

    private static let realDeviceUIDKey = "appmixer_real_device_uid"

    static func saveRealDeviceUID(_ uid: String) {
        UserDefaults.standard.set(uid, forKey: realDeviceUIDKey)
    }

    static func clearSavedRealDevice() {
        UserDefaults.standard.removeObject(forKey: realDeviceUIDKey)
    }

    /// Restore the real output device from saved UID (called on crash recovery or signal)
    static func restoreSavedRealDevice() {
        guard let savedUID = UserDefaults.standard.string(forKey: realDeviceUIDKey) else { return }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz
        ) == noErr else { return }
        let count = Int(sz) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &devices
        ) == noErr else { return }

        for dev in devices {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
                  let uid = uidRef?.takeUnretainedValue() as String?,
                  uid == savedUID else { continue }

            var devID = dev
            let size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &outAddr, 0, nil, size, &devID
            )
            outAddr.mSelector = kAudioHardwarePropertyDefaultSystemOutputDevice
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &outAddr, 0, nil, size, &devID
            )
            break
        }

        UserDefaults.standard.removeObject(forKey: realDeviceUIDKey)
    }
}
