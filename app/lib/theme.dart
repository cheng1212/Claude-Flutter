import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 明快奶油 Framer 风:奶油底 + 焦糖橙主色 + 暖棕文字,干净无辉光。
/// widget API 与 zremote theme.dart 同形(HardCard/StatusChip/PulseDot/BigButton),
/// 页面代码可近乎照搬;仅把 token 换成浅色系。
abstract final class ZT {
  // ---- palette -----------------------------------------------------------
  static const Color bg = Color(0xFFFAF6EF); // 奶油底
  static const Color surface = Color(0xFFFFFFFF); // 卡片
  static const Color surfaceHi = Color(0xFFFFF8F0); // 高亮面板
  static const Color ink = Color(0xFF2B2118); // 主文字(暖深棕)
  static const Color inkSoft = Color(0xFF8A8275); // 次级文字
  static const Color inkFaint = Color(0xFFB9B1A4); // 暗文字
  static const Color line = Color(0xFFEDE5D8); // 发丝线
  static const Color edge = Color(0xFFE2D7C6); // 默认描边(浅暖)

  static const Color primary = Color(0xFFE8590C); // 焦糖橙
  static const Color primaryDeep = Color(0xFFC74405); // 深橙(浅底上可读)
  static const Color aqua = Color(0xFF4C8A7E); // 哑光青(工具/信息)
  static const Color lemon = Color(0xFFE9A13B); // 琥珀(等待/警示)
  static const Color rose = Color(0xFFD65745); // 珊瑚红(错误)
  static const Color grape = Color(0xFF9B6FC9); // 柔紫(思考)
  static const Color onInk = Color(0xFFFFFFFF); // 主色填充上的文字

  static const double radius = 12; // Framer 柔和圆角

  static const String mono = 'monospace'; // 代码块保留等宽
  static const String sans = 'Roboto'; // 主 UI 干净无衬线

  // ---- shadows / borders -------------------------------------------------

  /// 柔和暖阴影(取代原辉光)。dx/dy 保留 zremote 签名(按压位移仍有效),
  /// 但渲染为低透明度的双层柔影,符合浅色界面。
  static List<BoxShadow> hard({double dx = 2.5, double dy = 2.5, Color? color}) {
    final c = (color ?? primary).withValues(alpha: 0.16);
    return [
      BoxShadow(color: c, offset: Offset(0, dy * 1.4), blurRadius: 16, spreadRadius: -6),
      BoxShadow(color: c.withValues(alpha: 0.10), offset: Offset(0, dy * 0.5), blurRadius: 5, spreadRadius: -1),
    ];
  }

  static BorderSide inkSide({double w = 1.4, Color? color}) =>
      BorderSide(width: w, color: color ?? edge);

  // ---- theme -------------------------------------------------------------

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.light(
        primary: primary,
        onPrimary: onInk,
        secondary: aqua,
        surface: surface,
        onSurface: ink,
        error: rose,
        onError: onInk,
      ),
    );
    final sansStyle = TextStyle(fontFamily: sans, color: ink);
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        bodyLarge: sansStyle.copyWith(fontSize: 14),
        bodyMedium: sansStyle.copyWith(fontSize: 13),
        bodySmall: sansStyle.copyWith(fontSize: 11.5, color: inkSoft),
        titleLarge: sansStyle.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
        titleMedium: sansStyle.copyWith(fontSize: 14.5, fontWeight: FontWeight.w700),
        titleSmall: sansStyle.copyWith(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
        ),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: inkFaint, fontSize: 13, fontFamily: sans),
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
        contentTextStyle: sansStyle.copyWith(fontSize: 12.5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: inkSide(),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        titleTextStyle: sansStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
        contentTextStyle: sansStyle.copyWith(fontSize: 13, color: inkSoft),
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

/// 硬卡:浅暖底 + 柔和阴影;Material+Ink 让涟漪盖住底色。
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

/// 状态徽章:running 橙 / 等待琥珀 / 其余浅暖。
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
      'done' || 'idle' || '' => (ZT.inkSoft, '空闲'),
      _ => (ZT.aqua, phase),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9, vertical: compact ? 2.5 : 4),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
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
                fontFamily: ZT.sans)),
      ]),
    );
  }
}

/// 脉冲点:呼吸指示。控制器必须在 initState 里创建(不要用 late 懒初始化——
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

/// 大按钮:焦糖橙填充 + 柔和阴影 + 按压下沉。
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
                  fontSize: 13.5, fontWeight: FontWeight.w700, color: enabled ? fg : ZT.inkFaint, fontFamily: ZT.sans)),
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
