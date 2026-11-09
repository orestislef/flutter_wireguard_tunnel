Pod::Spec.new do |s|
  s.name             = 'flutter_wireguard_tunnel'
  s.version          = '0.1.0'
  s.summary          = 'WireGuard tunnel for Flutter.'
  s.description      = <<-DESC
The app side of flutter_wireguard_tunnel: VPN profile, device key in the
Keychain, start and stop of the packet tunnel extension.
                       DESC
  s.homepage         = 'https://github.com/orestislef/flutter_wireguard_tunnel'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Orestis Lef'
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_wireguard_tunnel/Sources/flutter_wireguard_tunnel/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.frameworks = 'NetworkExtension', 'CryptoKit', 'Security'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
