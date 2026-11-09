import Foundation
import NetworkExtension
import WireGuardKit
import os

/// The packet tunnel itself. Runs as its own process, the app's packet tunnel
/// extension, started by the plugin in the app.
///
/// The extension only needs a subclass, nothing else:
///
///     import WireGuardTunnelKit
///
///     class PacketTunnelProvider: WireGuardTunnelProvider {}
///
/// Everything comes in the start options, private key included, so the key
/// is only ever held in the app's Keychain and in this process's memory.
/// Started any other way (the switch in iOS Settings) there is no config and
/// it refuses.
open class WireGuardTunnelProvider: NEPacketTunnelProvider {
  /// The app pings every 10s while it wants the tunnel. A kill doesn't always
  /// give it the chance to stop us, so this long without a ping means no app.
  private static let appSilenceLimit: TimeInterval = 45

  private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "flutter_wireguard_tunnel",
    category: "tunnel"
  )
  private let watchdogQueue = DispatchQueue(label: "flutter_wireguard_tunnel.watchdog")
  private var lastHeard = Date()
  private var watchdog: DispatchSourceTimer?

  private lazy var adapter = WireGuardAdapter(with: self) { [log] _, message in
    log.info("\(message, privacy: .public)")
  }

  open override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let config = Self.configuration(from: options) else {
      log.error("no usable config in the start options")
      completionHandler(TunnelError.badConfiguration)
      return
    }
    adapter.start(tunnelConfiguration: config) { [weak self, log] error in
      if let error = error {
        log.error("start failed: \(String(describing: error), privacy: .public)")
      } else {
        self?.startWatchdog()
      }
      completionHandler(error)
    }
  }

  open override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    watchdogQueue.sync {
      watchdog?.cancel()
      watchdog = nil
    }
    adapter.stop { [log] error in
      if let error = error {
        log.error("stop failed: \(String(describing: error), privacy: .public)")
      }
      completionHandler()
    }
  }

  open override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    heardFromApp()
    completionHandler?(nil)
  }

  // The app's timers stopped along with ours, its next ping is on the way.
  open override func wake() {
    heardFromApp()
  }

  private func heardFromApp() {
    watchdogQueue.async { self.lastHeard = Date() }
  }

  private func startWatchdog() {
    watchdogQueue.async {
      self.lastHeard = Date()
      self.watchdog?.cancel()
      let timer = DispatchSource.makeTimerSource(queue: self.watchdogQueue)
      timer.schedule(deadline: .now() + 15, repeating: 15)
      timer.setEventHandler { [weak self] in
        guard let self = self,
          Date().timeIntervalSince(self.lastHeard) > Self.appSilenceLimit
        else { return }
        self.log.info("no app behind the tunnel, stopping")
        self.watchdog?.cancel()
        self.watchdog = nil
        self.cancelTunnelWithError(nil)
      }
      timer.resume()
      self.watchdog = timer
    }
  }

  private static func configuration(from options: [String: NSObject]?) -> TunnelConfiguration? {
    guard let options = options,
      let privateBase64 = options["privateKey"] as? String,
      let privateKey = PrivateKey(base64Key: privateBase64),
      let addressStrings = options["address"] as? [String],
      let serverBase64 = options["serverPublicKey"] as? String,
      let serverKey = PublicKey(base64Key: serverBase64),
      let endpoint = (options["endpoint"] as? String).flatMap(Endpoint.init(from:)),
      let allowed = options["allowedIps"] as? [String]
    else { return nil }

    let addresses = addressStrings.compactMap(IPAddressRange.init(from:))
    guard !addresses.isEmpty, addresses.count == addressStrings.count else { return nil }
    let allowedRanges = allowed.compactMap(IPAddressRange.init(from:))
    guard !allowedRanges.isEmpty, allowedRanges.count == allowed.count else { return nil }
    let dnsStrings = options["dns"] as? [String] ?? []
    let dns = dnsStrings.compactMap(DNSServer.init(from:))
    guard dns.count == dnsStrings.count else { return nil }

    var interface = InterfaceConfiguration(privateKey: privateKey)
    interface.addresses = addresses
    interface.dns = dns
    interface.mtu = (options["mtu"] as? NSNumber)?.uint16Value ?? 1280

    var peer = PeerConfiguration(publicKey: serverKey)
    peer.endpoint = endpoint
    peer.allowedIPs = allowedRanges
    if let presharedBase64 = options["presharedKey"] as? String {
      guard let preshared = PreSharedKey(base64Key: presharedBase64) else { return nil }
      peer.preSharedKey = preshared
    }
    let keepalive = (options["keepalive"] as? NSNumber)?.uint16Value ?? 25
    peer.persistentKeepAlive = keepalive == 0 ? nil : keepalive

    return TunnelConfiguration(name: "wireguard", interface: interface, peers: [peer])
  }

  private enum TunnelError: Error {
    case badConfiguration
  }
}
