import SwiftUI

struct ContentView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  @Environment(\.scenePhase) private var scenePhase
  @State private var showingSettings = false
  @State private var showingTranscript = false

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: 16) {
            VoiceControlView()
              .frame(height: geometry.size.height)

            HStack(spacing: 10) {
              Button { showingTranscript = true } label: {
                Image(systemName: "text.bubble")
              }
              .accessibilityLabel("Conversation transcript")
              if sessionManager.isConnected {
                Button { sessionManager.toggleMute() } label: {
                  Image(systemName: sessionManager.isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(sessionManager.isMuted ? Color.orange : Color.mint)
                }
                .accessibilityLabel(sessionManager.isMuted ? "Unmute microphone" : "Mute microphone")
              }
              Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
              }
              .disabled(sessionManager.isListening)
              .accessibilityLabel("Settings")
            }
            .buttonStyle(ConversationControlStyle())
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
          }
        }
        .scrollIndicators(.hidden)
      }
      .ignoresSafeArea(.container, edges: .bottom)
      .containerBackground(.black, for: .navigation)
      .sheet(isPresented: $showingSettings) { SettingsView() }
      .sheet(isPresented: $showingTranscript) {
        TranscriptView(store: sessionManager.conversationStore)
      }
      .alert("Chime", isPresented: Binding(
        get: { sessionManager.error != nil },
        set: { if !$0 { sessionManager.error = nil } }
      )) {
        Button("Open settings") { showingSettings = true }
        Button("OK", role: .cancel) { sessionManager.error = nil }
      } message: {
        Text(sessionManager.error ?? "Please try again.")
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background { sessionManager.stopListening() }
      }
    }
    .tint(.mint)
  }
}

private struct ConversationControlStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(maxWidth: .infinity)
      .frame(height: 36)
      .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
      .contentShape(Capsule())
  }
}

private struct TranscriptView: View {
  @ObservedObject var store: ConversationStore
  @EnvironmentObject var sessionManager: AgentSessionManager

  var body: some View {
    NavigationStack {
      Group {
        if let conversation = store.currentConversation, !conversation.messages.isEmpty {
          MessageListView(messages: conversation.messages)
        } else {
          ContentUnavailableView("Your conversation", systemImage: "text.bubble", description: Text("Start talking to see your transcript here."))
        }
      }
      .navigationTitle("Transcript")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            List(store.conversations.sorted { $0.updatedAt > $1.updatedAt }) { conversation in
              Button {
                sessionManager.selectConversation(conversation)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(conversation.messages.first(where: { $0.role == .user })?.content ?? conversation.title)
                    .font(.caption).lineLimit(2)
                  Text(conversation.updatedAt, style: .date)
                    .font(.caption2).foregroundStyle(.secondary)
                  if store.currentConversation?.id == conversation.id {
                    Text("Selected").font(.caption2).foregroundStyle(.mint)
                  }
                }
              }
            }
            .navigationTitle("History")
          } label: { Image(systemName: "clock.arrow.circlepath") }
          .disabled(sessionManager.isListening)
          .accessibilityLabel("Saved conversations")
        }
        ToolbarItem(placement: .bottomBar) {
          Button("New conversation", systemImage: "plus") {
            sessionManager.newConversation()
          }
          .disabled(sessionManager.isListening)
        }
      }
    }
  }
}

#Preview {
  ContentView().environmentObject(AgentSessionManager())
}
