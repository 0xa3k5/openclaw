import SwiftUI

// MARK: - Lobster Face: Scuttler
// Wide low body, 8 rippling legs with knee joints, sideways scuttle, tail flip escape

struct LobsterFaceView: View {
    let speed: Float
    let state: Float
    let hoverBoost: Float
    let dropHighlight: Float
    let presence: Float
    let notification: Float

    @State private var tick: Double = 0
    @State private var blinkPhase: Bool = false
    @State private var timer: Timer?

    // State derivations
    private var isThinking: Bool { self.state >= 0.5 && self.state < 1.5 }
    private var isToolUse: Bool { self.state >= 1.5 && self.state < 2.5 }
    private var isStreaming: Bool { self.state >= 2.5 }
    private var isSleeping: Bool { self.presence < 0.3 }
    private var hasNudge: Bool { self.notification > 0.1 }

    // Warm lobster palette
    private let bodyRed = Color(red: 0.91, green: 0.27, blue: 0.19)
    private let bodyRedDark = Color(red: 0.80, green: 0.20, blue: 0.15)
    private let limbRed = Color(red: 0.72, green: 0.18, blue: 0.13)
    private let limbRedDark = Color(red: 0.60, green: 0.15, blue: 0.10)
    private let clawOrange = Color(red: 0.91, green: 0.42, blue: 0.13)
    private let clawOrangeDark = Color(red: 0.82, green: 0.35, blue: 0.09)
    private let bellyYellow = Color(red: 0.96, green: 0.78, blue: 0.29)

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let s = size / 200

