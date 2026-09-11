import Foundation

/// Failure metadata only: never record document text, model prompts or generated tokens.
enum GhostDiagnostics {
  private static let queue = DispatchQueue(label: "im.rime.ghost.status", qos: .utility)
  private static var lastWrite: [String: TimeInterval] = [:]
  private static var states: [String: [String: Any]] = [:]
  static func record(app: String, reason: String, fields: [String: Any] = [:]) {
    guard !app.isEmpty else { return }
    let now = ProcessInfo.processInfo.systemUptime
    queue.async {
      let key = app + ":" + reason
      guard now - (lastWrite[key] ?? -10) >= 1 else { return }
      lastWrite[key] = now
      var metadata = fields
      metadata["reason"] = reason
      metadata["updated_at"] = ISO8601DateFormatter().string(from: Date())
      states[app] = metadata
      let url = SquirrelApp.userDir.appendingPathComponent("ghost/compatibility-status.json")
      if let data = try? JSONSerialization.data(withJSONObject: states, options: [.sortedKeys]) {
        try? data.write(to: url, options: .atomic)
      }
    }
  }
}
