import AppKit
import ExchangeMailKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if model.showsMail {
                MailSplitView()
            } else {
                SignInView()
            }
        }
        .task {
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings, openWindow: openWindow)
        }
        .task(id: model.isSignedIn) { await model.reloadAll() }
        .task(id: model.isSignedIn) { await autoRefresh() }
        .alert("오류", isPresented: Binding(get: { model.errorMessage != nil },
                                          set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// 앱이 앞에 있는 동안 2분마다 받은 메일을 가져온다 (S-015).
    private func autoRefresh() async {
        guard model.isSignedIn, !model.isDemo else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            if NSApp.isActive { await model.refresh() }
        }
    }
}

struct MailSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            FolderSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            MessageListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 360)
        } detail: {
            MessageDetailView()
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "검색")
        .onSubmit(of: .search) { Task { await model.loadMessages() } }
        .onChange(of: model.searchText) { old, new in
            // 검색어를 지우면 원래 목록으로 돌아간다 (S-014).
            if new.isEmpty && !old.isEmpty { Task { await model.loadMessages() } }
        }
    }
}

struct FolderSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedFolderID) {
            Section(model.auth.email ?? "사서함") {
                ForEach(model.folders) { folder in
                    Label(folder.displayName, systemImage: folder.symbol)
                        .badge(folder.unreadItemCount ?? 0)
                        .tag(folder.id)
                }
            }
        }
        .overlay {
            if model.folders.isEmpty && model.isLoading {
                ProgressView()
            }
        }
    }
}
