import AppKit
import Foundation
import ImageIO
import Observation
@preconcurrency import ScreenCaptureKit

/// Periodically captures a screenshot and sends it to the gateway as
/// ambient visual context. Respects presence: captures more when active,
/// skips when idle or screen is asleep.
@MainActor
@Observable
final class PeriodicScreenCapture {
    static let shared = PeriodicScreenCapture()

    private(set) var isRunning = false
    private(set) var lastCaptureAt: Date?
    private(set) var captureCount = 0

    /// Whether the user has enabled periodic capture.
    var isEnabled = true {
        didSet {
            if self.isEnabled, !self.isRunning { self.start() }
            if !self.isEnabled, self.isRunning { self.stop() }
        }
    }

    private var timer: Timer?

    /// Interval between captures (seconds). Adapts to presence.
    private let activeInterval: TimeInterval = 45
    private let idleInterval: TimeInterval = 120

    /// Max image dimension (longer side) to keep payloads small.
    private let maxDimension: CGFloat = 1024
    /// JPEG quality for compression.
    private let jpegQuality: CGFloat = 0.5

    func start() {
        guard !self.isRunning else { return }
        self.isRunning = true
        self.scheduleNext()
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.isRunning = false
    }

    private func scheduleNext() {
        self.timer?.invalidate()
        let interval = self.currentInterval()
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.isEnabled else { return }
                Task { await self.captureAndSend() }
            }
        }
    }

    private func currentInterval() -> TimeInterval {
        guard let seconds = PresenceReporter.idleSeconds() else { return self.activeInterval }
        if seconds > 300 { return 0 } // skip entirely when very idle
        if seconds > 60 { return self.idleInterval }
        return self.activeInterval
    }

    private func captureAndSend() async {
        defer { self.scheduleNext() }

        // Skip if user is very idle or screen is likely asleep
        if let idle = PresenceReporter.idleSeconds(), idle > 300 { return }

        // Check screen recording permission
        guard await self.hasPermission() else { return }

        do {
            let imageData = try await self.captureFrame()
            self.lastCaptureAt = Date()
            self.captureCount += 1
            try await self.sendToGateway(imageData)
        } catch {
            // Silently skip on failure (permission denied, no displays, etc.)
        }
    }

    // MARK: - Capture

    private func captureFrame() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.sorted { $0.displayID < $1.displayID }
        guard let display = displays.first else { throw CaptureError.noDisplays }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        // Scale down to save bandwidth
        let scale = min(self.maxDimension / CGFloat(display.width),
                        self.maxDimension / CGFloat(display.height))
        config.width = Int(CGFloat(display.width) * min(scale, 1.0))
        config.height = Int(CGFloat(display.height) * min(scale, 1.0))
        config.showsCursor = false
        config.captureResolution = .nominal

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Self.jpegData(from: image, quality: self.jpegQuality)
    }

    private static func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return Data() }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    // MARK: - Send

    /// Save screenshot to a stable path and notify the gateway with the file path.
    private func sendToGateway(_ imageData: Data) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openclaw-ambient")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Keep last 3 captures for context, rotate out old ones
        let path = dir.appendingPathComponent("screen-latest.jpg")
        try imageData.write(to: path)

        let app = AmbientContext.shared.currentApp ?? "unknown"
        let title = AmbientContext.shared.currentTitle

        var text = "[ambient-screenshot] Screen captured → \(path.path)"
        text += "\nUser is in: \(app)"
        if let title, !title.isEmpty {
            text += " — \"\(title)\""
        }

        try await ControlChannel.shared.sendSystemEvent(text, params: [
            "silent": AnyHashable(true),
            "kind": AnyHashable("ambient-screenshot"),
        ])
    }

    // MARK: - Permission

    private func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    enum CaptureError: Error {
        case noDisplays
    }
}
