import MetalKit
import simd

// MARK: - Uniforms

struct OrbUniforms {
    var time: Float = 0
    var speed: Float = 1.0
    var state: Float = 0
    var dropHighlight: Float = 0
    var presence: Float = 1.0
    var notification: Float = 0
    var resolution: SIMD2<Float> = .zero
}

// MARK: - Animation Parameters

struct OrbAnimParams: Sendable {
    var speed: Float = 1.0
    var state: Float = 0
    var hoverBoost: Float = 1.0
    var dropHighlight: Float = 0
    var presence: Float = 1.0
    var notification: Float = 0

    mutating func lerp(toward t: OrbAnimParams, factor f: Float) {
        // Adaptive lerp: faster for active transitions
        let activeFactor = t.speed > speed ? min(f * 1.8, 0.2) : f
        speed         += (t.speed - speed) * activeFactor
        state         += (t.state - state) * activeFactor
        hoverBoost    += (t.hoverBoost - hoverBoost) * (f * 0.4)  // slow ease for hover
        dropHighlight += (t.dropHighlight - dropHighlight) * f
        presence      += (t.presence - presence) * (f * 0.5)  // slow fade for presence
        notification  += (t.notification - notification) * (f * 2.0)  // fast for notifications
    }
}

// MARK: - Metal Renderer

