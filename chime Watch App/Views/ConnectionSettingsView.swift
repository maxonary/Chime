#if os(iOS)
import SwiftUI

struct ConnectionSettingsView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  @ObservedObject private var companion = CompanionConnection.shared
  @State private var address = AppSettings.load().userToken.isEmpty
    ? "https://chime-gateway.onrender.com" : AppSettings.load().gatewayURL.absoluteString
  @State private var token = AppSettings.load().userToken
  @State private var message: String?

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        Image("SoapBubble")
          .resizable().scaledToFit().frame(height: 100)
          .frame(maxWidth: .infinity).accessibilityHidden(true)
        Text("Your voice, a little closer.").font(.title2)
        Text("Connect once on your iPhone. Your paired Watch receives the connection automatically.")
          .foregroundStyle(.secondary)
      }
      .listRowBackground(Color.black)
    }
    Section("Connection") {
      TextField("Service address", text: $address)
        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
      SecureField("Chime access token", text: $token)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      Button("Save connection") { save() }
      if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
      Text("Use your Chime service token, not an OpenAI API key.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .disabled(sessionManager.isListening)
    Section("Apple Watch") {
      Button("Sync to Watch") { companion.sync() }
        .disabled(AppSettings.load().userToken.isEmpty)
      Text(companion.status).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func save() {
    var settings = AppSettings.load()
    guard settings.setConnection(address: address, token: token) else {
      message = "Enter an HTTPS service address and your Chime access token."
      return
    }
    settings.save()
    companion.sync()
    message = "Saved. Swipe right to the bubble to start a conversation."
  }
}
#endif
