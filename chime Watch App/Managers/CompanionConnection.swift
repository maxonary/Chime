import Foundation
import Combine
import WatchConnectivity

/// The phone owns subsequent connection changes. An already-configured Watch
/// may bootstrap a fresh phone, but can never replace a saved phone connection.
@MainActor
final class CompanionConnection: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = CompanionConnection()
  @Published private(set) var isConfigured = AppSettings.load().hasConnection
  @Published private(set) var status = "Open Chime on your Watch to connect automatically."

  func start() {
    isConfigured = AppSettings.load().hasConnection
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    session.delegate = self
    if session.activationState == .activated {
      receive(session.receivedApplicationContext)
      sync()
    } else {
      session.activate()
    }
  }

  func sync() {
    let settings = AppSettings.load()
    isConfigured = settings.hasConnection
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    guard session.activationState == .activated else { return }
    guard settings.hasConnection else {
      status = "Open Chime on your Watch to connect automatically."
      // Ask a foreground counterpart to send its current connection immediately.
      if session.isReachable {
        session.sendMessage(["requestConnection": true], replyHandler: nil, errorHandler: { _ in })
      }
      return
    }
    let payload = ["gatewayURL": settings.gatewayURL.absoluteString, "userToken": settings.userToken]
    do {
      try session.updateApplicationContext(payload)
      status = "Your connection is ready."
    } catch {
      status = "Connected here. Open Chime on your other device to finish pairing."
    }
    if session.isReachable {
      // Application context remains the durable fallback if live delivery fails.
      session.sendMessage(payload, replyHandler: nil, errorHandler: { _ in })
    }
  }

  private func receive(_ payload: [String: Any]) {
    guard let address = payload["gatewayURL"] as? String,
          let token = payload["userToken"] as? String else { return }
    var settings = AppSettings.load()
    #if os(iOS)
    let bootstrapOnly = true
    #else
    let bootstrapOnly = false
    #endif
    guard settings.importCompanionConnection(address: address, token: token, bootstrapOnly: bootstrapOnly) else { return }
    settings.save()
    isConfigured = true
    status = "Your connection is ready."
    sync()
  }

  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    let failed = error != nil
    Task { @MainActor in
      if failed {
        self.status = "Pairing is unavailable. Keep both devices nearby and try again."
      } else {
        self.receive(WCSession.default.receivedApplicationContext)
        self.sync()
      }
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    deliver(applicationContext)
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    if message["requestConnection"] as? Bool == true {
      Task { @MainActor in
        // Do not echo a request if neither device is configured.
        if AppSettings.load().hasConnection { self.sync() }
      }
    } else {
      deliver(message)
    }
  }

  nonisolated private func deliver(_ payload: [String: Any]) {
    guard let address = payload["gatewayURL"] as? String,
          let token = payload["userToken"] as? String else { return }
    Task { @MainActor in self.receive(["gatewayURL": address, "userToken": token]) }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in self.sync() }
  }

  #if os(iOS)
  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in self.sync() }
  }
  #endif
}
