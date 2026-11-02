import AppKit
import ExchangeMailKit
import Foundation
import SwiftUI

/// 깃발 색 (맥 Mail처럼 일곱 가지). Exchange에는 색이 없어 이 Mac에 메일마다 저장한다.
extension AppModel {

    /// 이 메일의 깃발 색. 깃발이 없으면 nil, 색을 정한 적이 없으면 빨간색.
    func flagColor(for m: MailMessage) -> FlagColor? {
        guard m.isFlagged else { return nil }
        return flagColors[FlagColor.key(for: m)] ?? .fallback
    }

    /// 지금 쓰는 색들 (사이드바의 깃발 표시 아래 색별 상자)
    var usedFlagColors: [FlagColor] {
        let used = Set(flagColors.values)
        return FlagColor.allCases.filter { used.contains($0) }
    }

    /// 고른 메일에 그 색 깃발을 단다 (깃발이 없으면 서버에 깃발도 단다).
    func setFlagColorSelected(_ color: FlagColor) async {
        let targets = messages.filter { selectedIDs.contains($0.id) }
        for m in targets {
            if !m.isFlagged { _ = await setFlag(id: m.id, flagged: true) }
            flagColors[FlagColor.key(for: m)] = color
        }
        updateMenu()
    }

    /// 메시지 창의 메일 한 통에
    func setFlagColor(_ color: FlagColor, for m: MailMessage) async -> Bool {
        if !m.isFlagged, !(await setFlag(id: m.id, flagged: true)) { return false }
        flagColors[FlagColor.key(for: m)] = color
        return true
    }

    /// 깃발을 뗄 때 색도 지운다.
    func forgetFlagColor(of m: MailMessage) {
        flagColors.removeValue(forKey: FlagColor.key(for: m))
    }
}

extension FlagColor {
    /// 화면에 보일 색 (시스템 색)
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    /// 색을 입힌 깃발 그림. 메뉴는 SF Symbol을 흑백(template)으로 그려 색을 지우므로,
    /// 색을 구운 non-template 그림을 쓴다 (메뉴, 사이드바).
    var flagImage: Image {
        let config = NSImage.SymbolConfiguration(paletteColors: [nsColor])
        guard let image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: label)?
                .withSymbolConfiguration(config) else { return Image(systemName: "flag.fill") }
        image.isTemplate = false
        return Image(nsImage: image)
    }

    /// 깃발 색 메뉴의 단축키 ⌥⌘1~7
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((FlagColor.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

/// 깃발 색 고르기 메뉴 항목들 (메시지 메뉴, 오른쪽 클릭, 도구 막대가 같이 쓴다)
struct FlagColorItems: View {
    var current: FlagColor?
    var shortcuts = false
    let choose: (FlagColor) -> Void

    var body: some View {
        ForEach(FlagColor.allCases, id: \.self) { c in
            let item = Button {
                choose(c)
            } label: {
                Label {
                    Text(c.label)
                } icon: {
                    c.flagImage
                }
            }
            if shortcuts {
                item.keyboardShortcut(c.shortcut, modifiers: [.command, .option])
            } else {
                item
            }
        }
    }
}
