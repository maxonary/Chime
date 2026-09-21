import Foundation

@main
struct ConversationStoreTests {
  @MainActor
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chime-store-tests-\(UUID())")
    let suite = "chime-store-tests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    let store = ConversationStore(directory: root, defaults: defaults)
    let first = store.createConversation(title: "First")
    let original = Message(id: "caption", role: .user, content: "Hello", timestamp: Date(timeIntervalSince1970: 100))
    store.upsertMessage(original, to: first.id)
    store.upsertMessage(Message(id: original.id, role: .user, content: "Hello world"), to: first.id)
    let second = store.createConversation(title: "Second")
    store.upsertMessage(Message(id: "reply", role: .assistant, content: "Second conversation"), to: second.id)
    store.flush()

    let restored = ConversationStore(directory: root, defaults: defaults)
    guard let restoredFirst = restored.conversations.first(where: { $0.id == first.id }) else { fatalError("First conversation missing") }
    precondition(restoredFirst.messages.count == 1, "Switching conversations must preserve pending captions")
    precondition(restoredFirst.messages[0].content == "Hello world", "Caption updates must replace, not duplicate, text")
    precondition(restoredFirst.messages[0].timestamp == original.timestamp, "A caption retains its original creation time")
    precondition(restored.currentConversation?.id == second.id, "The active conversation survives restart")

    // A late update to an inactive conversation must neither steal selection nor disappear.
    restored.upsertMessage(Message(id: "late", role: .assistant, content: "Late result"), to: first.id)
    restored.updateConversationTitle(second.id, newTitle: "Updated title")
    restored.flush()
    let afterLateUpdate = ConversationStore(directory: root, defaults: defaults)
    precondition(afterLateUpdate.currentConversation?.id == second.id)
    precondition(afterLateUpdate.currentConversation?.title == "Updated title", "Flush must not overwrite a newer title with a stale selected copy")
    precondition(afterLateUpdate.conversations.first(where: { $0.id == first.id })?.messages.count == 2)

    // History views can hold old value copies; selection must resolve the current stored version.
    afterLateUpdate.setActiveConversation(first)
    precondition(afterLateUpdate.currentConversation?.messages.count == 2)
    afterLateUpdate.saveMessage(Message(role: .assistant, content: "Other reply"), to: second.id)
    precondition(afterLateUpdate.currentConversation?.id == first.id)

    afterLateUpdate.upsertMessage(Message(id: "automatic", role: .user, content: "Saved automatically"), to: first.id)
    try await Task.sleep(for: .milliseconds(1200))
    let automaticallySaved = ConversationStore(directory: root, defaults: defaults)
    precondition(automaticallySaved.currentConversation?.messages.last?.content == "Saved automatically", "Captions must save without an explicit flush")

    // Existing installs must retain their credentials and old transcript JSON.
    let oldSettings = Data(#"{"gatewayURL":"https://example.com","userToken":"test-token","agentModel":"claude-opus-5","autoResearch":false}"#.utf8)
    defaults.set(oldSettings, forKey: "appSettings")
    let migrated = AppSettings.load(from: defaults)
    precondition(migrated.userToken == "test-token" && !migrated.autoResearch)
    precondition(migrated.liveVoice == nil || migrated.liveVoice == "marin")
    var connection = AppSettings(gatewayURL: URL(string: "https://old.example.com")!,
                                 userToken: "old-token", autoResearch: false,
                                 lastActiveConversationId: "keep-history")
    connection.liveVoice = "willow"
    for address in ["http://example.com", "https://user:secret@example.com", "https://example.com?token=secret", "https://example.com#secret", "not a URL"] {
      precondition(!connection.setConnection(address: address, token: "replacement"))
      precondition(connection.userToken == "old-token", "Invalid setup must preserve the working connection")
    }
    precondition(!connection.setConnection(address: "https://example.com", token: " \n"))
    precondition(connection.setConnection(address: " https://example.com/voice ", token: " new-token\n"))
    precondition(connection.gatewayURL.absoluteString == "https://example.com/voice" && connection.userToken == "new-token")
    precondition(connection.liveVoice == "willow" && !connection.autoResearch && connection.lastActiveConversationId == "keep-history",
                 "Pairing must not replace voice preferences or the local conversation pointer")
    let oldMessage = Data(#"{"id":"old","role":"user","content":"Old chat","timestamp":0}"#.utf8)
    let decodedMessage = try JSONDecoder().decode(Message.self, from: oldMessage)
    precondition(decodedMessage.transcriptStartMs == nil)
    print("PASS: caption persistence, conversation switching, original timestamps, late updates, title updates, and legacy data migration")
  }
}
