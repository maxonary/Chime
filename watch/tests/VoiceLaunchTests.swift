import Foundation

@main
struct VoiceLaunchTests {
  @MainActor
  static func main() {
    let navigation = ChimeNavigation()
    func consume(active: Bool = true, configured: Bool = true, ending: Bool = false) -> Bool {
      navigation.consumeConversationRequest(isActive: active, isConfigured: configured, isEnding: ending)
    }
    assert(!consume(active: false), "Cold launch waits for an active scene")
    assert(!consume(configured: false), "First installation waits for connection setup")
    assert(consume(), "Configured foreground launch starts voice")
    assert(!consume(), "Repeated active callbacks must not start another call")
    navigation.openBubble()
    assert(!consume(), "Returning from Memory must not restart an ended call")
    assert(!consume(active: false))
    assert(!consume(), "Wrist dimming or permission dialogs do not rearm voice")
    navigation.page = 2
    navigation.open(URL(string: "chime://bubble")!)
    assert(navigation.page == 1)
    assert(consume(), "A widget starts voice even when the app is already open")
    navigation.open(URL(string: "https://example.com/bubble")!)
    assert(!consume(), "Unrelated URLs cannot start the microphone")
    navigation.requestConversation()
    assert(!consume(active: false), "Reopening waits for foreground")
    assert(!consume(ending: true), "Wait for the previous call to finish")
    assert(consume(), "Resume the queued launch after closing finishes")
    assert(!consume())
    navigation.openConversation()
    assert(consume(), "A shortcut starts voice")
    print("PASS: cold and warm launches, widgets and shortcuts start once; setup and closing defer; inactive transitions do not restart voice")
  }
}
