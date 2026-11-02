import AppKit
import SwiftUI

/// 설정 > 일반 > 앱 아이콘 색. 앱 아이콘(tools/icon_fakuku.py와 같은 그림)을 코드로 그려 Dock 아이콘을 바꾼다.
/// macOS는 앱이 켜져 있는 동안의 Dock 아이콘만 바꾸게 한다. Finder와 꺼진 앱의 아이콘은 기본(보라)이다.
enum AppIconColor: String, CaseIterable, Identifiable {
    case standard, blue, sky, green, orange, red, pink, graphite, black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "보라 (기본)"
        case .blue: "파랑"
        case .sky: "하늘"
        case .green: "초록"
        case .orange: "주황"
        case .red: "빨강"
        case .pink: "분홍"
        case .graphite: "회색"
        case .black: "검정"
        }
    }

    /// 아이콘 바탕 색 (아이콘 그림의 색이라 시스템 색이 아니라 고정 값이다)
    var color: Color {
        switch self {
        case .standard: Color(hex: "#6B4DE6") ?? .purple
        case .blue: Color(hex: "#2F6FEB") ?? .blue
        case .sky: Color(hex: "#1FA2E8") ?? .cyan
        case .green: Color(hex: "#2FB560") ?? .green
        case .orange: Color(hex: "#F08C2E") ?? .orange
        case .red: Color(hex: "#E5484D") ?? .red
        case .pink: Color(hex: "#E54D9A") ?? .pink
        case .graphite: Color(hex: "#6E7681") ?? .gray
        case .black: Color(hex: "#1F1F24") ?? .black
        }
    }

    static let key = "icon.color"

    static var current: AppIconColor {
        AppIconColor(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .standard
    }

    /// Dock 아이콘에 반영한다. 기본이면 앱 번들의 아이콘(Liquid Glass)으로 되돌린다.
    @MainActor
    static func apply(_ choice: AppIconColor = .current) {
        guard choice != .standard else {
            NSApp.applicationIconImage = nil
            return
        }
        let renderer = ImageRenderer(content: AppIconArt(color: choice.color).frame(width: 1024, height: 1024))
        renderer.scale = 1
        if let image = renderer.nsImage { NSApp.applicationIconImage = image }
    }
}

