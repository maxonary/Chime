import Combine
import Foundation

/// Shared by foreground App Intents and the app, including a cold shortcut launch.
@MainActor
final class ChimeNavigation: ObservableObject {
  static let shared = ChimeNavigation()
  @Published var page = 1
  private(set) var researchTaskID: String?

  func openResearch(_ id: String) {
    guard UUID(uuidString: id) != nil else { return }
    researchTaskID = id
    openConversation()
  }

  func takeResearchTaskID() -> String? {
    defer { researchTaskID = nil }
    return researchTaskID
  }
  @Published private(set) var wantsConversation = true

  func requestConversation() { wantsConversation = true }

  func openConversation() {
    openBubble()
    requestConversation()
  }

  /// Consume each launch once; permission dialogs and wrist raises may activate
  /// the scene repeatedly without being another request to open the app.
  func consumeConversationRequest(isActive: Bool, isConfigured: Bool, isEnding: Bool) -> Bool {
    guard wantsConversation, isActive, isConfigured, !isEnding else { return false }
    wantsConversation = false
    return true
  }

  func openBubble() { page = 1 }

  func open(_ url: URL) {
    guard url.scheme == "chime", url.host == "bubble" else { return }
    openConversation()
  }
}