@MainActor
class OrbMetalRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let startTime: CFAbsoluteTime

    var targetParams = OrbAnimParams()
    private var currentParams = OrbAnimParams()
    private var uniforms = OrbUniforms()

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        self.device = device
        self.commandQueue = queue
        self.startTime = CFAbsoluteTimeGetCurrent()

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.preferredFramesPerSecond = 60
        if let layer = mtkView.layer {
            layer.isOpaque = false
            layer.backgroundColor = .clear
        }

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else {
            print("[OrbMetal] Failed to compile shader")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "orbVertex")
        desc.fragmentFunction = library.makeFunction(name: "orbFragment")

        let attach = desc.colorAttachments[0]!
        attach.pixelFormat = mtkView.colorPixelFormat
        attach.isBlendingEnabled = true
        attach.sourceRGBBlendFactor = .sourceAlpha
        attach.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attach.sourceAlphaBlendFactor = .sourceAlpha
        attach.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            print("[OrbMetal] Failed to create pipeline")
            return nil
        }
        self.pipelineState = pipeline

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        uniforms.resolution = SIMD2<Float>(Float(size.width), Float(size.height))
    }

    func draw(in view: MTKView) {
        currentParams.lerp(toward: targetParams, factor: 0.08)

        uniforms.time = Float(CFAbsoluteTimeGetCurrent() - startTime)
        uniforms.speed = currentParams.speed * currentParams.hoverBoost
        uniforms.state = currentParams.state
        uniforms.dropHighlight = currentParams.dropHighlight
        uniforms.presence = currentParams.presence
        uniforms.notification = currentParams.notification
        uniforms.resolution = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))

        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor else { return }

        passDesc.colorAttachments[0].loadAction = .clear

        guard let buf = commandQueue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        buf.present(drawable)
        buf.commit()
    }

    // MARK: - Shader Source — Aurora Curtain

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct OrbUniforms {
        float time;
        float speed;
        float state;
        float dropHighlight;
        float presence;
        float notification;
        float2 resolution;
    };

    // ---- Simplex noise ----

    float3 mod289(float3 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
    float4 mod289(float4 x) { return x - floor(x * (1.0/289.0)) * 289.0; }
    float4 permute(float4 x) { return mod289(((x * 34.0) + 10.0) * x); }

    float snoise(float3 v) {
        const float2 C = float2(1.0/6.0, 1.0/3.0);
        const float4 D = float4(0.0, 0.5, 1.0, 2.0);

        float3 i = floor(v + dot(v, C.yyy));
        float3 x0 = v - i + dot(i, C.xxx);

        float3 g = step(x0.yzx, x0.xyz);
        float3 l = 1.0 - g;
        float3 i1 = min(g.xyz, l.zxy);
        float3 i2 = max(g.xyz, l.zxy);

        float3 x1 = x0 - i1 + C.xxx;
        float3 x2 = x0 - i2 + C.yyy;
        float3 x3 = x0 - D.yyy;

        i = mod289(i);
        float4 p = permute(permute(permute(
            i.z + float4(0.0, i1.z, i2.z, 1.0))
          + i.y + float4(0.0, i1.y, i2.y, 1.0))
          + i.x + float4(0.0, i1.x, i2.x, 1.0));

        float n_ = 0.142857142857;
        float3 ns = n_ * D.wyz - D.xzx;

        float4 j = p - 49.0 * floor(p * ns.z * ns.z);
        float4 x_ = floor(j * ns.z);
        float4 y_ = floor(j - 7.0 * x_);

        float4 x = x_ * ns.x + ns.yyyy;
        float4 y = y_ * ns.x + ns.yyyy;
        float4 h = 1.0 - abs(x) - abs(y);

        float4 b0 = float4(x.xy, y.xy);
        float4 b1 = float4(x.zw, y.zw);

        float4 s0 = floor(b0) * 2.0 + 1.0;
        float4 s1 = floor(b1) * 2.0 + 1.0;
        float4 sh = -step(h, float4(0.0));

        float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
        float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;

        float3 p0 = float3(a0.xy, h.x);
        float3 p1 = float3(a0.zw, h.y);
        float3 p2 = float3(a1.xy, h.z);
        float3 p3 = float3(a1.zw, h.w);

        float4 norm = 1.79284291400159 - 0.85373472095314 *
            float4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3));
        p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;

        float4 m = max(0.6 - float4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
        m = m * m;
        return 42.0 * dot(m*m, float4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
    }

    // ---- Vertex ----

    vertex VertexOut orbVertex(uint vid [[vertex_id]]) {
        VertexOut out;
        float2 pos = float2((vid << 1) & 2, vid & 2);
        out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(pos.x, 1.0 - pos.y);
        return out;
    }

    // ---- Fragment: Aurora Curtain (state-driven, presence-aware) ----

    fragment float4 orbFragment(VertexOut in [[stage_in]],
                                constant OrbUniforms &u [[buffer(0)]]) {
        float2 uv = in.uv * 2.0 - 1.0;
        float t = u.time * u.speed;
        float st = u.state;
        float pres = u.presence;
        float notif = u.notification;

        float dist = length(uv);
        float angle = atan2(uv.y, uv.x);

        // --- State weights ---
        float wIdle   = 1.0 - clamp(st, 0.0, 1.0);
        float wThink  = clamp(st, 0.0, 1.0) * (1.0 - clamp(st - 1.0, 0.0, 1.0));
        float wTalk   = clamp(st - 1.0, 0.0, 1.0) * (1.0 - clamp(st - 2.0, 0.0, 1.0));
        float wListen = clamp(st - 2.0, 0.0, 1.0);

        // --- State-driven radius modulation ---
        float radiusMod = 0.0;
        radiusMod += wThink * sin(t * 2.5) * 0.04;
        radiusMod += wThink * sin(t * 3.8 + 1.3) * 0.025;
        radiusMod += wTalk * sin(t * 4.5) * 0.035;
        radiusMod += wTalk * snoise(float3(angle * 3.0, t * 0.5, 0.0)) * 0.045;
        radiusMod += wListen * sin(t * 1.5) * 0.045;
        // Notification: rhythmic pulse + shape wobble
        radiusMod += notif * sin(u.time * 5.0) * 0.06;
        radiusMod += notif * sin(u.time * 3.2 + 0.7) * 0.03;

        // --- Organic orb shape (two octaves for more life) ---
        // Notification adds extra shape turbulence (the orb gets "excited")
        float shapeSpeed = 0.06 + notif * 0.15;
        float shapeAmp = 0.12 + notif * 0.06;
        float shapeN = snoise(float3(uv * 1.8, t * shapeSpeed)) * shapeAmp;
        shapeN += snoise(float3(uv * 0.7 + 15.0, t * 0.035)) * 0.07;
        shapeN += snoise(float3(uv * 3.5 + 30.0, t * 0.08)) * 0.04;
        // Notification: angular distortion makes the shape less round
        shapeN += notif * snoise(float3(angle * 4.0, t * 0.3, 5.0)) * 0.08;
        float dd = dist + shapeN;

        // Breathing: visible in idle, subtle otherwise
        float breathe = sin(u.time * 0.15) * 0.03 * wIdle
                       + sin(u.time * 0.3) * 0.015 * (1.0 - wIdle);
        float orbR = 0.50 + breathe + radiusMod;
        float nd = dd / orbR;

        // Soft feathered edge (multi-layer falloff, not a hard line)
        float maskInner = 1.0 - smoothstep(0.2, 0.85, nd);
        float maskOuter = 1.0 - smoothstep(0.7, 1.15, nd);
        float mask = maskInner * 0.7 + maskOuter * 0.3;

        // --- Color palettes ---
        float3 iC1 = float3(0.18, 0.50, 0.98);
        float3 iC2 = float3(0.00, 0.79, 0.65);
        float3 iC3 = float3(0.30, 0.20, 0.70);
        float3 iC4 = float3(0.10, 0.60, 0.90);
        float3 iC5 = float3(0.15, 0.75, 0.55);
        float3 iC6 = float3(0.10, 0.85, 0.90);

        float3 tC1 = float3(0.70, 0.10, 0.95);
        float3 tC2 = float3(0.90, 0.15, 0.70);
        float3 tC3 = float3(0.50, 0.05, 1.00);
        float3 tC4 = float3(0.80, 0.20, 0.90);
        float3 tC5 = float3(0.40, 0.00, 0.80);
        float3 tC6 = float3(0.95, 0.10, 0.60);

        float3 kC1 = float3(1.00, 0.40, 0.05);
        float3 kC2 = float3(1.00, 0.15, 0.45);
        float3 kC3 = float3(1.00, 0.70, 0.00);
        float3 kC4 = float3(1.00, 0.20, 0.30);
        float3 kC5 = float3(1.00, 0.55, 0.10);
        float3 kC6 = float3(0.95, 0.30, 0.50);

        float3 lC1 = float3(0.00, 1.00, 0.55);
        float3 lC2 = float3(0.00, 0.85, 0.95);
        float3 lC3 = float3(0.10, 1.00, 0.35);
        float3 lC4 = float3(0.00, 0.90, 0.75);
        float3 lC5 = float3(0.20, 1.00, 0.45);
        float3 lC6 = float3(0.00, 0.80, 1.00);

        float3 c1 = iC1*wIdle + tC1*wThink + kC1*wTalk + lC1*wListen;
        float3 c2 = iC2*wIdle + tC2*wThink + kC2*wTalk + lC2*wListen;
        float3 c3 = iC3*wIdle + tC3*wThink + kC3*wTalk + lC3*wListen;
        float3 c4 = iC4*wIdle + tC4*wThink + kC4*wTalk + lC4*wListen;
        float3 c5 = iC5*wIdle + tC5*wThink + kC5*wTalk + lC5*wListen;
        float3 c6 = iC6*wIdle + tC6*wThink + kC6*wTalk + lC6*wListen;

        float3 glowA = mix(mix(iC1, tC1, wThink), kC1, wTalk);
        glowA = mix(glowA, lC1, wListen);
        float3 glowB = mix(mix(iC2, tC2, wThink), kC2, wTalk);
        glowB = mix(glowB, lC2, wListen);

        // --- Outer glow (outside orb) ---
        if (mask < 0.001) {
            float g1 = exp(-dist * 2.5) * 0.14;
            float g2 = exp(-dist * 4.5) * 0.08;
            float a = snoise(float3(angle, dist * 2.0, t * 0.03));
            float3 gc = mix(glowA, glowB, a * 0.5 + 0.5);
            gc += float3(0.3, 0.7, 1.0) * u.dropHighlight * exp(-dist * 3.0) * 0.15;
            // Notification: bright ring pulse
            gc += mix(c1, float3(1.0), 0.5) * notif * exp(-dist * 4.0) * 0.2
                * (0.5 + 0.5 * sin(u.time * 6.0));
            float totalG = g1 + g2;
            // Presence dimming on outer glow
            float presBright = mix(0.1, 1.0, pres);
            float ga = totalG * 0.5 * presBright;
            return float4(gc * totalG * presBright, ga);
        }

        // --- Aurora curtain folds ---
        float yw = uv.y;
        float foldSpeed = mix(1.0, 1.6, wTalk);
        yw += snoise(float3(uv.x * 2.5, t * 0.09 * foldSpeed, 0.0)) * 0.20;
        yw += snoise(float3(uv.x * 4.0 + 20.0, t * 0.07 * foldSpeed, 5.0)) * 0.12;
        yw += snoise(float3(uv.x * 1.2 + 40.0, t * 0.04 * foldSpeed, 10.0)) * 0.14;

        // Color bands
        float b1 = exp(-pow((yw - 0.15) * 4.5, 2.0));
        float b2 = exp(-pow((yw + 0.05) * 3.8, 2.0));
        float b3 = exp(-pow((yw - 0.30) * 5.5, 2.0));
        float b4 = exp(-pow((yw + 0.22) * 4.5, 2.0));
        float b5 = exp(-pow((yw + 0.35) * 5.0, 2.0));
        float b6 = exp(-pow((yw - 0.02) * 6.0, 2.0));

        float shift = t * 0.02;
        float3 col = c1 * b1 * (1.0 + sin(shift) * 0.3)
                   + c2 * b2 * (1.0 + sin(shift + 1.5) * 0.3)
                   + c3 * b3 * (1.0 + sin(shift + 3.0) * 0.3)
                   + c4 * b4 * (1.0 + sin(shift + 4.5) * 0.3)
                   + c5 * b5 * (1.0 + sin(shift + 2.0) * 0.25)
                   + c6 * b6 * (1.0 + sin(shift + 5.5) * 0.2);

        // Notification: warm golden color shift (overrides, not just tints)
        float3 nudgeWarm = float3(1.0, 0.65, 0.15);
        float nudgePulse = 0.5 + 0.5 * sin(u.time * 3.0);
        col = mix(col, nudgeWarm * (0.8 + nudgePulse * 0.4), notif * 0.7);

        // Intensity per state
        float intensity = 1.0;
        intensity = mix(intensity, 0.8, wIdle);
        intensity = mix(intensity, 1.4, wTalk);
        intensity = mix(intensity, 1.2, wThink);
        intensity = mix(intensity, 1.1, wListen);
        intensity += notif * 0.3; // brighter when nudging
        col *= intensity;

        // Shimmer
        float shimmer = snoise(float3(uv * 4.0, t * 0.1)) * 0.12 + 0.88;
        col *= shimmer;

        // Core glow
        float coreStr = 0.5 + wTalk * 0.2 + notif * 0.3;
        float core = exp(-nd * nd * 2.2) * coreStr;
        col += mix(c1, float3(1.0), 0.6) * core;

        // Inner luminance for depth
        float innerGlow = exp(-nd * nd * 5.0) * 0.18;
        col += float3(1.0) * innerGlow;

        // Base fill
        float fill = 0.08 * (1.0 - nd * 0.5);
        col += mix(c3, c1, nd) * fill;

        // Edge bloom (soft colored rim)
        float eb = smoothstep(0.55, 0.9, nd) * smoothstep(1.15, 0.85, nd);
        float3 ebCol = mix(c2, c4, sin(angle + t * 0.1) * 0.5 + 0.5);
        col += ebCol * eb * 0.3;

        // Drop highlight
        col += float3(0.25, 0.5, 0.8) * u.dropHighlight * 0.3 * (1.0 - nd * 0.6);

        // Notification: additive flash on entire orb
        col += mix(c1, float3(1.0, 0.9, 0.8), 0.6) * notif * 0.25
             * (0.5 + 0.5 * sin(u.time * 6.0));

        // --- Presence dimming (the whole point) ---
        float presBright = mix(0.15, 1.0, pres);
        col *= presBright;

        float alpha = mask * max(0.3, length(col) * 0.85);
        alpha = clamp(alpha, 0.0, 1.0);

        // Outer glow contribution
        float glow = exp(-dist * 2.2) * 0.12;
        float glowTight = exp(-dist * 5.0) * 0.06;
        col += mix(glowA, glowB, 0.5) * (glow + glowTight) * presBright;
        alpha = clamp(alpha + (glow + glowTight) * 0.5 * presBright, 0.0, 1.0);

        // Final presence alpha fade
        alpha *= mix(0.3, 1.0, pres);

        return clamp(float4(col * alpha, alpha), 0.0, 1.0);
    }
    """
}
