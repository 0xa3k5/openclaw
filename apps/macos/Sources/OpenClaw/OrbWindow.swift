import AppKit
import Observation
import OpenClawChatUI
import SwiftUI

// MARK: - Drop state observable

@MainActor
@Observable
final class OrbDropState {
    static let shared = OrbDropState()
    var isDragHovering = false
}

// MARK: - Drop NSView wrapper

@MainActor
final class OrbDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard self.hasFileURLs(sender) else { return [] }
        OrbDropState.shared.isDragHovering = true
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        self.hasFileURLs(sender) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        _ = sender
        OrbDropState.shared.isDragHovering = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        OrbDropState.shared.isDragHovering = false
        guard let urls = self.extractFileURLs(sender), !urls.isEmpty else { return false }
        self.onDrop?(urls)
        return true
    }

    private func hasFileURLs(_ info: any NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])
    }

    private func extractFileURLs(_ info: any NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]
    }
}

// MARK: - Orb panel (accepts drags even as nonactivating)

final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - OrbWindowController

@MainActor
final class OrbWindowController {
    static let shared = OrbWindowController()

    private var panel: NSPanel?
    private let orbSize: CGFloat = 420
    private var moveObserver: NSObjectProtocol?

    var panelFrame: NSRect? {
        self.panel?.frame
    }

    func show() {
        guard self.panel == nil else {
            self.panel?.orderFrontRegardless()
            return
        }

        let panel = OrbPanel(
            contentRect: NSRect(x: 0, y: 0, width: self.orbSize, height: self.orbSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let orbView = OrbHostView(orbSize: self.orbSize)
        let hostView = NSHostingView(rootView: orbView)
        hostView.frame = panel.contentView?.bounds ?? .zero
        hostView.autoresizingMask = [.width, .height]

        // Drop view wraps the hosting view for drag-and-drop support
        let dropView = OrbDropView(frame: panel.contentView?.bounds ?? .zero)
        dropView.autoresizingMask = [.width, .height]
        dropView.onDrop = { urls in
            Task { @MainActor in
                // Open chat panel if not already visible
                let sessionKey = await WebChatManager.shared.preferredSessionKey()
                WebChatManager.shared.showPanel(sessionKey: sessionKey) {
                    OrbWindowController.shared.panelFrame
                }
                // Route files into the composer so the user sees thumbnails
                WebChatManager.shared.addAttachments(urls: urls)
            }
        }
        hostView.frame = dropView.bounds
        hostView.unregisterDraggedTypes()  // Prevent NSHostingView from intercepting drags
        dropView.addSubview(hostView)
        panel.contentView = dropView

        // Position top-right of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - self.orbSize - 40
            let y = screenFrame.maxY - self.orbSize - 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        self.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                WebChatManager.shared.repositionPanel {
                    self.panelFrame
                }
            }
        }
    }

    func hide() {
        if let observer = self.moveObserver {
            NotificationCenter.default.removeObserver(observer)
            self.moveObserver = nil
        }
        self.panel?.orderOut(nil)
    }

    func toggle() {
        if let panel, panel.isVisible {
            self.hide()
        } else {
            self.show()
        }
    }

    // MARK: - File drop handling

    private static func handleFileDrop(urls: [URL]) async {
        guard let result = await FileDropHandler.process(urls: urls) else { return }

        let sessionKey = await WebChatManager.shared.preferredSessionKey()
        let idempotencyKey = UUID().uuidString

        do {
            _ = try await GatewayConnection.shared.chatSend(
                sessionKey: sessionKey,
                message: result.message,
                thinking: "",
                idempotencyKey: idempotencyKey,
                attachments: result.attachments)
        } catch {
            print("[OrbDrop] Failed to send: \(error)")
        }
    }
}

/// SwiftUI host that observes WorkActivityStore and maps IconState to orb speed + state.
private struct OrbHostView: View {
    private let activityStore = WorkActivityStore.shared
    private let dropState = OrbDropState.shared
    @State private var isHovering = false
    let orbSize: CGFloat

    var body: some View {
        MetalOrbView(
            speed: self.orbSpeed,
            state: self.orbState,
            hoverBoost: self.isHovering ? 1.5 : 1.0,
            dropHighlight: self.dropState.isDragHovering ? 1.0 : 0.0
        )
        .frame(width: self.orbSize, height: self.orbSize)
        .scaleEffect(self.isHovering ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.3), value: self.isHovering)
        .contentShape(Circle())
        .onTapGesture {
            self.toggleChat()
        }
        .onHover { hovering in
            self.isHovering = hovering
        }
    }

    private var orbSpeed: Float {
        switch self.activityStore.iconState {
        case .idle:
            return 0.15
        case .workingMain(.job):
            return 0.6
        case .workingMain(.tool):
            return 0.8
        case .workingOther:
            return 0.4
        case .overridden:
            return 0.5
        }
    }

    private var orbState: Float {
        switch self.activityStore.iconState {
        case .idle:
            return 0        // idle
        case .workingMain(.job):
            return 1        // thinking
        case .workingMain(.tool):
            return 2        // talking
        case .workingOther:
            return 1        // thinking
        case .overridden:
            return 2        // talking
        }
    }

    private func toggleChat() {
        WebChatManager.shared.togglePanel(sessionKey: "main") {
            OrbWindowController.shared.panelFrame
        }
    }
}
