import SwiftUI

@main
struct chimeApp: App {
  #if os(watchOS)
  @WKApplicationDelegateAdaptor(ChimeAppDelegate.self) private var appDelegate
  #else
  @UIApplicationDelegateAdaptor(ChimeAppDelegate.self) private var appDelegate
  #endif
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
