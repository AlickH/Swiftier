import SwiftUI

struct ConfigEditorView: View {
    @Binding var isPresented: Bool
    let fileURL: URL
    
    @State private var content: String = ""
    @State private var originalContent: String = ""
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            UnifiedHeader(title: fileURL.lastPathComponent) {
                Button("取消", role: .destructive) {
                    withAnimation { isPresented = false }
                }
                .buttonStyle(.bordered)
            } right: {
                Button("保存") {
                    saveContent()
                }
                .buttonStyle(.borderedProminent)
            }
            
            // Editor
            ZStack(alignment: .top) {
                if let error = errorMessage {
                    Text("加载失败: \(error)")
                        .foregroundColor(.red)
                        .padding()
                } else {
                    CodeEditor(text: $content)
                        .padding(5)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor)) // 适配系统背景色
        .onAppear {
            loadContent()
        }

    }
    
    private func loadContent() {
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
            originalContent = content
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func saveContent() {
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            originalContent = content // 更新原始状态
            
            withAnimation {
                isPresented = false
            }
            
            // 通知 ConfigManager 或 Runner 可能需要重载？
            // 目前 EasyTier 可能需要重启服务才能生效，或者它支持热重载？
            // 这里我们只负责保存文件。
        } catch {
            errorMessage = "保存失败: \(error.localizedDescription)"
        }
    }
}