            ZStack {
                // Legs behind body
                self.legs(s: s)
                // Body
                self.bodyShape(s: s)
                // Eyes
                self.eyes(s: s)
                // Claws
                self.claws(s: s)
                // Mouth
                self.mouth(s: s)
            }
            .frame(width: size, height: size)
            // Sideways scuttle (lobsters walk sideways!)
            .offset(x: self.scuttleOffsetX(s: s), y: self.verticalOffset(s: s))
            // Tail flip: quick rotation on nudge
            .rotationEffect(.degrees(self.bodyTilt))
        }
        .onAppear { self.startAnimation() }
        .onDisappear { self.timer?.invalidate() }
    }

    // MARK: - Locomotion

    /// Sideways scuttle offset (lobsters walk sideways)
    private func scuttleOffsetX(s: Double) -> Double {
        if self.isThinking { return sin(self.tick * 3) * 10 * s }
        if self.isStreaming { return sin(self.tick * 2) * 6 * s }
        return sin(self.tick * 0.3) * 1.5 * s
    }

    /// Vertical: tail flip jump on nudge, sink on sleep
    private func verticalOffset(s: Double) -> Double {
        if self.hasNudge { return sin(self.tick * 8) * 15 * s }
        if self.isSleeping { return 12 * s }
        return sin(self.tick * 0.8) * 1.5 * s
    }

    /// Body tilt: lean into scuttle direction, wobble on nudge
    private var bodyTilt: Double {
        if self.hasNudge { return sin(self.tick * 6) * 6 }
        if self.isThinking { return sin(self.tick * 3) * -3 } // lean opposite to movement
        if self.isToolUse { return 4 } // lean forward
        return sin(self.tick * 0.4) * 0.5
    }

    // MARK: - Body

    private func bodyShape(s: Double) -> some View {
        ZStack {
            // Wide low body
            RoundedRectangle(cornerRadius: 8 * s)
                .fill(
                    LinearGradient(
                        colors: [self.bodyRed, self.bodyRedDark],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 64 * s, height: 30 * s)
                .shadow(color: .black.opacity(0.12), radius: 4 * s, y: 3 * s)

            // Belly accent
            RoundedRectangle(cornerRadius: 4 * s)
                .fill(self.bellyYellow.opacity(0.18))
                .frame(width: 38 * s, height: 16 * s)
                .offset(y: 2 * s)
        }
    }

    // MARK: - Eyes

    private func eyes(s: Double) -> some View {
        HStack(spacing: 12 * s) {
            self.singleEye(s: s)
            self.singleEye(s: s)
        }
        .offset(y: -22 * s)
    }

    private func singleEye(s: Double) -> some View {
        VStack(spacing: 0) {
            ZStack {
                // Eye housing
                RoundedRectangle(cornerRadius: 4 * s)
                    .fill(
                        LinearGradient(
                            colors: [self.bodyRed, self.bodyRedDark],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 14 * s, height: 15 * s)

                // White
                Ellipse()
                    .fill(.white)
                    .frame(width: 10 * s, height: 11 * s)

                // Pupil
                Ellipse()
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.18))
                    .frame(
                        width: 6 * s,
                        height: self.blinkPhase || self.isSleeping ? 1 * s : 7 * s
                    )
                    .offset(x: self.pupilOffsetX * s)
                    .animation(.easeInOut(duration: 0.08), value: self.blinkPhase)

                // Shine
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 3 * s, height: 3 * s)
                    .offset(x: -2 * s, y: -2 * s)
            }

            // Stalk
            RoundedRectangle(cornerRadius: 2 * s)
                .fill(self.limbRed)
                .frame(width: 5 * s, height: 8 * s)
        }
    }

    /// Pupils track scuttle direction
    private var pupilOffsetX: Double {
        if self.isThinking { return sin(self.tick * 3) * 2 } // look where scuttling
        if self.isStreaming { return sin(self.tick * 2) * 1.5 }
        if self.isToolUse { return 0 } // focused forward
        return 0
    }

    // MARK: - Claws

    private func claws(s: Double) -> some View {
        HStack(spacing: 58 * s) {
            self.singleClaw(s: s, side: -1)
            self.singleClaw(s: s, side: 1)
        }
        .offset(y: -4 * s)
    }

    private func singleClaw(s: Double, side: Double) -> some View {
        VStack(spacing: 0) {
            ZStack {
                // Top pincer
                RoundedRectangle(cornerRadius: 3 * s)
                    .fill(self.clawOrange)
                    .frame(width: 14 * s, height: 9 * s)
                    .offset(y: -3 * s)
                    .rotationEffect(
                        .degrees(self.clawOpenAngle * (side < 0 ? -0.4 : 0.4)),
                        anchor: side < 0 ? .bottomTrailing : .bottomLeading
                    )

                // Bottom pincer
                RoundedRectangle(cornerRadius: 2 * s)
                    .fill(self.clawOrangeDark)
                    .frame(width: 12 * s, height: 7 * s)
                    .offset(y: 3 * s)
                    .rotationEffect(
                        .degrees(-self.clawOpenAngle * (side < 0 ? -0.25 : 0.25)),
                        anchor: side < 0 ? .topTrailing : .topLeading
                    )
            }

            // Arm
            RoundedRectangle(cornerRadius: 2 * s)
                .fill(self.limbRed)
                .frame(width: 6 * s, height: 14 * s)
        }
        .rotationEffect(.degrees(self.armAngle(side: side)))
    }

    private func armAngle(side: Double) -> Double {
        let base = side * -25
        if self.hasNudge { return base + sin(self.tick * 5 + side * 2) * 20 }
        if self.isToolUse { return base + sin(self.tick * 5) * 15 } // snapping
        if self.isThinking { return base + sin(self.tick * 1.5 + side) * 6 }
        return base + sin(self.tick * 0.6 + side) * 2
    }

    private var clawOpenAngle: Double {
        if self.isToolUse { return abs(sin(self.tick * 6)) * 22 }
        if self.hasNudge { return abs(sin(self.tick * 4)) * 16 }
        return 5 + sin(self.tick * 0.8) * 3
    }

    // MARK: - Mouth

    private func mouth(s: Double) -> some View {
        Capsule()
            .fill(self.limbRedDark)
            .frame(width: self.mouthWidth(s: s), height: 2 * s)
            .offset(y: 8 * s)
    }

    private func mouthWidth(s: Double) -> Double {
        if self.isStreaming { return (14 + sin(self.tick * 4) * 3) * s }
        if self.hasNudge { return 18 * s }
        return 12 * s
    }

    // MARK: - Legs (8 total, 4 per side, rippling with knee joints)

    private func legs(s: Double) -> some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                self.singleLeg(s: s, index: i)
            }
        }
    }

    private func singleLeg(s: Double, index: Int) -> some View {
        let side: Double = index < 4 ? -1 : 1
        let legIndex = index < 4 ? index : index - 4
        let spread: Double = 18 + Double(legIndex) * 10

        // Ripple phase: each leg has offset timing for wave-like walk
        let phase = self.tick * 4 + Double(legIndex) * 0.8 + (side > 0 ? Double.pi : 0)
        let step = self.isSleeping ? 0.0 : sin(phase) * 6

        let baseAngle = side * (15 + Double(legIndex) * 5) + step

        return LegShape(
            s: s,
            baseAngle: baseAngle,
            sideSign: side,
            limbColor: self.limbRed,
            footColor: self.limbRedDark
        )
        .offset(x: side * spread * s, y: 12 * s)
    }

    // MARK: - Animation Timer

    private func startAnimation() {
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                self.tick += 1.0 / 30.0
                // Blink every ~3.5s
                if Int(self.tick * 10) % 35 == 0 && !self.blinkPhase {
                    self.blinkPhase = true
                    Task {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        await MainActor.run { self.blinkPhase = false }
                    }
                }
            }
        }
    }
}

// MARK: - Leg Shape (upper + knee + lower + foot tip)

private struct LegShape: View {
    let s: Double
    let baseAngle: Double
    let sideSign: Double
    let limbColor: Color
    let footColor: Color

    var body: some View {
        VStack(spacing: 0) {
            // Upper leg
            RoundedRectangle(cornerRadius: 1.5 * self.s)
                .fill(self.limbColor)
                .frame(width: 4 * self.s, height: 12 * self.s)

            // Knee + lower leg
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5 * self.s)
                    .fill(self.footColor)
                    .frame(width: 3.5 * self.s, height: 10 * self.s)

                // Foot tip
                Circle()
                    .fill(self.footColor)
                    .frame(width: 3 * self.s, height: 3 * self.s)
            }
            .rotationEffect(.degrees(self.sideSign * 25))
        }
        .rotationEffect(.degrees(self.baseAngle))
    }
}
