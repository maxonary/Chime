import SwiftUI

struct ContentView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  @Environment(\.scenePhase) private var scenePhase
  @State private var showingSettings = false
  @State private var showingTranscript = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 8) {
          HStack {
            Text("CHIME")
              .font(.system(size: 11, weight: .bold, design: .rounded))
              .tracking(3)
            Spacer()
            HStack(spacing: 4) {
              Circle().fill(sessionManager.isConnected ? Color.mint : Color.secondary).frame(width: 5, height: 5)
              Text(sessionManager.isConnected ? "LIVE" : "GPT LIVE")
                .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
          }

          VoiceControlView()

          if sessionManager.isConnected, let start = sessionManager.startedAt {
            Text(start, style: .timer)
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }

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
          .buttonStyle(.bordered)
          .font(.caption)
          if !sessionManager.currentResponse.isEmpty {
            Text(sessionManager.currentResponse)
              .font(.caption)
              .lineLimit(3)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
          }

          Text("AI voice · GPT-Live")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
      }
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
