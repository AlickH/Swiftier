import SwiftUI

// MARK: - Unified Header Component

/// 统一风格的页面 Header 布局容器
/// 仅负责布局结构，样式完全由内部按钮的系统 Style 决定
struct UnifiedHeader<LeftBtn: View, RightBtn: View>: View {
    let title: LocalizedStringKey
    let leftButton: () -> LeftBtn
    let rightButton: () -> RightBtn
    
    init(title: LocalizedStringKey, @ViewBuilder left: @escaping () -> LeftBtn, @ViewBuilder right: @escaping () -> RightBtn) {
        self.title = title
        self.leftButton = left
        self.rightButton = right
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                leftButton()
                
                Spacer()
                
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
                
                rightButton()
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor)) // 保持背景一致
            
            Divider()
        }
    }
}
