import SwiftUI
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

struct VoiceControlView: View {
  var isVisible = true
  @EnvironmentObject var sessionManager: AgentSessionManager
  @FocusState private var ownsCrown: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var holding = false
  @State private var burst: SoapBubbleBurst?

  private var popped: Bool { burst != nil }

  private var activity: SoapBubbleView.Activity {
    switch sessionManager.state {
    case .idle: return .idle
    case .connecting, .ending: return .connecting
    case .live:
      if sessionManager.isSpeaking { return .speaking }
      if sessionManager.isResearching { return .researching }
      return sessionManager.isMuted ? .muted : .listening
    }
  }

  var body: some View {
    // Recognize taps directly: making them wait for a long press to fail can
    // swallow short touches inside the paged container on iPhone and Watch.
    Rectangle().fill(.black)
      .overlay {
        SoapBubbleView(activity: activity,
                       microphoneActive: sessionManager.isConnected && !sessionManager.isMuted,
                       audioLevel: max(sessionManager.inputLevel, sessionManager.outputLevel),
                       isVisible: isVisible)
          .padding(4)
          .scaleEffect(x: popped ? 0.08 : holding && sessionManager.isListening ? 0.80 : 1,
                       y: popped ? 0.08 : holding && sessionManager.isListening ? 0.92 : 1)
          .opacity(popped ? 0 : 1)
          .animation(reduceMotion ? nil : .easeIn(duration: 1), value: holding)
          .animation(reduceMotion || popped ? nil : .easeOut(duration: 0.65), value: popped)
          .allowsHitTesting(false)

        if let burst {
          SoapBubbleBurstView(burst: burst, isVisible: isVisible)
            .padding(4)
            .allowsHitTesting(false)
        }
      }
      .task(id: burst?.id) {
        guard let id = burst?.id else { return }
        // Let the film and droplets disappear, then hold an empty screen before
        // forming a fresh idle bubble. This never starts another conversation.
        do {
          try await Task.sleep(for: .seconds(1.8))
          // Do not respawn a connecting spinner while the old call drains.
          while sessionManager.state == .ending {
            try await Task.sleep(for: .milliseconds(100))
          }
        } catch { return }
        guard burst?.id == id else { return }
        burst = nil
      }
      .contentShape(Rectangle())
      .onTapGesture { tap() }
      .onLongPressGesture(minimumDuration: 1, maximumDistance: 24,
                          perform: { endConversation() },
                          onPressingChanged: { holding = $0 })
      .allowsHitTesting(sessionManager.state != .ending && !popped)
    // Consume Crown input on the center page without scrolling, zooming, or
    // changing pages. The side pages retain their normal Crown behavior.
    #if os(watchOS)
    .focusable(isVisible)
    .focused($ownsCrown)
    .focusEffectDisabled()
    .digitalCrownRotation(.constant(0), from: 0, through: 1, isContinuous: true, isHapticFeedbackEnabled: false)
    .onAppear { ownsCrown = isVisible }
    .onChange(of: isVisible) { _, visible in ownsCrown = visible }
    #endif
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(sessionManager.isConnected ? (sessionManager.isMuted ? "Unmute microphone" : "Mute microphone") : "Start conversation")
    .accessibilityValue(sessionManager.statusText)
    .accessibilityHint("Tap to mute or unmute. Hold for one second to end the conversation.")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { tap() }
    .accessibilityAction(named: Text("End conversation")) { endConversation() }
  }

  private func tap() {
    guard !popped else { return }
    if sessionManager.state == .live { sessionManager.toggleMute() }
    else if sessionManager.state == .idle { sessionManager.startListening() }
  }

  private func endConversation() {
    guard sessionManager.isListening, sessionManager.state != .ending, !popped else { return }
    holding = false
    #if os(watchOS)
    WKInterfaceDevice.current().play(.stop)
    #else
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    #endif
    burst = SoapBubbleBurst(scale: sessionManager.isConnected && !sessionManager.isMuted ? 1.10 : 0.68)
    sessionManager.stopListening(cancelResearch: true)
  }
}
