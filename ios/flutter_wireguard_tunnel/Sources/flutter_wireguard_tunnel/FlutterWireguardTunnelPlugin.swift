import CryptoKit
import Flutter
import NetworkExtension
import Security
import UIKit

/// The app's half of the tunnel on iOS. The tunnel itself runs in the app's
/// packet tunnel extension (WireGuardTunnelProvider in WireGuardTunnelKit).
///
/// The private key is made here, kept in the Keychain on this device only,
/// and handed to the extension when the tunnel starts. Dart only ever sees
/// the public key.
public final class FlutterWireguardTunnelPlugin: NSObject, FlutterPlugin {
  private static let keychainService = "flutter_wireguard_tunnel"
  private static let startTimeout: TimeInterval = 20
  private static let stopTimeout: TimeInterval = 5
  private static let packetTunnelPoint = "com.apple.networkextension.packet-tunnel"

  /// Once per process, also when other plugins start more engines.
  private static var cleanedUpAtLaunch = false
  private static var upRequested = false

  /// The app's packet tunnel extension, found in the app bundle.
  private static let providerBundleId: String? = {
    guard let plugIns = Bundle.main.builtInPlugInsURL,
      let items = try? FileManager.default.contentsOfDirectory(
        at: plugIns, includingPropertiesForKeys: nil)
    else { return nil }
    for url in items where url.pathExtension == "appex" {
      guard let bundle = Bundle(url: url),
        let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
        ext["NSExtensionPointIdentifier"] as? String == packetTunnelPoint,
        let id = bundle.bundleIdentifier
      else { continue }
      return id
    }
    return nil
  }()

