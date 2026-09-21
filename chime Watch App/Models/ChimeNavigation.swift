import Combine
import Foundation

/// Shared by foreground App Intents and the app, including a cold shortcut launch.
@MainActor
final class ChimeNavigation: ObservableObject {
  static let shared = ChimeNavigation()
  @Published var page = 1

  func openBubble() { page = 1 }

  func open(_ url: URL) {
    guard url.scheme == "chime", url.host == "bubble" else { return }
    openBubble()
  }
}
