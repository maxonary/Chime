#if os(iOS)
import SwiftUI

struct ConnectionSettingsView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  @ObservedObject private var companion = CompanionConnection.shared
  @State private var address = AppSettings.load().hasConnection
    ? AppSettings.load().gatewayURL.absoluteString : "https://chime-gateway.onrender.com"
  @State private var token = AppSettings.load().userToken
  @State private var message: String?

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 16) {
        Image("SoapBubble")
          .resizable().scaledToFit().frame(height: 110)
          .frame(maxWidth: .infinity).accessibilityHidden(true)
        Text(companion.isConfigured ? "All connected." : "Your Watch knows the way.")
          .font(.title2.weight(.medium))
        Text(companion.isConfigured
             ? "Your voice connection is ready on this iPhone."
             : "Open Chime on your paired Apple Watch. We’ll bring your connection over and take you straight to the bubble.")
          .font(.body).foregroundStyle(.secondary)
      }
      .padding(.vertical, 12)
      .listRowBackground(Color.black)
    }
    if !companion.isConfigured {
      Section {
        Button("Connect with my Watch", systemImage: "applewatch") { companion.start() }
        Text(companion.status).font(.callout).foregroundStyle(.secondary)
      }
    }
    Section {
      DisclosureGroup("Advanced connection") {
        TextField("Service address", text: $address)
          .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        SecureField("Chime access token", text: $token)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Save connection") { save() }
        if companion.isConfigured {
          Button("Sync to Watch") { companion.sync() }
        }
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        Text("For a new service or a phone without a configured Watch. Use a Chime service token, not an OpenAI API key.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .disabled(sessionManager.isListening)
    .onChange(of: companion.isConfigured) { _, configured in
      if configured {
        let settings = AppSettings.load()
        address = settings.gatewayURL.absoluteString
        token = settings.userToken
      }
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
    message = "Saved. Your connection is ready."
    ChimeNavigation.shared.openBubble()
  }
}
#endif
