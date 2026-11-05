import AppKit
import ExchangeMailKit
import IOKit.pwr_mgt
import SwiftUI

/// Screenshot mode for agents (demo mailbox, no network).
///   APP_STORE=/tmp/FAKUKUMail-test APP_SEED=1 APP_SNAPSHOT=/tmp/shots ~/Applications/FAKUKU\ Mail.app/Contents/MacOS/FAKUKUMail
/// writes <page>-light.png and <page>-dark.png for:
///   every well-known folder (inbox with the first message open, sentitems, drafts, archive, deleteditems),
///   signin (the sign-in page), compose (a reply window with a signature and a quote),
///   message (a message opened in its own window, S-043),
///   mailboxes (the VIP and smart mailbox editor sheets: vip-editor, smart-editor),
///   and settings-<tab> for every Settings tab. Then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=inbox,compose limits the pages. Add "settings" to include Settings.
enum Snapshot {
    static let folderPages = ["inbox", "sentitems", "drafts", "archive", "deleteditems"]

    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction, openWindow: OpenWindowAction) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty else { return }
        // Snapshots never run against the real account.
        guard Store.isDemo else {
            print("SNAPSHOT refused: set APP_STORE to a folder in /tmp and APP_SEED=1")
            NSApp.terminate(nil)
            return
        }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ page: String) -> Bool { only?.contains(page) ?? true }

        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))
            // 메인 창은 이름표("main", Window(id: "main"))로 찾는다. 지난 실행에서 복원된 작성 창 같은 다른 창이
            // 먼저 떠 있으면 그 창을 받은 편지함으로 잘못 찍었다. 찍기 전에 다른 창은 닫는다.
            let main = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && !$0.isSheet }
                ?? NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
            for window in NSApp.windows where window !== main && window.canBecomeMain && !window.isSheet {
                window.close()
            }
            main?.makeKeyAndOrderFront(nil)

            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for page in folderPages where wanted(page) {
                    model.selectedFolderID = page
                    try? await Task.sleep(for: .seconds(0.8))
                    if page == "inbox" { model.selectedMessageID = model.messages.first?.id }
                    try? await Task.sleep(for: .seconds(1.2))
                    capture(to: "\(dir)/\(page)-\(mode).png", window: main)
                }
                if wanted("signin") {
                    model.previewSignIn = true
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/signin-\(mode).png", window: main)
                    model.previewSignIn = false
                }
            }

            if wanted("compose") {
                model.selectedFolderID = "inbox"
                try? await Task.sleep(for: .seconds(0.8))
                model.selectedMessageID = model.messages.first?.id
                await model.loadDetail()
                if let draft = model.draft(.reply) {
                    openWindow(id: "compose", value: draft)
                    try? await Task.sleep(for: .seconds(2))
                    let compose = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet && $0.canBecomeMain }
                    for mode in ["light", "dark"] {
                        NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                        try? await Task.sleep(for: .seconds(0.8))
                        capture(to: "\(dir)/compose-\(mode).png", window: compose)
                    }
                    compose?.close()
                }
            }

            // 메일을 별도 창으로 (S-043)
            if wanted("message") {
                model.selectedFolderID = "inbox"
                try? await Task.sleep(for: .seconds(0.8))
                if let id = model.messages.first?.id {
                    openWindow(id: "message", value: id)
                    try? await Task.sleep(for: .seconds(2))
                    let window = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet && $0.canBecomeMain }
                    for mode in ["light", "dark"] {
                        NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                        try? await Task.sleep(for: .seconds(0.8))
                        capture(to: "\(dir)/message-\(mode).png", window: window)
                    }
                    window?.close()
                }
            }

            // VIP·스마트 메일상자 편집 시트 (S-045, S-046)
            if wanted("mailboxes") {
                model.selectedFolderID = "inbox"
                try? await Task.sleep(for: .seconds(0.8))
                let sheets: [(String, () -> Void)] = [
                    ("vip", { model.editingVIP = VIP(address: "kim@contoso.com", name: "김 팀장", symbol: "crown.fill") }),
                    ("smart", {
                        model.editingSmart = SmartMailbox(name: "이번 주 첨부", symbol: "paperclip", matchAll: true,
                                                          conditions: [.init(field: .attachments),
                                                                       .init(field: .receivedWithinDays, value: "7"),
                                                                       .init(field: .sender, value: "contoso")])
                    }),
                ]
                for (name, open) in sheets {
                    open()
                    for mode in ["light", "dark"] {
                        NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                        try? await Task.sleep(for: .seconds(1))
                        capture(to: "\(dir)/\(name)-editor-\(mode).png", window: main?.attachedSheet ?? main)
                    }
                    model.editingVIP = nil
                    model.editingSmart = nil
                    try? await Task.sleep(for: .seconds(0.6))
                }
            }

            if only == nil || only?.contains("settings") == true {
                openSettings()
                try? await Task.sleep(for: .seconds(1))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsTab.allCases {
                        model.settingsTab = tab
                        try? await Task.sleep(for: .seconds(1))
                        let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
                        capture(to: "\(dir)/settings-\(tab.rawValue)-\(mode).png", window: settings)
                    }
                }
            }
            print("SNAPSHOT done \(dir)")
            // An open sheet refuses terminate, and the run would wait forever.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
        }
    }

    /// Captures the real window with screencapture, so glass, sidebars, and
    /// materials look exactly as on screen. That needs Screen Recording
    /// permission for the app that started this one (your terminal, or Claude).
    /// Without it, falls back to drawing the view hierarchy, which leaves
    /// sidebars, glass, and web views blank.
    private static func capture(to path: String, window: NSWindow? = nil) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window for \(path)")
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, sidebars and web views are blank)")
        }
    }
}
