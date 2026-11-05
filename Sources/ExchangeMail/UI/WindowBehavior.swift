import AppKit
import SwiftUI

extension View {
    /// Opens the window with nothing focused: no focus ring and no text
    /// cursor until the person clicks or presses Tab. Use it on every window
    /// and sheet, except one whose only job is typing (a search or quick-add
    /// panel focuses its field on purpose).
    func noInitialFocus() -> some View {
        background(WindowHook())
    }

    /// Sizes a Form, List, or ScrollView to its content, up to `max` points.
    /// A Settings page or sheet then grows to fit, and scrolls only when its
    /// content is taller than `max`.
    func fitsContent(max: CGFloat = 640) -> some View {
        modifier(FitsContent(max: max))
    }
}

private struct FitsContent: ViewModifier {
    var max: CGFloat
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        content
            // Only the content's own height: the insets change as the window
            // resizes, which would start a resize loop.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height.rounded(.up)
            } action: { _, new in
                if abs(new - (height ?? 0)) >= 1 { height = new }
            }
            .frame(height: height.map { min($0, max) })
            .scrollBounceBehavior(.basedOnSize)
    }
}

/// A zero-size view that reaches the NSWindow it sits in.
private struct WindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        private var reopened = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.removeObserver(self)
            clear(window)
            // A closed window keeps its views. Clear again when it opens next time.
            NotificationCenter.default.addObserver(self, selector: #selector(willClose),
                                                   name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(didBecomeKey),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
        }

        @objc private func willClose(_ note: Notification) {
            reopened = true
        }

        @objc private func didBecomeKey(_ note: Notification) {
            guard reopened, let window else { return }
            reopened = false
            clear(window)
        }

        /// AppKit picks a first control right after the window shows. Clear it after that.
        private func clear(_ window: NSWindow) {
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }
}

extension View {
    /// 이 보기가 든 스크롤 영역의 스크롤 막대를 내용 위에 겹쳐 그린다(오버레이). 시스템 설정이 "항상"이어도
    /// 막대가 생길 때 내용 폭이 줄지 않는다. 사이드바처럼 줄 오른쪽 끝에 단추가 있는 목록에 쓴다.
    /// 목록의 줄(또는 구역 머리글) 안에 붙인다: 그 줄을 감싼 NSScrollView를 찾는다.
    func overlayScrollers() -> some View {
        background(OverlayScrollerHook())
    }
}

private struct OverlayScrollerHook: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.apply() }

    /// SwiftUI List는 줄 수가 바뀔 때 막대 모양을 다시 정하므로, 목록 크기가 바뀔 때마다 다시 건다.
    final class Probe: NSView {
        private weak var scroll: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            apply()
            NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                                   name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }

        @objc private func changed() { apply() }

        /// 이 보기를 감싼 스크롤 영역 (부모를 따라 올라가며 찾는다)
        private func findScroll() -> NSScrollView? {
            if let enclosingScrollView { return enclosingScrollView }
            var view = superview
            while let v = view {
                if let s = v as? NSScrollView { return s }
                view = v.superview
            }
            return nil
        }

        func apply() {
            guard let s = scroll ?? findScroll() else { return }
            if scroll !== s {
                scroll = s
                // 목록이 길어지거나 짧아질 때(구역 펼치기·접기) 다시 건다
                if let doc = s.documentView {
                    doc.postsFrameChangedNotifications = true
                    NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                                           name: NSView.frameDidChangeNotification, object: doc)
                }
            }
            if s.scrollerStyle != .overlay { s.scrollerStyle = .overlay }
        }
    }
}
