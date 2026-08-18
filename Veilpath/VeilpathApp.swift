import SwiftUI

@main
struct VeilpathApp: App {
    @State private var model = VeilpathModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