  private var terminateObserver: NSObjectProtocol?
  private var activeObserver: NSObjectProtocol?
  // Set while Dart wants the tunnel up. Kept here so a terminating app can
  // stop it at once, there is no time left to load the profile first.
  private var activeManager: NETunnelProviderManager?
  private var activeOptions: [String: NSObject]?
  private var heartbeat: Timer?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_wireguard_tunnel", binaryMessenger: registrar.messenger())
    let instance = FlutterWireguardTunnelPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  override init() {
    super.init()
    // Like Android: no app behind it, no tunnel. Otherwise the keepalives
    // make the server think the device is still there.
    terminateObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.activeManager?.connection.stopVPNTunnel()
    }
    // Suspended for long enough, the extension stopped itself. Back in front
    // the app still wants it.
    activeObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.restartIfDropped()
    }
    // The extension outlives the app, and a kill doesn't always reach the
    // observer above. A tunnel already up at launch is an orphan.
    if !Self.cleanedUpAtLaunch {
      Self.cleanedUpAtLaunch = true
      loadManager { manager, _ in
        guard !Self.upRequested else { return }
        manager?.connection.stopVPNTunnel()
      }
    }
  }

  deinit {
    if let terminateObserver = terminateObserver {
      NotificationCenter.default.removeObserver(terminateObserver)
    }
    if let activeObserver = activeObserver {
      NotificationCenter.default.removeObserver(activeObserver)
    }
    heartbeat?.invalidate()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "publicKey":
      do {
        result(try privateKey().publicKey.rawRepresentation.base64EncodedString())
      } catch {
        fail(result, error)
      }
    case "isPrepared":
      loadManager { manager, _ in result(manager != nil) }
    case "prepare":
      prepare(result)
    case "up":
      up(call, result)
    case "down":
      down(result)
    case "state":
      loadManager { manager, _ in
        result(manager?.connection.status == .connected ? "up" : "down")
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ---- VPN profile ----

  private func loadManager(_ done: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    guard let providerBundleId = Self.providerBundleId else {
      done(nil, nil)
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      let manager = managers?.first {
        ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
          == providerBundleId
      }
      DispatchQueue.main.async { done(manager, error) }
    }
  }

  /// iOS's own "Add VPN Configurations" alert, once per install. False when
  /// the user says no, like Android.
  private func prepare(_ result: @escaping FlutterResult) {
    guard Self.providerBundleId != nil else {
      fail(result, TunnelError.noExtension)
      return
    }
    loadManager { [weak self] existing, _ in
      guard let self = self else { return }
      if existing != nil {
        result(true)
        return
      }
      self.save(NETunnelProviderManager()) { error in
        if let error = error {
          NSLog("[WireGuardTunnel] prepare failed: \(error)")
        }
        result(error == nil)
      }
    }
  }

  /// Also what turns the profile back on after another VPN app took over.
  private func save(_ manager: NETunnelProviderManager, _ done: @escaping (Error?) -> Void) {
    let name =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? "WireGuard"
    let proto = NETunnelProviderProtocol()
    proto.providerBundleIdentifier = Self.providerBundleId
    proto.serverAddress = name
    manager.protocolConfiguration = proto
    manager.localizedDescription = name
    manager.isEnabled = true
    manager.saveToPreferences { error in
      if let error = error {
        DispatchQueue.main.async { done(error) }
        return
      }
      // Starting a just-saved manager fails until it has been loaded again.
      manager.loadFromPreferences { error in
        DispatchQueue.main.async { done(error) }
      }
    }
  }

  // ---- up / down ----

  private func up(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard Self.providerBundleId != nil else {
      fail(result, TunnelError.noExtension)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let address = args["address"] as? [String], !address.isEmpty,
      let serverKey = args["serverPublicKey"] as? String,
      let endpoint = args["endpoint"] as? String,
      let allowed = args["allowedIps"] as? [String], !allowed.isEmpty
    else {
      fail(result, TunnelError.badArguments)
      return
    }
    Self.upRequested = true
    let key: String
    if let given = args["privateKey"] as? String {
      key = given
    } else {
      do {
        key = try privateKey().rawRepresentation.base64EncodedString()
      } catch {
        fail(result, error)
        return
      }
    }
    var options: [String: NSObject] = [
      "privateKey": key as NSString,
      "address": address as NSArray,
      "serverPublicKey": serverKey as NSString,
      "endpoint": endpoint as NSString,
      "allowedIps": allowed as NSArray,
      "dns": (args["dns"] as? [String] ?? []) as NSArray,
      "keepalive": NSNumber(value: args["keepalive"] as? Int ?? 25),
      "mtu": NSNumber(value: args["mtu"] as? Int ?? 1280),
    ]
    if let preshared = args["presharedKey"] as? String {
      options["presharedKey"] = preshared as NSString
    }

    loadManager { [weak self] manager, error in
      guard let self = self else { return }
      guard let manager = manager else {
        self.fail(result, error ?? TunnelError.notPrepared)
        return
      }
      self.save(manager) { error in
        if let error = error {
          self.fail(result, error)
          return
        }
        // A new config needs a new start, the running tunnel keeps the old one.
        self.stop(manager.connection) {
          do {
            try manager.connection.startVPNTunnel(options: options)
          } catch {
            self.fail(result, error)
            return
          }
          self.wait(
            for: manager.connection, status: .connected, timeout: Self.startTimeout
          ) { reached in
            if reached {
              NSLog("[WireGuardTunnel] up \(address) via \(endpoint) allowed=\(allowed)")
              self.tunnelWanted(manager, options)
              result(true)
            } else {
              manager.connection.stopVPNTunnel()
              self.fail(result, TunnelError.didNotConnect)
            }
          }
        }
      }
    }
  }

  private func down(_ result: @escaping FlutterResult) {
    Self.upRequested = false
    tunnelWanted(nil, nil)
    loadManager { [weak self] manager, _ in
      guard let self = self, let manager = manager else {
        result(true)
        return
      }
      self.stop(manager.connection) { result(true) }
    }
  }

  /// Pings the extension every 10s while the tunnel is wanted. Without the
  /// pings it stops itself, so a killed app does not leave it running.
  private func tunnelWanted(_ manager: NETunnelProviderManager?, _ options: [String: NSObject]?) {
    activeManager = manager
    activeOptions = options
    heartbeat?.invalidate()
    heartbeat = nil
    guard let session = manager?.connection as? NETunnelProviderSession else { return }
    let timer = Timer(timeInterval: 10, repeats: true) { _ in
      try? session.sendProviderMessage(Data([1]), responseHandler: nil)
    }
    RunLoop.main.add(timer, forMode: .common)
    heartbeat = timer
  }

  private func restartIfDropped() {
    guard let manager = activeManager, let options = activeOptions,
      manager.connection.status == .disconnected
    else { return }
    NSLog("[WireGuardTunnel] back in front with the tunnel down, starting it again")
    do {
      try manager.connection.startVPNTunnel(options: options)
    } catch {
      NSLog("[WireGuardTunnel] restart failed: \(error)")
    }
  }

  private func stop(_ connection: NEVPNConnection, _ done: @escaping () -> Void) {
    if connection.status == .disconnected || connection.status == .invalid {
      done()
      return
    }
    connection.stopVPNTunnel()
    wait(for: connection, status: .disconnected, timeout: Self.stopTimeout) { _ in done() }
  }

  /// Calls back true on reaching [status]. False on timing out, or on the
  /// tunnel dropping while waiting for it to connect.
  private func wait(
    for connection: NEVPNConnection,
    status target: NEVPNStatus,
    timeout: TimeInterval,
    _ done: @escaping (Bool) -> Void
  ) {
    var observer: NSObjectProtocol?
    var finished = false
    let finish: (Bool) -> Void = { reached in
      guard !finished else { return }
      finished = true
      if let observer = observer {
        NotificationCenter.default.removeObserver(observer)
      }
      done(reached)
    }
    let check = {
      if connection.status == target {
        finish(true)
      } else if target == .connected && connection.status == .disconnected {
        finish(false)
      }
    }
    observer = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: connection, queue: .main
    ) { _ in check() }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
    if connection.status == target { finish(true) }
  }

  private func fail(_ result: @escaping FlutterResult, _ error: Error) {
    NSLog("[WireGuardTunnel] failed: \(error)")
    var code = "failed"
    var message = "\(error)"
    if let error = error as? TunnelError {
      switch error {
      case .noExtension:
        code = "no_extension"
        message = "No packet tunnel extension in the app, see the iOS setup in the README"
      case .notPrepared:
        code = "not_prepared"
        message = "VPN permission not given, call prepare() first"
      case .badArguments:
        code = "bad_config"
        message = "The config was rejected"
      case .didNotConnect:
        message = "The tunnel did not come up"
      case .keychain(let status):
        message = "Keychain error \(status)"
      }
    }
    result(FlutterError(code: code, message: message, details: nil))
  }

  // ---- key, made once and kept in the Keychain ----

  private func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
    ]
    var found: CFTypeRef?
    let read = SecItemCopyMatching(
      query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found
    )
    if read == errSecSuccess, let data = found as? Data,
      let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    {
      return key
    }
    SecItemDelete(query as CFDictionary)
    let key = Curve25519.KeyAgreement.PrivateKey()
    let add = query.merging([
      kSecValueData as String: key.rawRepresentation,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]) { $1 }
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw TunnelError.keychain(status) }
    return key
  }

  private enum TunnelError: Error {
    case noExtension
    case notPrepared
    case badArguments
    case didNotConnect
    case keychain(OSStatus)
  }
}
