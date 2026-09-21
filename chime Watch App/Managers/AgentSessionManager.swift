import Foundation
import Combine
import AVFoundation
import OSLog
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

@MainActor
final class AgentSessionManager: ObservableObject {
  enum State { case idle, connecting, live, ending }
  @Published private(set) var state: State = .idle
  @Published private(set) var isMuted = false
  @Published private(set) var isSpeaking = false
  @Published private(set) var isResearching = false
  @Published private(set) var inputLevel = 0.0
  @Published private(set) var outputLevel = 0.0
  @Published private(set) var currentResponse = ""
  @Published private(set) var userTranscript = ""
  @Published private(set) var startedAt: Date?
  @Published var error: String?
  let conversationStore: ConversationStore
  let memoryStore: MemoryStore

  var isConnected: Bool { state == .live }
  var isListening: Bool { state != .idle }
  var statusText: String {
    switch state {
    case .idle: return "Ready when you are"
    case .connecting: return "Connecting…"
    case .ending: return "Ending conversation…"
    case .live: return isMuted ? "Microphone muted" : isSpeaking ? "Assistant is speaking" : isResearching ? "Researching; you can keep talking" : "Listening to you"
    }
  }

  private var socket: URLSessionWebSocketTask?
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var hasTap = false
  private var receiveTask: Task<Void, Never>?
  private var captureTask: Task<Void, Never>?
  private var playbackStartTask: Task<Void, Never>?
  private var warmupTask: Task<Void, Never>?
  private var lastWarmup = Date.distantPast
  private var connectionStartedAt = ProcessInfo.processInfo.systemUptime
  private let logger = Logger(subsystem: "maxonary.chime", category: "Voice")
  private var timeoutTask: Task<Void, Never>?
  private var audioContinuation: AsyncStream<Data>.Continuation?
  private var generation = UUID()
  private var queuedFrames = 0
  private struct OutputMeter { let start: Int64; let end: Int64; let level: Double }
  private var outputMeters: [OutputMeter] = []
  private var scheduledOutputFrames: Int64 = 0
  private var queuedSpeechBuffers = 0
  private var microphoneResumeAt = Date.distantPast
  private var transcriptGroups: [MessageRole: (id: String, text: String, start: Double, end: Double)] = [:]
  private var conversationId: String?
  private var interruption: AnyCancellable?