/// 앱 아이콘 그림: 둥근 사각형 바탕, 위가 열린 봉투와 편지, 오른쪽 아래 F 타일. 1024 기준 좌표.
struct AppIconArt: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let s = size.width / 1024
            // macOS 아이콘 격자: 1024 안에 824 크기 몸통 (가장자리 100 여백)
            let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let shape = Path(roundedRect: body, cornerRadius: 185 * s, style: .continuous)  // grid: ok 아이콘 그림 좌표(1024 기준)
            context.fill(shape, with: .linearGradient(
                Gradient(colors: [color.mix(with: .white, by: 0.25), color, color.mix(with: .black, by: 0.2)]),
                startPoint: CGPoint(x: body.midX, y: body.minY), endPoint: CGPoint(x: body.midX, y: body.maxY)))

            // 그림 좌표(1024 전체)를 몸통 안으로
            let k = 824.0 / 1024.0
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (100 + x * k) * s, y: (100 + y * k) * s) }
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
                CGRect(origin: p(x, y), size: CGSize(width: w * k * s, height: h * k * s))
            }
            let white = Color.white
            let line = StrokeStyle(lineWidth: 40 * k * s, lineJoin: .round)
            let (L, R, TOP, BOTTOM) = (170.0, 700.0, 430.0, 790.0)
            let MID = (L + R) / 2

            // 열린 덮개
            var flap = Path()
            flap.addLines([p(L, TOP), p(MID, TOP - 250), p(R, TOP)])
            flap.closeSubpath()
            context.fill(flap, with: .color(white.opacity(0.55)))
            context.stroke(flap, with: .color(white.opacity(0.55)), style: line)

            // 편지
            context.fill(Path(roundedRect: r(L + 70, TOP - 175, R - L - 140, 360), cornerRadius: 28 * k * s), with: .color(white))
            let ink = color.opacity(0.45)
            context.fill(Path(roundedRect: r(L + 125, TOP - 105, R - L - 250, 34), cornerRadius: 17 * k * s), with: .color(ink))  // grid: ok 아이콘 그림 좌표(1024 기준)
            context.fill(Path(roundedRect: r(L + 125, TOP - 40, R - L - 310, 34), cornerRadius: 17 * k * s), with: .color(ink))  // grid: ok 아이콘 그림 좌표(1024 기준)

            // 앞주머니
            let pocketColor = Color(hex: "#EFEAFF") ?? white
            var pocket = Path()
            pocket.addLines([p(L, TOP), p(MID, TOP + 210), p(R, TOP), p(R, BOTTOM), p(L, BOTTOM)])
            pocket.closeSubpath()
            context.fill(pocket, with: .color(pocketColor))
            context.stroke(pocket, with: .color(pocketColor), style: line)
            var fold = Path()
            fold.addLines([p(L + 10, BOTTOM - 10), p(MID, TOP + 260), p(R - 10, BOTTOM - 10)])
            context.stroke(fold, with: .color(color.opacity(0.18)),
                           style: StrokeStyle(lineWidth: 12 * k * s, lineCap: .round, lineJoin: .round))

            // F 타일
            let (TX, TY, TS) = (545.0, 505.0, 340.0)
            var shadow = context
            shadow.addFilter(.shadow(color: .black.opacity(0.25), radius: 14 * s, y: 6 * s))
            shadow.fill(Path(roundedRect: r(TX, TY, TS, TS), cornerRadius: 76 * k * s),
                        with: .color(Color(hex: "#1B2A80") ?? .indigo))
            let (sx, ty) = (TX + 105, TY + 72)
            for rect in [r(sx, ty, 58, 196), r(sx, ty, 150, 54), r(sx, ty + 80, 124, 50)] {
                context.fill(Path(roundedRect: rect, cornerRadius: 10 * k * s), with: .color(white))  // grid: ok 아이콘 그림 좌표(1024 기준)
            }
        }
        .accessibilityLabel("FAKUKU Mail 아이콘")
    }
}

/// 설정 > 일반의 앱 아이콘 색 고르기
struct AppIconSettings: View {
    @AppStorage(AppIconColor.key) private var choice = AppIconColor.standard.rawValue

    var body: some View {
        Section {
            LabeledContent("앱 아이콘:") {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .center, spacing: Space.md) {
                        AppIconArt(color: (AppIconColor(rawValue: choice) ?? .standard).color)
                            .frame(width: 64, height: 64)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: Space.sm), count: 9),
                                  alignment: .leading, spacing: Space.sm) {
                            ForEach(AppIconColor.allCases) { c in
                                Button {
                                    choice = c.rawValue
                                } label: {
                                    Circle()
                                        .fill(c.color)
                                        .frame(width: 20, height: 20)
                                        .overlay {
                                            if choice == c.rawValue {
                                                Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
                                            }
                                        }
                                        .frame(width: 28, height: 28)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(c.label)
                                .accessibilityLabel(c.label)
                                .accessibilityAddTraits(choice == c.rawValue ? .isSelected : [])
                            }
                        }
                        .frame(width: 9 * 28 + 8 * Space.sm)  // grid: ok 아이콘 그림 좌표(1024 기준)
                    }
                    SettingsNote("Dock 아이콘은 앱이 켜져 있는 동안 바뀝니다. Finder와 Launchpad의 아이콘은 macOS 규칙상 기본 보라색으로 남습니다.")
                }
            }
        }
        .onChange(of: choice) { _, value in AppIconColor.apply(AppIconColor(rawValue: value) ?? .standard) }
    }
}
