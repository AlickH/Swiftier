import SwiftUI
import AppKit

// MARK: - 高性能 Sparkline (UIKit 实现)
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
        nsView.updateData(data)
    }
}

class SparklineNSView: NSView {
    var color: NSColor = .systemBlue {
        didSet { if oldValue != color { updatePulseColors() } }
    }
    var maxScale: Double = 1_048_576.0
    var isPaused: Bool = false {
        didSet {
            if isPaused {
                stopAnimationTimer()
            } else if window != nil {
                setupAnimationTimer()
            }
        }
    }
    
    private var data: [Double] = []
    private var animationTimer: Timer?
    private var lastData: [Double] = []
    private var lastUpdateTime: CFTimeInterval = 0
    private var interpolationProgress: Double = 0
    private var startRange: Double = 1_048_576.0
    private var displayedRange: Double = 1_048_576.0
    
    // 性能优化缓存
    private var normalizedYRatios: [Double] = []
    private var pointBuffer: [CGPoint] = []
    
    private let rightPad: CGFloat = 12.0 // 增加右侧边距
    private let strokeWidth: CGFloat = 2.5
    private let bottomPad: CGFloat = 0.0 // 线宽底边与卡片底部对齐
    private let topPad: CGFloat = 8.0
    private let cornerRadius: CGFloat = 12.0 // 匹配卡片圆角
    
