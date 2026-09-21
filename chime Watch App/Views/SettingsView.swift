import SwiftUI

/// Preferences only. Installation provisioning owns the gateway credentials.
struct SettingsView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  @State private var voice = AppSettings.load().liveVoice ?? "marin"
  @State private var webSearch = AppSettings.load().autoResearch

  var body: some View {
    Form {
      Section("Preferences") {
        Picker("Voice", selection: $voice) {
          Text("Marin").tag("marin")
          Text("Gleam").tag("gleam")
          Text("Quartz").tag("quartz")
          Text("Willow").tag("willow")
          Text("Vesper").tag("vesper")
        }
        Toggle("Web search", isOn: $webSearch)
      }
      .disabled(sessionManager.isListening)
      if sessionManager.isConnected {
        Button(sessionManager.isMuted ? "Unmute microphone" : "Mute microphone") { sessionManager.toggleMute() }
      }
      Text("Changes apply to your next conversation.")
        .font(.caption2).foregroundStyle(.secondary)
    }
    .onChange(of: voice) { _, _ in save() }
    .onChange(of: webSearch) { _, _ in save() }
  }

  private func save() {
    // Merge preferences into the latest settings without overwriting credentials
    // or a conversation pointer that changed while this page was offscreen.
    var settings = AppSettings.load()
    settings.liveVoice = voice
    settings.autoResearch = webSearch
    settings.save()
  }
}
