import SwiftUI
import WatchKit

struct VoiceControlView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  private var bubbleSize: CGFloat { WKInterfaceDevice.current().screenBounds.width < 180 ? 60 : 88 }

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
    VStack(spacing: 4) {
      Button {
        if sessionManager.isListening { sessionManager.stopListening() }
        else { sessionManager.startListening() }
      } label: {
        SoapBubbleView(activity: activity)
          .frame(width: bubbleSize, height: bubbleSize)
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(sessionManager.state == .ending)
      .accessibilityLabel(sessionManager.isListening ? "End conversation" : "Start conversation")
      .accessibilityValue(sessionManager.statusText)
      .accessibilityHint("Talk naturally with Chime")

      VStack(spacing: 2) {
        Text(sessionManager.state == .idle ? "Let’s talk" : sessionManager.statusText)
          .font(.system(.headline, design: .rounded))
        Text(sessionManager.state == .idle ? "Tap the bubble" : sessionManager.state == .ending ? "Saving your transcript" : "Tap to end")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
}
