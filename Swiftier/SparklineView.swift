import SwiftUI
import AppKit
import QuartzCore

// MARK: - 高性能 Sparkline (Phase-Synced Scanner)
// 终极修复：相位对齐 (Phase Synchronization)
// 1. 问题：用户打开窗口的时间点是随机的，而数据更新是每秒一次固定的。
//    这导致了随机的等待时长（0~1秒）。
// 2. 方案：View 在初始化时，主动询问 Runner "距离上次更新过去了多久 (elapsed)？"
//    如果 elapsed = 0.6秒，说明当前的 1.0s 动画其实应该已经播放到 60% 了。
//    我们直接设置 `scrollLayer` 的初始位置为 `startX - stepX * 0.6`。
//    并让接下来的动画只播放剩下的 0.4s。
// 3. 结果：无论何时打开窗口，波形都处于它"本该在"的位置，看起来就像它一直在后台默默流淌，没有任何顿挫。

struct SparklineView: NSViewRepresentable {
    let data: [Double]
    let color: Color
    let maxScale: Double
    let paused: Bool
    
    func makeNSView(context: Context) -> SparklineNSView {
        let view = SparklineNSView()
        view.color = NSColor(color)
        return view
    }
    
    func updateNSView(_ nsView: SparklineNSView, context: Context) {
        nsView.color = NSColor(color)
        nsView.maxScale = maxScale
        nsView.isPaused = paused
        nsView.cachedData = data
        if nsView.frame.width > 0 {
            nsView.updateData(data)
        } else {
            nsView.needsLayout = true
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        init() {
            // Register as subscriber when view is actively instantiated (and likely to appear)
            // But better done in onAppear.
        }
        deinit {
            // Safety cleanup just in case
            // DispatchQueue.main.async { SwiftierRunner.shared.removeSubscriber() }
        }
    }
}

extension SparklineView {
    // SwiftUI View Modifier wrapper to handle lifecycle
    // Actually, NSViewRepresentable does not have body.
    // We should rely on the PARENT view to add these modifiers or wrap this in a View.
    // However, we can hack it by invoking side effects in updateNSView? No, that's bad.
    // Best practice: The container (ConfigGeneratorView or PeerCard list) applies the logic.
    // OR: We wrap this struct in a View.
}

// Wrapper to handle Lifecycle comfortably
struct SmartSparklineView: View {
    let data: [Double]
    let color: Color
    let maxScale: Double
    let paused: Bool
    
    var body: some View {
        SparklineView(data: data, color: color, maxScale: maxScale, paused: paused)
            .onAppear { SwiftierRunner.shared.addSubscriber() }
            .onDisappear { SwiftierRunner.shared.removeSubscriber() }
    }
}

final class SparklineNSView: NSView {
    var color: NSColor = .systemBlue {
        didSet { if oldValue != color { updateColors() } }
    }
    var maxScale: Double = 1_048_576.0
    var isPaused: Bool = false {
        didSet { updatePause() }
    }
    var cachedData: [Double] = []
    
    // Layers
    private let rootLayer = CALayer()
    private let scrollLayer = CALayer()
    private let lineLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let gradientLayer = CAGradientLayer()
    private let viewportMask = CAShapeLayer()
    
    private let pulseContainer = CALayer()
    private let haloLayer = CAShapeLayer()
    private let dotLayer = CALayer()
    
    private let rightPad: CGFloat = 12.0
    private let strokeWidth: CGFloat = 2.5
    private let topPad: CGFloat = 8.0
    private let cornerRadius: CGFloat = 12.0
    private let animationDuration: CFTimeInterval = 1.0
    
    // State
    private var prevLastValue: Double? = nil
    private var leftOutBuffer: Double? = nil
    private var lastDataSnapshot: [Double] = []
    
    
    // Scale Smoothing State
    private var currentRenderScale: Double = 100.0
    
    // Phase Sync State
    private var isFirstPhase: Bool = true
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(rootLayer)
        
        let maskedContainer = CALayer()
        maskedContainer.mask = viewportMask
        rootLayer.addSublayer(maskedContainer)
        maskedContainer.addSublayer(scrollLayer)
        
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradientLayer.endPoint   = CGPoint(x: 0.5, y: 1.0)
        gradientLayer.mask = fillLayer
        scrollLayer.addSublayer(gradientLayer)
        
        lineLayer.fillColor = nil
        lineLayer.lineWidth = strokeWidth
        lineLayer.lineCap = .round
        lineLayer.lineJoin = .round
        lineLayer.zPosition = 10
        scrollLayer.addSublayer(lineLayer)
        
        pulseContainer.zPosition = 100
        rootLayer.addSublayer(pulseContainer)
        
