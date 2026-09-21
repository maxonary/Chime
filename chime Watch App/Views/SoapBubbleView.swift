import SwiftUI

/// Curved reflections and a thin iridescent film give the bubble depth without
/// requiring a continuously running 3D scene on the Watch.
struct SoapBubbleView: View {
  enum Activity { case idle, connecting, listening, speaking, muted }

  let activity: Activity
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  @Environment(\.scenePhase) private var scenePhase
  @State private var origin = Date()

  private var paused: Bool { reduceMotion || isLuminanceReduced || scenePhase != .active }
  private var strength: Double {
    switch activity {
    case .speaking: return 1
    case .listening: return 0.42
    case .connecting: return 0.25
    case .idle: return 0.12
    case .muted: return 0.04
    }
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: activity == .speaking ? 1.0 / 30 : 1.0 / 15, paused: paused)) { timeline in
      let time = paused ? 0 : timeline.date.timeIntervalSince(origin)
      let ripple = sin(time * 3.2) * strength
      let swell = sin(time * 1.8) * strength
      GeometryReader { geometry in
        let diameter = min(geometry.size.width, geometry.size.height) * 0.86
        ZStack {
          Circle()
            .fill(Color.blue.opacity(0.12))
            .blur(radius: diameter * 0.15)
            .frame(width: diameter * 0.8, height: diameter * 0.8)

          film(diameter: diameter, time: time, drift: ripple * 0.04)
            .frame(width: diameter, height: diameter)
            .scaleEffect(x: 1 + swell * 0.045, y: 1 - ripple * 0.035)
            .rotationEffect(.degrees(ripple * 4))
            .offset(y: sin(time * 1.3) * strength * 3)
            .saturation(activity == .muted ? 0.25 : 1)

          if activity == .connecting {
            ProgressView().controlSize(.mini).tint(.white.opacity(0.8))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .accessibilityHidden(true)
  }

  private func film(diameter: CGFloat, time: Double, drift: Double) -> some View {
    ZStack {
      Circle().fill(RadialGradient(stops: [
        .init(color: .white.opacity(0.17), location: 0),
        .init(color: .indigo.opacity(0.12), location: 0.36),
        .init(color: .black.opacity(0.2), location: 0.72),
        .init(color: .cyan.opacity(0.23), location: 0.94),
        .init(color: .white.opacity(0.4), location: 1)
      ], center: UnitPoint(x: 0.38 + drift * 0.3, y: 0.3), startRadius: 0, endRadius: diameter * 0.67))

      reflectionBand(diameter: diameter, bend: drift)
        .stroke(LinearGradient(colors: [.cyan.opacity(0.7), .pink.opacity(0.6), .orange.opacity(0.65)],
                               startPoint: .leading, endPoint: .trailing), lineWidth: diameter * 0.085)
        .blur(radius: diameter * 0.035)
      reflectionBand(diameter: diameter, bend: -drift)
        .stroke(LinearGradient(colors: [.blue.opacity(0.6), .purple.opacity(0.45), .mint.opacity(0.65)],
                               startPoint: .leading, endPoint: .trailing), lineWidth: diameter * 0.055)
        .blur(radius: diameter * 0.025)
        .rotationEffect(.degrees(165 + sin(time * 0.8) * strength * 12))

      Circle()
        .stroke(AngularGradient(colors: [.cyan, .purple, .pink, .orange, .mint, .blue, .cyan], center: .center),
                lineWidth: diameter * 0.035)
        .blur(radius: diameter * 0.016)
        .rotationEffect(.degrees(time * 7 + sin(time * 2) * strength * 12))
      Circle()
        .stroke(AngularGradient(colors: [.white.opacity(0.9), .cyan.opacity(0.2), .purple.opacity(0.8),
                                         .pink.opacity(0.5), .yellow.opacity(0.75), .mint.opacity(0.4),
                                         .blue.opacity(0.3), .white.opacity(0.9)], center: .center), lineWidth: 0.8)
        .padding(0.6)

      Ellipse().fill(.white.opacity(0.9))
        .frame(width: diameter * 0.29, height: diameter * 0.095)
        .rotationEffect(.degrees(-38 + drift * 25))
        .blur(radius: 0.5)
        .offset(x: -diameter * 0.23, y: -diameter * 0.3)
      Circle().fill(.white.opacity(0.8))
        .frame(width: diameter * 0.035, height: diameter * 0.035)
        .offset(x: -diameter * 0.37, y: -diameter * 0.15)
      Ellipse().fill(.white.opacity(0.65))
        .frame(width: diameter * 0.22, height: diameter * 0.035)
        .rotationEffect(.degrees(-42))
        .blur(radius: 0.6)
        .offset(x: diameter * 0.26, y: diameter * 0.31)
    }
    .clipShape(Circle())
  }

  private func reflectionBand(diameter: CGFloat, bend: Double) -> Path {
    Path { path in
      path.move(to: CGPoint(x: diameter * 0.04, y: diameter * 0.43))
      path.addCurve(to: CGPoint(x: diameter * 0.94, y: diameter * 0.64),
                    control1: CGPoint(x: diameter * (0.12 + bend), y: diameter * 0.94),
                    control2: CGPoint(x: diameter * (0.76 + bend), y: diameter * 1.02))
    }
  }
}
