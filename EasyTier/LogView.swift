import SwiftUI

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: String
    let content: String
    let fullText: String
    let level: LogLevel
    
    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

enum LogLevel: String {
    case trace, debug, info, warn, error
    
    var color: Color {
        switch self {
        case .error: return .red
        case .warn: return .orange
        case .info: return .green
        case .debug: return .cyan
        case .trace: return .gray
        }
    }
}

struct EventEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: String
    let type: EventType
    let details: String
    
    enum EventType: String {
        case peerAdded = "PeerAdded"
        case peerRemoved = "PeerRemoved"
        case connecting = "Connecting"
        case connected = "Connected"
        case routeChanged = "RouteChanged"
        case unknown = "Event"
        
        var color: Color {
            switch self {
            case .peerAdded, .connected: return .green
            case .peerRemoved: return .red
            case .connecting: return .blue
            case .routeChanged: return .orange
            case .unknown: return .primary
            }
        }
    }
}

struct LogView: View {
    @Binding var isPresented: Bool
    
    @State private var logs: [LogEntry] = []
    @State private var events: [EventEntry] = []
    @State private var selectedLog: LogEntry?
    @State private var timer: Timer?
    @State private var lastFileSize: UInt64 = 0
    @State private var fileHandle: FileHandle?
    @State private var leftoverData: Data = Data()
    @State private var showCoreOnly: Bool = false
    @State private var currentFileID: UInt64?
    @State private var viewMode: ViewMode = .events
    
    private let logPath = "/var/log/swiftier-helper.log"
    
    enum ViewMode: Int {
        case events = 0
        case logs = 1
    }
    
    private var filteredLogs: [LogEntry] {
        if showCoreOnly {
            return logs.filter { !$0.content.contains("[Helper]") }
        }
        return logs
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            UnifiedHeader(title: "") {
                Picker("", selection: $viewMode) {
                    Text("交互事件").tag(ViewMode.events)
                    Text("调试日志").tag(ViewMode.logs)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            } right: {
                HStack {
                    if viewMode == .logs {
                        Picker("日志类型", selection: $showCoreOnly) {
                            Text("全部").tag(false)
                            Text("核心").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    
                    Button("关闭") {
                        withAnimation { isPresented = false }
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            if viewMode == .events {
                EventListView(events: events)
            } else {
                LogListView(
                    logs: filteredLogs,
                    selectedLog: $selectedLog
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            startMonitoring()
        }
        .onDisappear {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        if FileManager.default.fileExists(atPath: logPath) {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: logPath))
                let attrs = try FileManager.default.attributesOfItem(atPath: logPath)
                let size = attrs[.size] as? UInt64 ?? 0
                
                if size > 20000 {
                    try handle.seek(toOffset: size - 20000)
                }
                
                self.fileHandle = handle
                self.lastFileSize = handle.offsetInFile
                
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    checkLogRotation()
                    readNewData()
                }
                
                if let fileID = attrs[.systemFileNumber] as? UInt64 {
                    self.currentFileID = fileID
                }
                
                readNewData()
            } catch {
                print("Failed to open log: \(error)")
            }
        }
    }
    
    private func checkLogRotation() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let newID = attrs[.systemFileNumber] as? UInt64,
              let oldID = currentFileID else { return }
        
        if newID != oldID {
            try? fileHandle?.close()
            if let newHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: logPath)) {
                self.fileHandle = newHandle
                self.currentFileID = newID
                self.leftoverData = Data()
            }
        }
    }
    
    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        try? fileHandle?.close()
        fileHandle = nil
    }
    
    private func readNewData() {
        guard let handle = fileHandle else { return }
        let data = handle.availableData
        if !data.isEmpty {
            let combined = leftoverData + data
            if let range = combined.range(of: Data([0x0A]), options: .backwards) {
                 let validChunk = combined[..<range.lowerBound]
                 leftoverData = combined[range.upperBound...]
                 if let string = String(data: validChunk, encoding: .utf8) {
                     parseAndAppend(string)
                 }
            } else {
                leftoverData = combined
            }
        }
    }
    
