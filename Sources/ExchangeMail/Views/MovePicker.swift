import ExchangeMailKit
import SwiftUI

/// 메시지 > 이동… (S-028): 폴더를 찾아 골라 옮긴다.
struct MovePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var query = ""
    @State private var choice: String?

    private var targets: [MoveTarget] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? model.moveTargets : model.moveTargets.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("메시지 \(model.selectedIDs.count)개를 옮길 폴더")
                .font(.headline)
            TextField("폴더 찾기", text: $query)
                .textFieldStyle(.roundedBorder)
            List(targets, selection: $choice) { target in
                Text(target.title).tag(target.id)
            }
            .frame(height: 240)
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("이동") { moveAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil)
            }
        }
        .padding(Space.margin)
        .frame(width: 360)
    }

    private func moveAndClose() {
        guard let folder = choice else { return }
        dismiss()
        Task { await model.moveSelected(to: folder, undoManager: undoManager, undoName: "이동") }
    }
}
