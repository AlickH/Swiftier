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
            UnifiedHeader(title: LocalizedStringKey(fileURL.lastPathComponent)) {
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
            content = try ConfigManager.shared.readConfigContent(fileURL)
            originalContent = content
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func saveContent() {
        // 获取安全域访问
        let dirURL = ConfigManager.shared.currentDirectory
        let isScoped = dirURL?.startAccessingSecurityScopedResource() ?? false
        defer { if isScoped { dirURL?.stopAccessingSecurityScopedResource() } }
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            originalContent = content
            
            withAnimation {
                isPresented = false
            }
        } catch {
            errorMessage = "保存失败: \(error.localizedDescription)"
        }
    }
}
