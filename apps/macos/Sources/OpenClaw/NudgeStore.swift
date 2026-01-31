import Foundation
import Observation

/// Tracks pending "nudge" state: the agent said something while the user isn't looking.
///
/// When a chat message arrives and the chat panel is hidden, we light up the orb
/// and optionally show a preview bubble. The nudge clears when the user opens chat.
@MainActor
@Observable
final class NudgeStore {
    static let shared = NudgeStore()

    /// Whether the orb should show the notification animation.
    private(set) var hasNudge: Bool = false

    /// Short preview of what the agent said.
    private(set) var previewText: String?

    /// When the nudge started (for animation pacing).
    private(set) var nudgeStartedAt: Date?

    /// Session key of the nudge source.
    private(set) var sessionKey: String?

    /// Number of unread nudges stacked up.
    private(set) var count: Int = 0

    // MARK: - API

    /// Called when the agent sends a message and the chat panel is hidden.
    func push(preview: String?, sessionKey: String?) {
        self.count += 1
        self.hasNudge = true
        self.sessionKey = sessionKey
        self.nudgeStartedAt = self.nudgeStartedAt ?? Date()

        if let preview, !preview.isEmpty {
            // Take the first meaningful line, capped at 80 chars.
            let firstLine = preview
                .components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                ?? preview
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            self.previewText = trimmed.count > 80
                ? String(trimmed.prefix(77)) + "..."
                : trimmed
        }
    }

    /// Called when the user opens chat or otherwise acknowledges the nudge.
    func acknowledge() {
        self.hasNudge = false
        self.previewText = nil
        self.nudgeStartedAt = nil
        self.sessionKey = nil
        self.count = 0
    }
}
