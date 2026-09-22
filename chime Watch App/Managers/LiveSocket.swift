import Foundation

/// Keep transport lifetime under the session owner's control. Cancelling the
/// microphone task must not cancel the shared socket while its final response drains.
enum LiveSocket {
  static func send(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask) async throws {
    try await completeSend { completion in socket.send(message, completionHandler: completion) }
  }

  static func completeSend(_ begin: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      begin { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  static func message(for error: Error, httpStatus: Int?) -> String {
    switch httpStatus ?? 0 {
    case 401, 403:
      return "Your connection was not authorized. Open Chime on your iPhone to check its connection settings."
    case 429:
      return "The voice service is busy. Wait a moment, then tap the bubble to reconnect."
    case 500...599:
      return "The voice service is temporarily unavailable. Tap the bubble to try again."
    default: break
    }
    let failure = error as NSError
    if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorNotConnectedToInternet {
      return "No network connection. Check Wi-Fi or your paired iPhone, then tap the bubble to reconnect."
    }
    return "The voice connection was interrupted. Keep Chime open and tap the bubble to reconnect."
  }
}
