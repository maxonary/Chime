import Foundation

/// Delay completion to reproduce tapping Stop while a send is still in flight.
final class ControlledSend: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: (@Sendable (Error?) -> Void)?
  var hasPendingSend: Bool { lock.withLock { completion != nil } }

  func begin(completionHandler: @escaping @Sendable (Error?) -> Void) {
    lock.withLock { completion = completionHandler }
  }
  func finish(_ error: Error? = nil) {
    let callback = lock.withLock { let value = completion; completion = nil; return value }
    callback?(error)
  }
}

@main
struct LiveSocketTests {
  static func waitForSend(_ send: ControlledSend) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !send.hasPendingSend {
      precondition(ContinuousClock.now < deadline, "Send did not start")
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  static func main() async throws {
    let socket = ControlledSend()
    let capture = Task { try await LiveSocket.completeSend(socket.begin) }
    try await waitForSend(socket)
    capture.cancel()
    await Task.yield()
    assert(socket.hasPendingSend, "Cancelling capture must let its in-flight send finish")
    socket.finish()
    try await capture.value

    let close = Task { try await LiveSocket.completeSend(socket.begin) }
    try await waitForSend(socket)
    socket.finish()
    try await close.value

    let failedSocket = ControlledSend()
    let failing = Task { try await LiveSocket.completeSend(failedSocket.begin) }
    try await waitForSend(failedSocket)
    failedSocket.finish(URLError(.networkConnectionLost))
    do { try await failing.value; assertionFailure("A real transport error must propagate") }
    catch { assert((error as NSError).code == NSURLErrorNetworkConnectionLost) }

    let cancellation = NSError(domain: NSPOSIXErrorDomain, code: 89)
    assert(!LiveSocket.message(for: cancellation, httpStatus: nil).contains("settings"), "OS cancellation is not evidence of bad credentials")
    assert(!LiveSocket.message(for: URLError(.cancelled), httpStatus: 101).contains("settings"))
    assert(LiveSocket.message(for: URLError(.badServerResponse), httpStatus: 401).contains("not authorized"))
    assert(LiveSocket.message(for: URLError(.badServerResponse), httpStatus: 503).contains("temporarily unavailable"))
    assert(LiveSocket.message(for: URLError(.notConnectedToInternet), httpStatus: nil).contains("No network"))
    print("PASS: cancelling capture permits send completion and a subsequent finalization send; transport errors propagate; network failures never imply bad credentials")
  }
}
