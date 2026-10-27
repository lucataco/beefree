import SwiftData
import SwiftUI

@main
struct BeeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Created at launch, including background relaunches for Bluetooth state restoration,
    /// so the central manager exists before iOS hands over the restored connection.
    private let store = BeeStore.shared

    init() {
        // Background task handlers have to be registered before launch finishes.
        BackgroundWork.register(store)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onOpenURL { store.open($0) }
        }
        .modelContainer(store.container)
        .onChange(of: scenePhase, initial: true) { _, phase in
            store.isActive = phase == .active
        }
    }
}
