import SwiftUI

@main
struct chimeApp: App {
  @StateObject private var sessionManager = AgentSessionManager()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(sessionManager)
        .preferredColorScheme(.dark)
        .task { CompanionConnection.shared.start() }
    }
  }
}
