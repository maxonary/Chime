import SwiftUI

struct VoiceControlView: View {
  var isVisible = true
  @EnvironmentObject var sessionManager: AgentSessionManager
  @FocusState private var ownsCrown: Bool

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
    Button {
      if sessionManager.isListening { sessionManager.stopListening() }
      else { sessionManager.startListening() }
    } label: {
      // The hit target stays fixed even when the bubble shrinks or pulses.
      Rectangle().fill(.black)
        .overlay {
          SoapBubbleView(activity: activity,
                         microphoneActive: sessionManager.isConnected && !sessionManager.isMuted,
                         audioLevel: max(sessionManager.inputLevel, sessionManager.outputLevel),
                         isVisible: isVisible)
            .padding(4)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(sessionManager.state == .ending)
    // Consume Crown input on the center page without scrolling, zooming, or
    // changing pages. The side pages retain their normal Crown behavior.
    .focusable(isVisible)
    .focused($ownsCrown)
    .focusEffectDisabled()
    .digitalCrownRotation(.constant(0), from: 0, through: 1, isContinuous: true, isHapticFeedbackEnabled: false)
    .onAppear { ownsCrown = isVisible }
    .onChange(of: isVisible) { _, visible in ownsCrown = visible }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(sessionManager.isListening ? "End conversation" : "Start conversation")
    .accessibilityValue(sessionManager.statusText)
    .accessibilityHint("Double tap to talk naturally with the voice assistant")
  }
}
