import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Binding var isPresented: Bool
    
    @AppStorage("connectOnStart") private var connectOnStart: Bool = true
    @AppStorage("breathEffect") private var breathEffect: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

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
                    
                    Toggle("Connect On Demand", isOn: $connectOnStart)
                        .onChange(of: connectOnStart) { newValue in
                            VPNManager.shared.updateOnDemand(enabled: newValue)
                        }
                    Toggle("连接时图标呼吸闪烁", isOn: $breathEffect)
                    
                    // 开机自启
                    Toggle("开机自动启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            toggleLaunchAtLogin(enabled: newValue)
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
                                Text(LocalizedStringKey("开源声明"))
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            }
                            Text(LocalizedStringKey("本项目遵循 GPL-3.0 开源许可证。"))
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
    
    private let gplLicense = """
GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

Copyright (C) 2007 Free Software Foundation, Inc.
<https://fsf.org/>

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.

Preamble

The GNU General Public License is a free, copyleft license for software
and other kinds of works.

The licenses for most software and other practical works are designed to
take away your freedom to share and change the works. By contrast, the
GNU General Public License is intended to guarantee your freedom to share
and change all versions of a program--to make sure it remains free software
for all its users.

When we speak of free software, we are referring to freedom, not price.
Our General Public Licenses are designed to make sure that you have the
freedom to distribute copies of free software (and charge for them if you
wish), that you receive source code or can get it if you want it, that
you can change the software or use pieces of it in new free programs, and
that you know you can do these things.

To protect your rights, we need to prevent others from denying you these
rights or asking you to surrender the rights. Therefore, you have certain
responsibilities if you distribute copies of the software, or if you
modify it: responsibilities to respect the freedom of others.

For the complete license text, visit:
https://www.gnu.org/licenses/gpl-3.0.en.html

Copyright (c) 2024 Alick Huang

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
"""

    var body: some View {
        VStack(spacing: 0) {
            UnifiedHeader(title: "GPL-3.0 License") {
                Button(LocalizedStringKey("关闭")) { 
                    withAnimation { isPresented = false }
                }
                .buttonStyle(.bordered)
            } right: { EmptyView() }
            
            ScrollView {
                Text(gplLicense)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
