import SwiftUI

struct LogListView: View {
    let logs: [LogEntry]
    @Binding var selectedLog: LogEntry?
    var levelFilter: LogLevel? = nil
    
    private let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private func formatTimestamp(_ ts: String) -> String {
        if let date = isoFormatter.date(from: ts) {
            return fullDateFormatter.string(from: date)
        }
        let proper = ts.replacingOccurrences(of: "T", with: " ")
        if proper.count >= 19 { return String(proper.prefix(19)) }
        return ts
    }
    
    private var filteredLogs: [LogEntry] {
        guard let filter = levelFilter else { return logs }
        return logs.filter { $0.level == filter }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    List {
                        let displayLogs = Array(filteredLogs.reversed())
                        ForEach(displayLogs) { log in
                            let index = displayLogs.firstIndex(where: { $0.id == log.id }) ?? 0
                            LogListRow(log: log, timestampFormatted: formatTimestamp(log.timestamp), isSelected: selectedLog?.id == log.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    (selectedLog?.id == log.id) 
                                    ? Color.blue.opacity(0.15) 
                                    : (index % 2 == 0 ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(0.04)) 
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedLog = (selectedLog?.id == log.id) ? nil : log
                                    }
                                }
                                .id(log.id)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    
                    if logs.count > 5 {
                        Button {
                            if let topLog = logs.last {
                                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(topLog.id, anchor: .top) }
                            }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .modifier(FlatCircleButtonModifier())
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(width: selectedLog == nil ? 420 : 180)
            
            if let entry = selectedLog {
                Divider()
                VStack(spacing: 0) {
                    LogDetailView(log: .constant(entry))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .id("log-list-stable")
        .onChange(of: selectedLog) { val in
            if val != nil { LogParser.shared.isPaused = true }
            else { LogParser.shared.isPaused = false; LogParser.shared.flushPending() }
        }
    }
}

struct LogListRow: View {
    let log: LogEntry
    let timestampFormatted: String
    var isSelected: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Main Content
            Text(log.cleanContent)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundColor(isSelected ? .blue : .primary)
                .lineLimit(isSelected ? 3 : 2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Bottom Meta Row: Timestamp | Level
            HStack(spacing: 6) {
                Text(timestampFormatted.isEmpty ? "---- -- -- --:--:--" : timestampFormatted)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if !isSelected {
                    LogListTagView(text: log.level.rawValue.uppercased(), color: log.level.color)
                        .scaleEffect(0.8)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
        .padding(.horizontal, 14) // Increased padding
        .frame(minHeight: 64, maxHeight: 64)
    }
}

struct LogListTagView: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
    }
}

struct LogDetailView: View {
    @Binding var log: LogEntry?
    var body: some View {
        VStack(spacing: 0) {
            if let entry = log {
                CodeEditor(text: .constant(entry.fullText), mode: .log, isEditable: false)
            }
        }
    }
}
