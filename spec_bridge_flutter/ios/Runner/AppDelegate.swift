import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    private var metaDATPlugin: MetaDATPlugin?
    private var bluetoothAudioPlugin: BluetoothAudioPlugin?

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpecBridgeNative") else { return }
        metaDATPlugin = MetaDATPlugin(messenger: registrar.messenger())
        bluetoothAudioPlugin = BluetoothAudioPlugin(messenger: registrar.messenger())
    }
    // FlutterSceneDelegate and app_links deliver both meeting links and Meta
    // callbacks to Dart. Do not swallow them or log URLs containing JWTs here.
}
