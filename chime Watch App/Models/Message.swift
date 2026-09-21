import Foundation

struct Message: Identifiable, Codable {
  let id: String
  let role: MessageRole
  let content: String
  let timestamp: Date
  let metadata: MessageMetadata?
  let transcriptStartMs: Double?
  let transcriptEndMs: Double?

  init(id: String = UUID().uuidString, role: MessageRole, content: String, timestamp: Date = Date(), metadata: MessageMetadata? = nil, transcriptStartMs: Double? = nil, transcriptEndMs: Double? = nil) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
    self.metadata = metadata
    self.transcriptStartMs = transcriptStartMs
    self.transcriptEndMs = transcriptEndMs
  }
}

enum MessageRole: String, Codable {
  case user
  case assistant
  case system
}

struct MessageMetadata: Codable {
  let citations: [Citation]?
  let confidence: Double?

  struct Citation: Codable {
    let title: String
    let url: String
    let snippet: String
  }
}

struct Conversation: Identifiable, Codable {
  let id: String
  var title: String
  var messages: [Message]
  var createdAt: Date
  var updatedAt: Date

  init(id: String = UUID().uuidString, title: String = "New Chat", messages: [Message] = [], createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.messages = messages
    self.createdAt = createdAt
    self.updatedAt = Date()
  }
}
