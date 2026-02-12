import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Binding var isPresented: Bool
    
    @AppStorage("connectOnStart") private var connectOnStart: Bool = true
    @AppStorage("breathEffect") private var breathEffect: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("exitBehavior") private var exitBehavior: String = "stopVPN" // keepRunning, stopVPN
    @AppStorage("logLevel", store: UserDefaults(suiteName: "group.com.alick.swiftier")) private var logLevel: String = "INFO"
    
    
    
    @State private var showLicense = false
    

    
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
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            .foregroundColor(.secondary)
                    }
                    
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
