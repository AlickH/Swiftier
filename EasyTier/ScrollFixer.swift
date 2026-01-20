import SwiftUI
import AppKit

/// A robust utility to find the underlying NSScrollView of a SwiftUI ScrollView and apply specific configurations.
/// This bypasses SwiftUI's limitations by interacting directly with the AppKit layer.
struct ScrollFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Delay execution slightly to ensure the view hierarchy is built
        DispatchQueue.main.async {
            if let scrollView = findScrollView(for: view) {
                scrollView.verticalScrollElasticity = .none
                scrollView.hasVerticalScroller = false
                scrollView.usesPredominantAxisScrolling = false // Forces strict axis locking
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    private func findScrollView(for view: NSView) -> NSScrollView? {
        var current: NSView? = view.superview
        while let s = current {
            if let sv = s as? NSScrollView {
                return sv
            }
            current = s.superview
        }
        return nil
    }
}

extension View {
    func lockVerticalScroll() -> some View {
        self.background(ScrollFixer())
    }
}
