import SwiftUI
import PanoLumeCore

@main
struct PanoLumeApp: App {
    @StateObject private var model = NativeWorkbenchModel()

    var body: some Scene {
        WindowGroup("PanoLume") {
            ContentView(model: model)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Photos...") {
                    PhotoImporter.importPhotos(into: model)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Import PTGui Project...") {
                    PTSProjectPanel.importAndPreview()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Reconstruct Imported Project...") {
                    PTSProjectPanel.reconstructFullResolution()
                }

                Button("Run Preview") {
                    model.runPreview()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
