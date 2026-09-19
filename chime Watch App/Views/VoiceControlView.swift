import SwiftUI
import WatchKit

struct VoiceControlView: View {
  @EnvironmentObject var sessionManager: AgentSessionManager
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var glowing = false
  private var dialSize: CGFloat { WKInterfaceDevice.current().screenBounds.width < 180 ? 56 : 80 }

  var body: some View {
    VStack(spacing: 6) {
      Button {
        if sessionManager.isListening { sessionManager.stopListening() }
        else { sessionManager.startListening() }
      } label: {
        ZStack {
          Circle()
            .stroke(Color.mint.opacity(0.12), lineWidth: 1)
            .frame(width: dialSize, height: dialSize)
          Circle()
            .fill(Color.mint.opacity(sessionManager.isConnected ? 0.18 : 0.07))
            .frame(width: dialSize * 0.85, height: dialSize * 0.85)
            .scaleEffect(glowing && sessionManager.isConnected && !reduceMotion ? 1.10 : 1)
          Circle()
            .fill(LinearGradient(colors: [Color.mint, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: dialSize * 0.7, height: dialSize * 0.7)
          if sessionManager.state == .connecting || sessionManager.state == .ending {
            ProgressView().tint(.black)
          } else {
            Image(systemName: sessionManager.isConnected ? "stop.fill" : "waveform")
              .font(.system(size: dialSize * 0.3, weight: .medium))
              .foregroundStyle(.black)
          }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(sessionManager.state == .ending)
      .accessibilityLabel(sessionManager.isListening ? "End conversation" : "Start conversation")
      .accessibilityHint("Talk naturally with Chime")

      VStack(spacing: 3) {
        Text(sessionManager.state == .idle ? "Let’s talk" : sessionManager.statusText)
          .font(.system(.headline, design: .rounded))
        Text(sessionManager.state == .idle ? "Tap to start" : sessionManager.state == .ending ? "Saving your transcript" : "Tap to end")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .onAppear { glowing = true }
    .animation(reduceMotion ? nil : .easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: glowing)
  }
}