    private func parseAndAppend(_ chunk: String) {
        let lines = chunk.components(separatedBy: .newlines)
        var newEntries: [LogEntry] = []
        var newEvents: [EventEntry] = []
        
        for line in lines {
            let clean = line
                .replacingOccurrences(of: "\\x1B\\[[0-9;]*[mK]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[Helper\\] Core output: ", with: "")
            
            if clean.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            
            // Basic Parsing
            let timeRegex = try? NSRegularExpression(pattern: "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2})", options: [])
            var timestamp = ""
            var content = clean
            
            if let match = timeRegex?.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count)) {
                if let range = Range(match.range(at: 1), in: clean) {
                    timestamp = String(clean[range])
                    content = String(clean[clean.index(range.upperBound, offsetBy: 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if content.hasPrefix(":") { content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces) }
                }
            } else {
                 timestamp = "Log" 
            }
            
            // Level
            let lower = clean.lowercased()
            var level: LogLevel = .info
            if lower.contains("error") || lower.contains("fatal") { level = .error }
            else if lower.contains("warn") { level = .warn }
            else if lower.contains("debug") { level = .debug }
            else if lower.contains("trace") { level = .trace }
            
            newEntries.append(LogEntry(timestamp: timestamp, content: content, fullText: clean, level: level))
            
            // Event Parsing
            if lower.contains("new peer") {
                newEvents.append(EventEntry(timestamp: timestamp, type: .peerAdded, details: content))
            } else if lower.contains("peer disconnected") {
                newEvents.append(EventEntry(timestamp: timestamp, type: .peerRemoved, details: content))
            } else if lower.contains("try connect to") {
                newEvents.append(EventEntry(timestamp: timestamp, type: .connecting, details: content))
            } else if lower.contains("connected to") {
                newEvents.append(EventEntry(timestamp: timestamp, type: .connected, details: content))
            } else if lower.contains("route cost") {
                newEvents.append(EventEntry(timestamp: timestamp, type: .routeChanged, details: content))
            }
        }
        
        DispatchQueue.main.async {
            self.logs.append(contentsOf: newEntries)
            if self.logs.count > 1000 { self.logs.removeFirst(self.logs.count - 1000) }
            
            self.events.append(contentsOf: newEvents)
            if self.events.count > 200 { self.events.removeFirst(self.events.count - 200) }
        }
    }
}

struct EventListView: View {
    let events: [EventEntry]
    
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 16) {
                        Text(event.timestamp.components(separatedBy: " ").last ?? event.timestamp)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                            .padding(.top, 4)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(event.type.color).frame(width: 8, height: 8)
                                Text(event.type.rawValue)
                                    .font(.system(size: 14, weight: .bold))
                            }
                            
                            Text(event.details)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowSeparator(.visible)
                }
            }
            .listStyle(.inset)
            .onChange(of: events.count) { _ in
                if let last = events.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

struct LogListView: View {
    let logs: [LogEntry]
    @Binding var selectedLog: LogEntry?
    
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(logs) { log in
                    LogListRow(log: log)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedLog = log
                        }
                        .popover(item: Binding<LogEntry?>(
                            get: { selectedLog == log ? log : nil },
                            set: { if $0 == nil { selectedLog = nil } }
                        )) { entry in
                            LogDetailView(log: $selectedLog)
                                .frame(width: 480, height: 360)
                        }
                        .listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.inset)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: logs) { _ in
                if let last = logs.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
struct LogListRow: View {
    let log: LogEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(log.level.color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(log.content)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2) // Summary 2 lines
                
                Text(log.timestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .contentShape(Rectangle()) // Make full row tappable
        .padding(.vertical, 4)
    }
}

struct LogDetailView: View {
    @Binding var log: LogEntry?
    
    var body: some View {
        VStack(spacing: 0) {
            UnifiedHeader(title: "Log Detail") {
                Button("关闭") {
                    log = nil
                }
                .buttonStyle(.bordered)
            } right: {
                EmptyView()
            }
            
            if let entry = log {
                CodeEditor(text: .constant(entry.fullText), mode: .log, isEditable: false)
                    .background(Color.black)
            }
        }
    }
}
