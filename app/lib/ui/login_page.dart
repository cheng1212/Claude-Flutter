// 登录页:填服务器地址 + 访问令牌。布局参考 pair 页:链接输入 + 状态条。
import 'package:flutter/material.dart';

import '../theme.dart';

class LoginPage extends StatefulWidget {
  final String? initialBaseUrl;
  final String? initialToken;
  final void Function(String baseUrl, String token) onDone;
  final String? error;

  const LoginPage({
    super.key,
    this.initialBaseUrl,
    this.initialToken,
    required this.onDone,
    this.error,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _base = TextEditingController(text: widget.initialBaseUrl ?? '');
  late final _token = TextEditingController(text: widget.initialToken ?? '');
  bool _hideToken = true;

  @override
  void dispose() {
    _base.dispose();
    _token.dispose();
    super.dispose();
  }

  void _go() {
    final base = _base.text.trim();
    final token = _token.text.trim();
    if (base.isEmpty || token.isEmpty) return;
    FocusScope.of(context).unfocus();
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
                  child: const Icon(Icons.terminal_rounded,
                      size: 30, color: ZT.primary),
                ),
                const SizedBox(height: 18),
                const Text('zCode 终端',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2)),
                const SizedBox(height: 5),
                Text('连上你电脑上的 Claude Code',
                    style: TextStyle(fontSize: 12.5, color: ZT.inkSoft)),
                const SizedBox(height: 26),
                TextField(
                  controller: _base,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'http://192.168.1.5:5190',
                    prefixIcon: Icon(Icons.dns_rounded, size: 19),
                  ),
                  style: const TextStyle(fontFamily: ZT.mono, fontSize: 13.5),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  obscureText: _hideToken,
                  autocorrect: false,
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
                  style: const TextStyle(fontFamily: ZT.mono, fontSize: 13.5),
                ),
                const SizedBox(height: 22),
                BigButton(label: '连接', icon: Icons.bolt_rounded, onPressed: _go, expand: true),
                if (widget.error != null) ...[
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
                    child: Text('${widget.error}',
                        style: const TextStyle(
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
