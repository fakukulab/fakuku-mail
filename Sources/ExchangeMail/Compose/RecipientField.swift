import AppKit
import ExchangeMailKit
import SwiftUI

/// 작성 창의 받는 사람 칸 (맥 Mail처럼): 끝난 주소는 이름 토큰으로, 마우스를 올리면 강조색과 ⌄, 누르면 메뉴.
/// 칸의 값은 예전처럼 "이름 <주소>, 주소, …" 글자 하나다 (초안·보내기는 그대로).
/// 쉼표·세미콜론·Return이나 자동완성으로 토큰이 되고, 빈 칸에서 ⌫를 누르면 마지막 토큰을 지운다.
struct RecipientField<Focus: Hashable>: View {
    let title: String
    @Binding var text: String
    let book: AddressBookStore
    var focus: FocusState<Focus?>.Binding
    let focusValue: Focus

    /// 끝난 주소와 쓰는 중인 글자. 칸 밖에 있으면 쓰던 글자도 토큰으로 보인다 (답장에 미리 채운 마지막 주소 등).
    private var pieces: (tokens: [String], pending: String) {
        let p = AddressBook.pieces(text)
        guard focus.wrappedValue != focusValue, !p.pending.isEmpty else { return p }
        return (p.tokens + [p.pending], "")
    }

    /// 지금 쓰는 글자 (토큰 뒤의 입력 칸)
    private var pending: Binding<String> {
        Binding(get: { pieces.pending },
                set: { text = AddressBook.join(tokens: pieces.tokens, pending: $0) })
    }

    var body: some View {
        let tokens = pieces.tokens
        TokenFlow(spacing: Space.xs, lastMinWidth: 120) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                ComposeAddressToken(token: token,
                                    edit: { edit(at: index) },
                                    remove: { remove(at: index) })
            }
            TextField(title, text: pending, prompt: Text(""))
                .textFieldStyle(.plain)
                .focused(focus, equals: focusValue)
                .addressSuggestions(for: pending.wrappedValue, from: book)
                .onSubmit(commit)
                .onKeyPress(.delete) {
                    guard pieces.pending.isEmpty, !pieces.tokens.isEmpty else { return .ignored }
                    remove(at: pieces.tokens.count - 1)
                    return .handled
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = focusValue }
        .onChange(of: focus.wrappedValue) { old, new in
            // 칸을 떠나면 쓰던 주소도 토큰으로
            if old == focusValue && new != focusValue { commit() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func commit() {
        let p = pieces
        guard !p.pending.isEmpty else { return }
        text = AddressBook.join(tokens: p.tokens + [p.pending], pending: "")
    }

    private func remove(at index: Int) {
        var tokens = pieces.tokens
        guard tokens.indices.contains(index) else { return }
        tokens.remove(at: index)
        text = AddressBook.join(tokens: tokens, pending: pieces.pending)
    }

    /// 토큰을 다시 글자로 (입력 칸에 넣어 고친다)
    private func edit(at index: Int) {
        var tokens = pieces.tokens
        guard tokens.indices.contains(index) else { return }
        let token = tokens.remove(at: index)
        text = AddressBook.join(tokens: tokens, pending: token)
        focus.wrappedValue = focusValue
    }
}

/// 작성 창의 주소 토큰: 받은 메일 머리글의 `AddressToken`과 같은 모양 (이름, 마우스를 올리면 강조색과 ⌄)
struct ComposeAddressToken: View {
    let token: String
    let edit: () -> Void
    let remove: () -> Void
    private var address: MailAddress? { AddressParser.parseOne(token) }

    var body: some View {
        Menu {
            if let address {
                Toggle(address.address, isOn: .constant(true)).disabled(true)
                Divider()
            }
            Button(L("주소 편집")) { edit() }
            Button(L("주소 복사")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address?.editable ?? token, forType: .string)
            }
            Divider()
            Button(L("제거"), role: .destructive) { remove() }
        } label: {
            // 맥 Mail처럼 늘 같은 모양: 연한 강조색 바탕, 이름, ⌄ (마우스를 올려도 크기·색이 바뀌지 않아 줄이 흔들리지 않는다)
            HStack(spacing: 2) {
                Text(address?.display ?? token)
                    .foregroundStyle(address == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: Space.xs, style: .continuous)
                .fill(address == nil ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(Palette.accentFill)))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(address == nil ? L("주소 형식이 맞지 않습니다: \(token)") : (address?.editable ?? token))
    }
}

/// 토큰을 줄 바꿈하며 놓고, 마지막(입력 칸)은 그 줄의 남은 폭을 다 쓴다 (모자라면 다음 줄 전체)
struct TokenFlow: Layout {
    var spacing: CGFloat
    var lastMinWidth: CGFloat

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var out: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let isLast = i == subviews.count - 1
            var size = v.sizeThatFits(.unspecified)
            if isLast {
                if x > 0 && width - x < lastMinWidth { x = 0; y += line + spacing; line = 0 }
                size.width = max(lastMinWidth, width - x)
                size.height = v.sizeThatFits(ProposedViewSize(width: size.width, height: nil)).height
            } else if x > 0 && x + size.width > width {
                x = 0; y += line + spacing; line = 0
            }
            out.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            line = max(line, size.height)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let f = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: f.map(\.maxY).max() ?? 0)
    }

    /// 레이블("받는 사람:")과 첫 줄의 글자 기준선을 맞춘다
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first,
              let r = frames(width: bounds.width, subviews: subviews).first else { return nil }
        return bounds.minY + r.minY + first.dimensions(in: ProposedViewSize(width: r.width, height: r.height))[.firstTextBaseline]
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = frames(width: bounds.width, subviews: subviews)
        for (v, r) in zip(subviews, f) {
            v.place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY),
                    proposal: ProposedViewSize(width: r.width, height: r.height))
        }
    }
}
