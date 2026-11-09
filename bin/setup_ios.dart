// Copies WireGuardTunnelKit (the packet tunnel extension's code and the
// prebuilt WireGuard library) into the app's ios folder.
//
//   dart run flutter_wireguard_tunnel:setup_ios
//
// Run it from the app's root folder, again after each upgrade of the package.
// Only ios/WireGuardTunnelKit is replaced. When the extension target already
// exists with Xcode's template PacketTunnelProvider.swift, that file is
// replaced too.
import 'dart:io';
import 'dart:isolate';

const kitName = 'WireGuardTunnelKit';
const providerSource = '''
import WireGuardTunnelKit

class PacketTunnelProvider: WireGuardTunnelProvider {}
''';

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln('Usage: dart run flutter_wireguard_tunnel:setup_ios');
    stdout.writeln('Copies $kitName into ios/ of the app in the current folder.');
    return;
  }

  final app = Directory.current;
  final ios = Directory(_join(app.path, 'ios'));
  if (!File(_join(app.path, 'pubspec.yaml')).existsSync() || !ios.existsSync()) {
    stderr.writeln('Run this from your Flutter app folder, the one with '
        'pubspec.yaml and ios/.');
    exitCode = 1;
    return;
  }

  final library = await Isolate.resolvePackageUri(
      Uri.parse('package:flutter_wireguard_tunnel/flutter_wireguard_tunnel.dart'));
  if (library == null) {
    stderr.writeln('flutter_wireguard_tunnel is not a dependency of this app. '
        'Add it to pubspec.yaml and run flutter pub get first.');
    exitCode = 1;
    return;
  }
  final package = File.fromUri(library).parent.parent;
  final source = Directory(_join(package.path, 'ios', kitName));
  if (!source.existsSync()) {
    stderr.writeln('$kitName is missing from ${package.path}');
    exitCode = 1;
    return;
  }

  final target = Directory(_join(ios.path, kitName));
  final updating = target.existsSync();
  if (updating) target.deleteSync(recursive: true);
  _copy(source, target);
  stdout.writeln('${updating ? 'Updated' : 'Copied'} ios/$kitName');

  final provider = _findProvider(ios);
  if (provider == null) {
    stdout.writeln('''

Next, in Xcode (open ios/Runner.xcworkspace):

  1. File > New > Target > Network Extension. Name it WireGuardTunnel,
     Provider Type Packet Tunnel, Embed in Application Runner.
  2. Run this command again, it fills in PacketTunnelProvider.swift.

The README has every step, with the capabilities and the package to add.''');
    return;
  }

  final text = provider.readAsStringSync();
  final relative = provider.path.substring(app.path.length + 1);
  if (text.contains('WireGuardTunnelProvider')) {
    stdout.writeln('$relative is already set up');
  } else if (_isXcodeTemplate(text)) {
    provider.writeAsStringSync(providerSource);
    stdout.writeln('Replaced Xcode\'s template in $relative');
  } else {
    stdout.writeln('''

$relative has your own code, left as it is. For the tunnel it should be:

$providerSource''');
  }
}

/// PacketTunnelProvider.swift of an extension target, outside the kit.
File? _findProvider(Directory ios) {
  for (final entry in ios.listSync()) {
    if (entry is! Directory) continue;
    final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == kitName || name == 'Pods' || name.startsWith('.')) continue;
    final file = File(_join(entry.path, 'PacketTunnelProvider.swift'));
    if (file.existsSync()) return file;
  }
  return null;
}

bool _isXcodeTemplate(String text) =>
    text.contains('class PacketTunnelProvider: NEPacketTunnelProvider') &&
    text.contains('Add code here');

void _copy(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entry in from.listSync(followLinks: false)) {
    final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final dest = _join(to.path, name);
    if (entry is Directory) {
      _copy(entry, Directory(dest));
    } else if (entry is File) {
      entry.copySync(dest);
    }
  }
}

String _join(String a, String b) =>
    a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';
