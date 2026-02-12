import SwiftUI
import AppKit

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var mode: Mode = .toml
    var isEditable: Bool = true
    
    enum Mode {
        case toml
        case log
        case json
    }
    
    // 高亮逻辑
    func highlight(_ storage: NSTextStorage) {
        let string = storage.string as NSString
        let fullRange = NSRange(location: 0, length: string.length)
        
        // Helper
        func applyStyle(pattern: String, color: NSColor, bold: Bool = false) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return }
            regex.enumerateMatches(in: storage.string, options: [], range: fullRange) { match, _, _ in
                if let range = match?.range {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                    if bold {
                        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), range: range)
                    }
                }
            }
        }
        
        if mode == .toml {
            // 1. 重置基础样式 (TOML)
            storage.removeAttribute(.foregroundColor, range: fullRange)
            storage.removeAttribute(.font, range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: fullRange)
            
            // [Section]
            applyStyle(pattern: "^\\s*\\[.+\\]", color: NSColor.systemOrange, bold: true)
            // Key =
            applyStyle(pattern: "^\\s*[a-zA-Z0-9_-]+\\s*(?==)", color: NSColor.systemBlue)
            // # Comment
            applyStyle(pattern: "#.*$", color: NSColor.secondaryLabelColor)
        } else if mode == .log {
            // 1. 重置基础样式 (Cleaner Log Style)
            storage.removeAttribute(.foregroundColor, range: fullRange)
            storage.removeAttribute(.font, range: fullRange)
            
            // Standard Text Color (Adaptive White/Black) instead of Matrix Green
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
            
            // Menlo or Monospace Font
            let font = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            storage.addAttribute(.font, value: font, range: fullRange)
            
            // Time & Meta Styling (Gray)
            // Matches [2026-01-18 ...] or [Helper]
            applyStyle(pattern: "^\\[[^\\]]+\\]", color: NSColor.secondaryLabelColor)
            applyStyle(pattern: "\\[easytier_core::[^\\]]+\\]", color: NSColor.secondaryLabelColor)
            
            // Log Level Highlighting
            // ERROR / FATAL -> Red
            applyStyle(pattern: "(?i)ERROR|FATAL", color: NSColor.systemRed, bold: true)
            
            // WARN -> Yellow
            applyStyle(pattern: "(?i)WARN|WARNING", color: NSColor.systemOrange, bold: true)
            
            // INFO -> Green
            applyStyle(pattern: "(?i)INFO", color: NSColor.systemGreen, bold: true)
            
            // DEBUG -> Cyan
            applyStyle(pattern: "(?i)DEBUG", color: NSColor.systemCyan, bold: true)
            
            // TRACE -> Blue/Gray
            // Usually verbose, keep it subtle or blue
            applyStyle(pattern: "(?i)TRACE", color: NSColor.systemBlue, bold: true)
            
            // Highlight Swiftier keywords
            applyStyle(pattern: "Swiftier", color: NSColor.labelColor, bold: true)
        } else if mode == .json {
            // JSON Syntax Highlighting
            storage.removeAttribute(.foregroundColor, range: fullRange)
            storage.removeAttribute(.font, range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
            
            let font = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            storage.addAttribute(.font, value: font, range: fullRange)
            
            // Keys ("key":) - Blue
            applyStyle(pattern: "\"[^\"]+\"\\s*:", color: NSColor.systemBlue, bold: true)
            
            // String values ("value") - Green
            applyStyle(pattern: ":\\s*\"[^\"]*\"", color: NSColor.systemGreen)
            
            // Numbers - Orange
            applyStyle(pattern: ":\\s*[0-9]+\\.?[0-9]*", color: NSColor.systemOrange)
            
            // Boolean and null - Purple
            applyStyle(pattern: "\\b(true|false|null)\\b", color: NSColor.systemPurple, bold: true)
            
            // Brackets and braces - Gray
            applyStyle(pattern: "[\\[\\]\\{\\}]", color: NSColor.secondaryLabelColor)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let textView = NSTextView()
        textView.autoresizingMask = [.width, .height]
        textView.allowsUndo = true
        textView.drawsBackground = false // 透明背景
        textView.textColor = .labelColor // 自适应文字颜色
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isEditable = isEditable
        textView.textContainerInset = NSSize(width: 12, height: 12)
        
        // Disable all automatic text systems to prevent 'autofill' and other background processes
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        
        // 关键设置：容器自动调整
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        
        // 设置 Delegate
        textView.delegate = context.coordinator
        
        scrollView.documentView = textView
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        
        // 只在内容不同时更新，避免死循环
        if textView.string != text {
            textView.string = text
            highlight(textView.textStorage!)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        
        init(_ parent: CodeEditor) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            // 实时更新高亮
            parent.highlight(textView.textStorage!)
            
            // 更新绑定
            parent.text = textView.string
        }
    }
}
