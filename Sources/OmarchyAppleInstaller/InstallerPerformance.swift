#if os(macOS)
  import Foundation
  import OSLog

  public enum InstallerPerformance {
    private static let logger = Logger(
      subsystem: InstallerProductIdentity.appIdentifier, category: "performance")

    /// Wall-clock records the owner can line up with the engine's ESP log
    /// (/boot/efi/asahi/install-timing.jsonl) and Linux's first-boot log.
    /// ~/Library/Logs for the app; /var/log for the root helper.
    static let logURL: URL = {
      let base =
        getuid() == 0
        ? URL(fileURLWithPath: "/var/log", isDirectory: true)
        : FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Logs", isDirectory: true)
      return base.appendingPathComponent("omarchy-installer-timing.jsonl")
    }()

    static func record(_ phase: String, start: Date, end: Date, completed: Bool) {
      let iso = ISO8601DateFormatter()
      let line =
        "{\"phase\":\"\(phase)\",\"started_at\":\"\(iso.string(from: start))\","
        + "\"ended_at\":\"\(iso.string(from: end))\",\"seconds\":\(end.timeIntervalSince(start)),"
        + "\"outcome\":\"\(completed ? "completed" : "failed")\"}\n"
      guard let data = line.data(using: .utf8) else { return }
      if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: logURL)
      }
    }

    /// Call once from the app delegate's launch: the start of the measurement.
    public static func markLaunch() {
      let now = Date()
      record("app_launched", start: now, end: now, completed: true)
    }

    static func measure<T>(_ phase: String, _ action: () throws -> T) rethrows -> T {
      let start = ProcessInfo.processInfo.systemUptime
      let wallStart = Date()
      var completed = false
      defer {
        let seconds = ProcessInfo.processInfo.systemUptime - start
        logger.notice("phase=\(phase, privacy: .public) seconds=\(seconds) completed=\(completed)")
        record(phase, start: wallStart, end: Date(), completed: completed)
      }
      let result = try action()
      completed = true
      return result
    }
  }
#endif
