import AppIntents

struct OpenChimeIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Chime"
  static let description = IntentDescription("Open the bubble, ready for a voice conversation.")
  static var supportedModes: IntentModes { .foreground }

  @MainActor
  func perform() async throws -> some IntentResult {
    ChimeNavigation.shared.openBubble()
    return .result()
  }
}

struct ChimeShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenChimeIntent(),
      phrases: ["Open \(.applicationName)", "Show my \(.applicationName) bubble"],
      shortTitle: "Open Chime",
      systemImageName: "bubbles.and.sparkles"
    )
  }

  static var shortcutTileColor: ShortcutTileColor { .teal }
}
