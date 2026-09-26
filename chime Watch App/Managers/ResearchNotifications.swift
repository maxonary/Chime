import Foundation
import UserNotifications
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

@MainActor
final class ResearchNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = ResearchNotifications()
  private var token: String?
  private var requesting = false

  func registerIfAuthorized() async {
    UNUserNotificationCenter.current().delegate = self
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
    #if os(watchOS)
    WKApplication.shared().registerForRemoteNotifications()
    #else
    UIApplication.shared.registerForRemoteNotifications()
    #endif
    await uploadToken()
  }
  func enableForResearch() async {
    guard !requesting else { return }
    requesting = true
    defer { requesting = false }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
    await registerIfAuthorized()
  }
  func registered(_ data: Data) {
    token = data.map { String(format: "%02x", $0) }.joined()
    Task { await uploadToken() }
  }
  private func uploadToken() async {
    guard let token, AppSettings.load().hasConnection else { return }
    #if os(watchOS)
    let platform = "watchos"
    #else
    let platform = "ios"
    #endif
    #if DEBUG
    let environment = "sandbox"
    #else
    let environment = "production"
    #endif
    _ = try? await ResearchInbox.request(path: "v1/push/devices", method: "PUT", body: ["token": token, "platform": platform, "environment": environment])
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard let id = response.notification.request.content.userInfo["research_task_id"] as? String, UUID(uuidString: id) != nil else { return }
    await MainActor.run { ChimeNavigation.shared.openResearch(id) }
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}

#if os(watchOS)
final class ChimeAppDelegate: NSObject, WKApplicationDelegate {
  func applicationDidFinishLaunching() { UNUserNotificationCenter.current().delegate = ResearchNotifications.shared }
  func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) { ResearchNotifications.shared.registered(deviceToken) }
}
#else
final class ChimeAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    UNUserNotificationCenter.current().delegate = ResearchNotifications.shared
    return true
  }
  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { ResearchNotifications.shared.registered(deviceToken) }
}
#endif
