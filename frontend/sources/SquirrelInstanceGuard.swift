import AppKit
import Darwin

// Refuse a second frontend instead of competing for the same Rime databases.
enum SquirrelInstanceGuard {
  private static var descriptor: Int32 = -1
  static func acquire() -> Bool {
    if let bundle = Bundle.main.bundleIdentifier {
      let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
      guard others.isEmpty else {
        fputs("Squirrel already running; refusing duplicate frontend.\n", stderr)
        return false
      }
    }
    let path = SquirrelApp.userDir.appendingPathComponent("ghost-frontend.lock").path
    descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      fputs("Another custom Squirrel owns the frontend lock.\n", stderr)
      if descriptor >= 0 { close(descriptor) }; descriptor = -1
      return false
    }
    return true
  }
}
