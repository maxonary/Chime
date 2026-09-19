import Foundation
import Combine

@MainActor
final class ConversationStore: ObservableObject {
  @Published var conversations: [Conversation] = []
  @Published var currentConversation: Conversation?

  private var pendingSave: Task<Void, Never>?
  private var dirtyConversationIds: Set<String> = []
  private let storePath: URL
  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(directory: URL? = nil, defaults: UserDefaults = .standard) {
    let fm = FileManager.default
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.storePath = directory ?? appSupport.appendingPathComponent("conversations")
    self.defaults = defaults

    do {
      try fm.createDirectory(at: storePath, withIntermediateDirectories: true)
    } catch {
      print("[ConversationStore] Failed to create directory: \(error)")
    }

    loadConversations()
    loadLastActiveConversation()
  }

  func createConversation(title: String = "New Chat") -> Conversation {
    let conv = Conversation(title: title)
    conversations.append(conv)
    setActiveConversation(conv)
    save(conv)
    return conv
  }

  func saveMessage(_ message: Message, to conversationId: String) {
    upsertMessage(message, to: conversationId)
    flush()
  }

  func upsertMessage(_ message: Message, to conversationId: String) {
    guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
    if let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == message.id }) {
      let original = conversations[index].messages[messageIndex]
      conversations[index].messages[messageIndex] = Message(
        id: message.id, role: message.role, content: message.content,
        timestamp: original.timestamp, metadata: message.metadata ?? original.metadata,
        transcriptStartMs: message.transcriptStartMs ?? original.transcriptStartMs,
        transcriptEndMs: message.transcriptEndMs ?? original.transcriptEndMs
      )
    } else {
      conversations[index].messages.append(message)
    }
    conversations[index].updatedAt = Date()
    dirtyConversationIds.insert(conversationId)
    if currentConversation?.id == conversationId { currentConversation = conversations[index] }
    // Coalesce caption fragments into at most one disk write per second.
    guard pendingSave == nil else { return }
    pendingSave = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  func flush() {
    pendingSave?.cancel()
    pendingSave = nil
    for conversation in conversations where dirtyConversationIds.contains(conversation.id) {
      save(conversation)
    }
  }

  func updateConversationTitle(_ id: String, newTitle: String) {
    if let index = conversations.firstIndex(where: { $0.id == id }) {
      conversations[index].title = newTitle
      conversations[index].updatedAt = Date()
      if currentConversation?.id == id { currentConversation = conversations[index] }
      save(conversations[index])
    }
  }

  private func save(_ conversation: Conversation) {
    dirtyConversationIds.insert(conversation.id)
    let path = storePath.appendingPathComponent("\(conversation.id).json")
    do {
      let data = try encoder.encode(conversation)
      try data.write(to: path, options: .atomic)
      dirtyConversationIds.remove(conversation.id)
    } catch {
      print("[ConversationStore] Failed to save: \(error)")
    }
  }

  private func loadConversations() {
    let fm = FileManager.default
    do {
      let files = try fm.contentsOfDirectory(at: storePath, includingPropertiesForKeys: nil)
      conversations = files
        .filter { $0.pathExtension == "json" }
        .compactMap { path in
          guard let data = try? Data(contentsOf: path) else { return nil }
          return try? decoder.decode(Conversation.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    } catch {
      print("[ConversationStore] Failed to load: \(error)")
    }
  }

  private func loadLastActiveConversation() {
    let settings = AppSettings.load(from: defaults)
    if let lastId = settings.lastActiveConversationId,
       let conv = conversations.first(where: { $0.id == lastId }) {
      currentConversation = conv
    } else if !conversations.isEmpty {
      currentConversation = conversations[0]
    }
  }

  func setActiveConversation(_ conversation: Conversation) {
    guard let stored = conversations.first(where: { $0.id == conversation.id }) else { return }
    flush()
    currentConversation = stored
    var settings = AppSettings.load(from: defaults)
    settings.lastActiveConversationId = conversation.id
    settings.save(to: defaults)
  }
}
