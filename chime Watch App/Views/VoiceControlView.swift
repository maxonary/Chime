import SwiftUI

struct VoiceControlView: View {
  var isVisible = true
  @EnvironmentObject var sessionManager: AgentSessionManager
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showHint = false
  @State private var hintGeneration = UUID()

  private var activity: SoapBubbleView.Activity {
    switch sessionManager.state {
    case .idle: return .idle
    case .connecting, .ending: return .connecting
    case .live:
      if sessionManager.isSpeaking { return .speaking }
      return sessionManager.isMuted ? .muted : .listening
    }
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      Button {
        resetHint()
        if sessionManager.isListening { sessionManager.stopListening() }
        else { sessionManager.startListening() }
      } label: {
        // The hit target is stable and independent of the moving artwork.
        Rectangle().fill(.black)
          .overlay {
            SoapBubbleView(activity: activity, isVisible: isVisible)
              .padding(4)
              .padding(.bottom, 18)
              .allowsHitTesting(false)
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(sessionManager.state == .ending)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(sessionManager.isListening ? "End conversation" : "Start conversation")
      .accessibilityValue(sessionManager.statusText)
      .accessibilityHint("Double tap to talk naturally with the voice assistant")

      // The reminder overlays the stage without changing its size or hit target.
      Text("Tap the bubble")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .opacity(showHint && sessionManager.state == .idle ? 1 : 0)
        .accessibilityHidden(!showHint || sessionManager.state != .idle)
        .frame(height: 18)
        .padding(.bottom, 10)
        .allowsHitTesting(false)
    }
    .task(id: hintGeneration) {
      guard isVisible, scenePhase == .active, sessionManager.state == .idle else { return }
      do { try await Task.sleep(for: .seconds(10)) }
      catch { return }
      guard !Task.isCancelled, isVisible, scenePhase == .active, sessionManager.state == .idle else { return }
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) { showHint = true }
    }
    .onChange(of: isVisible) { _, _ in resetHint() }
    .onChange(of: scenePhase) { _, _ in resetHint() }
    .onChange(of: sessionManager.state) { _, _ in resetHint() }
  }

  private func resetHint() {
    showHint = false
    hintGeneration = UUID()
  }
}
