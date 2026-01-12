import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var metaDATPlugin: MetaDATPlugin?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        // Initialize Meta DAT Plugin
        metaDATPlugin = MetaDATPlugin(messenger: controller.binaryMessenger)

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // Handle URL callbacks from Meta View app
    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        // Check if this is a Meta View callback
        if url.scheme == "specbridge" {
            metaDATPlugin?.handleIncomingURL(url)
            return true
        }
        return super.application(app, open: url, options: options)
    }

    // Handle universal links
    override func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            metaDATPlugin?.handleIncomingURL(url)
            return true
        }
        return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }
}
