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
  @GestureState private var holding = false
  @State private var popped = false

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
    // Exclusive recognition prevents a completed hold from also firing a tap.
    Rectangle().fill(.black)
      .overlay {
        SoapBubbleView(activity: activity,
                       microphoneActive: sessionManager.isConnected && !sessionManager.isMuted,
                       audioLevel: max(sessionManager.inputLevel, sessionManager.outputLevel),
                       isVisible: isVisible)
          .padding(4)
          .scaleEffect(x: popped ? 1.12 : holding && sessionManager.isListening ? 0.80 : 1,
                       y: holding && sessionManager.isListening && !popped ? 0.92 : 1)
          .opacity(popped ? 0 : 1)
          .animation(reduceMotion ? nil : .easeIn(duration: 1), value: holding)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: popped)
          .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
      .gesture(
        LongPressGesture(minimumDuration: 1, maximumDistance: 24)
          .updating($holding) { value, state, _ in state = value }
          .onEnded { _ in endConversation() }
          .exclusively(before: TapGesture().onEnded { tap() })
      )
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
    #if os(watchOS)
    WKInterfaceDevice.current().play(.stop)
    #else
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    #endif
    popped = true
    sessionManager.stopListening(cancelResearch: true)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(350))
      popped = false
    }
  }
}
