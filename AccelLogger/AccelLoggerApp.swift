import SwiftUI

@main
struct AccelLoggerApp: App {
    @StateObject private var recorder = MotionRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
        }
    }
}
