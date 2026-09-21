import Foundation
import Combine
import AVFoundation

@MainActor
final class AgentSessionManager: ObservableObject {
  enum State { case idle, connecting, live, ending }
  @Published private(set) var state: State = .idle
  @Published private(set) var isMuted = false
  @Published private(set) var isSpeaking = false
  @Published private(set) var currentResponse = ""
  @Published private(set) var userTranscript = ""
  @Published private(set) var startedAt: Date?
  @Published var error: String?
  let conversationStore = ConversationStore()

  var isConnected: Bool { state == .live }
  var isListening: Bool { state != .idle }
  var statusText: String {
    switch state {
    case .idle: return "Ready when you are"
    case .connecting: return "Connecting…"
    case .ending: return "Ending conversation…"
    case .live: return isMuted ? "Microphone muted" : isSpeaking ? "Chime is speaking" : "Listening to you"
    }
  }

  private var socket: URLSessionWebSocketTask?
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var hasTap = false
  private var receiveTask: Task<Void, Never>?
  private var captureTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var audioContinuation: AsyncStream<Data>.Continuation?
  private var generation = UUID()
  private var queuedFrames = 0
  private var queuedSpeechBuffers = 0
  private var transcriptGroups: [MessageRole: (id: String, text: String, start: Double, end: Double)] = [:]
  private var conversationId: String?
  private var interruption: AnyCancellable?

  init() {
    interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              kind == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor in self?.stopListening() }
      }
  }

  func startListening() {
    guard state == .idle else { return }
    let settings = AppSettings.load()
    guard settings.gatewayURL.host != nil,
          ["http", "https"].contains(settings.gatewayURL.scheme ?? ""),
          !settings.userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      error = "Add your gateway address and access token in Settings."
      return
    }
    error = nil
    currentResponse = ""
    userTranscript = ""
    transcriptGroups = [:]
    isMuted = false
    state = .connecting
    let id = UUID()
    generation = id
    receiveTask = Task { [weak self] in
      guard let self else { return }
      let allowed = await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
      }
      guard generation == id, state == .connecting, !Task.isCancelled else { return }
      guard allowed else { fail("Allow microphone access in Watch Settings to talk to Chime."); return }
      do {
        guard try await prepareAudio(generation: id) else { return }
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
        let conversation = conversationStore.currentConversation ?? conversationStore.createConversation(title: "Live conversation")
        conversationId = conversation.id
        let history = conversation.messages.suffix(20).map {
          ["role": $0.role.rawValue, "content": String(decoding: $0.content.utf8.prefix(1500), as: UTF8.self)]
        }
        timeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(25))
          guard !Task.isCancelled, let self, self.generation == id, self.state == .connecting else { return }
          self.fail("Connection timed out. Check your gateway and try again.")
        }
        try await send(["type": "chime.session.start", "voice": settings.liveVoice ?? "marin", "research": settings.autoResearch, "history": history], on: connection)
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
          fail("\(error.localizedDescription) Check your gateway address, token, and connection.")
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
      state = .live
      startedAt = Date()
      try startAudio(generation: id)
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
    try session.setCategory(.playAndRecord, mode: .voiceChat)
    // Synchronous setActive succeeds on watchOS without enabling low-level
    // networking. Await watchOS audio activation before opening the WebSocket.
    let activated = try await session.activate(options: [])
    guard generation == id, state == .connecting, !Task.isCancelled else {
      // Activation may finish after Stop. Don't deactivate a newer session.
      if state == .idle {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
      }
      return false
    }
    guard activated else {
      throw NSError(domain: "Chime", code: 3, userInfo: [NSLocalizedDescriptionKey: "The Watch could not activate audio. Please try again."])
    }
    let engine = AVAudioEngine()
    try engine.inputNode.setVoiceProcessingEnabled(true)
    let player = AVAudioPlayerNode()
    engine.attach(player)
    // Player nodes render floating-point PCM; wire bytes are converted explicitly below.
    engine.connect(player, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!)
    self.engine = engine
    self.player = player
    return true
  }

  private func startAudio(generation id: UUID) throws {
    guard let engine, let socket else { return }
    let input = engine.inputNode
    let sourceFormat = input.outputFormat(forBus: 0)
    guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
          let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw NSError(domain: "Chime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone audio format is unavailable."])
    }
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(8))
    audioContinuation = continuation
    input.installTap(onBus: 0, bufferSize: 2048, format: sourceFormat) { buffer, _ in
      if let data = LiveAudioCodec.encode(buffer, using: converter, to: targetFormat) {
        guard !data.isEmpty else { return }
        if case .dropped = continuation.yield(data) {
          // Stop rather than silently skipping microphone samples or growing memory without bound.
          continuation.finish()
        }
      } else { continuation.finish() }
    }
    hasTap = true
    engine.prepare()
    try engine.start()
    captureTask = Task { [weak self] in
      for await bytes in stream {
        guard let self, self.generation == id, self.state == .live, !Task.isCancelled else { return }
        do {
          // Continue the audio clock with silence while the local microphone is muted.
          let audio = self.isMuted ? Data(count: bytes.count) : bytes
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
    queuedFrames += count
    if audible { queuedSpeechBuffers += 1 }
    isSpeaking = queuedSpeechBuffers > 0
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.generation == id, self.state == .live else { return }
        self.queuedFrames = max(0, self.queuedFrames - count)
        if audible { self.queuedSpeechBuffers = max(0, self.queuedSpeechBuffers - 1) }
        self.isSpeaking = self.queuedSpeechBuffers > 0
      }
    }
    if !player.isPlaying { player.play() }
  }

  private func stopAudio(deactivateSession: Bool = true) {
    if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
    audioContinuation?.finish()
    audioContinuation = nil
    captureTask?.cancel()
    captureTask = nil
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    queuedFrames = 0
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
    stopAudio()
    timeoutTask?.cancel()
    timeoutTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    isMuted = false
    startedAt = nil
  }
}
