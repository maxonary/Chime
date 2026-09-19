import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var settings = AppSettings.load()
  @State private var gatewayAddress = AppSettings.load().gatewayURL.absoluteString
  @State private var validationError: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Connection") {
          TextField("Gateway URL", text: $gatewayAddress)
            .textContentType(.URL)
            .autocorrectionDisabled()
          SecureField("Access token", text: $settings.userToken)
            .autocorrectionDisabled()
        }
        Section("Voice") {
          Picker("Voice", selection: Binding(get: { settings.liveVoice ?? "marin" }, set: { settings.liveVoice = $0 })) {
            Text("Marin").tag("marin")
            Text("Gleam").tag("gleam")
            Text("Quartz").tag("quartz")
            Text("Willow").tag("willow")
            Text("Vesper").tag("vesper")
          }
          Toggle("Web search", isOn: $settings.autoResearch)
        }
        Section {
          Text("GPT-Live handles your voice conversation. Web search helps answer questions about current information.")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text("Your OpenAI key belongs on the gateway. Enter only your Chime access token here.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        if let validationError {
          Text(validationError).font(.caption2).foregroundStyle(.orange)
        }
        Button("Save settings") { save() }
          .tint(.mint)
      }
      .navigationTitle("Settings")
    }
  }

  private func save() {
    let address = gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: address), let host = url.host, !host.isEmpty,
          ["https", "http"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil else {
      validationError = "Enter a full gateway address, such as https://chime.example.com."
      return
    }
    guard !settings.userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      validationError = "Enter the access token configured on your gateway."
      return
    }
    settings.gatewayURL = url
    settings.userToken = settings.userToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.save()
    dismiss()
  }
}
