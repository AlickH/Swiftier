import SwiftUI
import WebKit
import ServiceManagement

struct SettingsView: View {
    @Binding var isPresented: Bool
    
    @AppStorage("connectOnStart") private var connectOnStart: Bool = true
    @AppStorage("breathEffect") private var breathEffect: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("exitBehavior") private var exitBehavior: String = "stopVPN" // keepRunning, stopVPN
    @AppStorage("logLevel", store: UserDefaults(suiteName: "group.com.alick.swiftier")) private var logLevel: String = "INFO"
    
    
    
    @State private var showLicense = false
    
    // APP Update Check
    @State private var isCheckingAppUpdate = false
    @State private var appUpdateStatus: String?
    @State private var showAppUpdateDetail = false
    @State private var appVersionInfo: (version: String, body: String, downloadURL: String, assets: [[String: Any]])?
    @AppStorage("appAutoUpdate") private var appAutoUpdate: Bool = true
    @AppStorage("appBetaChannel") private var appBetaChannel: Bool = false
    
    private let logLevels = ["OFF", "ERROR", "WARN", "INFO", "DEBUG", "TRACE"]
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            // Header
            UnifiedHeader(title: LocalizedStringKey("设置")) {
                Button(LocalizedStringKey("完成")) {}.buttonStyle(.bordered).hidden() // Placeholder
            } right: {
                Button(LocalizedStringKey("完成")) {
                    withAnimation { isPresented = false }
                }
                .buttonStyle(.borderedProminent)
            }
            
