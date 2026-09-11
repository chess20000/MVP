import AppKit
import CoreGraphics

enum GhostFocus {
  // Callers must still own an active IMK client and validate its current selection.
  static func matches(app: String, caret: () -> NSRect) -> Bool {
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    guard frontmost != "com.apple.loginwindow" else { return false }
    if !app.isEmpty && frontmost == app { return true }
    guard app == "com.apple.Spotlight", frontmost != nil else { return false }

    let ownPID = ProcessInfo.processInfo.processIdentifier
    let spotlightPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: app)
      .filter { !$0.isTerminated && $0.processIdentifier > 0 && $0.processIdentifier != ownPID }
      .map(\.processIdentifier))
    guard !spotlightPIDs.isEmpty else { return false }

    let rect = caret()
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
          rect.size.width.isFinite, rect.size.height.isFinite,
          rect.width >= 0, rect.height > 0,
          let primaryScreen = NSScreen.screens.first else { return false }
    let center = NSPoint(x: rect.midX, y: rect.midY)
    guard center.x.isFinite, center.y.isFinite,
          NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { return false }
    // IMK rectangles use AppKit coordinates; window-list bounds start at the
    // upper-left of the primary display, including when another display is active.
    let point = CGPoint(x: center.x, y: primaryScreen.frame.maxY - center.y)
    guard let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }

    for window in windows {
      guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
            owner.int32Value != ownPID,
            let alpha = window[kCGWindowAlpha as String] as? NSNumber,
            alpha.doubleValue.isFinite, alpha.doubleValue > 0,
            let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
            bounds.origin.x.isFinite, bounds.origin.y.isFinite,
            bounds.size.width.isFinite, bounds.size.height.isFinite,
            bounds.width > 0, bounds.height > 0,
            bounds.contains(point) else { continue }

      // Window-list order is front to back. Do not look through another app's
      // visible window for an old Spotlight panel underneath it. Public window
      // metadata has no hit-testing flag, so unknown overlays also block this path.
      guard let level = window[kCGWindowLayer as String] as? NSNumber else { return false }
      return spotlightPIDs.contains(owner.int32Value)
        && level.int32Value >= CGWindowLevelForKey(.floatingWindow)
    }
    return false
  }
}
