// 入口:读配置自动连;没配置进登录页。回前台刷新会话。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'debug_log.dart';
import 'ui/chat_page.dart';
import 'state/zapp.dart';
import 'theme.dart';
import 'ui/login_page.dart';
import 'notify.dart';
import 'ui/app_shell.dart';
import 'ws.dart';

const String _kBase = 'zcode.baseUrl';
const String _kToken = 'zcode.token';
const String _kTokenKey = 'zcode.token';
/// 令牌走系统安全存储(Android Keystore 加密):shared_preferences 是明文 XML,
/// root/备份/文件泄露即丢令牌(审计 #6)。
const FlutterSecureStorage _tokenStore = FlutterSecureStorage();

/// 读令牌:安全存储优先;空则查 prefs 旧值并**迁移**(搬进安全存储、抹掉明文副本)。
Future<String?> readStoredToken() async {
  try {
    final v = await _tokenStore.read(key: _kTokenKey);
    if (v != null && v.isNotEmpty) return v;
  } on Object {
    // 安全存储不可用(个别模拟器/桌面测试环境):退化读 prefs
  }
  try {
    final p = await SharedPreferences.getInstance();
    final legacy = p.getString(_kToken);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        await _tokenStore.write(key: _kTokenKey, value: legacy);
        await p.remove(_kToken); // 明文副本抹掉
      } on Object {
        // 迁移失败不影响本次登录:下次启动再搬
      }
      return legacy;
    }
  } on Object {
    // prefs 也不可用:当没存过处理
  }
  return null;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ZLog.install(); // 诊断日志:框架异常/主线程卡顿自动留证,设置里可复制
  await Notify.init();
  runApp(const ZCodeApp());
}

class ZCodeApp extends StatefulWidget {
  const ZCodeApp({super.key});

  @override
  State<ZCodeApp> createState() => _ZCodeAppState();
}

/// 全局导航 key:通知点击时从静态回调里拿 context 之外的导航能力。
final zcodeNavigatorKey = GlobalKey<NavigatorState>();

class _ZCodeAppState extends State<ZCodeApp> with WidgetsBindingObserver {

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
    // 前后台状态回写:后台时 complete/error/审批 会弹系统通知
    _app?.appLifecycle = state.name;
    // 回到前台:刷新会话列表(WS 断线重连由 ZSocket 自己兜)
    if (state == AppLifecycleState.resumed) {
      unawaited(_app?.refreshSessions());
    }
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final base = p.getString(_kBase);
    final token = await readStoredToken();
    unawaited(ZThemeController.load()); // 主题独立加载,不阻塞连接配置
    unawaited(NotifyPrefs.load()); // 通知开关与提醒方式同上
    if (base != null && base.isNotEmpty && token != null && token.isNotEmpty) {
      _wire(base, token);
    }
    if (mounted) setState(() => _ready = true);
  }

  void _wire(String base, String token) {
    _app?.dispose();
    final app = ZApp(
      api: ZApi(baseUrl: base, token: token, onUnauthorized: _onAuthExpired),
      socket: ZSocket(uri: ZApp.wsUriOf(base), token: token, onUnauthorized: _onAuthExpired),
      onUnauthorized: _onAuthExpired,
    );
    // 通知点击 → 直达对应会话(通知 payload 带会话 id)
    Notify.onTap = (sessionId) {
      if (_app != app || !_ready) return;
      Navigator.of(zcodeNavigatorKey.currentContext!).push(MaterialPageRoute(
        builder: (_) => ChatPage(app: app, sessionId: sessionId),
      ));
    };
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
          _loginError = apiErrorMessage(e);
        });
      }
      return;
    }
    await probe.close();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBase, base);
    try {
      await _tokenStore.write(key: _kTokenKey, value: token);
    } on Object {
      // 安全存储写不进(个别环境):令牌只留内存,本次会话可用,下次要重登
    }
    if (mounted) setState(() => _connecting = false);
    _wire(base, token);
  }

  /// 令牌失效(REST 401 / WS unauthorized):清令牌回登录页,不再 WS 无限重连、
  /// 页面反复弹同一个错(审计 #5)。保留 baseUrl,重登只需补 token。
  Future<void> _onAuthExpired() async {
    if (_app == null) return; // 并发 401 只处理一次
    try {
      await _tokenStore.delete(key: _kTokenKey);
    } on Object {
      // 清不掉也要回登录页:下次登录覆盖
    }
    _app?.dispose();
    if (mounted) {
      setState(() {
        _app = null;
        _token = null;
        _loginError = '令牌已失效,请重新登录';
      });
    }
  }

  Future<void> _logout() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kBase);
    await p.remove(_kToken);
    try {
      await _tokenStore.delete(key: _kTokenKey);
    } on Object {
      // 同上:清不掉不阻塞登出
    }
    _app?.dispose();
    setState(() {
      _app = null;
      _baseUrl = null;
      _token = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ZTheme>(
      valueListenable: ZThemeController.notifier,
      builder: (context, _, _) => MaterialApp(
        title: 'zCode',
        navigatorKey: zcodeNavigatorKey,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        locale: const Locale('zh', 'CN'),
        theme: ZT.theme(),
        home: !_ready
            ? Scaffold(backgroundColor: ZT.bg, body: SizedBox.shrink())
            : _app == null
                ? LoginPage(
                    initialBaseUrl: _baseUrl,
                    initialToken: _token,
                    onDone: _saveAndWire,
                    error: _loginError,
                    busy: _connecting,
                  )
                : AppShell(app: _app!, onLogout: _logout),
      ),
    );
  }
}
