import SwiftUI

struct LogView: View {
    @Binding var isPresented: Bool
    
    @ObservedObject private var logParser = LogParser.shared
    @State private var selectedLog: LogEntry?
    @State private var viewMode: ViewMode = .events
    @State private var logLevelFilter: LogLevel? = nil // nil = show all
    
    private var logPath: String {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.alick.swiftier") {
            return containerURL.appendingPathComponent("easytier.log").path
        }
        return "/var/log/swiftier-helper.log" // fallback
    }
    
    enum ViewMode: Int {
        case events = 0
        case logs = 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom Header
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $viewMode) {
                        Text(LocalizedStringKey("交互事件")).tag(ViewMode.events)
                        Text(LocalizedStringKey("调试日志")).tag(ViewMode.logs)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        if viewMode == .logs {
                            Picker("", selection: $logLevelFilter) {
                                Text("全部").tag(nil as LogLevel?)
                                Text("ERROR").tag(LogLevel.error as LogLevel?)
                                Text("WARN").tag(LogLevel.warn as LogLevel?)
                                Text("INFO").tag(LogLevel.info as LogLevel?)
                                Text("DEBUG").tag(LogLevel.debug as LogLevel?)
                                Text("TRACE").tag(LogLevel.trace as LogLevel?)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                        }
                        
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.title3)
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                        .help("在系统控制台中打开完整日志")
                        
                        Button {
                            withAnimation {
                                isPresented = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor))
                
                Divider()
            }
            
            if viewMode == .events {
                EventListView(events: logParser.events)
            } else {
                LogListView(
                    logs: logParser.logs,
                    selectedLog: $selectedLog,
                    levelFilter: logLevelFilter
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Delay log loading until the slide-up animation completes (0.4s)
            try? await Task.sleep(nanoseconds: 400_000_000)
            logParser.startMonitoring()
        }
        .onDisappear {
            logParser.stopMonitoring()
        }
    }
}
