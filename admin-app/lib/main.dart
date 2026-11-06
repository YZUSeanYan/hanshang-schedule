import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:webview_flutter/webview_flutter.dart';

const String _sshHost = 'your-server.example';
const int _sshPort = 22;
const String _sshUser = 'your-ssh-user';
const int _localPort = 8000;

void main() => runApp(const AdminApp());

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '邗上课表管理后台',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF158A63),
        ),
        home: const TunnelPage(),
      );
}

class TunnelPage extends StatefulWidget {
  const TunnelPage({super.key});
  @override
  State<TunnelPage> createState() => _TunnelPageState();
}

class _TunnelPageState extends State<TunnelPage> {
  SSHClient? _client;
  String _status = '正在连接服务器…';
  bool _connected = false;
  WebViewController? _webView;
  StreamSubscription? _doneSub;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    setState(() { _status = '正在连接服务器…'; _connected = false; });
    try {
      final keyPem = await rootBundle.loadString('assets/admin_tunnel');
      final socket = await SSHSocket.connect(_sshHost, _sshPort);
      final client = SSHClient(
        socket,
        username: _sshUser,
        identities: SSHKeyPair.fromPem(keyPem),
      );
      _client = client;
      // 本地监听 8000，每个连接经 SSH 隧道转发到服务器 localhost:8000
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _localPort);
      server.listen((socket) async {
        try {
          final channel = await client.forwardLocal('localhost', 8000);
          socket.cast<List<int>>().pipe(channel.sink);
          channel.stream.listen(socket.add,
              onDone: socket.close, onError: (_) => socket.destroy());
        } catch (_) {
          socket.destroy();
        }
      });
      setState(() {
        _status = '已连接，正在加载管理后台…';
        _connected = true;
      });
      client.done.then((_) {
        if (mounted) setState(() { _status = '连接已断开'; _connected = false; });
      });
      _loadAdmin();
    } catch (e) {
      setState(() { _status = '连接失败：$e'; _connected = false; });
    }
  }

  void _loadAdmin() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _status = '');
        },
      ))
      ..loadRequest(Uri.parse('http://localhost:$_localPort/admin/'));
    setState(() => _webView = controller);
  }

  @override
  void dispose() {
    _doneSub?.cancel();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('邗上课表管理后台'),
        actions: [
          if (!_connected && _status.isNotEmpty)
            TextButton(onPressed: _connect, child: const Text('重连')),
        ],
      ),
      body: Column(
        children: [
          if (_status.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              color: _connected ? const Color(0xFFE8F5E9) : const Color(0xFFFFF3E0),
              child: Text(_status, style: TextStyle(
                color: _connected ? const Color(0xFF158A63) : const Color(0xFFE65100),
                fontSize: 13,
              )),
            ),
          Expanded(
            child: _webView != null
                ? WebViewWidget(controller: _webView!)
                : const Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }
}
