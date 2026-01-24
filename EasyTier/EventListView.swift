import SwiftUI

struct EventListView: View {
    let events: [EventEntry]
    
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium // 自动处理 24h/12h 格式
        return f
    }()
    
    private func formatDateOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    
    var body: some View {
        if events.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("暂无交互事件")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    List {
                        ForEach(events.reversed()) { event in
                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let date = event.date {
                                        Text(timeFormatter.string(from: date))
                                            .font(.system(size: 16, weight: .black, design: .rounded))
                                        Text(formatDateOnly(date))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(event.timestamp)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(width: 80, alignment: .trailing)
                                .padding(.trailing, 8)
                                .padding(.vertical, 8)
                                
                                ZStack(alignment: .top) {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(width: 2)
                                    Circle()
                                        .fill(event.type.color)
                                        .frame(width: 10, height: 10)
                                        .background(Color(NSColor.windowBackgroundColor))
                                        .padding(.top, 14)
                                }
                                .frame(width: 12)
                                .padding(.trailing, 8)
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(event.type.rawValue)
                                        .font(.system(size: 16, weight: .bold))
                                    
                                    CharWrappingJSONView(json: event.details, highlights: event.highlights ?? [], eventId: event.id)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(6)
                                }
                                .padding(.vertical, 10)
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0))
                            .id(event.id)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    
                    Button {
                        if let topEvent = events.last {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(topEvent.id, anchor: .top)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 20, weight: .bold))
                            .modifier(FlatCircleButtonModifier())
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
        }
    }
}

@available(macOS 12.0, *)
struct CharWrappingJSONView: NSViewRepresentable {
    let json: String
    let highlights: [HighlightRange]
    let eventId: UUID

    func makeNSView(context: Context) -> WrappingTextView {
        let textView = WrappingTextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        return textView
    }

    func updateNSView(_ nsView: WrappingTextView, context: Context) {
        let attributed = highlightWithMetadata(json, highlights: highlights)
        // 性能优化：内容没变就不刷新列表
        if nsView.textStorage?.string != attributed.string {
            nsView.textStorage?.setAttributedString(attributed)
            nsView.invalidateIntrinsicContentSize()
        }
    }
    
    // 关键修复：这个类能告诉 SwiftUI 它需要多高
    class WrappingTextView: NSTextView {
        override var intrinsicContentSize: NSSize {
            guard let layoutManager = layoutManager, let textContainer = textContainer else {
                return super.intrinsicContentSize
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            return NSSize(width: NSView.noIntrinsicMetric, height: usedRect.height + 4)
        }
        
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            textContainer?.lineBreakMode = .byCharWrapping
            textContainer?.widthTracksTextView = true
        }
    }
    
    private func highlightWithMetadata(_ json: String, highlights: [HighlightRange]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: json)
        let fullRange = NSRange(location: 0, length: (json as NSString).length)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: fullRange)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        
        for h in highlights {
            let range = NSRange(location: h.start, length: h.length)
            if range.location + range.length <= (json as NSString).length {
                let color: NSColor
                switch h.color {
                case "blue": color = .systemBlue
                case "green": color = .systemGreen
                case "orange": color = .systemOrange
                case "purple": color = .systemPurple
                default: color = .labelColor
                }
                attributed.addAttribute(.foregroundColor, value: color, range: range)
                if h.bold {
                    attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: range)
                }
            }
        }
        return attributed
    }
}

struct FlatCircleButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .padding(12) // 保持足够的点击区域
            .background(
                Circle()
                    .fill(Color.blue)
            )
            .contentShape(Circle())
            .onHover { isHovering in
                if isHovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
    }
}
