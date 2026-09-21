import Foundation
import Combine
import WatchConnectivity

/// Only connection settings cross devices; each device retains its own memory.
@MainActor
final class CompanionConnection: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = CompanionConnection()
  @Published private(set) var status = "Connection will sync to your paired Watch."

  func start() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  func sync() {
    #if os(iOS)
    let session = WCSession.default
    guard session.activationState == .activated else { return }
    let settings = AppSettings.load()
    guard !settings.userToken.isEmpty else { return }
    do {
      try session.updateApplicationContext([
        "gatewayURL": settings.gatewayURL.absoluteString,
        "userToken": settings.userToken
      ])
      status = "Connection queued for your Watch. Open Chime there to finish setup."
    } catch {
      status = "Watch setup is pending. Open Chime on your paired Watch, then tap Sync to Watch."
    }
    #endif
  }

  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    Task { @MainActor in self.sync() }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    #if os(watchOS)
    guard let address = applicationContext["gatewayURL"] as? String,
          let token = applicationContext["userToken"] as? String, !token.isEmpty else { return }
    Task { @MainActor in
      var settings = AppSettings.load()
      guard settings.setConnection(address: address, token: token) else { return }
      settings.save()
    }
    #endif
  }

  #if os(iOS)
  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in self.sync() }
  }
  #endif
}
