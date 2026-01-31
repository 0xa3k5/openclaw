import AppKit
import Foundation
import Observation

/// Periodically reports what the user is doing (frontmost app, window title)
/// to the gateway as ambient context the agent can use proactively.
@MainActor
@Observable
final class AmbientContext {
    static let shared = AmbientContext()

    private(set) var currentApp: String?
    private(set) var currentTitle: String?
    private(set) var isEnabled = true

    private var pollTimer: Timer?
    private var lastReportedApp: String?
    private var lastReportedTitle: String?
    private var lastReportAt: Date?
    private var consecutiveIdleCount = 0

    /// Minimum seconds between context reports to the gateway.
    private let reportIntervalMin: TimeInterval = 30
    /// How often to poll the frontmost app.
    private let pollInterval: TimeInterval = 5

    func start() {
        guard self.pollTimer == nil else { return }
        self.pollTimer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        self.poll()
    }

    func stop() {
        self.pollTimer?.invalidate()
        self.pollTimer = nil
    }

    private func poll() {
        guard self.isEnabled else { return }

        // Skip when user is idle (>5 min)
        if let idleSeconds = PresenceReporter.idleSeconds(), idleSeconds > 300 {
            self.consecutiveIdleCount += 1
            return
        }
        self.consecutiveIdleCount = 0

        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? app?.bundleIdentifier ?? "unknown"

        // Get window title via accessibility (best effort)
        let title = Self.frontmostWindowTitle(for: app)

        self.currentApp = appName
        self.currentTitle = title

        // Only report when something changed or enough time passed
        let changed = appName != self.lastReportedApp || title != self.lastReportedTitle
        let elapsed = self.lastReportAt.map { Date().timeIntervalSince($0) } ?? .infinity

        if changed || elapsed > 120 {
            self.report(app: appName, title: title)
        }
    }

    private func report(app: String, title: String?) {
        // Throttle: don't spam the gateway
        if let last = self.lastReportAt, Date().timeIntervalSince(last) < self.reportIntervalMin {
            return
        }

        self.lastReportedApp = app
        self.lastReportedTitle = title
        self.lastReportAt = Date()

        var text = "[ambient] User is in: \(app)"
        if let title, !title.isEmpty {
            text += " — \"\(title)\""
        }

        Task {
            try? await ControlChannel.shared.sendSystemEvent(text, params: [
                "silent": AnyHashable(true),
                "kind": AnyHashable("ambient-context"),
            ])
        }
    }

    // MARK: - Window Title (Accessibility)

    /// Best-effort window title from the frontmost app via AX API.
    private static func frontmostWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app, let pid = Optional(app.processIdentifier) else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value)
        guard result == .success, let windowRef = value else { return nil }
        let window = windowRef as! AXUIElement
        var titleValue: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
        guard titleResult == .success, let title = titleValue as? String else { return nil }
        return title.isEmpty ? nil : title
    }
}