    // Core Animation Layers
    private let pulseContainer = CALayer()
    private let haloLayer = CAShapeLayer()
    private let dotLayer = CALayer()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
        setupAnimationTimer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
        setupAnimationTimer()
    }

    private func configureView() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        autoresizingMask = [.width, .height]
        layer?.masksToBounds = false
        setupPulseLayers()
    }
    
    private func setupPulseLayers() {
        pulseContainer.zPosition = 100
        layer?.addSublayer(pulseContainer)
        
        // 1. 脉冲环 (Diffusion Halo) - 极细线
        haloLayer.fillColor = nil
        haloLayer.lineWidth = 0.6
        pulseContainer.addSublayer(haloLayer)
        
        // 2. 主圆点 (Main Dot)
        dotLayer.cornerRadius = 6.0 // 12pt 直径
        dotLayer.borderWidth = 2.0  // 更明显的白边
        dotLayer.borderColor = NSColor.white.cgColor
        pulseContainer.addSublayer(dotLayer)
        
        startPulseAnimation()
    }
    
    private func startPulseAnimation() {
        // 扩散动画
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 3.2 // 减小扩散范围
        
        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.5
        opacityAnim.toValue = 0.0
        
        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = 1.0
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        
        haloLayer.add(group, forKey: "pulse")
    }
    
    private func updatePulseColors() {
        let cgColor = color.cgColor
        haloLayer.strokeColor = color.withAlphaComponent(0.6).cgColor
        dotLayer.backgroundColor = cgColor
        
        let haloSize: CGFloat = 12 // 匹配圆点大小
        haloLayer.bounds = CGRect(x: 0, y: 0, width: haloSize, height: haloSize)
        haloLayer.path = CGPath(ellipseIn: haloLayer.bounds, transform: nil)
        haloLayer.position = .zero
        
        dotLayer.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        dotLayer.position = .zero
    }
    
    deinit {
        stopAnimationTimer()
    }
    
    private func setupAnimationTimer() {
        stopAnimationTimer()
        // 20 FPS 平滑动画，在保持丝滑滚动的同时显著降低 CPU 负载
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused, !self.data.isEmpty else { return }
            self.needsDisplay = true
        }
        RunLoop.current.add(animationTimer!, forMode: .common)
    }
    
    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
    
    func updateData(_ newData: [Double]) {
        guard !newData.isEmpty else {
            data = []
            lastData = []
            normalizedYRatios = []
            needsDisplay = true
            return
        }
        
        if !data.isEmpty {
            lastData = data
            lastUpdateTime = CACurrentMediaTime()
            interpolationProgress = 0
            startRange = displayedRange
        }
        data = newData
        
        // 性能优化：提前计算归一化 Y 轴比例 (基于 1MB 临界点)
        // 这样在 draw 循环中就不需要处理逻辑判断和 sqrt 了
        let threshold: Double = 1_048_576.0
        normalizedYRatios = data.map { val in
            if val <= threshold {
                return sqrt(val / threshold) * 0.5 // 0.0 - 0.5 范围
            } else {
                return 0.5 + (val - threshold) // 暂时存储超出部分原始值
            }
        }
        
        // 预分配点缓冲区，避免 draw 时高频内存分配
        if pointBuffer.count != data.count {
            pointBuffer = Array(repeating: .zero, count: data.count)
        }
        
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        guard !isPaused, !data.isEmpty, data.count > 1 else {
            return
        }
        
        let now = CACurrentMediaTime()
        if lastUpdateTime == 0 {
            lastUpdateTime = now
        }
        let timeSinceUpdate = now - lastUpdateTime
        let updateInterval: Double = 1.0 // 数据每秒更新一次
        interpolationProgress = min(timeSinceUpdate / updateInterval, 1.0)
        
        let w = bounds.width
        let h = bounds.height
        let innerWidth = w - rightPad
        let stepX = innerWidth / CGFloat(data.count - 1)
        let hasLastData = !lastData.isEmpty && lastData.count == data.count
        let scrollOffset = (1.0 - interpolationProgress) * stepX
        
        // Y轴逻辑：以1M为临界点的分段函数
        // macOS坐标系：Y=0在顶部，Y=h在底部
        // 值越大，折线应该越往上（Y值越小）
        // 1M以下：线性映射到0-50%高度（从底部到中间）
        // 1M以上：1M占50%高度，超出部分映射到50-100%高度（从中间到顶部）
        // 0速时，线宽的底边正好与卡片底边重合
        // Y=0 是底部，Y=h 是顶部
        func calculateYPosition(value: Double, currentRange: Double) -> CGFloat {
            let threshold: Double = 1_048_576.0 // 1MB
            let valueClamped = min(value, max(currentRange, threshold))
            
            let minY = strokeWidth / 2.0 // 底部位置，预留半个线宽防止切边
            let maxY = h - topPad // 顶部位置
            let availableHeight = maxY - minY
            let middleY = minY + (availableHeight * 0.5)
            
            if valueClamped <= threshold {
                // 1M以下：使用平方根映射
                let ratio = sqrt(valueClamped / threshold)
                return minY + CGFloat(ratio) * (middleY - minY)
            } else {
                // 1M以上：线性映射
                let aboveThreshold = valueClamped - threshold
                let maxAbove = max(currentRange - threshold, 1.0)
                let ratio = aboveThreshold / maxAbove
                return middleY + CGFloat(ratio) * (maxY - middleY)
            }
        }
        
        // 计算插值后的量程，实现 Y 轴平滑压缩/拉伸
        let targetRange = max(maxScale, 1_048_576.0)
        displayedRange = startRange + (targetRange - startRange) * interpolationProgress
        let range = displayedRange
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        
        // 1. 快速构建点序列 (复用缓冲区，避免 logic 判断)
        let minY = strokeWidth / 2.0
        let availableH = h - topPad - minY
        let midH = minY + availableH * 0.5
        let threshold: Double = 1_048_576.0
        let maxAbove = max(range - threshold, 1.0)
        
        @inline(__always)
        func clamp01(_ x: Double) -> Double { min(max(x, 0.0), 1.0) }
        
        var allPoints: [CGPoint] = []
        allPoints.reserveCapacity(data.count + 2)
        
        // 幽灵点
        let ghostX = -stepX
        var ghostY: CGFloat = 0
        if hasLastData, let firstRatio = normalizedYRatios.first {
            // 这里为了平滑稍微保留一点计算，但已经快了很多
            let prevY = calculateYPosition(value: lastData.first ?? 0, currentRange: range)
            let currRatio = firstRatio
            let currY = currRatio <= 0.5 ? (minY + CGFloat(currRatio) * availableH) : (midH + CGFloat(clamp01((currRatio - 0.5) / maxAbove)) * (availableH * 0.5))
            ghostY = prevY + (currY - prevY) * CGFloat(interpolationProgress)
        } else {
            let ratio = normalizedYRatios.first ?? 0
            ghostY = ratio <= 0.5 ? (minY + CGFloat(ratio) * availableH) : (midH + CGFloat(clamp01((ratio - 0.5) / maxAbove)) * (availableH * 0.5))
        }
        allPoints.append(CGPoint(x: ghostX, y: ghostY))
        
        // 中间点循环 (由于已经预处理了 Ratios，这里只有极简的浮点乘加)
        for i in 0..<(data.count - 1) {
            let ratio = normalizedYRatios[i]
            let y: CGFloat = ratio <= 0.5 
                ? (minY + CGFloat(ratio) * availableH) 
                : (midH + CGFloat(clamp01((ratio - 0.5) / maxAbove)) * (availableH * 0.5))
            allPoints.append(CGPoint(x: CGFloat(i) * stepX, y: y))
        }
        
        // 最后一个点 (脉冲点)
        let lastPointFixedX = innerWidth
        var lastPointY: CGFloat = 0
        if let lastRatio = normalizedYRatios.last {
            let targetY = lastRatio <= 0.5 ? (minY + CGFloat(lastRatio) * availableH) : (midH + CGFloat(clamp01((lastRatio - 0.5) / maxAbove)) * (availableH * 0.5))
            if hasLastData {
                let prevY = calculateYPosition(value: lastData.last ?? 0, currentRange: range)
                lastPointY = prevY + (targetY - prevY) * CGFloat(interpolationProgress)
            } else {
                lastPointY = targetY
            }
        }
        allPoints.append(CGPoint(x: lastPointFixedX - scrollOffset, y: lastPointY))
        
        // 裁剪区域（圆角遮罩，防止超出左下角圆角）
        let clipPath = CGMutablePath()
        clipPath.addRoundedRect(in: CGRect(x: 0, y: 0, width: bounds.width, height: h + cornerRadius), 
                                cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        context.addPath(clipPath)
        context.clip()
        
        context.saveGState()
        // 应用水平滚动偏移
        context.translateBy(x: scrollOffset, y: 0)
        
        // 2. 辅助函数：绘制平滑曲线
        func addCurvedPath(to path: CGMutablePath, points: [CGPoint], startWithMove: Bool) {
            guard points.count > 1 else { return }
            if startWithMove {
                path.move(to: points[0])
            } else {
                path.addLine(to: points[0])
            }
            
            for i in 0..<(points.count - 1) {
                let p1 = points[i]
                let p2 = points[i+1]
                let controlPoint1 = CGPoint(x: p1.x + (p2.x - p1.x) / 2, y: p1.y)
                let controlPoint2 = CGPoint(x: p2.x - (p2.x - p1.x) / 2, y: p2.y)
                path.addCurve(to: p2, control1: controlPoint1, control2: controlPoint2)
            }
        }
        
        // 1. 填充路径 (需要闭合到基准线 Y=0)
        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: ghostX, y: 0))
        addCurvedPath(to: fillPath, points: allPoints, startWithMove: false)
        fillPath.addLine(to: CGPoint(x: lastPointFixedX - scrollOffset, y: 0))
        fillPath.closeSubpath()
        
        // 渐变填充（从上往下：靠近线深，靠近底部浅）
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color.withAlphaComponent(0.35).cgColor,  // 靠近折线
                color.withAlphaComponent(0.0).cgColor    // 靠近底部
            ] as CFArray,
            locations: [0.0, 1.0]
        )
        context.addPath(fillPath)
        context.clip()
        
        // 渐变从 view 顶部到底部，因为 clipPath 限制了只在 fillPath 内显示
        // 这样在任何位置，靠近线的地方都比靠近底部的颜色深
        context.drawLinearGradient(
            gradient!,
            start: CGPoint(x: 0, y: h), // 顶部（深色）
            end: CGPoint(x: 0, y: 0),   // 底部（浅色）
            options: []
        )
        context.restoreGState()
        
        // 2. 画折线 (采用曲线绘制)
        context.saveGState()
        context.translateBy(x: scrollOffset, y: 0)
        
        let linePath = CGMutablePath()
        addCurvedPath(to: linePath, points: allPoints, startWithMove: true)
        
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(linePath)
        context.strokePath()
        context.restoreGState()
        
        context.restoreGState()
        
        // 更新脉冲层位置（硬件加速渲染）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseContainer.position = CGPoint(x: lastPointFixedX, y: lastPointY)
        CATransaction.commit()
    }
    
    override var isOpaque: Bool {
        return false
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimationTimer()
        } else if !isPaused {
            setupAnimationTimer()
        }
    }
    
    override func updateLayer() {
        guard !isPaused, !data.isEmpty else { return }
        layer?.setNeedsDisplay()
    }
}
