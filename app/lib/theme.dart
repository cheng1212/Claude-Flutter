import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 磷光终端风:深黑绿底 + 磷光绿 + 琥珀,全等宽,方角,辉光。
/// widget API 与 zremote theme.dart 同形(HardCard/StatusChip/PulseDot/BigButton),
/// 页面代码可近乎照搬。
abstract final class ZT {
  // ---- palette -----------------------------------------------------------
  static const Color bg = Color(0xFF0A0E0A); // 深黑绿底
  static const Color surface = Color(0xFF101710); // 面板
  static const Color surfaceHi = Color(0xFF162216); // 高亮面板
  static const Color ink = Color(0xFFC9F2D2); // 主文字/亮填充(绿白)
  static const Color inkSoft = Color(0xFF7FA88A); // 次级文字
  static const Color inkFaint = Color(0xFF4A6B52); // 暗文字
  static const Color line = Color(0xFF1C2B1E); // 发丝线
  static const Color edge = Color(0xFF2E4A34); // 默认描边(暗绿)

  static const Color primary = Color(0xFF33FF66); // 磷光绿
  static const Color primaryDeep = Color(0xFF1FBF4A); // 深磷光绿(浅底上可读)
  static const Color aqua = Color(0xFF4AE8D8); // 青绿(工具/信息)
  static const Color lemon = Color(0xFFFFB000); // 琥珀(等待/警示)
  static const Color rose = Color(0xFFFF5566); // 错误
  static const Color grape = Color(0xFFB48CFF); // 思考/紫
  static const Color onInk = Color(0xFF071009); // 亮填充上的深字

  static const double radius = 3; // 方角

  static const String mono = 'monospace';

  // ---- shadows / borders -------------------------------------------------

  /// 辉光:磷光绿柔光。dx/dy 保留 zremote 签名(按压位移仍有效),但渲染为辉光。
  static List<BoxShadow> hard({double dx = 2.5, double dy = 2.5, Color? color}) {
    final c = color ?? primary.withValues(alpha: 0.35);
    return [
      BoxShadow(color: c, offset: Offset(dx * 0.4, dy * 0.4), blurRadius: 10, spreadRadius: 0),
      BoxShadow(color: c.withValues(alpha: 0.35), offset: Offset.zero, blurRadius: 22, spreadRadius: 1),
    ];
  }

  static BorderSide inkSide({double w = 1.4, Color? color}) =>
      BorderSide(width: w, color: color ?? edge);

  // ---- theme -------------------------------------------------------------

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        onPrimary: onInk,
        secondary: aqua,
        surface: surface,
        onSurface: ink,
        error: rose,
        onError: onInk,
      ),
    );
    final monoStyle = TextStyle(fontFamily: mono, color: ink);
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        bodyLarge: monoStyle.copyWith(fontSize: 14),
        bodyMedium: monoStyle.copyWith(fontSize: 13),
        bodySmall: monoStyle.copyWith(fontSize: 11.5, color: inkSoft),
        titleLarge: monoStyle.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
        titleMedium: monoStyle.copyWith(fontSize: 14.5, fontWeight: FontWeight.w700),
        titleSmall: monoStyle.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bg,
        hintStyle: const TextStyle(color: inkFaint, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: inkSide(),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: inkSide(),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(width: 1.6, color: primary),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: monoStyle.copyWith(fontSize: 12.5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: inkSide(),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        titleTextStyle: monoStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
        contentTextStyle: monoStyle.copyWith(fontSize: 13, color: inkSoft),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? primary : inkFaint),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? primary.withValues(alpha: 0.25) : line),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}

/// 硬卡:磷光边 + 可选辉光;Material+Ink 让涟漪盖住底色。
class HardCard extends StatelessWidget {
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double shadowDx;
  final double shadowDy;
  final Color? borderColor;
  final double borderWidth;

  const HardCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(13),
    this.onTap,
    this.onLongPress,
    this.shadowDx = 0,
    this.shadowDy = 0,
    this.borderColor,
    this.borderWidth = 1.3,
  });

  @override
  Widget build(BuildContext context) {
    final glow = (shadowDx != 0 || shadowDy != 0) ? ZT.hard(dx: shadowDx, dy: shadowDy) : null;
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: color ?? ZT.surface,
          shadows: glow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: ZT.inkSide(w: borderWidth, color: borderColor),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZT.radius),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 状态徽章:running 绿 / 等待琥珀 / 其余暗。
class StatusChip extends StatelessWidget {
  final String phase;
  final bool compact;

  const StatusChip({super.key, required this.phase, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final p = phase.toLowerCase();
    final (Color color, String label) = switch (p) {
      'running' || 'working' || 'processing' => (ZT.primary, '运行中'),
      'waiting' || 'permission' => (ZT.lemon, '待确认'),
      'error' || 'failed' => (ZT.rose, '异常'),
      'done' || 'idle' || '' => (ZT.inkFaint, '空闲'),
      _ => (ZT.aqua, phase),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9, vertical: compact ? 2.5 : 4),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
          side: BorderSide(width: 1, color: color.withValues(alpha: 0.7)),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        PulseDot(color: color, animate: p == 'running' || p == 'waiting' || p == 'permission', size: 5),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w700,
                color: color,
                fontFamily: ZT.mono)),
      ]),
    );
  }
}

/// 脉冲点:CRT 光标呼吸。控制器必须在 initState 里创建(不要用 late 懒初始化——
/// unmount 时才首次创建会在 deactivated 树上查 TickerMode,触发断言崩溃)。
class PulseDot extends StatefulWidget {
  final Color color;
  final bool animate;
  final double size;

  const PulseDot({super.key, required this.color, this.animate = false, this.size = 7});

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900), lowerBound: 0.35, upperBound: 1);
    if (widget.animate) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant PulseDot old) {
    super.didUpdateWidget(old);
    widget.animate ? _c.repeat(reverse: true) : _c.animateTo(0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 大按钮:磷光填充 + 辉光 + 按压下沉。
class BigButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;
  final Color? color;
  final Color? textColor;

  const BigButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.color,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fill = color ?? ZT.primary;
    final fg = textColor ?? ZT.onInk;
    final button = _PressSink(
      pressed: enabled,
      onTap: onPressed,
      builder: (pressed) => Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        transform: Matrix4.translationValues(enabled && pressed ? 2 : 0, enabled && pressed ? 2 : 0, 0),
        decoration: ShapeDecoration(
          color: enabled ? fill : ZT.line,
          shadows: enabled ? ZT.hard(dx: 2.5, dy: 2.5, color: fill.withValues(alpha: 0.5)) : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: BorderSide(width: 1.4, color: enabled ? fill : ZT.edge),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          if (icon != null) ...[
            Icon(icon, size: 17, color: enabled ? fg : ZT.inkFaint),
            const SizedBox(width: 7),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700, color: enabled ? fg : ZT.inkFaint, fontFamily: ZT.mono)),
        ]),
      ),
    );
    if (expand) {
      return SizedBox(width: double.infinity, child: Center(child: button));
    }
    return button;
  }
}

/// 按压状态容器:按下时 builder(pressed=true),松手回调 onTap。
class _PressSink extends StatefulWidget {
  final bool pressed;
  final VoidCallback? onTap;
  final Widget Function(bool pressed) builder;

  const _PressSink({required this.pressed, this.onTap, required this.builder});

  @override
  State<_PressSink> createState() => _PressSinkState();
}

class _PressSinkState extends State<_PressSink> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.pressed ? (_) => setState(() => _down = true) : null,
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: widget.builder(_down),
    );
  }
}
