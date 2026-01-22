# Swiftier 性能分析：为什么显示页面时资源消耗高？

## 问题现象
显示页面时 CPU 占用较高（20%+），即使只有一小部分数据在更新。

## 根本原因分析

### 1. SwiftUI 的视图更新机制

**核心问题**：SwiftUI 使用**声明式视图树**，每次 `@Published` 属性变化时，会重新计算整个视图树的 `body` 属性。

#### 当前架构：
```
ContentView (@StateObject runner)
├── headerView (观察 runner.isRunning, runner.peerCount, runner.virtualIP)
├── contentArea (观察 runner.isRunning, runner.isWindowVisible)
│   ├── RippleRingsView (Timer 30 FPS)
│   ├── PeerListArea (@ObservedObject runner) ← 每次 runner 变化都重新计算
│   └── SpeedDashboard (@ObservedObject runner) ← 每次 runner 变化都重新计算
│       ├── SpeedCard (观察 runner.downloadSpeed, runner.downloadHistory)
│       └── SpeedCard (观察 runner.uploadSpeed, runner.uploadHistory)
│           └── SparklineView (Timer 20 FPS)
```

#### 数据更新频率：
- `downloadSpeed` / `uploadSpeed`: **每秒更新**
- `downloadHistory` / `uploadHistory`: **每秒更新**（20 个元素的数组）
- `uptimeText`: **每秒更新**
- `peers`: **不定期更新**

#### 问题：
每次 `@Published` 属性变化时：
1. **所有观察 `runner` 的视图都会重新计算 `body`**
   - `ContentView.body` 重新计算
   - `SpeedDashboard.body` 重新计算
   - `PeerListArea.body` 重新计算
2. **SwiftUI 进行视图差异比较（diffing）**
   - 比较新旧视图树
   - 决定哪些视图需要重新渲染
3. **即使数据没变化，视图计算也会发生**
   - 例如：`downloadHistory` 数组引用变化，但内容相同，仍会触发重新计算

### 2. 视图计算开销

#### `SpeedDashboard.body` 每次都会：
```swift
var body: some View {
    let maxSpeed = max(
        (runner.downloadHistory.max() ?? 0.0),  // ← 每次都要遍历 20 个元素
        (runner.uploadHistory.max() ?? 0.0),    // ← 每次都要遍历 20 个元素
        1_048_576.0
    )
    // ... 构建 HStack、SpeedCard 等
}
```

#### `PeerListArea.body` 每次都会：
```swift
var body: some View {
    // ... 构建 LazyHGrid、ForEach 等
    ForEach(runner.peers) { peer in  // ← 每次都要遍历 peers 数组
        PeerCard(peer: peer)
    }
}
```

### 3. 动画驱动的重绘

- **SparklineView**: Timer 20 FPS → 每秒 20 次 `draw(_:)` 调用
- **RippleRingsView**: Timer 30 FPS → 每秒 30 次 `draw(_:)` 调用
- 即使数据没变化，这些视图也在持续重绘

### 4. GeometryReader 和动画修饰符

```swift
private var contentArea: some View {
    GeometryReader { geo in  // ← 每次视图更新都会重新计算
        ZStack {
            // ...
        }
        .animation(.spring(...), value: runner.isRunning)  // ← 监听值变化
        .blur(radius: isAnyOverlayShown ? 10 : 0)  // ← 每次都要计算
        .opacity(isAnyOverlayShown ? 0.3 : 1.0)    // ← 每次都要计算
    }
}
```

## 为什么"只有一小部分在更新"但资源消耗高？

### SwiftUI 的工作流程：

1. **数据变化**：`runner.downloadSpeed = "1.2 MB/s"`
2. **触发通知**：`@Published` 发送 `objectWillChange` 通知
3. **视图重新计算**：
   - `ContentView.body` 重新计算
   - `SpeedDashboard.body` 重新计算（即使只用了 `downloadSpeed`）
   - `PeerListArea.body` 重新计算（即使没用 `downloadSpeed`）
4. **视图差异比较**：SwiftUI 比较新旧视图树
5. **渲染决策**：决定哪些视图需要重新渲染
6. **实际渲染**：只有 `SpeedCard` 的文本需要更新

**关键点**：即使最终只有一小部分视图需要重新渲染，**整个视图树的计算和差异比较过程本身就有 CPU 开销**。

## 优化建议

### 1. 使用 `EquatableView` 或 `Equatable` 协议

