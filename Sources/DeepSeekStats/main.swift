import AppKit
import Foundation

// MARK: - App Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Hide from Dock (menu bar only)
app.setActivationPolicy(.accessory)
app.run()
