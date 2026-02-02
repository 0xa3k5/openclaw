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

        // Restore saved position or default to top-right
        if let savedX = UserDefaults.standard.object(forKey: "orbPositionX") as? CGFloat,
           let savedY = UserDefaults.standard.object(forKey: "orbPositionY") as? CGFloat {
            panel.setFrameOrigin(NSPoint(x: savedX, y: savedY))
        } else if let screen = NSScreen.main {
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
                // Persist position
                if let frame = self.panel?.frame {
                    UserDefaults.standard.set(frame.origin.x, forKey: "orbPositionX")
                    UserDefaults.standard.set(frame.origin.y, forKey: "orbPositionY")
                }
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

/// SwiftUI host that observes WorkActivityStore and maps IconState to face speed + state.
private struct OrbHostView: View {
    private let activityStore = WorkActivityStore.shared
    private let dropState = OrbDropState.shared
    private let nudgeStore = NudgeStore.shared
    @State private var isHovering = false
    @State private var presenceValue: Float = 1.0
    @State private var notificationValue: Float = 0
    @State private var isScreenAsleep = false
    @State private var presenceTimer: Timer?
    @State private var nudgeDecayTask: Task<Void, Never>?
    @State private var faceKind: FaceKind = FaceKind.current
    let orbSize: CGFloat

    // Common animation parameters
    private var faceSpeed: Float {
        self.nudgeStore.hasNudge ? max(self.orbSpeed, 0.5) : self.orbSpeed
    }

    private var faceState: Float { self.orbState }
    private var faceHoverBoost: Float { self.isHovering ? 1.2 : 1.0 }
    private var faceDropHighlight: Float { self.dropState.isDragHovering ? 1.0 : 0.0 }
    private var facePresence: Float { self.nudgeStore.hasNudge ? 1.0 : self.presenceValue }
    private var faceNotification: Float { self.notificationValue }

    var body: some View {
        self.activeFace
            .frame(width: self.orbSize, height: self.orbSize)
            .contentShape(Circle())
            .onTapGesture {
                self.nudgeStore.acknowledge()
                self.notificationValue = 0
                self.nudgeBounce = false
                self.toggleChat()
            }
            .contextMenu {
                ForEach(FaceKind.allCases) { kind in
                    Button {
                        self.faceKind = kind
                        FaceKind.current = kind
                    } label: {
                        HStack {
                            Text(kind.displayName)
                            if kind == self.faceKind {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .onHover { hovering in
                self.isHovering = hovering
            }
            .onAppear {
                self.startPresencePolling()
                self.observeScreenSleep()
            }
            .onDisappear {
                self.presenceTimer?.invalidate()
                self.nudgeDecayTask?.cancel()
            }
            .onChange(of: self.nudgeStore.hasNudge) { _, hasNudge in
                if hasNudge {
                    self.notificationValue = 1.0
                    self.nudgeBounce = true
                    self.nudgeDecayTask?.cancel()
                    self.nudgeDecayTask = Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run {
                            withAnimation(.easeOut(duration: 2.0)) {
                                self.notificationValue = 0.4
                            }
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.notificationValue = 0
                    }
                    self.nudgeBounce = false
                }
            }
    }

    @ViewBuilder
    private var activeFace: some View {
        switch self.faceKind {
        case .orb:
            MetalOrbView(
                speed: self.faceSpeed,
                state: self.faceState,
                hoverBoost: self.faceHoverBoost,
                dropHighlight: self.faceDropHighlight,
                presence: self.facePresence,
                notification: self.faceNotification
            )
            .scaleEffect(self.orbNudgeScale)
            .animation(.easeInOut(duration: 0.5), value: self.isHovering)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: self.nudgeBounce)

        case .lobster:
            LobsterFaceView(
                speed: self.faceSpeed,
                state: self.faceState,
                hoverBoost: self.faceHoverBoost,
                dropHighlight: self.faceDropHighlight,
                presence: self.facePresence,
                notification: self.faceNotification
            )
        }
    }

    @State private var nudgeBounce = false

    /// Scale effect only applies to the orb face.
    private var orbNudgeScale: CGFloat {
        if self.nudgeBounce {
            return 1.12
        } else if self.isHovering {
            return 1.08
        } else {
            return 1.0
        }
    }

    // MARK: - Presence

    private func startPresencePolling() {
        self.presenceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.updatePresence()
            }
        }
    }

    private func updatePresence() {
        if self.isScreenAsleep {
            self.presenceValue = 0.1
            return
        }
        guard let seconds = PresenceReporter.idleSeconds() else {
            self.presenceValue = 0.7
            return
        }
        if seconds < 30 {
            self.presenceValue = 1.0
        } else if seconds < 120 {
            self.presenceValue = 0.7
        } else if seconds < 300 {
            self.presenceValue = 0.4
        } else {
            self.presenceValue = 0.2
        }
    }

    private func observeScreenSleep() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.isScreenAsleep = true }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.isScreenAsleep = false }
        }
    }

    // MARK: - State Mapping

    private var orbSpeed: Float {
        switch self.activityStore.iconState {
        case .idle:
            return 0.15
        case .workingMain(.job):
            return 0.6
        case .workingMain(.tool(.bash)):
            return 0.7         // executing
        case .workingMain(.tool(.read)):
            return 0.4         // reading
        case .workingMain(.tool(.write)):
            return 0.6         // writing
        case .workingMain(.tool(.edit)):
            return 0.5         // editing
        case .workingMain(.tool(.attach)):
            return 0.45
        case .workingMain(.tool(.other)):
            return 0.6
        case .workingOther:
            return 0.4
        case .overridden:
            return 0.5
        }
    }

    private var orbState: Float {
        switch self.activityStore.iconState {
        case .idle:
            return 0           // calm blue/teal
        case .workingMain(.job):
            return 1.0         // thinking: violet/magenta
        case .workingMain(.tool(.bash)):
            return 2.0         // executing: hot orange
        case .workingMain(.tool(.read)):
            return 1.5         // reading: violet-orange blend
        case .workingMain(.tool(.write)):
            return 2.5         // writing: orange-green blend
        case .workingMain(.tool(.edit)):
            return 2.5         // editing: orange-green blend
        case .workingMain(.tool(.attach)):
            return 1.8         // attaching: transitional
        case .workingMain(.tool(.other)):
            return 2.0         // other tools: orange
        case .workingOther:
            return 1.0         // background work: thinking
        case .overridden:
            return 2.0
        }
    }

    private func toggleChat() {
        WebChatManager.shared.togglePanel(sessionKey: "main") {
            OrbWindowController.shared.panelFrame
        }
    }
}


