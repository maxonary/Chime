import SwiftUI

struct ContentView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject private var companion = CompanionConnection.shared
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
      if phase == .active {
        sessionManager.memoryStore.refresh()
        companion.start()
        sessionManager.prepareConnection()
      }
    }
    .onOpenURL { navigation.open($0) }
    .onChange(of: companion.isConfigured) { wasConfigured, isConfigured in
      if !wasConfigured && isConfigured {
        navigation.openBubble()
        sessionManager.prepareConnection()
      }
    }
    .task {
      sessionManager.prepareConnection()
      sessionManager.memoryStore.refresh()
      #if os(iOS)
      if AppSettings.load().userToken.isEmpty { navigation.page = 2 }
      #endif
      #if DEBUG
      // Repeatable simulator screenshots without a live voice connection.
      if ProcessInfo.processInfo.arguments.contains("--preview-memory") { navigation.page = 0 }
      #endif
    }
  }
}

private struct MemoryView: View {
  @ObservedObject var store: MemoryStore
  @EnvironmentObject var sessionManager: AgentSessionManager
  @State private var confirmingForget = false

  private var hasMemory: Bool { !store.content.facts.isEmpty || !store.content.context.isEmpty }
  private var hasConversations: Bool {
    sessionManager.conversationStore.conversations.contains { !$0.messages.isEmpty }
  }

  var body: some View {
    #if os(iOS)
    phoneContent
      .confirmationDialog("Forget all remembered details and saved conversations?", isPresented: $confirmingForget) {
        Button("Forget everything", role: .destructive) { store.forget() }
      }
    #else
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
        if hasMemory || hasConversations {
          Button("Forget everything", role: .destructive) { confirmingForget = true }
            .font(.caption)
            .disabled(sessionManager.isListening)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
    }
    .confirmationDialog("Forget all remembered details and saved conversations?", isPresented: $confirmingForget) {
      Button("Forget everything", role: .destructive) { store.forget() }
    }
    #endif
  }

  #if os(iOS)
  private var phoneContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Memory").font(.largeTitle.weight(.medium))
          Text("The details that stay with you.")
            .font(.body).foregroundStyle(.secondary)
        }
        .padding(.top, 24)

        if !hasMemory {
          VStack(spacing: 20) {
            Image("SoapBubble")
              .resizable().scaledToFit().frame(width: 150, height: 150)
              .blendMode(.screen)
              .accessibilityHidden(true)
            Text("Memory starts with\na conversation.")
              .font(.title2.weight(.medium))
              .multilineTextAlignment(.center)
            Text("Useful details appear here automatically, so you can pick up where you left off.")
              .font(.body).foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
            Button("Back to the bubble") { ChimeNavigation.shared.openBubble() }
              .font(.body.weight(.medium)).buttonStyle(.bordered)
              .buttonBorderShape(.capsule).tint(.mint)
              .padding(.top, 8)
          }
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 24).padding(.vertical, 44)
          .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 28))
          .overlay { RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.08), lineWidth: 1) }
        } else {
          if !store.content.facts.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
              Text("ABOUT YOU").font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(.secondary)
              ForEach(Array(store.content.facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .top, spacing: 14) {
                  Circle().stroke(.mint.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 9, height: 9).padding(.top, 7)
                  Text(fact).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
              }
            }
          }
          if !store.content.context.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text("WHERE WE LEFT OFF").font(.caption.weight(.semibold)).tracking(1.6).foregroundStyle(.secondary)
              Text(store.content.context).font(.body).lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
            }
          }
        }

        if store.isUpdating {
          Label("Remembering your conversation…", systemImage: "sparkles")
            .font(.callout).foregroundStyle(.secondary)
        } else if let error = store.error {
          Text(error).font(.callout).foregroundStyle(.secondary)
        }
        if hasMemory || hasConversations {
          Button("Forget everything", role: .destructive) { confirmingForget = true }
            .font(.callout).disabled(sessionManager.isListening)
            .frame(maxWidth: .infinity).padding(.top, 8)
        }
      }
      .frame(maxWidth: 560)
      .padding(.horizontal, 24).padding(.bottom, 36)
      .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
  }
  #endif
}

#Preview {
  ContentView().environmentObject(AgentSessionManager())
}