            // Native Form
            Form {
                Section(header: Text("通用")) {
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
                            Text(LocalizedStringKey(appUpdateStatus ?? "Swiftier 已是最新版本"))
                                .font(.headline)
                            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                            Text("Swiftier \(version)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // 检查更新按钮
                        Button(LocalizedStringKey("检查更新")) {
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
                        Text(LocalizedStringKey("退出 APP 时"))
                        Spacer()
                        Picker("", selection: $exitBehavior) {
                            Text(LocalizedStringKey("保持连接运行")).tag("keepRunning")
                            Text(LocalizedStringKey("停止连接并退出")).tag("stopVPN")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                
                

                
                Section(header: Text("日志"), footer: Text("修改日志等级后，需要停止并重新启动服务才能生效。")) {
                    Picker(LocalizedStringKey("日志等级"), selection: $logLevel) {
                        ForEach(logLevels, id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                }
                
                Section(header: Text("关于")) {
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
            
            if showAppUpdateDetail, let info = appVersionInfo {
                AppUpdateDetailView(
                    isPresented: $showAppUpdateDetail,
                    version: info.version,
                    releaseNotes: info.body,
                    downloadURL: info.downloadURL,
                    assets: info.assets
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
            return "退出 APP 后，VPN 连接将保持运行。"
        case "stopVPN":
            return "退出 APP 后，断开 VPN 连接。"
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
                
                if remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                    
                    // Parse assets to find the best download URL

                    // For now we just pass the raw assets list, filtering logic will be in the Detail View
                    // However, we are parsing the RELEASE object above, so we need to get assets from it
                    
                    var releaseAssets: [[String: Any]] = []
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let assets = json["assets"] as? [[String: Any]] {
                        releaseAssets = assets
                    } else if let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                              let first = releases.first,
                              let assets = first["assets"] as? [[String: Any]] {
                        releaseAssets = assets
                    }

                    await MainActor.run {
                        appVersionInfo = (remoteVersion, releaseBody, downloadURL, releaseAssets)
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
    let assets: [[String: Any]]
    
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadTask: URLSessionDownloadTask?
    @State private var showRevealButton = false
    @State private var downloadedFileURL: URL?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            UnifiedHeader(title: LocalizedStringKey("Swiftier \(version) 可用")) {
                Button(LocalizedStringKey("稍后")) { 
                    if isDownloading {
                        downloadTask?.cancel()
                        isDownloading = false
                    }
                    withAnimation { isPresented = false } 
                }
                .buttonStyle(.bordered)
            } right: {
                if showRevealButton {
                    HStack {
                        Button(LocalizedStringKey("查看文件")) {
                            if let url = downloadedFileURL {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        Button(LocalizedStringKey("安装并自启")) {
                            smartInstall()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if isDownloading {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                } else {
                    Button(LocalizedStringKey("立即下载")) {
                        startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            
            // Release Notes
            MarkdownWebView(markdown: releaseNotes)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func startDownload() {
        // Find best asset (dmg > zip, arm64 vs x64 logic if needed, but usually universal or specific)
        // For simplicity, find first .dmg, then .zip
        // In a real scenario, check architecture
        
        guard let assetURL = findBestAssetURL() else {
            // Fallback to opening browser
            if let url = URL(string: downloadURL) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        
        isDownloading = true
        downloadProgress = 0
        
        let url = URL(string: assetURL)!
        let session = URLSession(configuration: .default, delegate: DownloadDelegate(progress: { p in
            DispatchQueue.main.async { self.downloadProgress = p }
        }, completion: { location, error in
            // Must be careful to capture values before jumping to async
            guard let location = location else { return }
            let fileManager = FileManager.default
            let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destinationURL = downloadsURL.appendingPathComponent(url.lastPathComponent)
            
            do {
                try? fileManager.removeItem(at: destinationURL) // Overwrite
                try fileManager.moveItem(at: location, to: destinationURL)
                
                // Force UI update on Main Thread
                Task { @MainActor in
                    self.downloadedFileURL = destinationURL
                    self.showRevealButton = true
                    self.isDownloading = false
                    
                    // Reveal file
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                }
            } catch {
                print("File move error: \(error)")
                Task { @MainActor in
                    self.isDownloading = false
                }
            }
        }), delegateQueue: nil)
        
        let task = session.downloadTask(with: url)
        task.resume()
        self.downloadTask = task
    }
    
    private func smartInstall() {
        guard let assetURL = downloadedFileURL else { return }
        let currentAppURL = Bundle.main.bundleURL
        
        // Safety: Only proceed if we are a .app bundle
        guard currentAppURL.pathExtension == "app" else {
            NSWorkspace.shared.open(assetURL)
            return
        }
        
        let fileManager = FileManager.default
        let tempScriptURL = fileManager.temporaryDirectory.appendingPathComponent("swiftier_update.sh")
        
        // Script Logic:
        // 1. Wait for PID to close (passed as arg)
        // 2. Extract/Mount
        // 3. Replace
        // 4. Relaunch
        // 5. Self-destruct script
        
        let script = """
        #!/bin/bash
        PID=$1
        DMG_PATH="$2"
        DEST_APP="$3"
        TEMP_MOUNT="/tmp/Swiftier_Update_Mount"
        
        # 1. Wait for parent to exit
        while kill -0 $PID 2>/dev/null; do sleep 0.5; done
        
        echo "Starting update..."
        
        # 2. Extract payload
        SOURCE_APP=""
        
        if [[ "$DMG_PATH" == *.dmg ]]; then
            hdiutil attach -nobrowse "$DMG_PATH" -mountpoint "$TEMP_MOUNT"
            SOURCE_APP=$(find "$TEMP_MOUNT" -maxdepth 1 -name "*.app" -print -quit)
        elif [[ "$DMG_PATH" == *.zip ]]; then
            unzip -o "$DMG_PATH" -d "$TEMP_MOUNT"
            SOURCE_APP=$(find "$TEMP_MOUNT" -maxdepth 2 -name "*.app" -print -quit)
        fi
        
        if [ -z "$SOURCE_APP" ]; then
            echo "Failed to find app in update"
            open "$DMG_PATH"
            exit 1
        fi
        
        # 3. Replace
        rm -rf "$DEST_APP"
        cp -R "$SOURCE_APP" "$DEST_APP"
        
        # 4. Cleanup
        if [[ "$DMG_PATH" == *.dmg ]]; then
            hdiutil detach "$TEMP_MOUNT"
        else
            rm -rf "$TEMP_MOUNT"
        fi
        
        # 5. Relaunch
        open "$DEST_APP"
        
        # Cleanup Script
        rm -- "$0"
        """
        
        do {
            try script.write(to: tempScriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScriptURL.path)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [tempScriptURL.path, String(ProcessInfo.processInfo.processIdentifier), assetURL.path, currentAppURL.path]
            
            try process.run()
            
            NSApplication.shared.terminate(nil)
        } catch {
            print("Install failed: \(error)")
            NSWorkspace.shared.open(assetURL)
        }
    }
    
    private func findBestAssetURL() -> String? {
        // Simple logic: prefer .dmg, then .zip
        // Filter for "Swiftier" in name to avoid other assets
        let validAssets = assets.filter { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.contains("Swiftier")
        }
        
        // Priority 1: .dmg
        if let dmg = validAssets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") ?? false }) {
            return dmg["browser_download_url"] as? String
        }
        
        // Priority 2: .zip
        if let zip = validAssets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") ?? false }) {
            return zip["browser_download_url"] as? String
        }
        
        return nil
    }
}

// Delegate for progress
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: (Double) -> Void
    let completion: (URL?, Error?) -> Void
    
    init(progress: @escaping (Double) -> Void, completion: @escaping (URL?, Error?) -> Void) {
        self.progress = progress
        self.completion = completion
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completion(location, nil)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progress(p)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            completion(nil, error)
        }
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
                Button(LocalizedStringKey("关闭")) { 
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