让视图只在数据真正变化时才更新：

```swift
struct SpeedCard: View, Equatable {
    let title: String
    let value: String
    let history: [Double]
    let maxVal: Double
    let isVisible: Bool
    let isPaused: Bool
    
    static func == (lhs: SpeedCard, rhs: SpeedCard) -> Bool {
        lhs.value == rhs.value &&
        lhs.history == rhs.history &&
        lhs.maxVal == rhs.maxVal &&
        lhs.isVisible == rhs.isVisible &&
        lhs.isPaused == rhs.isPaused
    }
    
    var body: some View {
        // ...
    }
}

// 使用：
SpeedCard(...)
    .equatable()  // 只在数据真正变化时才更新
```

### 2. 使用 `@State` 和 `onReceive` 替代 `@ObservedObject`

只订阅需要的数据，而不是整个对象：

```swift
struct SpeedDashboard: View {
    @State private var downloadSpeed: String = "0 KB/s"
    @State private var uploadSpeed: String = "0 KB/s"
    @State private var downloadHistory: [Double] = []
    @State private var uploadHistory: [Double] = []
    
    var body: some View {
        // ...
    }
    .onReceive(EasyTierRunner.shared.$downloadSpeed) { newValue in
        downloadSpeed = newValue
    }
    .onReceive(EasyTierRunner.shared.$uploadSpeed) { newValue in
        uploadSpeed = newValue
    }
    // ...
}
```

### 3. 缓存计算结果

避免在 `body` 中重复计算：

```swift
struct SpeedDashboard: View {
    @ObservedObject private var runner = EasyTierRunner.shared
    @State private var cachedMaxSpeed: Double = 1_048_576.0
    
    var body: some View {
        // 使用缓存的 maxSpeed
        let maxSpeed = cachedMaxSpeed
        // ...
    }
    .onChange(of: runner.downloadHistory) { _ in
        // 只在 history 变化时重新计算
        cachedMaxSpeed = max(
            (runner.downloadHistory.max() ?? 0.0),
            (runner.uploadHistory.max() ?? 0.0),
            1_048_576.0
        )
    }
}
```

### 4. 使用 `drawingGroup()` 进行离屏渲染

对于复杂的视图，使用 Metal 加速渲染：

```swift
SpeedCard(...)
    .drawingGroup()  // 使用 Metal 离屏渲染，减少 CPU 开销
```

### 5. 降低动画帧率

- SparklineView: 20 FPS → **15 FPS** 或 **10 FPS**
- RippleRingsView: 30 FPS → **20 FPS**

### 6. 使用 `@State` 存储不变的属性

对于不经常变化的属性，使用 `@State` 而不是从 `@ObservedObject` 读取：

```swift
struct SpeedCard: View {
    let title: String  // ← 不变，不需要观察
    let color: Color   // ← 不变，不需要观察
    
    @State private var value: String = "0 KB/s"  // ← 只观察变化的部分
    @State private var history: [Double] = []
    
    var body: some View {
        // ...
    }
}
```

### 7. 分离数据模型

将频繁更新的数据和静态数据分离：

```swift
// 频繁更新的数据
class SpeedData: ObservableObject {
    @Published var downloadSpeed: String = "0 KB/s"
    @Published var uploadSpeed: String = "0 KB/s"
    @Published var downloadHistory: [Double] = []
    @Published var uploadHistory: [Double] = []
}

// 静态或低频更新的数据
class RunnerState: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var peers: [PeerInfo] = []
    @Published var uptimeText: String = "00:00:00"
}

// 使用：
struct SpeedDashboard: View {
    @ObservedObject private var speedData = EasyTierRunner.shared.speedData  // 只观察速度数据
    @ObservedObject private var runnerState = EasyTierRunner.shared.state     // 只观察状态数据
}
```

## 总结

**核心问题**：SwiftUI 的声明式架构导致即使只有一小部分数据变化，整个视图树也会重新计算。

**解决方案**：
1. 使用 `EquatableView` 或 `Equatable` 协议减少不必要的更新
2. 使用 `@State` + `onReceive` 替代 `@ObservedObject`，只订阅需要的数据
3. 缓存计算结果，避免在 `body` 中重复计算
4. 使用 `drawingGroup()` 进行离屏渲染
5. 降低动画帧率
6. 分离数据模型，减少视图依赖

这些优化可以显著减少 CPU 占用，同时保持 UI 的流畅性。