  init() {
    let store = ConversationStore()
    conversationStore = store
    memoryStore = MemoryStore(conversations: store)
    interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              kind == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor in self?.stopListening() }
      }
  }

  /// Wake a sleeping gateway when the app opens, without starting a billed voice session.
  func prepareConnection() {
    guard state == .idle, warmupTask == nil, Date().timeIntervalSince(lastWarmup) > 30 else { return }
    let settings = AppSettings.load()
    guard settings.hasConnection else { return }
    lastWarmup = Date()
    var request = URLRequest(url: settings.gatewayURL.appendingPathComponent("health"))
    request.timeoutInterval = 60
    request.cachePolicy = .reloadIgnoringLocalCacheData
    warmupTask = Task { [weak self] in
      _ = try? await URLSession.shared.data(for: request)
      self?.warmupTask = nil
    }
  }

  func startListening() {
    audioDiagnostic("Start requested")
    guard state == .idle else { return }
    let settings = AppSettings.load()
    guard settings.gatewayURL.host != nil,
          ["http", "https"].contains(settings.gatewayURL.scheme ?? ""),
          !settings.userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      error = "This installation has not been connected to your voice service yet. Open Chime on your iPhone and connect in Preferences."
      return
    }
    error = nil
    currentResponse = ""
    userTranscript = ""
    transcriptGroups = [:]
    isMuted = false
    state = .connecting
    connectionStartedAt = ProcessInfo.processInfo.systemUptime
    let id = UUID()
    generation = id
    receiveTask = Task { [weak self] in
      guard let self else { return }
      let allowed = await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
      }
      guard generation == id, state == .connecting, !Task.isCancelled else { return }
      guard allowed else { fail("Allow microphone access in Settings to talk to Chime."); return }
      timeoutTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(25))
        guard !Task.isCancelled, let self, self.generation == id, self.state == .connecting else { return }
        self.fail("Connection timed out. Check your connection and try again.")
      }
      do {
        guard try await prepareAudio(generation: id) else { return }
      } catch {
        if generation == id, state != .idle {
          audioDiagnostic("Setup failed: \((error as NSError).domain) \((error as NSError).code)")
          fail("Audio could not start (error \((error as NSError).code)). Please try again with Chime open.")
        }
        return
      }
      do {
        var components = URLComponents(url: settings.gatewayURL, resolvingAgainstBaseURL: false)!
        components.scheme = settings.gatewayURL.scheme == "https" ? "wss" : "ws"
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([components.path, "v1/live"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { fail("The gateway address is invalid."); return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.userToken)", forHTTPHeaderField: "Authorization")
        let connection = URLSession.shared.webSocketTask(with: request)
        socket = connection
        connection.resume()
        audioDiagnostic("Opening gateway connection")
        let history = memoryStore.recentHistory
        let conversation = conversationStore.createConversation(title: "Live conversation")
        conversationId = conversation.id
        memoryStore.activeConversationID = conversation.id
        let memory = memoryStore.content
        try await send(["type": "chime.session.start", "voice": settings.liveVoice ?? "marin", "research": settings.autoResearch,
                        "history": history, "memory": ["facts": memory.facts, "context": memory.context]], on: connection)
        guard generation == id, !Task.isCancelled else { return }
        while !Task.isCancelled, generation == id {
          let message = try await connection.receive()
          guard generation == id else { return }
          let data: Data
          switch message {
          case .data(let bytes): data = bytes
          case .string(let text): data = Data(text.utf8)
          @unknown default: continue
          }
          try handle(data, generation: id)
        }
      } catch {
        if generation == id, state != .idle {
          let failure = error as NSError
          audioDiagnostic("Session failed: \(failure.domain) \(failure.code)")
          if failure.domain.contains("audio") || failure.domain == NSOSStatusErrorDomain {
            fail("The Watch could not run live audio (error \(failure.code)). Please try again with Chime open.")
          } else if failure.domain == "Chime" {
            fail(error.localizedDescription)
          } else {
            fail("\(error.localizedDescription) Check your gateway address, token, and connection.")
          }
        }
      }
    }
  }

  func stopListening() {
    guard state != .idle, state != .ending else { return }
    let wasLive = state == .live
    state = .ending
    // watchOS grants WebSocket access through the active audio session. Keep it
    // active until session.closed arrives so final usage and captions can drain.
    stopAudio(deactivateSession: false)
    timeoutTask?.cancel()
    guard wasLive, let socket else { cleanup(); return }
    let id = generation
    Task {
      do { try await send(["type": "session.close"], on: socket) }
      catch { if generation == id { cleanup() } }
    }
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(17))
      guard !Task.isCancelled, let self, self.generation == id else { return }
      self.fail("Conversation ended before final usage was confirmed.")
    }
  }

  func newConversation() {
    guard state == .idle else { return }
    conversationStore.flush()
    _ = conversationStore.createConversation(title: "Live conversation")
    currentResponse = ""
    userTranscript = ""
    error = nil
  }

  func selectConversation(_ conversation: Conversation) {
    guard state == .idle else { return }
    conversationStore.flush()
    conversationStore.setActiveConversation(conversation)
    currentResponse = conversationStore.currentConversation?.messages.last(where: { $0.role == .assistant })?.content ?? ""
    userTranscript = ""
    error = nil
  }

  func toggleMute() {
    guard state == .live, let socket else { return }
    isMuted.toggle()
    inputLevel = 0
    let muted = isMuted
    let id = generation
    Task {
      do { try await send(["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute"], on: socket) }
      catch { if generation == id { fail("Could not change microphone state. Please reconnect.") } }
    }
  }

  private func send(_ event: [String: Any], on socket: URLSessionWebSocketTask) async throws {
    let data = try JSONSerialization.data(withJSONObject: event)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }

  private func handle(_ data: Data, generation id: UUID) throws {
    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { return }
    switch type {
    case "session.started":
      guard state == .connecting else { return }
      timeoutTask?.cancel()
      audioDiagnostic("GPT Live ready")
      try startAudio(generation: id)
      state = .live
      startedAt = Date()
      // Signal readiness only after microphone capture successfully starts.
      #if os(watchOS)
      WKInterfaceDevice.current().play(.click)
      #else
      UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.4)
      #endif
    case "chime.research.state":
      if state == .live, let active = event["active"] as? Int, (0...64).contains(active) {
        isResearching = active > 0
      }
    case "session.output_audio.delta":
      if state == .live, let delta = event["delta"] as? String { try play(delta, generation: id) }
    case "session.input_transcript.delta", "session.output_transcript.delta":
      if let delta = event["delta"] as? String {
        appendTranscript(delta, role: type == "session.input_transcript.delta" ? .user : .assistant,
                         start: event["start_ms"] as? Double ?? 0, end: event["end_ms"] as? Double ?? 0)
      }
    case "session.closed": cleanup()
    case "error":
      let details = event["error"] as? [String: Any]
      fail(details?["message"] as? String ?? "The voice connection failed. Try again.")
    default: break
    }
  }

  private func appendTranscript(_ delta: String, role: MessageRole, start: Double, end: Double) {
    guard let conversationId else { return }
    var group = transcriptGroups[role]
    // Each speaker has an independent caption: overlapping speech must not split the other speaker.
    if group == nil || start - group!.end > 1500 {
      group = (UUID().uuidString, "", start, end)
    }
    group!.text += delta
    group!.end = end
    transcriptGroups[role] = group
    if role == .assistant { currentResponse = group!.text } else { userTranscript = group!.text }
    conversationStore.upsertMessage(Message(id: group!.id, role: role, content: group!.text,
      transcriptStartMs: group!.start, transcriptEndMs: group!.end), to: conversationId)
  }

  private func prepareAudio(generation id: UUID) async throws -> Bool {
    let session = AVAudioSession.sharedInstance()
    audioDiagnostic("Configuring audio session")
    // The voice-processing audio unit crashes the audio service on the tested
    // Series 8. Use ordinary duplex I/O and suppress speaker echo below.
    #if os(watchOS)
    try session.setCategory(.playAndRecord, mode: .default)
    // Synchronous setActive succeeds on watchOS without enabling low-level
    // networking. Await watchOS audio activation before opening the WebSocket.
    audioDiagnostic("Activating audio session")
    let activated = try await session.activate(options: [])
    #else
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
    try? session.setPreferredIOBufferDuration(0.02)
    try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
    try session.setActive(true)
    let activated = true
    #endif
    audioDiagnostic("Audio session activated: \(activated)")
    guard generation == id, state == .connecting, !Task.isCancelled else {
      // Activation may finish after Stop. Don't deactivate a newer session.
      if state == .idle {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
      }
      return false
    }
    #if os(watchOS)
    guard activated else {
      throw NSError(domain: "Chime", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not activate audio. Please try again."])
    }
    #endif
    microphoneResumeAt = .distantPast
    try configureAudioEngine()
    return true
  }

  private func configureAudioEngine() throws {
    let engine = AVAudioEngine()
    #if os(iOS)
    // iPhone speakerphone needs Apple's echo cancellation and noise suppression.
    // Enable before reading formats or wiring the graph: processing changes I/O.
    try engine.inputNode.setVoiceProcessingEnabled(true)
    engine.inputNode.isVoiceProcessingAGCEnabled = true
    #endif
    let player = AVAudioPlayerNode()
    engine.attach(player)
    // Player nodes render floating-point PCM; wire bytes are converted explicitly below.
    engine.connect(player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!)
    self.engine = engine
    self.player = player
  }

  private func audioDiagnostic(_ message: String) {
    let elapsed = Int((ProcessInfo.processInfo.systemUptime - connectionStartedAt) * 1000)
    logger.info("\(message, privacy: .public), elapsed=\(elapsed)ms")
  }

  private func startAudio(generation id: UUID) throws {
    guard let engine, let socket else {
      throw NSError(domain: "Chime", code: 4, userInfo: [NSLocalizedDescriptionKey: "Audio is not ready."])
    }
    audioDiagnostic("Starting microphone capture")
    let input = engine.inputNode
    let sourceFormat = input.outputFormat(forBus: 0)
    guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
          let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw NSError(domain: "Chime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone audio format is unavailable."])
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(8))
    audioContinuation = continuation
    #if os(iOS)
    let captureFrames: AVAudioFrameCount = 1024
    #else
    let captureFrames: AVAudioFrameCount = 2048
    #endif
    input.installTap(onBus: 0, bufferSize: captureFrames, format: sourceFormat) { buffer, _ in
      if let data = LiveAudioCodec.encode(buffer, using: converter, to: targetFormat) {
        guard !data.isEmpty else { return }
        if case .dropped = continuation.yield(data) {
          // Stop rather than silently skipping microphone samples or growing memory without bound.
          continuation.finish()
        }
      } else { continuation.finish() }
    }
    hasTap = true
    audioDiagnostic("Preparing audio engine")
    engine.prepare()
    audioDiagnostic("Starting audio engine")
    try engine.start()
    audioDiagnostic("Audio engine started")
    captureTask = Task { [weak self] in
      for await bytes in stream {
        guard let self, self.generation == id, self.state == .live, !Task.isCancelled else { return }
        do {
          // Continue the audio clock with silence while the local microphone is muted.
          #if os(watchOS)
          // The Series 8 cannot run voice processing reliably; retain its echo guard.
          let suppressEcho = (self.isSpeaking || Date() < self.microphoneResumeAt)
          #else
          // Echo-cancelled iPhone input stays open for interruptions and questions
          // while the assistant speaks or the backend researches.
          let suppressEcho = false
          #endif
          let audio = self.isMuted || suppressEcho ? Data(count: bytes.count) : bytes
          self.inputLevel = self.isMuted || suppressEcho ? 0 : LiveAudioCodec.level(bytes)
          self.updateOutputLevel()
          try await self.send(["type": "session.input_audio.append", "audio": audio.base64EncodedString()], on: socket)
        } catch {
          if self.generation == id { self.fail("Audio connection lost. Tap to reconnect.") }
          return
        }
      }
      if let self, self.generation == id, self.state == .live {
        self.fail("Audio could not keep up with this connection. Please reconnect.")
      }
    }
  }

  private func play(_ encoded: String, generation id: UUID) throws {
    guard let bytes = Data(base64Encoded: encoded), let player,
          let buffer = LiveAudioCodec.decode(bytes) else { return }
    let count = Int(buffer.frameLength)
    guard queuedFrames + count <= 24000 * 3 else {
      throw NSError(domain: "Chime", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio playback fell behind. Please reconnect."])
    }
    let audible = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count).contains { abs($0) > 0.015 }
    // Meter small slices against the player's sample clock, so animation follows
    // audible playback rather than the arrival time of network packets.
    let renderFrame = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? 0
    // Refill briefly after an underrun instead of playing each late packet alone.
    // Pause preserves the player sample clock and already scheduled buffers.
    if player.isPlaying, renderFrame >= scheduledOutputFrames {
      player.pause()
      audioDiagnostic("Playback buffer underrun; refilling")
    }
    scheduledOutputFrames = max(scheduledOutputFrames, renderFrame)
    for offset in stride(from: 0, to: bytes.count, by: 1920) {
      let slice = bytes.subdata(in: offset..<min(offset + 1920, bytes.count))
      let start = scheduledOutputFrames + Int64(offset / 2)
      outputMeters.append(OutputMeter(start: start, end: start + Int64(slice.count / 2), level: LiveAudioCodec.level(slice)))
    }
    scheduledOutputFrames += Int64(count)
    queuedFrames += count
    if audible { queuedSpeechBuffers += 1 }
    if audible {
      microphoneResumeAt = Date().addingTimeInterval(Double(queuedFrames) / 24000 + 0.25)
    }
    isSpeaking = queuedSpeechBuffers > 0
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.generation == id, self.state == .live else { return }
        self.queuedFrames = max(0, self.queuedFrames - count)
        if audible { self.queuedSpeechBuffers = max(0, self.queuedSpeechBuffers - 1) }
        self.isSpeaking = self.queuedSpeechBuffers > 0
      }
    }
    if !player.isPlaying, playbackStartTask == nil {
      playbackStartTask = Task { [weak self] in
        // Output arrives in 100 ms chunks. A small cushion absorbs ordinary jitter
        // without building a multi-second backlog or waiting for an audio-done event.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, let self, self.generation == id, self.state == .live else { return }
        self.playbackStartTask = nil
        self.player?.play()
      }
    }
  }

  private func updateOutputLevel() {
    guard let player, let render = player.lastRenderTime,
          let time = player.playerTime(forNodeTime: render) else { outputLevel = 0; return }
    outputMeters.removeAll { $0.end <= time.sampleTime }
    outputLevel = outputMeters.first(where: { $0.start <= time.sampleTime && time.sampleTime < $0.end })?.level ?? 0
  }

  private func stopAudio(deactivateSession: Bool = true) {
    if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
    audioContinuation?.finish()
    audioContinuation = nil
    captureTask?.cancel()
    captureTask = nil
    playbackStartTask?.cancel()
    playbackStartTask = nil
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    queuedFrames = 0
    outputMeters = []
    scheduledOutputFrames = 0
    inputLevel = 0
    outputLevel = 0
    queuedSpeechBuffers = 0
    isSpeaking = false
    if deactivateSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    conversationStore.flush()
  }

  private func fail(_ message: String) {
    error = message
    cleanup()
  }

  private func cleanup() {
    generation = UUID()
    state = .idle
    isResearching = false
    stopAudio()
    timeoutTask?.cancel()
    timeoutTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    isMuted = false
    startedAt = nil
    memoryStore.activeConversationID = nil
    memoryStore.refresh()
  }
}
