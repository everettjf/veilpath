import SwiftUI

@main
struct VelluneApp: App {
    @State private var model = VelluneModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
