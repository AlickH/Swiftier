import SwiftUI
import ServiceManagement
import WebKit

struct SettingsView: View {
    @Binding var isPresented: Bool
    
    @AppStorage("refreshInterval") private var refreshInterval: Double = 1.0
    @AppStorage("connectOnStart") private var connectOnStart: Bool = true
    @AppStorage("breathEffect") private var breathEffect: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("quitHelperOnExit") private var quitHelperOnExit: Bool = true
    @AppStorage("keepRunningOnExit") private var keepRunningOnExit: Bool = false
    @AppStorage("logLevel") private var logLevel: String = "TRACE"
    
    // Kernel Settings
    @ObservedObject private var downloader = CoreDownloader.shared
    @AppStorage("useBetaChannel") private var useBetaChannel = false
    @AppStorage("useGitHubProxy") private var useGitHubProxy = true
    @State private var checkUpdateStatus: String?
    @State private var isCheckingUpdate = false
    @State private var showUpdateAlert = false
    @State private var newVersionInfo: (version: String, body: String)?
    
    @State private var showUpdateDetail = false
    @State private var showLicense = false
    
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
                    HStack {
                        Text("状态刷新间隔")
                        Spacer()
                        Text("\(refreshInterval, specifier: "%.1f") s")
                            .foregroundColor(.secondary)
                        Stepper("", value: $refreshInterval, in: 0.5...10.0, step: 0.5).labelsHidden()
                    }
                    
                    Toggle("启动 APP 时自动连接", isOn: $connectOnStart)
                    Toggle("连接时图标呼吸闪烁", isOn: $breathEffect)
                    
                    // 开机自启
                    Toggle("开机自动启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            toggleLaunchAtLogin(enabled: newValue)
                        }
                    
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("退出 APP 时保持连接服务运行", isOn: $keepRunningOnExit)
                        Text("开启此选项后，退出 APP 将不会断开 EasyTier 连接，后台服务将继续运行。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("退出 APP 时停止后台服务", isOn: $quitHelperOnExit)
                        
                        Text("开启此选项后，APP 退出时将同时终止 EasyTierHelper 守护进程。关闭此选项仅保留 Helper 进程以加速下次启动，但 EasyTier 连接仍会断开。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true) // 确保文字能自动换行
                    }
                }
                

                
                Section("内核管理") {
                    HStack {
                        Text("内核版本")
                        Spacer()
                        if let v = downloader.currentVersion {
                            Text(v).foregroundColor(.secondary)
                        } else {
                            Text("未安装").foregroundColor(.red)
                        }
                    }
                    
                    Toggle("使用 GitHub 加速镜像 (ghfast.top)", isOn: $useGitHubProxy)
                    Toggle("接收 Beta 版本更新", isOn: $useBetaChannel)
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Button("检查更新") {
                                performUpdateCheck()
                            }
                            .disabled(downloader.isDownloading || isCheckingUpdate)
                            
                            if isCheckingUpdate {
                                ProgressView().controlSize(.small)
                            }
                        }
                        
                        if downloader.isDownloading {
                            VStack(alignment: .leading) {
                                Text(downloader.statusMessage)
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                ProgressView(value: downloader.downloadProgress)
                            }
                        } else if let status = checkUpdateStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                        Text("APP 版本")
                        Spacer()
                        Text("0.0.1")
                            .foregroundColor(.secondary)
                    }
                    
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
            
            // Update Detail Sheet
            if showUpdateDetail, let info = newVersionInfo {
                UpdateDetailView(
                    isPresented: $showUpdateDetail,
                    version: info.version,
                    releaseNotes: info.body,
                    onUpdate: {
                        Task {
                             checkUpdateStatus = nil
                             try? await downloader.installCore(useBeta: useBetaChannel, useProxy: useGitHubProxy)
                        }
                    }
                )
                .transition(.move(edge: .bottom))
            }
            
            // License Popup
            if showLicense {
                LicenseView(isPresented: $showLicense)
                    .transition(.move(edge: .trailing)) // Slide from right like a push
                    .zIndex(100)
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
    
    private func performUpdateCheck() {
        isCheckingUpdate = true
        checkUpdateStatus = "正在检查..."
        Task {
            do {
                // Check if update available
                if let (ver, body) = try await downloader.checkForUpdate(useBeta: useBetaChannel) {
                    await MainActor.run {
                        newVersionInfo = (ver, body)
                        showUpdateDetail = true
                        checkUpdateStatus = nil
                    }
                } else {
                    await MainActor.run {
                        checkUpdateStatus = "当前已是最新版本"
                    }
                }
            } catch {
                await MainActor.run {
                    checkUpdateStatus = "检查失败: \(error.localizedDescription)"
                }
            }
            await MainActor.run { isCheckingUpdate = false }
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

struct UpdateDetailView: View {
    @Binding var isPresented: Bool
    let version: String
    let releaseNotes: String
    let onUpdate: () -> Void
    
    // Clean version string: remove 'v' prefix if present to avoid "vv2.5.0"
    private var displayVersion: String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            UnifiedHeader(title: "新版本 v\(displayVersion)") {
                Button("关闭") { withAnimation { isPresented = false } }
                    .buttonStyle(.bordered)
            } right: {
                Button("立即更新") {
                    onUpdate()
                    withAnimation { isPresented = false }
                }
                .buttonStyle(.borderedProminent)
            }
            
            // Web Content
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
