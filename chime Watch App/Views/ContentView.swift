import SwiftUI

struct ContentView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject private var navigation = ChimeNavigation.shared

  var body: some View {
    TabView(selection: $navigation.page) {
      MemoryView(store: sessionManager.memoryStore)
        .tag(0)
      VoiceControlView(isVisible: navigation.page == 1)
        // Center against the entire display, including the system clock inset.
        .ignoresSafeArea(.container)
        .tag(1)
      SettingsView()
        .tag(2)
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .background(.black)
    .tint(.mint)
    .alert("Voice connection", isPresented: Binding(
      get: { sessionManager.error != nil },
      set: { if !$0 { sessionManager.error = nil } }
    )) {
      Button("OK", role: .cancel) { sessionManager.error = nil }
    } message: {
      Text(sessionManager.error ?? "Please try again.")
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { sessionManager.stopListening() }
      if phase == .active { sessionManager.memoryStore.refresh() }
    }
    .onOpenURL { navigation.open($0) }
    .task { sessionManager.memoryStore.refresh() }
  }
}

private struct MemoryView: View {
  @ObservedObject var store: MemoryStore
  @EnvironmentObject var sessionManager: AgentSessionManager
  @State private var confirmingForget = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Memory").font(.headline)
        if store.content.facts.isEmpty && store.content.context.isEmpty {
          Text("Useful details from our conversations will be remembered here automatically.")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(store.content.facts.enumerated()), id: \.offset) { _, fact in
          Text(fact).font(.caption)
        }
        if !store.content.context.isEmpty {
          Text(store.content.context).font(.caption).foregroundStyle(.secondary)
        }
        if store.isUpdating {
          Label("Remembering…", systemImage: "sparkles").font(.caption2).foregroundStyle(.secondary)
        } else if let error = store.error {
          Text(error).font(.caption2).foregroundStyle(.secondary)
        }
        Button("Forget everything", role: .destructive) { confirmingForget = true }
          .font(.caption)
          .disabled(sessionManager.isListening)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
    }
    .confirmationDialog("Forget all remembered details and saved conversations?", isPresented: $confirmingForget) {
      Button("Forget everything", role: .destructive) { store.forget() }
    }
  }
}

#Preview {
  ContentView().environmentObject(AgentSessionManager())
}
