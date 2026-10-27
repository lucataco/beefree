import BeePipeline
import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(BeeStore.self) private var store
    @Query(filter: #Predicate<TodoItem> { $0.stateRaw == "inbox" }) private var inbox: [TodoItem]

    var body: some View {
        @Bindable var store = store
        Group {
            if store.known == nil {
                OnboardingView()
            } else {
                TabView {
                    Tab("Bee", systemImage: "circle.circle") { HomeView() }
                    Tab("Conversations", systemImage: "text.bubble") { ConversationsView() }
                    Tab("To-dos", systemImage: "checklist") { TodosView() }
                        .badge(inbox.filter { $0.owner != .someoneElse }.count)
                    Tab("Settings", systemImage: "gearshape") { SettingsView() }
                }
            }
        }
        .tint(.honey)
        .animation(.default, value: store.known == nil)
        .alert(item: $store.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .sheet(isPresented: $store.showKeyImport) {
            NavigationStack { KeyView(isSheet: true) }
        }
    }
}

#Preview {
    RootView().environment(BeeStore(preview: true))
}
