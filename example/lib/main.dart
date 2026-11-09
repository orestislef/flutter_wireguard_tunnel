import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_wireguard_tunnel/flutter_wireguard_tunnel.dart';

void main() => runApp(const TunnelApp());

class TunnelApp extends StatelessWidget {
  const TunnelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_wireguard_tunnel',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const TunnelPage(),
    );
  }
}

class TunnelPage extends StatefulWidget {
  const TunnelPage({super.key});

  @override
  State<TunnelPage> createState() => _TunnelPageState();
}

class _TunnelPageState extends State<TunnelPage> {
  static const _sample = '''
[Interface]
Address = 10.8.0.2/32

[Peer]
PublicKey = <server public key>
Endpoint = vpn.example.com:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
''';

  final _tunnel = const WireGuardTunnel();
  final _config = TextEditingController(text: _sample);
  String _publicKey = '';
  WireGuardState _state = WireGuardState.down;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _config.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!_tunnel.isSupported) {
      setState(() => _message = 'Android and iOS only');
      return;
    }
    try {
      final key = await _tunnel.publicKey();
      final state = await _tunnel.state();
      if (!mounted) return;
      setState(() {
        _publicKey = key;
        _state = state;
      });
    } on WireGuardException catch (e) {
      if (mounted) setState(() => _message = e.message);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on WireGuardException catch (e) {
      _message = '${e.code}: ${e.message}';
    } on FormatException catch (e) {
      _message = 'Config: ${e.message}';
    }
    final state = await _tunnel.state();
    if (!mounted) return;
    setState(() {
      _state = state;
      _busy = false;
    });
  }

  Future<void> _start() => _run(() async {
        final config = WireGuardConfig.parse(_config.text);
        if (!await _tunnel.prepare()) {
          _message = 'VPN permission not given';
          return;
        }
        await _tunnel.start(config);
      });

  Future<void> _stop() => _run(_tunnel.stop);

  @override
  Widget build(BuildContext context) {
    final up = _state == WireGuardState.up;
    return Scaffold(
      appBar: AppBar(title: const Text('WireGuard tunnel')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('This device', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _publicKey.isEmpty ? '...' : _publicKey,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                tooltip: 'Copy public key',
                icon: const Icon(Icons.copy),
                onPressed: _publicKey.isEmpty
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: _publicKey)),
              ),
            ],
          ),
          const Text(
            'Add this public key as a peer on your server. Leave PrivateKey '
            'out of the config below to use it.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _config,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              labelText: 'Config (wg-quick format)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(
                up ? Icons.vpn_lock : Icons.lock_open,
                color: up ? Colors.green : null,
              ),
              const SizedBox(width: 8),
              Text(up ? 'Up' : 'Down'),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _start,
                child: Text(up ? 'Restart' : 'Start'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy || !up ? null : _stop,
                child: const Text('Stop'),
              ),
            ],
          ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(
              _message!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
