import ImageIO
import SwiftUI
import WidgetKit

private struct BubbleEntry: TimelineEntry {
  let date: Date
}

private struct BubbleProvider: TimelineProvider {
  func placeholder(in context: Context) -> BubbleEntry { BubbleEntry(date: .now) }

  func getSnapshot(in context: Context, completion: @escaping (BubbleEntry) -> Void) {
    completion(BubbleEntry(date: .now))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<BubbleEntry>) -> Void) {
    // A launcher has no live data and needs no periodic network or timeline work.
    completion(Timeline(entries: [BubbleEntry(date: .now)], policy: .never))
  }
}

private enum BubbleArtwork {
  static let compact = thumbnail(pixels: 64)
  static let large = thumbnail(pixels: 128)

  private static func thumbnail(pixels: Int) -> CGImage? {
    guard let url = Bundle.main.url(forResource: "soap-bubble", withExtension: "png"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    // WidgetKit archives the actual bitmap, even when a SwiftUI Image is resizable.
    // Decode a small thumbnail instead of embedding the full app artwork.
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: pixels,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ] as CFDictionary)
  }
}

private struct BubbleMark: View {
  var large = false
  @Environment(\.widgetRenderingMode) private var renderingMode

  var body: some View {
    if renderingMode == .fullColor, let image = large ? BubbleArtwork.large : BubbleArtwork.compact {
      Image(decorative: image, scale: 2)
        .resizable()
        .scaledToFit()
        .clipShape(Circle())
    } else {
      // Keep the bubble recognizable when the Watch face tints the complication.
      ZStack {
        Circle().strokeBorder(.primary, lineWidth: 1.5)
        Circle().trim(from: 0.55, to: 0.72)
          .stroke(.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .padding(5)
        Circle().fill(.primary.opacity(0.5))
          .frame(width: 3, height: 3).offset(x: 6, y: 8)
      }
      .padding(3)
    }
  }
}

private struct BubbleWidgetView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    Group {
      switch family {
      case .accessoryInline:
        Label("Chime", systemImage: "bubbles.and.sparkles")
      case .accessoryRectangular:
        HStack(spacing: 10) {
          BubbleMark(large: true).frame(width: 54, height: 54)
          VStack(alignment: .leading, spacing: 2) {
            Text("Chime").font(.headline)
            Text("Open the bubble").font(.caption).foregroundStyle(.secondary)
          }
          .minimumScaleFactor(0.8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .accessoryCorner:
        BubbleMark().widgetLabel { Text("Chime") }
      default:
        BubbleMark()
      }
    }
    .foregroundStyle(.white)
    .containerBackground(.black, for: .widget)
    .widgetURL(URL(string: "chime://bubble")!)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Open Chime")
    .accessibilityHint("Opens the bubble for a voice conversation")
  }
}

@main
struct ChimeWidget: Widget {
  let kind = "ChimeBubble"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: BubbleProvider()) { _ in
      BubbleWidgetView()
    }
    .configurationDisplayName("Chime")
    .description("Your bubble, one tap away. Open Chime for a voice conversation.")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
  }
}
