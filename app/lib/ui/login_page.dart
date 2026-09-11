// 登录页:填服务器地址 + 访问令牌。布局参考 pair 页:链接输入 + 状态条。
import 'package:flutter/material.dart';

import '../theme.dart';

class LoginPage extends StatefulWidget {
  final String? initialBaseUrl;
  final String? initialToken;
  final void Function(String baseUrl, String token) onDone;

  /// 连不上时留在本页显示的具体错误(上层探连失败回传)。
  final String? error;

  /// true = 上层正在探连:按钮禁用转提示,防止重复点。
  final bool busy;

  const LoginPage({
    super.key,
    this.initialBaseUrl,
    this.initialToken,
    required this.onDone,
    this.error,
    this.busy = false,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  // 默认地址 = 家里局域网的实际地址,开箱少打一截;令牌不硬编码进安装包
  // (服务器首启已是随机令牌,预填只回填上次成功登录存下来的值)。
  static const _defaultBase = 'http://192.168.31.194:5190';
  late final _base = TextEditingController(text: widget.initialBaseUrl ?? _defaultBase);
  late final _token = TextEditingController(text: widget.initialToken);
  bool _hideToken = true;
  String? _localError;

  @override
  void dispose() {
    _base.dispose();
    _token.dispose();
    super.dispose();
  }

  void _go() {
    if (widget.busy) return;
    var base = _base.text.trim();
    final token = _token.text.trim();
    // 地址规范化:少打 http:// 不该连不上;格式错了当场说,别让人对着一排黄条猜
    if (base.isNotEmpty && !base.contains('://')) base = 'http://$base';
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty || token.isEmpty) {
      setState(() => _localError = '地址格式应形如 192.168.1.5:5190,令牌不能为空');
      return;
    }
    _base.text = base; // 回填规范化结果
    FocusScope.of(context).unfocus();
    setState(() => _localError = null);
    widget.onDone(base, token);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZT.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 标识:磷光方块 + 标题
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: ShapeDecoration(
                    color: ZT.primary.withValues(alpha: 0.12),
                    shadows: ZT.hard(dx: 3, dy: 3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(ZT.radius),
                      side: ZT.inkSide(w: 1.6, color: ZT.primary),
                    ),
                  ),
                  child: Icon(Icons.terminal_rounded,
                      size: 30, color: ZT.primary),
                ),
                const SizedBox(height: 18),
                const Text('zCode 终端',
                    style: TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1.5)),
                const SizedBox(height: 5),
                Text('连上你电脑上的 Claude Code',
                    style: TextStyle(fontSize: 12.5, color: ZT.inkSoft)),
                const SizedBox(height: 26),
                TextField(
                  controller: _base,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'http://192.168.1.5:5190',
                    prefixIcon: Icon(Icons.dns_rounded, size: 19),
                  ),
                  style: TextStyle(fontFamily: ZT.mono, fontSize: 13.5),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  obscureText: _hideToken,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _go(), // 填完键盘确认直接连
                  decoration: InputDecoration(
                    labelText: '访问令牌',
                    prefixIcon: const Icon(Icons.key_rounded, size: 19),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _hideToken
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          size: 19),
                      onPressed: () => setState(() => _hideToken = !_hideToken),
                    ),
                  ),
                  style: TextStyle(fontFamily: ZT.mono, fontSize: 13.5),
                ),
                const SizedBox(height: 22),
                BigButton(
                  label: widget.busy ? '连接中…' : '连接',
                  icon: widget.busy ? Icons.hourglass_top_rounded : Icons.bolt_rounded,
                  onPressed: widget.busy ? null : _go,
                  expand: true,
                ),
                if (_localError != null || widget.error != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: ShapeDecoration(
                      color: ZT.rose.withValues(alpha: 0.1),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(ZT.radius),
                        side: ZT.inkSide(w: 1.2, color: ZT.rose),
                      ),
                    ),
                    child: Text('${_localError ?? widget.error}',
                        style: TextStyle(
                            fontSize: 12, color: ZT.rose, fontFamily: ZT.mono)),
                  ),
                ],
                const SizedBox(height: 26),
                Text('服务器地址就是 zcode-server 打印的 URL,令牌同印在一行。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: ZT.inkFaint, height: 1.6)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