        haloLayer.fillColor = nil
        haloLayer.lineWidth = 0.6
        let haloSize: CGFloat = 12
        haloLayer.bounds = CGRect(x: 0, y: 0, width: haloSize, height: haloSize)
        haloLayer.path = CGPath(ellipseIn: haloLayer.bounds, transform: nil)
        haloLayer.position = .zero
        pulseContainer.addSublayer(haloLayer)
        
        dotLayer.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        dotLayer.cornerRadius = 6.0
        dotLayer.borderWidth = 2.0
        dotLayer.borderColor = NSColor.white.cgColor
        dotLayer.position = .zero
        pulseContainer.addSublayer(dotLayer)
        
        dotLayer.borderColor = NSColor.white.cgColor
        dotLayer.position = .zero
        pulseContainer.addSublayer(dotLayer)
        
        // Removed auto-start halo. Now triggered by data.
        updateColors()
    }
    
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = bounds
        
        let w = bounds.width
        let h = bounds.height
        
        let maskRect = CGRect(x: 0, y: 0, width: w - rightPad, height: h)
        let maskPath = CGPath(roundedRect: maskRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        viewportMask.path = maskPath
        
        if let container = rootLayer.sublayers?.first(where: { $0.mask == viewportMask }) {
            container.frame = bounds
        }
        scrollLayer.frame = bounds
        gradientLayer.frame = bounds
        lineLayer.frame = bounds
        fillLayer.frame = bounds
        CATransaction.commit()
        
        if !cachedData.isEmpty && bounds.width > rightPad {
            // Speculative Animation: Kickstart immediately with old data.
            // isLayoutPass: false -> Forces animation to run instead of snapping.
            // This is safe because 'Over-Run Strategy' handles phase mismatch gracefully.
            updateData(cachedData, isLayoutPass: false)
        }
    }
    
    private func triggerHaloPulse() {
        // Sync Pulse: Fire a one-shot animation when data updates.
        // This ensures the visual beat matches the data beat.
        haloLayer.removeAllAnimations()
        
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 3.5 // Slightly larger for impact
        
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.8 // Start brighter
        opacityAnim.toValue = 0.0
        
        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = 1.0 // Exact 1s match
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // No repeat count needed
        
        haloLayer.add(group, forKey: "pulse")
    }
    
    private func updatePause() { }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.strokeColor = color.cgColor
        
        let colors = [
            color.withAlphaComponent(0.0).cgColor,
            color.withAlphaComponent(0.35).cgColor
        ]
        gradientLayer.colors = colors
        
