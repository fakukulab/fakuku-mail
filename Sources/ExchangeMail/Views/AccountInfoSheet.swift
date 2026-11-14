import ExchangeMailKit
import SwiftUI

/// 계정 정보 창을 여는 값 (S-074)
struct AccountInfoRequest: Identifiable, Equatable {
    let id: String
}

/// 계정 정보 (맥 Mail의 "계정 정보 가져오기"): 메일상자마다 메시지 수와 크기, 아래에 모두 합친 크기.
/// 줄을 고르고 "메시지 표시"를 누르면(또는 두 번 클릭) 그 메일상자로 간다.
struct AccountInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: String

    struct Row: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let depth: Int
        let count: Int
        let size: Int64?
    }

    @State private var sizes: [String: Int64]?
    @State private var selection: String?
    @State private var sortOrder: [KeyPathComparator<Row>] = []

    private var account: MailAccount? { model.accounts.accounts.first { $0.id == accountID } }

    private var rows: [Row] {
        let list = (model.accountFolders[accountID] ?? []).map { f in
            Row(id: f.id, name: f.displayName, symbol: f.symbol, depth: f.depth ?? 0,
                count: f.totalItemCount ?? 0, size: sizes?[f.id])
        }
        return sortOrder.isEmpty ? list : list.sorted(using: sortOrder)
    }

    private var totalCount: Int { rows.reduce(0) { $0 + $1.count } }
    private var totalSize: Int64? { sizes.map { s in rows.reduce(Int64(0)) { $0 + (s[$1.id] ?? 0) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(account.map { model.accounts.title(for: $0) } ?? L("계정"))
                .font(.headline)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(L("메일상자"), value: \.name) { row in
                    Label(row.name, systemImage: row.symbol)
                        .padding(.leading, CGFloat(sortOrder.isEmpty ? row.depth : 0) * Space.lg)
                }
                TableColumn(L("메시지"), value: \.count) { row in
                    Text(row.count, format: .number)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 72, ideal: 96, max: 140)
                .alignment(.trailing)
                TableColumn(L("크기"), value: \.sortSize) { row in
                    Group {
                        if let size = row.size {
                            Text(size == 0 ? "0" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        } else if sizes == nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("—")  // l10n: data
                                .foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 72, ideal: 104, max: 160)
                .alignment(.trailing)
            }
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first { show(id) }
            }
            HStack(spacing: Space.md) {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(L("메시지 표시")) { if let selection { show(selection) } }
                    .disabled(selection == nil)
                Button(L("완료")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 560, height: 480)
        .noInitialFocus()
        .task {
            guard let account else { sizes = [:]; return }
            sizes = await model.folderSizes(of: account)
        }
    }

    private var summary: String {
        let count = totalCount.formatted()
        guard let total = totalSize else { return L("메시지 \(count)개 · 크기를 세는 중…") }
        return L("\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))(\(count)개의 메시지)")
    }

    private func show(_ folderID: String) {
        model.selectedFolderID = folderID
        dismiss()
    }
}

extension AccountInfoSheet.Row {
    /// 크기 정렬: 모르는 크기는 맨 뒤
    var sortSize: Int64 { size ?? -1 }
}
