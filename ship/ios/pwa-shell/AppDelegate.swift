import UIKit
import UserNotifications

// NO FIREBASE. The template this shell came from (PWABuilder) wires Firebase Cloud Messaging, and
// three things were true at once here: `FirebaseApp.configure()` was commented out, while
// `Messaging.messaging()` was still called on the line below it — which raises before the first
// frame, so this build would have crashed on launch every time — and GoogleService-Info.plist was
// still Microsoft's template (bundle com.microsoft.pwabuilder-ios, API key all zeros). It had
// never been compiled, because there was never a Mac.
//
// The product does not want it either: push is deliberately absent in the iOS shell (canAskPush()
// in the web app hides every reminder surface and feature-detects PushManager so WKWebView never
// asks). Carrying an unused, unconfigurable SDK would also mean CocoaPods in CI, a third-party
// privacy manifest, and an SDK-usage declaration to Apple, all for code that must never run.
//
// Remote-notification callbacks stay, minus the Firebase parts: they cost nothing, and if push is
// ever added natively they are the right hooks. Nothing registers for notifications, so they are
// unreachable in this build.
@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) {
        sendPushToWebView(userInfo: userInfo)
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        sendPushToWebView(userInfo: userInfo)
        completionHandler(.newData)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Unable to register for remote notifications: \(error.localizedDescription)")
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        sendPushToWebView(userInfo: notification.request.content.userInfo)
        completionHandler([[.banner, .list, .sound]])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        sendPushClickToWebView(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}
