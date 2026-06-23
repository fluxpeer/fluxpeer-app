// SPDX-License-Identifier: AGPL-3.0-or-later
import Flutter
import UIKit

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
    // Bridge the Flutter tunnel channels to the NETunnelProviderManager / NE.
    FluxpeerPlugin.register(with: engineBridge.pluginRegistry.registrar(forPlugin: "FluxpeerPlugin")!)
  }
}