        haloLayer.strokeColor = color.withAlphaComponent(0.6).cgColor
        dotLayer.backgroundColor = color.cgColor
        CATransaction.commit()
    }
    
    // Peak Hold State
    private var scaleHoldCounter: Int = 0
    private let scaleHoldFrames = 5 // approx 5 seconds
    
    func updateData(_ newData: [Double], isLayoutPass: Bool = false) {
        guard !isPaused, newData.count > 1 else { return }
        
        // --- Smart Scale Smoothing (Peak Follower) ---
        // 1. Calculate Target Scale (Global Max of current data)
        let dataMax = newData.max() ?? 1024.0
        let targetScale = max(maxScale, dataMax, 1024.0)
        
        // 2. Apply Smoothing
        if isLayoutPass || prevLastValue == nil {
            currentRenderScale = targetScale
        } else {
            let diff = targetScale - currentRenderScale
            
            if diff > 0 {
                // Case A: Expansion (Traffic Spike)
                // We must adapt quickly to show the spike, but smooth it out to avoid a "hard jump".
                // Factor 0.3 means it takes ~0.5s to catch up 80%.
                // A bit of clipping at the very top for a split second is acceptable for smoothness.
                currentRenderScale += diff * 0.3
                scaleHoldCounter = 0 // Reset hold timer
            } else {
                // Case B: Contraction (Traffic Drop)
                // Don't zoom in immediately! This causes the "bouncing" effect.
                // Hold the peak scale for a while.
                if scaleHoldCounter < scaleHoldFrames {
                    scaleHoldCounter += 1
                    // Keep current scale (Hold)
                } else {
                    // Slow Decay: Gently zoom back in to show details of low traffic.
                    // Factor 0.05 is very slow.
                    currentRenderScale += diff * 0.05
                }
            }
        }
        
        // --- Buffer Phase ---
        if !lastDataSnapshot.isEmpty {
            leftOutBuffer = lastDataSnapshot.first
        }
        if !isLayoutPass {
            lastDataSnapshot = newData
        }
        
        // Calculate Step
        let w = bounds.width
        let h = bounds.height
        if w <= rightPad { return }
        let innerRightX = w - rightPad
        
        // Fix StepX Stability
        let maxPoints = 20
        let effectiveDivisor = CGFloat(max(maxPoints, newData.count) - 1)
        let stepX = innerRightX / effectiveDivisor
        
        // Calculate Points (Using SMOOTHED Scale)
        let points = calculatePoints(data: newData, stepX: stepX, height: h, scale: currentRenderScale)
        if points.count < 2 { return }
        let p_N     = points.last!
        let p_N_1   = points[points.count - 2]
        
        // --- Path Construction (Standard, No Morphing) ---
        let drawShift = stepX
        let path = CGMutablePath()
        let fill = CGMutablePath()
        
        // Always calculate bufferY with CURRENT scale to ensure connection
        let bufferVal = leftOutBuffer ?? newData.first!
        let bufferY = calculateY(val: bufferVal, height: h, scale: currentRenderScale)
        let bufferP = CGPoint(x: 0, y: bufferY)
        
        path.move(to: bufferP)
        fill.move(to: bufferP)
        
        for p in points {
            let shifted = CGPoint(x: p.x + drawShift, y: p.y)
            path.addLine(to: shifted)
            fill.addLine(to: shifted)
        }
        
        if let last = points.last {
            let shiftedLastX = last.x + drawShift
            fill.addLine(to: CGPoint(x: shiftedLastX, y: 0))
            fill.addLine(to: CGPoint(x: 0, y: 0))
            fill.closeSubpath()
        }
        
        // --- PHASE SYNC LOGIC ---
        var catchUpProgress: Double = 0.0
        var remainingDuration: Double = animationDuration
        
        let isFirstRealUpdate = (prevLastValue == nil) && !isLayoutPass
        
        if isFirstRealUpdate {
            let lastTime = SwiftierRunner.shared.lastDataTime
            let now = Date()
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed >= 0 && elapsed < animationDuration {
                catchUpProgress = elapsed / animationDuration
                remainingDuration = animationDuration - elapsed
            }
            prevLastValue = newData.last
        } else if !isLayoutPass {
            prevLastValue = newData.last
        }
        
        // START ANIMATION
        
        if isLayoutPass {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lineLayer.path = path
            fillLayer.path = fill
            scrollLayer.transform = CATransform3DIdentity
            pulseContainer.position = CGPoint(x: innerRightX, y: p_N_1.y)
            CATransaction.commit()
            return
        }
        
        CATransaction.begin()
        // Over-Run Strategy
        let overRunFactor: Double = 2.0
        let effectiveDuration = remainingDuration + (animationDuration * (overRunFactor - 1.0))
        
        CATransaction.setAnimationDuration(effectiveDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        
        // A. Scroll
        let scrollStart = -stepX * CGFloat(catchUpProgress)
        let scrollEnd   = -stepX * CGFloat(overRunFactor)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.path = path
        fillLayer.path = fill
        scrollLayer.transform = CATransform3DMakeTranslation(scrollStart, 0, 0)
        CATransaction.commit()
        
        let scrollAnim = CABasicAnimation(keyPath: "transform.translation.x")
        scrollAnim.fromValue = scrollStart
        scrollAnim.toValue = scrollEnd
        scrollAnim.duration = effectiveDuration
        scrollAnim.fillMode = .forwards
        scrollAnim.isRemovedOnCompletion = false
        scrollLayer.add(scrollAnim, forKey: "scroll")
        
        // B. Pulse Y
        let pulseAnim = CAKeyframeAnimation(keyPath: "position.y")
        let pulseStart = p_N_1.y + (p_N.y - p_N_1.y) * CGFloat(catchUpProgress)
        pulseAnim.values = [pulseStart, p_N.y, p_N.y]
        let tData = remainingDuration / effectiveDuration
        pulseAnim.keyTimes = [0.0, NSNumber(value: tData), 1.0]
        pulseAnim.duration = effectiveDuration
        pulseContainer.add(pulseAnim, forKey: "jump")
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseContainer.position = CGPoint(x: innerRightX, y: p_N.y)
        CATransaction.commit()
        
        CATransaction.commit()
        
        // Fire synced pulse
        triggerHaloPulse()
    }
    
    private func calculateY(val: Double, height: CGFloat, scale: Double) -> CGFloat {
        // Pure Linear Mapping (Standard)
        // 1MB on 1MB Scale -> 100% Height
        let minY = strokeWidth / 2.0
        let maxY = height - topPad
        let availableHeight = maxY - minY
        
        let targetScale = max(scale, 1.0) // Avoid divide by zero
        let ratio = CGFloat(val / targetScale)
        
        // Clamp visually
        let robustRatio = max(0.0, min(1.0, ratio))
        
        return minY + robustRatio * availableHeight
    }
    
    private func calculatePoints(data: [Double], stepX: CGFloat, height: CGFloat, scale: Double) -> [CGPoint] {
        var points: [CGPoint] = []
        points.reserveCapacity(data.count)
        for i in 0..<data.count {
            points.append(CGPoint(x: CGFloat(i) * stepX, y: calculateY(val: data[i], height: height, scale: scale)))
        }
        return points
    }
}