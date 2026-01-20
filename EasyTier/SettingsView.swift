import SwiftUI
import ServiceManagement
import WebKit

struct SettingsView: View {
    @Binding var isPresented: Bool
    
    @AppStorage("connectOnStart") private var connectOnStart: Bool = true
    @AppStorage("breathEffect") private var breathEffect: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("exitBehavior") private var exitBehavior: String = "stopCore" // keepRunning, stopCore, stopAll
    @AppStorage("logLevel") private var logLevel: String = "TRACE"
    
    @ObservedObject private var permissionManager = PermissionManager.shared
    
    
    @State private var showLicense = false
    
    // APP Update Check
    @State private var isCheckingAppUpdate = false
    @State private var appUpdateStatus: String?
    @State private var showAppUpdateDetail = false
    @State private var appVersionInfo: (version: String, body: String, downloadURL: String)?
    @AppStorage("appAutoUpdate") private var appAutoUpdate: Bool = true
    @AppStorage("appBetaChannel") private var appBetaChannel: Bool = false
    
    private let logLevels = ["OFF", "ERROR", "WARN", "INFO", "DEBUG", "TRACE"]
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            // Header
            UnifiedHeader(title: "设置") {
                Button("完成") {}.buttonStyle(.bordered).hidden() // Placeholder
            } right: {
                Button("完成") {
                    withAnimation { isPresented = false }
                }
                .buttonStyle(.borderedProminent)
            }
            
