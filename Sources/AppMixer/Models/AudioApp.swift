import AppKit
import Foundation

struct AudioApp: Identifiable, Equatable {
    var id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage
    var volume: Float
    var isActive: Bool
    var lastSeenActive: Date

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}
