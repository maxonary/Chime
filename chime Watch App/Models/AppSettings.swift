import Foundation

struct AppSettings: Codable {
  var liveVoice: String? = "marin"
  var gatewayURL: URL
  var userToken: String
  var autoResearch: Bool
  var lastActiveConversationId: String?

  init(
    gatewayURL: URL = URL(string: "http://localhost:8788")!,
    userToken: String = "",
    autoResearch: Bool = true,
    lastActiveConversationId: String? = nil
  ) {
    self.gatewayURL = gatewayURL
    self.userToken = userToken
    self.autoResearch = autoResearch
    self.lastActiveConversationId = lastActiveConversationId
  }

  /// Merge a paired-device connection without replacing preferences or history.
  mutating func setConnection(address: String, token: String) -> Bool {
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme == "https", let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          !token.isEmpty else { return false }
    gatewayURL = url
    userToken = token
    return true
  }

  static func load(from defaults: UserDefaults = .standard) -> AppSettings {
    if let data = defaults.data(forKey: "appSettings"),
       let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
      return settings
    }
    return AppSettings()
  }

  func save(to defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: "appSettings")
    }
  }
}
