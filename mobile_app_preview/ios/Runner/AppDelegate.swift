import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let badgeChannel = FlutterMethodChannel(
      name: "dansmagazin/badge",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    badgeChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "clearBadge":
        DispatchQueue.main.async {
          UIApplication.shared.applicationIconBadgeNumber = 0
          UNUserNotificationCenter.current().removeAllDeliveredNotifications()
          UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
          result(nil)
        }
      case "setBadge":
        let args = call.arguments as? [String: Any]
        let count = max(0, args?["count"] as? Int ?? 0)
        DispatchQueue.main.async {
          UIApplication.shared.applicationIconBadgeNumber = count
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
