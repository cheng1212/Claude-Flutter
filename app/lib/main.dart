// 入口:读配置自动连;没配置进登录页。回前台刷新会话。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'state/zapp.dart';
import 'theme.dart';
import 'ui/login_page.dart';
import 'ui/app_shell.dart';
import 'ws.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ZCodeApp());
}

class ZCodeApp extends StatefulWidget {
  const ZCodeApp({super.key});

  @override
  State<ZCodeApp> createState() => _ZCodeAppState();
}

class _ZCodeAppState extends State<ZCodeApp> with WidgetsBindingObserver {
  static const _kBase = 'zcode.baseUrl';
  static const _kToken = 'zcode.token';

  ZApp? _app;
  String? _baseUrl;
  String? _token;
  bool _ready = false;
  bool _connecting = false;
  String? _loginError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _app?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台:刷新会话列表(WS 断线重连由 ZSocket 自己兜)
    if (state == AppLifecycleState.resumed) {
      unawaited(_app?.refreshSessions());
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final base = p.getString(_kBase);
    final token = p.getString(_kToken);
    if (base != null && base.isNotEmpty && token != null && token.isNotEmpty) {
      _wire(base, token);
    }
    if (mounted) setState(() => _ready = true);
  }

  void _wire(String base, String token) {
    _app?.dispose();
    final app = ZApp(
      api: ZApi(baseUrl: base, token: token),
      socket: ZSocket(uri: ZApp.wsUriOf(base), token: token),
    );
    setState(() {
      _app = app;
      _baseUrl = base;
      _token = token;
    });
    unawaited(app.bootstrap());
  }

  /// 登录:先探连(真 WS 握手),成功才存配置进主界面;失败留在登录页给具体错误,
  /// 不再「切过去看黄条」。探连多花一次握手,换来失败可见、按钮有 loading。
  Future<void> _saveAndWire(String base, String token) async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _loginError = null;
    });
    final probe = ZSocket(uri: ZApp.wsUriOf(base), token: token);
    try {
      await probe.connect(); // 连不上/鉴权失败都会抛
    } on Object catch (e) {
      await probe.close();
      if (mounted) {
        setState(() {
          _connecting = false;
          _loginError = '连不上服务器: $e';
        });
      }
      return;
    }
    await probe.close();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBase, base);
    await p.setString(_kToken, token);
    if (mounted) setState(() => _connecting = false);
    _wire(base, token);
  }

  Future<void> _logout() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kBase);
    await p.remove(_kToken);
    _app?.dispose();
    setState(() {
      _app = null;
      _baseUrl = null;
      _token = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'zCode',
      theme: ZT.theme(),
      home: !_ready
          ? const Scaffold(backgroundColor: ZT.bg, body: SizedBox.shrink())
          : _app == null
              ? LoginPage(
                  initialBaseUrl: _baseUrl,
                  initialToken: _token,
                  onDone: _saveAndWire,
                  error: _loginError,
                  busy: _connecting,
                )
              : AppShell(app: _app!, onLogout: _logout),
    );
  }
}
