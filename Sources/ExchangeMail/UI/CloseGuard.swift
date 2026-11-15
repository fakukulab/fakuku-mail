import AppKit
import SwiftUI

/// 창을 닫기 전에 물을 수 있게 한다 (S-083). 닫기 단추와 ⌘W가 `shouldClose`를 거친다.
/// false를 돌려주면 창은 열린 채 남고, 뷰가 물어본 뒤 `WindowCloser.close()`로 닫는다.
/// 앱을 끝낼 때(⌘Q)는 묻지 않는다: 그때는 뷰의 onDisappear가 쓰던 것을 남긴다.
@MainActor
final class WindowCloser {
    fileprivate weak var window: NSWindow?

    /// 묻지 않고 닫는다
    func close() { window?.close() }
}

extension View {
    func closeGuard(_ closer: WindowCloser, shouldClose: @escaping @MainActor () -> Bool) -> some View {
        background(CloseGuardHook(closer: closer, shouldClose: shouldClose).frame(width: 0, height: 0))
    }
}

private struct CloseGuardHook: NSViewRepresentable {
    let closer: WindowCloser
    let shouldClose: @MainActor () -> Bool

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.closer = closer
        probe.proxy.shouldClose = shouldClose
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.closer = closer
        probe.proxy.shouldClose = shouldClose
    }

    final class Probe: NSView {
        var closer: WindowCloser?
        /// 창의 delegate는 약하게 잡히므로 여기서 붙잡는다
        let proxy = CloseGuardDelegate()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            closer?.window = window
            guard window.delegate !== proxy else { return }
            proxy.original = window.delegate
            window.delegate = proxy
        }
    }
}

/// SwiftUI가 붙인 창 delegate 앞에 서서 windowShouldClose만 먼저 보고, 나머지는 그대로 넘긴다.
final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    /// AppKit이 메인 스레드에서만 부른다 (창 delegate)
    nonisolated(unsafe) weak var original: NSWindowDelegate?
    var shouldClose: (@MainActor () -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let shouldClose, !shouldClose() { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let target = original, target.responds(to: aSelector) { return target }
        return super.forwardingTarget(for: aSelector)
    }
}
