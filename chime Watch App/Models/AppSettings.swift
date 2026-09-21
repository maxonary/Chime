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

  var hasConnection: Bool { !userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// Return true only when a valid incoming connection changes local settings.
  /// A delayed Watch message must not undo setup or rotation on the phone.
  mutating func importCompanionConnection(address: String, token: String, bootstrapOnly: Bool) -> Bool {
    guard !bootstrapOnly || !hasConnection else { return false }
    var incoming = self
    guard incoming.setConnection(address: address, token: token),
          incoming.gatewayURL != gatewayURL || incoming.userToken != userToken else { return false }
    self = incoming
    return true
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
