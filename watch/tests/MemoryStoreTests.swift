import Foundation

@main
struct MemoryStoreTests {
  @MainActor
  static func settle(_ store: MemoryStore) async throws {
    for _ in 0..<500 {
      if !store.isUpdating { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    fatalError("Memory update did not finish")
  }

  @MainActor
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chime-memory-\(UUID())")
    let suite = "chime-memory-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    let source = root.appendingPathComponent("conversations")
    let conversations = ConversationStore(directory: source, defaults: defaults)
    let conversation = conversations.createConversation()
    for index in 0..<16 {
      conversations.upsertMessage(Message(role: .user, content: "Detail \(index)", timestamp: Date(timeIntervalSince1970: Double(index))), to: conversation.id)
    }
    conversations.flush()
    var fail = true
    var calls = 0
    let settings = { AppSettings(userToken: "test") }
    let store = MemoryStore(conversations: conversations, directory: root, settings: settings) { request, _ in
      calls += 1
      precondition(request.turns.count == 16)
      if fail { throw URLError(.notConnectedToInternet) }
      return MemoryContent(facts: ["Prefers tea"], context: "A project")
    }
    store.activeConversationID = conversation.id
    store.refresh()
    precondition(!store.isUpdating && calls == 0, "Active captions must not be compacted")
    store.activeConversationID = nil
    store.refresh()
    try await settle(store)
    precondition(store.error != nil && conversations.conversations[0].messages.count == 16)
    precondition(store.content.facts.isEmpty, "Failure must preserve previous memory and source")
    fail = false
    store.refresh()
    try await settle(store)
    precondition(calls == 2 && store.content.facts == ["Prefers tea"])
    precondition(conversations.conversations[0].messages.count == 12, "Keep only recent raw turns after durable compaction")
    let restoredConversations = ConversationStore(directory: source, defaults: defaults)
    let restored = MemoryStore(conversations: restoredConversations, directory: root, settings: settings) { _, _ in
      fatalError("Unchanged covered turns must not be recompiled after restart")
    }
    precondition(restored.content == store.content && restored.recentHistory.count == 12)
    restored.refresh()
    precondition(!restored.isUpdating)

    // Splitting preserves all Unicode text, including details beyond the first batch.
    let longConversation = conversations.createConversation()
    let text = String(repeating: "🫧", count: 15000) + "My dog is Pippa."
    conversations.saveMessage(Message(role: .user, content: text), to: longConversation.id)
    var received = ""
    var batchCount = 0
    let longStore = MemoryStore(conversations: conversations, directory: root, settings: settings) { request, _ in
      batchCount += 1
      received += request.turns.map(\.content).joined()
      return MemoryContent(facts: ["Has a dog called Pippa"], context: "")
    }
    longStore.refresh()
    try await settle(longStore)
    precondition(received == text && batchCount > 1, "Long turns must survive batching without truncation")

    // An in-flight result must never resurrect explicitly forgotten memory.
    conversations.saveMessage(Message(role: .user, content: "Forget this"), to: longConversation.id)
    var continuation: CheckedContinuation<MemoryContent, Never>?
    let delayed = MemoryStore(conversations: conversations, directory: root, settings: settings) { _, _ in
      await withCheckedContinuation { continuation = $0 }
    }
    delayed.refresh()
    while continuation == nil { await Task.yield() }
    delayed.forget()
    continuation?.resume(returning: MemoryContent(facts: ["Must not return"], context: ""))
    try await Task.sleep(for: .milliseconds(20))
    precondition(delayed.content.facts.isEmpty && delayed.recentHistory.isEmpty)
    let afterForget = MemoryStore(conversations: ConversationStore(directory: source, defaults: defaults), directory: root, settings: settings)
    precondition(afterForget.content.facts.isEmpty && afterForget.recentHistory.isEmpty)
    print("PASS: memory retries, durable reload, pruning, checkpoints, active-call exclusion, Unicode batching, and forgetting in-flight updates")
  }
}
