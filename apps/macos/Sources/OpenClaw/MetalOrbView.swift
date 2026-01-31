import MetalKit
import SwiftUI

@MainActor
struct MetalOrbView: NSViewRepresentable {
    let speed: Float
    let state: Float
    let hoverBoost: Float
    let dropHighlight: Float
    let presence: Float
    let notification: Float

    init(speed: Float, state: Float = 0, hoverBoost: Float = 1.0, dropHighlight: Float = 0, presence: Float = 1.0, notification: Float = 0) {
        self.speed = speed
        self.state = state
        self.hoverBoost = hoverBoost
        self.dropHighlight = dropHighlight
        self.presence = presence
        self.notification = notification
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear

        if let renderer = OrbMetalRenderer(mtkView: view) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
            renderer.targetParams = OrbAnimParams(
                speed: self.speed,
                state: self.state,
                hoverBoost: self.hoverBoost,
                dropHighlight: self.dropHighlight,
                presence: self.presence,
                notification: self.notification)
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.targetParams =
            OrbAnimParams(
                speed: self.speed,
                state: self.state,
                hoverBoost: self.hoverBoost,
                dropHighlight: self.dropHighlight,
                presence: self.presence,
                notification: self.notification)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var renderer: OrbMetalRenderer?
    }
}