            // Native Form
            Form {
                Section("通用") {
                    // macOS 风格的更新状态卡片
                    HStack(spacing: 12) {
                        // 状态图标
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(appUpdateStatus == "有新版本可用" ? Color.orange : Color.green)
                                .frame(width: 40, height: 40)
                            Image(systemName: appUpdateStatus == "有新版本可用" ? "arrow.down.circle.fill" : "checkmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        // 状态文字
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appUpdateStatus ?? "Swiftier 已是最新版本")
                                .font(.headline)
                            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                            Text("Swiftier \(version)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // 检查更新按钮
                        Button("检查更新") {
                            checkAppUpdate()
                        }
                        .disabled(isCheckingAppUpdate)
                        .buttonStyle(.bordered)
                        
                        if isCheckingAppUpdate {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    Toggle("自动更新", isOn: $appAutoUpdate)
                    Toggle("接收 Beta 版本", isOn: $appBetaChannel)
                    
                    Toggle("启动 APP 时自动连接", isOn: $connectOnStart)
                    Toggle("连接时图标呼吸闪烁", isOn: $breathEffect)
                    
                    // 开机自启
                    Toggle("开机自动启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            toggleLaunchAtLogin(enabled: newValue)
                        }
                    
                    HStack {
                        Text("退出 APP 时")
                        Spacer()
                        Picker("", selection: $exitBehavior) {
                            Text("保持连接运行").tag("keepRunning")
                            Text("仅保留 Helper 加速启动").tag("stopCore")
                            Text("完全退出").tag("stopAll")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                
                Section("隐私") {
                    HStack {
                        Text("完全磁盘访问权限")
                        Spacer()
                        if permissionManager.isFDAGranted {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("已开启")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Button("去开启") {
                                permissionManager.openFullDiskAccessSettings()
                            }
                            .foregroundColor(.red)
                        }
                    }
                }
                

                
                Section(header: Text("日志"), footer: Text("修改日志等级后，需要停止并重新启动服务才能生效。")) {
                    Picker("日志等级", selection: $logLevel) {
                        ForEach(logLevels, id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                }
                
                Section("关于") {
                    HStack {
                        Text("开发者")
                        Spacer()
                        Text("Alick Huang")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("联系邮箱")
                        Spacer()
                        Text("minamike2007@gmail.com")
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    
                    HStack {
                        Text("源代码")
                        Spacer()
                        Link("GitHub 仓库", destination: URL(string: "https://github.com/AlickH/Swiftier")!)
                            .foregroundColor(.blue)
                    }
                    
                    Button(action: { 
                        withAnimation {
                            showLicense = true 
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("开源声明")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            }
                            Text("本项目遵循 MIT 开源许可证。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped) // 使用系统标准的 Grouped 样式
            .scrollContentBackground(.hidden) // 让 Form 背景对齐到外部
            } // End VStack
            .background(Color(nsColor: .windowBackgroundColor)) // 整体背景
            

            
            // License Popup
            if showLicense {
                LicenseView(isPresented: $showLicense)
                    .transition(.move(edge: .trailing)) // Slide from right like a push
                    .zIndex(100)
            }
            
            // APP Update Detail Popup
            if showAppUpdateDetail, let info = appVersionInfo {
                AppUpdateDetailView(
                    isPresented: $showAppUpdateDetail,
                    version: info.version,
                    releaseNotes: info.body,
                    downloadURL: info.downloadURL
                )
                .transition(.move(edge: .bottom))
                .zIndex(101)
            }
        }
        .onAppear {
            checkLaunchAtLogin()
        }
    }
    
    private func checkLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
    
    private var exitBehaviorDescription: String {
        switch exitBehavior {
        case "keepRunning":
            return "退出 APP 后，Swiftier 连接将保持运行，您可以随时重新打开 APP 查看状态。"
        case "stopCore":
            return "退出 APP 后，断开 Swiftier 连接，但保留 Helper 进程以加速下次启动。"
        case "stopAll":
            return "退出 APP 后，完全停止所有后台服务（包括 Helper），下次启动需要重新授权。"
        default:
            return ""
        }
    }
    

    private func checkAppUpdate() {
        isCheckingAppUpdate = true
        appUpdateStatus = "正在检查..."
        
        Task {
            do {
                // 根据是否接收 Beta 版本选择不同的 API 端点
                let apiURL = appBetaChannel
                    ? "https://api.github.com/repos/AlickH/Swiftier/releases"
                    : "https://api.github.com/repos/AlickH/Swiftier/releases/latest"
                
                guard let url = URL(string: apiURL) else {
                    throw URLError(.badURL)
                }
                
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                
                let (data, _) = try await URLSession.shared.data(for: request)
                
                var tagName: String?
                var body: String?
                var htmlURL: String?
                
                if appBetaChannel {
                    // Beta 模式：获取所有 releases，取第一个（包括 prerelease）
                    if let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                       let firstRelease = releases.first {
                        tagName = firstRelease["tag_name"] as? String
                        body = firstRelease["body"] as? String
                        htmlURL = firstRelease["html_url"] as? String
                    }
                } else {
                    // 正式版模式：只获取 latest
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        tagName = json["tag_name"] as? String
                        body = json["body"] as? String
                        htmlURL = json["html_url"] as? String
                    }
                }
                
                guard let tag = tagName, let releaseBody = body, let downloadURL = htmlURL else {
                    throw NSError(domain: "ParseError", code: 0, userInfo: [NSLocalizedDescriptionKey: "无法解析版本信息"])
                }
                
                // 清理版本号（去掉 v 前缀）
                let remoteVersion = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                
                // 比较版本号
                if remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                    await MainActor.run {
                        appVersionInfo = (remoteVersion, releaseBody, downloadURL)
                        showAppUpdateDetail = true
                        appUpdateStatus = "有新版本可用"
                    }
                } else {
                    await MainActor.run {
                        appUpdateStatus = nil // 清空状态，显示默认的"已是最新版本"
                    }
                }
            } catch {
                await MainActor.run {
                    appUpdateStatus = "检查失败"
                }
            }
            
            await MainActor.run { isCheckingAppUpdate = false }
        }
    }
    
    private func toggleLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to toggle launch at login: \(error)")
                launchAtLogin = !enabled
            }
        }
    }
}



struct AppUpdateDetailView: View {
    @Binding var isPresented: Bool
    let version: String
    let releaseNotes: String
    let downloadURL: String
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            UnifiedHeader(title: "Swiftier \(version) 可用") {
                Button("稍后") { withAnimation { isPresented = false } }
                    .buttonStyle(.bordered)
            } right: {
                Button("前往下载") {
                    if let url = URL(string: downloadURL) {
                        NSWorkspace.shared.open(url)
                    }
                    withAnimation { isPresented = false }
                }
                .buttonStyle(.borderedProminent)
            }
            
            // Release Notes
            MarkdownWebView(markdown: releaseNotes)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let html = generateHTML(from: markdown)
        nsView.loadHTMLString(html, baseURL: nil)
    }
    
    func generateHTML(from markdown: String) -> String {
        // Escape backticks and backslashes for JS template string
        let escapedMarkdown = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            // Ensure newlines are preserved for JS string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
        
        // Use marked.js for robust parsing
        // Dark mode CSS
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            body { 
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                color: #DDD; 
                padding: 10px 15px; 
                background-color: transparent; 
                line-height: 1.6;
                font-size: 13px;
            }
            a { color: #4DAAFF; text-decoration: none; }
            a:hover { text-decoration: underline; }
            h1, h2, h3 { color: #FFF; margin-top: 20px; margin-bottom: 10px; border-bottom: 1px solid #444; padding-bottom: 5px; }
            h1 { font-size: 1.4em; }
            h2 { font-size: 1.3em; }
            h3 { font-size: 1.2em; }
            ul, ol { padding-left: 20px; margin: 10px 0; }
            li { margin-bottom: 5px; }
            code { 
                background: #333; 
                padding: 2px 4px; 
                border-radius: 3px; 
                font-family: "SF Mono", Menlo, Monaco, Consolas, monospace; 
                font-size: 12px;
                color: #FFD479;
            }
            pre { 
                background: #222; 
                padding: 10px; 
                border-radius: 6px; 
                overflow-x: auto; 
            }
            pre code { 
                background: transparent; 
                padding: 0; 
                color: #DDD;
            }
            blockquote {
                border-left: 3px solid #555;
                margin: 0;
                padding-left: 10px;
                color: #AAA;
            }
        </style>
        <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
        </head>
        <body>
        <div id="content"></div>
        <script>
            try {
                // If marked is loaded, use it
                if (typeof marked !== 'undefined') {
                    document.getElementById('content').innerHTML = marked.parse(`\(escapedMarkdown)`);
                } else {
                    // Fallback to simpler rendering (newlines to breaks) if offline
                    document.getElementById('content').innerText = `\(escapedMarkdown)`.replace(/\\\\n/g, '\\n');
                    document.getElementById('content').innerHTML = document.getElementById('content').innerText.replace(/\\n/g, '<br>');
                }
            } catch (e) {
                document.getElementById('content').innerText = "Error parsing markdown: " + e;
            }
        </script>
        </body>
        </html>
        """
    }
}

struct LicenseView: View {
    @Binding var isPresented: Bool
    
    private let mitLicense = """
MIT License

Copyright (c) 2024 Alick Huang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

    var body: some View {
        VStack(spacing: 0) {
            UnifiedHeader(title: "MIT License") {
                Button("关闭") { 
                    withAnimation { isPresented = false }
                }
                .buttonStyle(.bordered)
            } right: { EmptyView() }
            
            ScrollView {
                Text(mitLicense)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
