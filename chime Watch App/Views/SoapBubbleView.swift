import SwiftUI

/// A photographic soap-film surface with live deformation and moving light.
/// The image retains fine interference patterns that gradients cannot reproduce.
struct SoapBubbleView: View {
  enum Activity { case idle, connecting, listening, speaking, muted }

  let activity: Activity
  let microphoneActive: Bool
  let audioLevel: Double
  var isVisible = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  @Environment(\.scenePhase) private var scenePhase
  @State private var origin = Date()

  private var paused: Bool { reduceMotion || isLuminanceReduced || scenePhase != .active || !isVisible }
  private var strength: Double {
    switch activity {
    case .speaking: return 1
    case .listening: return 0.4
    case .connecting: return 0.24
    case .idle: return 0.10
    case .muted: return 0.03
    }
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: activity == .speaking ? 1.0 / 30 : 1.0 / 15, paused: paused)) { timeline in
      let time = paused ? 0 : timeline.date.timeIntervalSince(origin)
      let ripple = sin(time * 3.2) * strength
      let energy = paused ? 0 : min(1, max(0, audioLevel))
      GeometryReader { geometry in
        let side = min(geometry.size.width, geometry.size.height)
        ZStack {
          ZStack {
            Image("SoapBubble")
              .resizable()
              .interpolation(.high)
              .scaledToFit()

            // A moving grazing reflection rides the film instead of tinting its
            // clear center. The still photo supplies the detailed window light.
            Circle()
              .stroke(AngularGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .cyan.opacity(0.24), location: 0.24),
                .init(color: .white.opacity(0.45), location: 0.32),
                .init(color: .clear, location: 0.40),
                .init(color: .clear, location: 0.65),
                .init(color: .pink.opacity(0.20), location: 0.76),
                .init(color: .clear, location: 1)
              ], center: .center), lineWidth: side * 0.018)
              .frame(width: side * 0.80, height: side * 0.80)
              .blur(radius: side * 0.01)
              .rotationEffect(.degrees(time * 5 + ripple * 18))
              .blendMode(.screen)
          }
          .frame(width: side, height: side)
          .scaleEffect(x: 1 + ripple * energy * 0.025, y: 1 - ripple * energy * 0.02)
          .scaleEffect(1 + energy * 0.085)
          .animation(paused ? nil : .easeOut(duration: 0.12), value: energy)
          .scaleEffect(microphoneActive ? 1.10 : 0.68)
          .animation(paused ? nil : .easeInOut(duration: 0.35), value: microphoneActive)
          .rotation3DEffect(.degrees(ripple * 5), axis: (x: 1, y: 0.5, z: 0), perspective: 0.15)
          .rotationEffect(.degrees(sin(time * 0.7) * strength * 5))
          .saturation(activity == .muted ? 0.3 : 1)
          .brightness(isLuminanceReduced ? -0.15 : 0)

          if activity == .connecting {
            ProgressView().controlSize(.mini).tint(.white.opacity(0.7))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}
