import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import IOKit.hid

/// HID/session taps that swallow Tab while this IME is serving a field.
/// Brief deactivateServer blips (common in browsers after insertText) stay armed.
final class GhostTabTap {
  static let shared = GhostTabTap()

  private weak var activeController: SquirrelInputController?
  private var ports: [CFMachPort] = []
  private var sources: [CFRunLoopSource] = []
  private var retry: Timer?
  private var standby: Timer?
  private var armed = false
  private var squirrelSelected = true
  private var lastPrompt: TimeInterval = 0
  private var didOpenSettings = false
  private var tisObserver: NSObjectProtocol?

  private init() {
    squirrelSelected = Self.currentSourceIsSquirrel()
    tisObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.squirrelSelected = Self.currentSourceIsSquirrel()
      if self?.squirrelSelected != true { self?.armed = false }
    }
  }

  var isActivated: Bool { armed || activeController != nil }

  func activate(_ controller: SquirrelInputController) {
    standby?.invalidate(); standby = nil
    armed = true
    squirrelSelected = true
    activeController = controller
    install()
    if ports.isEmpty { scheduleRetry() }
  }

  func deactivate(_ controller: SquirrelInputController) {
    if activeController === controller { activeController = nil }
    retry?.invalidate(); retry = nil
    standby?.invalidate()
    // Browsers often deactivate IMK around Tab/insertText while the caret is still here.
    standby = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
      guard let self else { return }
      if self.activeController == nil { self.armed = false }
      self.standby = nil
    }
  }

  func invalidate() {
    armed = false
    activeController = nil
    retry?.invalidate(); retry = nil
    standby?.invalidate(); standby = nil
    if let tisObserver {
      DistributedNotificationCenter.default().removeObserver(tisObserver)
    }
    tisObserver = nil
    tearDownTaps()
  }

  fileprivate func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      for port in ports { CGEvent.tapEnable(tap: port, enable: true) }
      if ports.contains(where: { !CGEvent.tapIsEnabled(tap: $0) }) {
        DispatchQueue.main.async { [weak self] in self?.reinstall() }
      }
      return Unmanaged.passUnretained(event)
    }
    guard (armed || activeController != nil), squirrelSelected,
          type == .keyDown || type == .keyUp else {
      return Unmanaged.passUnretained(event)
    }
    guard event.getIntegerValueField(.keyboardEventKeycode) == 48 else {
      return Unmanaged.passUnretained(event)
    }
    let blocked: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    guard event.flags.intersection(blocked).isEmpty else {
      return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
      DispatchQueue.main.async { [weak self] in self?.activeController?.acceptSystemTab() }
    }
    return nil
  }

  private func reinstall() {
    tearDownTaps()
    install()
  }

  private func install() {
    ports = ports.filter { port in
      CGEvent.tapEnable(tap: port, enable: true)
      return CGEvent.tapIsEnabled(tap: port)
    }
    if !ports.isEmpty {
      retry?.invalidate(); retry = nil
      return
    }
    tearDownTaps()
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
    var locations: [String] = []
    for (location, name) in [(CGEventTapLocation.cgSessionEventTap, "session"),
                             (.cghidEventTap, "hid")] {
      guard let port = CGEvent.tapCreate(
        tap: location, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: ghostTabTapCallback, userInfo: nil
      ) else { continue }
      CGEvent.tapEnable(tap: port, enable: true)
      guard CGEvent.tapIsEnabled(tap: port) else {
        CFMachPortInvalidate(port)
        continue
      }
      guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
        CFMachPortInvalidate(port)
        continue
      }
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
      ports.append(port)
      sources.append(source)
      locations.append(name)
    }
    if !ports.isEmpty {
      retry?.invalidate(); retry = nil
      GhostDiagnostics.record(
        app: "im.rime.inputmethod.Squirrel",
        reason: "tab_tap_ready",
        fields: ["location": locations.joined(separator: "+")]
      )
      return
    }
    promptTrust()
    GhostDiagnostics.record(app: "im.rime.inputmethod.Squirrel", reason: "tab_tap_untrusted")
  }

  private func tearDownTaps() {
    for source in sources {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    for port in ports {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    sources = []
    ports = []
  }

  private func promptTrust() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastPrompt >= 8 else { return }
    lastPrompt = now
    if !AXIsProcessTrusted() {
      let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
      _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
    if !didOpenSettings {
      didOpenSettings = true
      SquirrelApplicationDelegate.showMessage(msgText: "请在「辅助功能」和「输入监控」中允许鼠须管，否则无法拦截浏览器 Tab")
      for pane in ["Privacy_Accessibility", "Privacy_ListenEvent"] {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") {
          NSWorkspace.shared.open(url)
        }
      }
    }
  }

  private func scheduleRetry() {
    guard retry == nil else { return }
    retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self, self.armed || self.activeController != nil else {
        self?.retry?.invalidate(); self?.retry = nil
        return
      }
      self.install()
    }
  }

  private static func currentSourceIsSquirrel() -> Bool {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
    let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    return id.hasPrefix("im.rime.inputmethod.Squirrel")
  }
}

private func ghostTabTapCallback(
  _: CGEventTapProxy, type: CGEventType, event: CGEvent,
  _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  GhostTabTap.shared.filter(type: type, event: event)
}
