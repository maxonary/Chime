import Foundation
import Combine
import CryptoKit

struct ResearchAnswer: Identifiable, Decodable {
  let id: String
  let request: String
  let state: String
  let result: String?
}

/// Answers remain on the authenticated gateway; no duplicate local transcript store.
@MainActor
final class ResearchInbox: ObservableObject {
  @Published private(set) var answers: [ResearchAnswer] = []
  @Published private(set) var error: String?
  private var refreshTask: Task<Void, Never>?
  private var generation = UUID()
  private var owner: String?
  private var forgottenKey: String {
    let settings = AppSettings.load()
    let identity = settings.gatewayURL.absoluteString + "|" + settings.userToken
    return "research.forget." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  var hasPendingForget: Bool { UserDefaults.standard.bool(forKey: forgottenKey) }

  func refresh() {
    guard refreshTask == nil else { return }
    let settings = AppSettings.load()
    guard settings.hasConnection else { return }
    let key = forgottenKey
    if owner != key { answers = []; owner = key; generation = UUID() }
    let id = generation
    refreshTask = Task { [weak self] in
      guard let self else { return }
      defer { if generation == id { refreshTask = nil } }
      do {
        if UserDefaults.standard.bool(forKey: key) {
          _ = try await Self.request(path: "v1/research", method: "DELETE", settings: settings)
          guard generation == id, forgottenKey == key else { return }
          UserDefaults.standard.removeObject(forKey: key)
        }
        let data = try await Self.request(path: "v1/research", settings: settings)
        struct Response: Decodable { let tasks: [ResearchAnswer] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard generation == id, forgottenKey == key else { return }
        answers = Array(response.tasks.suffix(20).reversed())
        error = nil
      } catch {
        guard generation == id, forgottenKey == key else { return }
        if hasPendingForget { self.error = "Waiting for a connection to forget saved research." }
        else { self.error = nil } // Older gateways do not have this optional endpoint.
      }
    }
  }
  func forget() {
    generation = UUID()
    answers = []
    UserDefaults.standard.set(true, forKey: forgottenKey)
    refreshTask?.cancel(); refreshTask = nil
    refresh()
  }
  func acknowledge(_ id: String) {
    guard UUID(uuidString: id) != nil else { return }
    Task { _ = try? await Self.request(path: "v1/research/\(id)/ack", method: "POST") }
  }
  static func request(path: String, method: String = "GET", body: [String: String]? = nil, settings suppliedSettings: AppSettings? = nil) async throws -> Data {
    let settings = suppliedSettings ?? AppSettings.load()
    var request = URLRequest(url: settings.gatewayURL.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 12
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(settings.userToken)", forHTTPHeaderField: "Authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    return data
  }
}
