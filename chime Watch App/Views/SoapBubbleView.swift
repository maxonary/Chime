import SwiftUI

/// A photographic soap-film surface with live deformation and moving light.
/// The image retains fine interference patterns that gradients cannot reproduce.
struct SoapBubbleView: View {
  enum Activity { case idle, connecting, listening, speaking, researching, muted }

  let activity: Activity
  let microphoneActive: Bool
  let audioLevel: Double
  var isVisible = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  @Environment(\.scenePhase) private var scenePhase
  @State private var origin = Date()
  @State private var reflectionPhase = 0.0
  @State private var reflectionChangedAt = Date()

  private var paused: Bool { reduceMotion || isLuminanceReduced || scenePhase != .active || !isVisible }
  private var strength: Double {
    switch activity {
    case .speaking: return 1
    case .listening: return 0.4
    case .researching: return 0.55
    case .connecting: return 0.24
    case .idle: return 0.10
    case .muted: return 0.03
    }
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: activity == .speaking ? 1.0 / 30 : 1.0 / 15, paused: paused)) { timeline in
      let time = paused ? 0 : timeline.date.timeIntervalSince(origin)
      let reflection = paused ? 0 : reflectionPhase + timeline.date.timeIntervalSince(reflectionChangedAt) * (activity == .researching ? 24 : 5)
      // Listening gently breathes; speech ripples with audio; research turns light
      // around the film without suggesting that microphone audio is playing.
      let pace = activity == .listening ? 1.4 : activity == .researching ? 0.9 : 3.2
      let ripple = sin(time * pace) * strength
      let breath = activity == .listening ? sin(time * 1.4) * 0.012 : 0
      let researchWarp = activity == .researching ? sin(time * 0.9) * 0.012 : 0
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
              .rotationEffect(.degrees(reflection + ripple * 18))
              .blendMode(.screen)
          }
          .frame(width: side, height: side)
          .scaleEffect(x: 1 + researchWarp + ripple * energy * 0.035, y: 1 - researchWarp + breath - ripple * energy * 0.025)
          .scaleEffect(1 + breath + energy * (activity == .speaking ? 0.085 : 0.045))
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
    .onChange(of: activity) { previous, _ in
      // Changing activity adjusts speed without snapping the reflection angle.
      let now = Date()
      reflectionPhase = (reflectionPhase + now.timeIntervalSince(reflectionChangedAt) * (previous == .researching ? 24 : 5))
        .truncatingRemainder(dividingBy: 360)
      reflectionChangedAt = now
    }
  }
}

/// A single, finite rupture. Its geometry is captured before ending the audio
/// session, so the film cannot shrink to the idle size midway through the pop.
struct SoapBubbleBurst {
  let id = UUID()
  let startedAt = Date()
  let scale: Double
}

struct SoapBubbleBurstView: View {
  let burst: SoapBubbleBurst
  var isVisible = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isLuminanceReduced) private var isLuminanceReduced
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30,
                            paused: !isVisible || scenePhase != .active || isLuminanceReduced)) { timeline in
      let elapsed = max(0, timeline.date.timeIntervalSince(burst.startedAt))
      Canvas { context, size in
        guard elapsed < 0.8 else { return }
        let side = min(size.width, size.height) * burst.scale
        let radius = side * 0.40
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let photo = context.resolve(Image("SoapBubble"))
        context.translateBy(x: center.x, y: center.y)
        // Preserve the squash at the end of the one-second hold.
        context.scaleBy(x: 0.80, y: 0.92)
        let photoRect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)

        if reduceMotion || isLuminanceReduced {
          // No flying particles or expanding hole when reduced motion is on.
          context.opacity = max(0, 1 - elapsed / 0.18)
          context.draw(photo, in: photoRect)
          return
        }

        let rupture = min(1, elapsed / 0.22)
        let puncture = CGPoint(x: radius * 0.30, y: -radius * 0.36)
        let holeRadius = radius * 1.65 * pow(rupture, 0.72)
        let hole = CGRect(x: puncture.x - holeRadius, y: puncture.y - holeRadius,
                          width: holeRadius * 2, height: holeRadius * 2)
        if rupture < 1 {
          context.drawLayer { film in
            film.draw(photo, in: photoRect)
            // A hole tears outwards from one point; the intact film stays
            // photographic until the retracting edge reaches it.
            film.blendMode = .destinationOut
            film.fill(Path(ellipseIn: hole), with: .color(.black))
          }
          var edge = context
          edge.clip(to: Path(ellipseIn: CGRect(x: -radius, y: -radius,
                                             width: radius * 2, height: radius * 2)))
          edge.stroke(Path(ellipseIn: hole), with: .color(.white.opacity((1 - rupture) * 0.75)),
                      lineWidth: max(0.6, side * 0.004))
        }

        // Irregular strands of the rim peel away, rather than turning into
        // confetti. Deterministic variation keeps every frame continuous.
        for index in 0..<11 {
          let seed = Double(index)
          let delay = 0.025 + seed.truncatingRemainder(dividingBy: 4) * 0.014
          let age = elapsed - delay
          guard age > 0, age < 0.30 else { continue }
          let progress = age / 0.30
          let angle = seed * 2.399963
          let distance = radius * (1 + progress * 0.22)
          let width = 0.10 + 0.07 * (sin(seed * 7.1) + 1)
          var strand = Path()
          strand.addArc(center: .zero, radius: distance,
                        startAngle: .radians(angle - width * (1 - progress)),
                        endAngle: .radians(angle + width * (1 - progress)), clockwise: false)
          var fragment = context
          fragment.translateBy(x: cos(angle) * radius * progress * 0.10,
                               y: sin(angle) * radius * progress * 0.10 + radius * progress * progress * 0.12)
          fragment.stroke(strand, with: .color(tint(index).opacity(pow(1 - progress, 1.5) * 0.8)),
                          style: StrokeStyle(lineWidth: max(0.5, side * 0.003 * (1 - progress)), lineCap: .round))
        }

        for index in 0..<30 {
          let seed = Double(index)
          let angle = seed * 2.399963
          let delay = 0.035 + (sin(seed * 3.7) + 1) * 0.055
          let age = elapsed - delay
          let lifetime = 0.36 + (cos(seed * 1.7) + 1) * 0.12
          guard age > 0, age < lifetime else { continue }
          let progress = age / lifetime
          let speed = 0.28 + (sin(seed * 8.3) + 1) * 0.16
          let distance = radius * (0.94 + speed * (1 - pow(1 - progress, 2)))
          let x = cos(angle) * distance
          let y = sin(angle) * distance + radius * progress * progress * 0.24
          let dropletSize = max(0.65, side * (0.0025 + (sin(seed * 2.1) + 1) * 0.002)) * (1 - progress * 0.65)
          let opacity = min(1, age / 0.025) * pow(1 - progress, 1.25)
          let rect = CGRect(x: x - dropletSize, y: y - dropletSize,
                            width: dropletSize * 2, height: dropletSize * 2)
          context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [.white.opacity(opacity), tint(index).opacity(opacity * 0.65), .clear]),
            center: CGPoint(x: x - dropletSize * 0.25, y: y - dropletSize * 0.3),
            startRadius: 0, endRadius: dropletSize * 1.25))
        }
      }
    }
    .accessibilityHidden(true)
  }

  private func tint(_ index: Int) -> Color {
    [.white, Color(red: 0.66, green: 0.90, blue: 1),
     Color(red: 1, green: 0.78, blue: 0.89), Color(red: 0.93, green: 0.86, blue: 0.64)][index % 4]
  }
}
