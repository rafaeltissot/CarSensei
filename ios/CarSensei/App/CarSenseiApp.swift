import SwiftUI

@main
struct CarSenseiApp: App {
    @StateObject private var store = CarSenseiStore.shared
    @StateObject private var loja = Loja.compartilhada

    init() {
        TissotFeedback.start()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(store)
                .environmentObject(loja)
        }
    }
}
