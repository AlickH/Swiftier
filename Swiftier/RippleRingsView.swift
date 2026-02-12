import SwiftUI
import AppKit
import QuartzCore

// MARK: - 水波纹动画（Core Animation 硬件加速版）
struct RippleRingsView: NSViewRepresentable {
    let isVisible: Bool
    var duration: Double = 4.0
    var maxScale: CGFloat = 5.0
    
    @Environment(\.colorScheme) private var colorScheme
    
    func makeNSView(context: Context) -> RippleRingsNSView {
        let view = RippleRingsNSView()
        updateViewProperties(view)
        return view
    }
    
    func updateNSView(_ nsView: RippleRingsNSView, context: Context) {
        updateViewProperties(nsView)
        nsView.isVisible = isVisible
    }
    
    private func updateViewProperties(_ view: RippleRingsNSView) {
        view.duration = duration
        view.maxScale = maxScale
        view.isLightMode = colorScheme == .light
    }
}

class RippleRingsNSView: NSView {
    var duration: Double = 4.0 {
        didSet { if oldValue != duration { updateAnimation() } }
    }
    var maxScale: CGFloat = 5.0 {
        didSet { if oldValue != maxScale { updateAnimation() } }
    }
    var isLightMode: Bool = true {
        didSet { if oldValue != isLightMode { updateColors() } }
    }
    var isVisible: Bool = false {
        didSet {
            if isVisible {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
    }
    
    private let replicatorLayer = CAReplicatorLayer()
    private let pulseLayer = CALayer()
    private let baseSize: CGFloat = 84
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }
    
    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false
        
        // 1. 设置复制层 (Replicator)
        replicatorLayer.instanceCount = 3
        replicatorLayer.instanceDelay = duration / 3.0
        layer?.addSublayer(replicatorLayer)
        
        // 2. 设置基础脉冲层 (Pulse)
        pulseLayer.backgroundColor = NSColor.white.cgColor
        pulseLayer.cornerRadius = baseSize / 2
        pulseLayer.opacity = 0
        replicatorLayer.addSublayer(pulseLayer)
        
        updateColors()
    }
    
    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replicatorLayer.frame = bounds
        pulseLayer.frame = CGRect(x: center.x - baseSize / 2, y: center.y - baseSize / 2, width: baseSize, height: baseSize)
        CATransaction.commit()
    }
    
    private func updateColors() {
        let baseOpacity = isLightMode ? 0.7 : 0.08
        pulseLayer.backgroundColor = NSColor.white.withAlphaComponent(CGFloat(baseOpacity)).cgColor
    }
    
    private func startAnimation() {
        if pulseLayer.animation(forKey: "ripple") != nil { return }
        
        // 缩放动画
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = maxScale
        
        // 透明度动画
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1.0
        opacityAnim.toValue = 0.0
        
        // 动画组
        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = duration
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        
        pulseLayer.add(group, forKey: "ripple")
    }
    
    private func stopAnimation() {
        pulseLayer.removeAnimation(forKey: "ripple")
    }
    
    private func updateAnimation() {
        if isVisible {
            stopAnimation()
            replicatorLayer.instanceDelay = duration / 3.0
            startAnimation()
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isVisible {
            startAnimation()
        }
    }
}
