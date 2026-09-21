import Foundation
import Combine
import CryptoKit

struct MemoryContent: Codable, Equatable, Sendable {
  var facts: [String] = []
  var context: String = ""
}

struct MemoryTurn: Codable, Sendable {
  let role: String
  let content: String
  let timestamp: String
}

struct MemoryRequest: Codable, Sendable {
  let memory: MemoryContent
  let turns: [MemoryTurn]
}

@MainActor
final class MemoryStore: ObservableObject {
  typealias Compiler = (MemoryRequest, AppSettings) async throws -> MemoryContent
  private struct Checkpoint: Codable { let digest: String; let chunks: Int }
  private struct State: Codable {
    var content = MemoryContent()
    var checkpoints: [String: Checkpoint] = [:]
    var updatedAt: Date?
    var forgottenBefore: Date?
  }
  private struct Work {
    let id: String
    let digest: String
    let nextChunk: Int
    let totalChunks: Int
    let turn: MemoryTurn
  }

  @Published private(set) var content = MemoryContent()
  @Published private(set) var updatedAt: Date?
  @Published private(set) var isUpdating = false
  @Published private(set) var error: String?
  var activeConversationID: String?
  private let conversations: ConversationStore
  private let path: URL
  private let compiler: Compiler
  private let settingsProvider: () -> AppSettings
  private var state = State()
  private var task: Task<Void, Never>?
  private var generation = UUID()

  init(conversations: ConversationStore, directory: URL? = nil, settings: @escaping () -> AppSettings = { AppSettings.load() }, compiler: Compiler? = nil) {
    self.conversations = conversations
    let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.path = folder.appendingPathComponent("memory.json")
    self.compiler = compiler ?? Self.compile
    self.settingsProvider = settings
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: path), let saved = try? JSONDecoder().decode(State.self, from: data) {
      state = saved
      content = saved.content
      updatedAt = saved.updatedAt
    }
  }

  private var eligibleMessages: [Message] {
    conversations.conversations.flatMap(\.messages)
      .filter { $0.role != .system && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (state.forgottenBefore == nil || $0.timestamp > state.forgottenBefore!) }
      .sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
  }

  var recentHistory: [[String: String]] {
    eligibleMessages.suffix(12).map { ["role": $0.role.rawValue, "content": String($0.content.prefix(1500))] }
  }

  /// Retry pending work after ending a call or returning to the app. A failed
  /// provider call leaves both the previous memory and the source turns intact.
  func refresh() {
    guard task == nil else { return }
    let excluded = Set(conversations.conversations.first(where: { $0.id == activeConversationID })?.messages.map(\.id) ?? [])
    var batch: [Work] = []
    var remaining = 24000
    for message in eligibleMessages where !excluded.contains(message.id) {
      let digest = Self.digest(message)
      let chunks = Self.chunks(message.content)
      let completed = state.checkpoints[message.id].flatMap { $0.digest == digest ? $0.chunks : nil } ?? 0
      for index in completed..<max(completed, chunks.count) {
        let text = chunks[index]
        guard batch.count < 32, text.utf8.count <= remaining else { break }
        batch.append(Work(id: message.id, digest: digest, nextChunk: index + 1, totalChunks: chunks.count,
                          turn: MemoryTurn(role: message.role.rawValue, content: text, timestamp: message.timestamp.ISO8601Format())))
        remaining -= text.utf8.count
      }
      if batch.count >= 32 || remaining < 5000 { break }
    }
    guard !batch.isEmpty else { return }
    let settings = settingsProvider()
    guard !settings.userToken.isEmpty else { return }
    let request = MemoryRequest(memory: content, turns: batch.map(\.turn))
    let id = generation
    isUpdating = true
    error = nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await compiler(request, settings)
        guard !Task.isCancelled, generation == id else { return }
        guard result.facts.count <= 12, result.facts.allSatisfy({ $0.utf16.count <= 180 }),
              result.context.utf16.count <= 1200 else { throw URLError(.cannotParseResponse) }
        var next = state
        next.content = result
        next.updatedAt = Date()
        for item in batch { next.checkpoints[item.id] = Checkpoint(digest: item.digest, chunks: item.nextChunk) }
        // Persist the summary before pruning any source transcripts.
        try persist(next)
        state = next
        content = result
        updatedAt = next.updatedAt
        let completedIDs = Set(eligibleMessages.filter { message in
          guard let checkpoint = next.checkpoints[message.id] else { return false }
          return checkpoint.digest == Self.digest(message) && checkpoint.chunks >= Self.chunks(message.content).count
        }.map(\.id))
        conversations.pruneCompiledMessages(completedIDs, keepingRecent: 12, excluding: activeConversationID)
        // Checkpoint metadata need only cover turns still present on disk.
        let retained = Set(conversations.conversations.flatMap(\.messages).map(\.id))
        next.checkpoints = next.checkpoints.filter { retained.contains($0.key) }
        if (try? persist(next)) != nil { state = next }
        task = nil
        isUpdating = false
        refresh()
      } catch {
        guard generation == id else { return }
        self.error = "Memory will update when the connection is available."
        task = nil
        isUpdating = false
      }
    }
  }

  func forget() {
    guard activeConversationID == nil else { return }
    var cleared = State()
    // This tombstone also excludes any old transcript file that cannot be removed.
    cleared.forgottenBefore = Date()
    do {
      try persist(cleared)
      generation = UUID()
      task?.cancel()
      task = nil
      isUpdating = false
      state = cleared
      content = cleared.content
      updatedAt = nil
      error = nil
      conversations.clear()
    } catch { self.error = "Could not clear memory. Please try again." }
  }

  private func persist(_ value: State) throws {
    try JSONEncoder().encode(value).write(to: path, options: .atomic)
  }

  private static func digest(_ message: Message) -> String {
    SHA256.hash(data: Data((message.role.rawValue + "\n" + message.content).utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Split long turns instead of silently dropping their later facts.
  private static func chunks(_ text: String) -> [String] {
    var result: [String] = []
    var chunk = ""
    var bytes = 0
    for scalar in text.unicodeScalars {
      let part = String(scalar)
      if bytes + part.utf8.count > 5000 { result.append(chunk); chunk = ""; bytes = 0 }
      chunk += part
      bytes += part.utf8.count
    }
    if !chunk.isEmpty { result.append(chunk) }
    return result
  }

  private static func compile(_ request: MemoryRequest, settings: AppSettings) async throws -> MemoryContent {
    let url = settings.gatewayURL.appendingPathComponent("v1/memory")
    var http = URLRequest(url: url, timeoutInterval: 40)
    http.httpMethod = "POST"
    http.setValue("Bearer \(settings.userToken)", forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.httpBody = try JSONEncoder().encode(request)
    let (data, response) = try await URLSession.shared.data(for: http)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw URLError(.badServerResponse) }
    return try JSONDecoder().decode(MemoryContent.self, from: data)
  }
}
