import SwiftUI
import UIKit
import UserNotifications

/// Seder on the iPhone: the web app, full screen, plus the two things only a real app can do:
/// alerts while it is closed, and the countdown on the Lock Screen.
@main
struct SederApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-sederDemo") {
                DemoScreen()
            } else {
                WebScreen()
                    .ignoresSafeArea()
                    .background(Color("LaunchBG").ignoresSafeArea())
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        LiveManager.shared.begin()
        if ProcessInfo.processInfo.arguments.contains("-sederDemoLive") {
            // Build machine only: a real countdown, so the real Lock Screen can be photographed.
            let now = Date().timeIntervalSince1970
            LiveManager.shared.show(key: "demo:kiddushin", title: "Masechet Kiddushin", sub: "with Rabbi Resnick", startAt: now - 2820, endAt: now + 4380, next: "Mincha")
        }
        // Already allowed: make sure the token the server holds is still the right one.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized {
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        LiveManager.shared.deviceToken = hex(deviceToken)
        NotificationCenter.default.post(name: .sederTokens, object: nil)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[seder] no push token: \(error.localizedDescription)")
        NotificationCenter.default.post(name: .sederTokens, object: nil)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        LiveManager.shared.tidy()
        completionHandler(.noData)
    }

    /// An alert while the app is open still shows.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A tapped alert opens the screen it is about.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let screen = response.notification.request.content.userInfo["screen"] as? String {
            NotificationCenter.default.post(name: .sederOpen, object: screen)
        }
        completionHandler()
    }
}
