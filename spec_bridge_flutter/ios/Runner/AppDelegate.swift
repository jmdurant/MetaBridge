import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var metaDATPlugin: MetaDATPlugin?
    private var bluetoothAudioPlugin: BluetoothAudioPlugin?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        // Initialize Meta DAT Plugin
        metaDATPlugin = MetaDATPlugin(messenger: controller.binaryMessenger)

        // Initialize Bluetooth Audio Plugin
        bluetoothAudioPlugin = BluetoothAudioPlugin(messenger: controller.binaryMessenger)

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // Handle URL callbacks from Meta View app and deep links
    override func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        // Handle specbridge:// and openemr-telehealth:// schemes
        if url.scheme == "specbridge" || url.scheme == "openemr-telehealth" {
            print("AppDelegate: Deep link received: \(url)")
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
