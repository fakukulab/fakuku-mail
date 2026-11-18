import AppKit

/// 받는 사람 칸의 주소 제안 목록 (S-087). 시스템 자동완성 팝업은 마우스를 올려도 줄이 바뀌지 않아 직접 그린다.
/// - 처음에는 맨 위 줄이 골라져 있다 (파란 강조).
/// - 마우스를 올린 줄이 같은 파란 강조로 바뀐다. 누르면 그 주소를 넣는다.
/// - ↑↓로 옮기고 Return·Tab으로 넣는다, Esc로 닫는다 (RecipientField.Coordinator가 키를 넘긴다).
/// 창의 자식 창이라 작성 창과 함께 움직이고, 키 창이 되지 않아 입력은 받는 사람 칸에 그대로 남는다.
@MainActor
final class AddressSuggestionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var items: [String] = []
    /// 고른 주소를 넣는다
    var onPick: ((String) -> Void)?

    private let rowHeight: CGFloat = 24
    private let inset: CGFloat = 4
    private let maxRows = 8

    private lazy var panel: NSPanel = {
        let p = SuggestionWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = true
        p.contentView = background
        return p
    }()

    private lazy var background: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .menu
        v.state = .active
        v.blendingMode = .behindWindow
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.masksToBounds = true
        v.addSubview(scroll)
        return v
    }()

    private lazy var scroll: NSScrollView = {
        let s = NSScrollView()
        s.drawsBackground = false
        s.hasVerticalScroller = false
        s.documentView = table
        return s
    }()

    private lazy var table: HoverTableView = {
        let t = HoverTableView()
        let column = NSTableColumn(identifier: .init("address"))
        t.addTableColumn(column)
        t.headerView = nil
        t.backgroundColor = .clear
        t.rowHeight = rowHeight
        t.intercellSpacing = .zero
        t.style = .plain
        t.selectionHighlightStyle = .regular
        t.focusRingType = .none
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.action = #selector(clicked)
        t.onHover = { [weak self] row in self?.select(row) }
        return t
    }()

    var isVisible: Bool { panel.isVisible }
    var selected: String? {
        let row = table.selectedRow
        return items.indices.contains(row) ? items[row] : nil
    }

    /// `anchor`(화면 좌표, 칸 아래 왼쪽) 아래에 목록을 보인다. 비어 있으면 닫는다.
    func show(_ list: [String], below anchor: NSPoint, width: CGFloat, in parent: NSWindow) {
        guard !list.isEmpty else { hide(); return }
        items = list
        table.reloadData()
        let rows = min(list.count, maxRows)
        let size = NSSize(width: width, height: CGFloat(rows) * rowHeight + inset * 2)
        panel.setFrame(NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height), display: false)
        scroll.frame = NSRect(x: 0, y: inset, width: size.width, height: size.height - inset * 2)
        table.tableColumns.first?.width = size.width
        select(0)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
    }

    /// ↑↓: 한 줄씩, 끝에서 멈춘다
    func move(by step: Int) {
        guard !items.isEmpty else { return }
        select(min(max(table.selectedRow + step, 0), items.count - 1))
    }

    private func select(_ row: Int) {
        guard items.indices.contains(row), row != table.selectedRow else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        onPick?(items[row])
    }

    // MARK: 표

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(text)
            c.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = items[row]
        return cell
    }

    /// 골라진 줄은 시스템 강조 색(파랑)으로, 키 창이 아니어도 흐려지지 않게
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }
}

/// 키 창이 되지 않는 제안 창 (입력은 작성 창에 남는다)
private final class SuggestionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 둥근 파란 강조 (맥 Mail의 주소 제안과 같은 모양)
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}

/// 마우스를 올린 줄을 알린다
private final class HoverTableView: NSTableView {
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover?(row) }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    /// 패널이 키 창이 아니어도 첫 클릭으로 고른다
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
