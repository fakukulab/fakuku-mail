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
        let targets = selectedMessages
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

    /// 색을 입힌 깃발 그림 (메뉴, 사이드바).
    /// 메뉴는 SF Symbol 그림을 모양만 쓰고 앱 강조색으로 덧칠한다. 그래서 색 깃발을 보통 그림(비트맵)으로
    /// 한 번 그려서 넘긴다: 기호 정보가 없는 그림은 덧칠하지 않는다.
    var flagImage: Image {
        Image(nsImage: Self.cache[self] ?? Self.makeImage(self)).renderingMode(.original)
    }

    private static var cache: [FlagColor: NSImage] = [:]

    private static func makeImage(_ color: FlagColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.nsColor]))
        let symbol = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: color.label)?
            .withSymbolConfiguration(config)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let image = NSImage(size: size)
        if let rep, let symbol {
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let s = symbol.size
            let scale = min(size.width / s.width, size.height / s.height)
            let drawn = NSSize(width: s.width * scale, height: s.height * scale)
            symbol.draw(in: NSRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                   width: drawn.width, height: drawn.height))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = false
        cache[color] = image
        return image
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
                // macOS 메뉴는 기본으로 Label의 글자만 보인다. 아이콘(색 깃발)도 보이게 한다.
                .labelStyle(.titleAndIcon)
            }
            if shortcuts {
                item.keyboardShortcut(c.shortcut, modifiers: [.command, .option])
            } else {
                item
            }
        }
    }
}
