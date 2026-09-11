import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题名:cream = 明快奶油(原版默认)/ citrus = 柑橘晨光(移植 zremote)/
/// sticker = 墨线贴纸(方案 A:柑橘加大号)。
enum ZTheme { cream, citrus, sticker }

extension ZThemeLabel on ZTheme {
  String get label => switch (this) {
        ZTheme.cream => '原版奶油',
        ZTheme.citrus => '柑橘晨光',
        ZTheme.sticker => '墨线贴纸',
      };
}

/// 一套主题的全部设计 token。换主题 = 换一个 const 调色板,
/// UI 代码零改动(全部经 [ZT] 委托读取,详见文件尾说明)。
class ZPalette {
  final Color bg; // 页面底
  final Color surface; // 卡片
  final Color surfaceHi; // 高亮面板
  final Color ink; // 主文字
  final Color inkSoft; // 次级文字
  final Color inkFaint; // 暗文字
  final Color line; // 发丝线
  final Color edge; // 默认描边
  final Color primary; // 主色
  final Color primaryDeep; // 深主色(浅底上可读)
  final Color aqua; // 青(工具/信息/完成)
  final Color lemon; // 黄(等待/警示)
  final Color rose; // 红(错误)
  final Color grape; // 紫(思考)
  final Color onInk; // 主色/墨色填充上的文字
  final double radius; // 全局圆角
  final bool neoShadow; // true = 墨线硬阴影(blur 0, neo-brutalist);false = 柔影
  final double borderWidth; // 默认描边宽度(citrus 墨线更粗更"硬")
  final double cardBorderWidth; // 会话卡等列表卡描边(cream 无框软卡 / citrus 墨线)
  final Color? bgDot; // 页面底的圆点纹理色;null = 纯平底色(cream/citrus)
  final double bgDotStep; // 圆点纹理的网格步长(逻辑像素)

  const ZPalette({
    required this.bg,
    required this.surface,
    required this.surfaceHi,
    required this.ink,
    required this.inkSoft,
    required this.inkFaint,
    required this.line,
    required this.edge,
    required this.primary,
    required this.primaryDeep,
    required this.aqua,
    required this.lemon,
    required this.rose,
    required this.grape,
    required this.onInk,
    required this.radius,
    required this.neoShadow,
    required this.borderWidth,
    required this.cardBorderWidth,
    this.bgDot,
    this.bgDotStep = 16,
  });
}

/// 原版:明快奶油 Framer 风 — 奶油底 + 焦糖橙主色 + 暖棕文字,干净无辉光。
const ZPalette kZCream = ZPalette(
  bg: Color(0xFFFAF6EF),
  surface: Color(0xFFFFFFFF),
  surfaceHi: Color(0xFFFFF8F0),
  ink: Color(0xFF2B2118),
  inkSoft: Color(0xFF8A8275),
  inkFaint: Color(0xFFB9B1A4),
  line: Color(0xFFEDE5D8),
  edge: Color(0xFFE2D7C6),
  primary: Color(0xFFE8590C),
  primaryDeep: Color(0xFFC74405),
  aqua: Color(0xFF4C8A7E),
  lemon: Color(0xFFE9A13B),
  rose: Color(0xFFD65745),
  grape: Color(0xFF9B6FC9),
  onInk: Color(0xFFFFFFFF),
  radius: 12,
  neoShadow: false,
  borderWidth: 1.3,
  cardBorderWidth: 0,
);

/// 柑橘晨光 Citrus Morning v0.1.0(移植 zremote):奶油底 + 蜜橘主色 +
/// 墨线硬阴影 neo-brutalist;edge 直接取墨色 — 所有描边都是墨线粗框,
/// 状态色语义 running=橘 / done=青 / error=玫红 / queued=柠黄 / thinking=葡萄紫,
/// 色值与 zremote theme.dart 完全一致。
const ZPalette kZCitrus = ZPalette(
  bg: Color(0xFFFFF6E9),
  surface: Color(0xFFFFFCF5),
  surfaceHi: Color(0xFFFFF3DE),
  ink: Color(0xFF241C15),
  inkSoft: Color(0xFF5C5044),
  inkFaint: Color(0xFF7A6853),
  line: Color(0xFFE8DCC8),
  edge: Color(0xFF241C15),
  primary: Color(0xFFFF6B1A),
  primaryDeep: Color(0xFFE05500),
  aqua: Color(0xFF0FB5A3),
  lemon: Color(0xFFFFC93C),
  rose: Color(0xFFE5484D),
  grape: Color(0xFF7C5CFF),
  onInk: Color(0xFFFFF6E9),
  radius: 14,
  neoShadow: true,
  borderWidth: 1.6,
  cardBorderWidth: 1.6,
);

/// 墨线贴纸 Sticker(方案 A,见 docs/ui-mockups/style-A-neo-sticker.html):
/// 柑橘系的"加大号"——底色更深、圆点纹理,墨线 2px 更粗、圆角 16 更圆,
/// 色块当贴纸用。色值取自原型 style-A 的 CSS;状态色语义与 citrus 同源
/// (running=橘 / done=青 / error=玫红 / queued=柠黄 / thinking=葡萄紫),
/// 因此所有 `neoShadow` 分流点会自动走 neo-brutalist 分支,与 citrus 同骨架。
const ZPalette kZSticker = ZPalette(
  bg: Color(0xFFFFE9CC), // 原型 body 底色(比 citrus 更深一档)
  surface: Color(0xFFFFFCF5), // 同 citrus:卡片保持亮面
  surfaceHi: Color(0xFFFFF3DE), // 同 citrus:高亮面板
  ink: Color(0xFF241C15), // 同 citrus:墨色
  inkSoft: Color(0xFF5C5044),
  inkFaint: Color(0xFF7A6853),
  line: Color(0xFFE8DCC8),
  edge: Color(0xFF241C15), // 描边 = 墨线(贴纸感的关键)
  primary: Color(0xFFFF6B1A),
  primaryDeep: Color(0xFFE05500),
  aqua: Color(0xFF0FB5A3),
  lemon: Color(0xFFFFC93C),
  rose: Color(0xFFE5484D),
  grape: Color(0xFF7C5CFF),
  onInk: Color(0xFFFFF6E9),
  radius: 16, // 原型 .bub 圆角 16
  neoShadow: true,
  borderWidth: 2.0, // 原型 2px 墨线
  cardBorderWidth: 2.0,
  bgDot: Color(0xFFE8B98A), // 原型 radial-gradient 点色
  bgDotStep: 16, // 原型 background-size:16px 16px
);

/// 主题切换开关:改 [ZT] 全局调色板 + 持久化。
/// notifier 挂在 MaterialApp 外层,切换时整树重建(所有色值都是 build 时读取)。
class ZThemeController {
  ZThemeController._();

  static final ValueNotifier<ZTheme> notifier = ValueNotifier<ZTheme>(ZTheme.cream);
  static const _kTheme = 'zcode.theme';

  /// 启动时读回持久化主题;存档损坏/未知名回退 cream。
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final t = ZTheme.values.asNameMap()[p.getString(_kTheme)] ?? ZTheme.cream;
    use(t);
    notifier.value = t;
  }

  static Future<void> set(ZTheme t) async {
    use(t);
    notifier.value = t;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTheme, t.name);
  }

  static void use(ZTheme t) => ZT._palette = paletteOf(t);

  /// 主题 → 调色板。UI 侧(如设置里的主题缩略色卡)请一律走这里,
  /// 别再自己写 switch —— 新增主题时只改这一处。
  static ZPalette paletteOf(ZTheme t) => switch (t) {
        ZTheme.cream => kZCream,
        ZTheme.citrus => kZCitrus,
        ZTheme.sticker => kZSticker,
      };
}

/// 主题 token 门面:全部委托给当前 [ZPalette]。
/// 历史上是 static const(明快奶油单主题),为支持双主题改成 getter——
/// 调用点写法不变,但 const 上下文里引用 ZT.* 的地方要摘掉 const。
abstract final class ZT {
  static ZPalette _palette = kZCream;
  static ZPalette get palette => _palette;

  // ---- palette -----------------------------------------------------------
  static Color get bg => _palette.bg; // 页面底
  static Color get surface => _palette.surface; // 卡片
  static Color get surfaceHi => _palette.surfaceHi; // 高亮面板
  static Color get ink => _palette.ink; // 主文字
  static Color get inkSoft => _palette.inkSoft; // 次级文字
  static Color get inkFaint => _palette.inkFaint; // 暗文字
  static Color get line => _palette.line; // 发丝线
  static Color get edge => _palette.edge; // 默认描边(浅暖)

  static Color get primary => _palette.primary; // 主色
  static Color get primaryDeep => _palette.primaryDeep; // 深主色(浅底上可读)
  static Color get aqua => _palette.aqua; // 青(工具/信息)
  static Color get lemon => _palette.lemon; // 黄(等待/警示)
  static Color get rose => _palette.rose; // 红(错误)
  static Color get grape => _palette.grape; // 紫(思考)
  static Color get onInk => _palette.onInk; // 主色填充上的文字

  static double get radius => _palette.radius; // 全局圆角
  static double get borderWidth => _palette.borderWidth; // 默认描边宽度
  static double get cardBorderWidth => _palette.cardBorderWidth; // 列表卡描边(cream 无框)

  static const String mono = 'monospace'; // 代码块保留等宽
  static const String sans = 'Roboto'; // 主 UI 干净无衬线

  // ---- shadows / borders -------------------------------------------------

  /// cream:柔和暖阴影(低透明双层柔影,符合浅色界面);
  /// citrus:neo-brutalist 纯墨不透明硬阴影(blur 0,与 zremote 一致),dx/dy 保留签名。
  static List<BoxShadow> hard({double dx = 2.5, double dy = 2.5, Color? color}) {
    if (_palette.neoShadow) {
      final c = color ?? _palette.ink; // zremote 签名:纯墨,不带透明度
      return [BoxShadow(color: c, offset: Offset(dx, dy), blurRadius: 0)];
    }
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
      colorScheme: ColorScheme.light(
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
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
        ),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: inkFaint, fontSize: 13, fontFamily: sans),
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
          // citrus=zremote:聚焦墨绿深主色粗框;cream=主色细框
          borderSide: _palette.neoShadow
              ? BorderSide(width: 2.2, color: primaryDeep)
              : BorderSide(width: 1.6, color: primary),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      snackBarTheme: SnackBarThemeData(
        // citrus=zremote:墨底白字;cream:白底墨字
        backgroundColor: _palette.neoShadow ? ZT.ink : surface,
        contentTextStyle: _palette.neoShadow
            ? TextStyle(color: ZT.onInk, fontSize: 13)
            : sansStyle.copyWith(fontSize: 12.5),
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
      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.all(12),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
      // citrus=zremote:InkRipple 经典涟漪;cream:InkSparkle 细闪
      splashFactory:
          _palette.neoShadow ? InkRipple.splashFactory : InkSparkle.splashFactory,
    );
  }
}

/// 页面底纹理:调色板带 [ZPalette.bgDot] 时铺圆点纹(sticker),否则透明直通。
/// 只在 AppShell 的 body 外层包一次 —— 不要每个页面各包一次(会重复叠加)。
class ZDotBg extends StatelessWidget {
  final Widget child;
  const ZDotBg({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dot = ZT.palette.bgDot;
    if (dot == null) return child;
    // RepaintBoundary:圆点网格每次 paint 全量画数千个圆,隔离后只在自身
    // 脏了(主题切换/尺寸变化)才重画,内容滚动/流式更新不再连带重绘底纹
    return RepaintBoundary(
      child: CustomPaint(
        painter: _DotPainter(color: dot, step: ZT.palette.bgDotStep),
        child: child,
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  final Color color;
  final double step;
  _DotPainter({required this.color, required this.step});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const r = 0.55; // 对应原型 1.1px 直径
    for (double y = step / 2; y < size.height; y += step) {
      for (double x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotPainter old) => old.color != color || old.step != step;
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
  final double? borderWidth;

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
    this.borderWidth, // null = 用主题默认(cream 1.3 / citrus 1.6)
  });

  @override
  Widget build(BuildContext context) {
    final glow = (shadowDx != 0 || shadowDy != 0)
        ? ZT.hard(dx: shadowDx, dy: shadowDy)
        // citrus=zremote:卡片默认 dx3dy3 纯墨硬影;cream:默认无影
        : (ZT.palette.neoShadow ? ZT.hard(dx: 3, dy: 3) : null);
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: color ?? ZT.surface,
          shadows: glow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: ZT.inkSide(w: borderWidth ?? ZT.borderWidth, color: borderColor),
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
    final citrus = ZT.palette.neoShadow;
    final (Color color, String label) = switch (p) {
      'running' || 'working' || 'processing' => (ZT.primary, '运行中'),
      'prewarming' => (ZT.lemon, '预热中'),
      'queued' => (ZT.lemon, '排队中'),
      'waitinginput' => (ZT.grape, '等待输入'),
      'waiting' || 'permission' => (ZT.lemon, '待确认'),
      'reconnecting' => (ZT.rose, '断线'),
      'error' || 'failed' => (ZT.rose, '异常'),
      'done' || 'idle' || '' => (ZT.inkSoft, '空闲'),
      _ => (ZT.aqua, phase),
    };
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 7 : 9, vertical: compact ? (citrus ? 2.0 : 2.5) : (citrus ? 3.5 : 4)),
      decoration: ShapeDecoration(
        // citrus=zremote:白底药丸 + 彩色墨线;cream:彩底圆角矩形
        color: citrus ? ZT.surface : color.withValues(alpha: 0.12),
        shape: citrus
            ? StadiumBorder(side: ZT.inkSide(w: 1.2, color: color))
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(width: 1, color: color.withValues(alpha: 0.7)),
              ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        PulseDot(color: color, animate: p == 'running' || p == 'waiting' || p == 'permission', size: citrus ? (compact ? 6 : 7) : 5),
        SizedBox(width: citrus ? 5 : 4),
        Text(label,
            style: TextStyle(
                fontSize: citrus ? (compact ? 10.5 : 11.5) : (compact ? 10 : 11),
                fontWeight: FontWeight.w700,
                color: color,
                height: citrus ? 1 : null,
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
    // citrus(zremote 呼吸)=白色高光层 0..1 渐隐渐显,圆点本体不动;
    // cream=整点 0.35..1 淡入淡出。控制器区间按主题分流。
    final citrus = ZT.palette.neoShadow;
    _c = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
        lowerBound: citrus ? 0 : 0.35,
        upperBound: 1);
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
    final citrus = ZT.palette.neoShadow;
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        // citrus=zremote:圆点带墨圈,呼吸靠白色高光层
        border: citrus ? Border.all(width: 1, color: ZT.ink.withValues(alpha: 0.55)) : null,
      ),
      child: (!widget.animate || !citrus)
          ? null
          : FadeTransition(
              opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
              child: const DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white),
              ),
            ),
    );
    return citrus ? dot : FadeTransition(opacity: _c, child: dot);
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
    final citrus = ZT.palette.neoShadow;
    final sink = citrus ? 2.5 : 2.0; // citrus=zremote 下沉量
    final button = _PressSink(
      pressed: enabled,
      onTap: onPressed,
      builder: (pressed) => Container(
        height: 44,
        padding: EdgeInsets.symmetric(horizontal: citrus ? 18 : 16),
        transform: Matrix4.translationValues(
            enabled && pressed ? sink : 0, enabled && pressed ? sink : 0, 0),
        decoration: ShapeDecoration(
          color: enabled ? fill : ZT.line,
          shadows: enabled
              ? (citrus
                  ? ZT.hard(dx: 2.5, dy: 2.5) // 纯墨硬影
                  : ZT.hard(dx: 2.5, dy: 2.5, color: fill.withValues(alpha: 0.5)))
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: citrus
                // citrus=zremote:墨线描边,禁用态转淡
                ? BorderSide(width: 1.8, color: enabled ? ZT.ink : ZT.inkFaint)
                : BorderSide(width: 1.4, color: enabled ? fill : ZT.edge),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          if (icon != null) ...[
            Icon(icon, size: 17, color: enabled ? fg : ZT.inkFaint),
            const SizedBox(width: 7),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: citrus ? 14.5 : 13.5,
                  fontWeight: citrus ? FontWeight.w800 : FontWeight.w700,
                  letterSpacing: citrus ? 0.2 : null,
                  color: enabled ? fg : ZT.inkFaint,
                  fontFamily: ZT.sans)),
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

/// 主题化对话框工厂:统一面板底色、accent 描边、金调标题行。
/// 所有确认/输入类弹窗走这里,别再用裸 AlertDialog(没有主题特征)。
AlertDialog zDialog({
  required String title,
  IconData icon = Icons.tune_rounded,
  Color? accent,
  required Widget content,
  List<Widget> actions = const [],
}) {
  final acc = accent ?? ZT.primary;
  return AlertDialog(
    backgroundColor: ZT.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(ZT.radius),
      side: ZT.inkSide(w: 1.4, color: acc.withValues(alpha: 0.55)),
    ),
    titlePadding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
    contentPadding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
    actionsPadding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
    title: Row(children: [
      Icon(icon, size: 18, color: acc),
      const SizedBox(width: 8),
      Expanded(
        child: Text(title,
            style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w900,
                color: acc.withValues(alpha: 0.92))),
      ),
    ]),
    content: content,
    actions: actions,
  );
}

/// 对话框统一按钮:primary 走焦糖实心,否则描边幽灵款。
Widget dialogAction(String label, {required VoidCallback? onPressed, bool primary = false, Color? color}) {
  if (primary) {
    return BigButton(label: label, onPressed: onPressed, color: color ?? ZT.primary);
  }
  return OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      side: ZT.inkSide(),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ZT.radius)),
      foregroundColor: ZT.inkSoft,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    ),
    child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
  );
}

/// 底部弹层顶部把手 + 金色顶线,包一层即有"自家弹层"的样子。
Widget sheetHandle() {
  return Column(children: [
    Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      decoration: BoxDecoration(color: ZT.edge, borderRadius: BorderRadius.circular(99)),
    ),
    Divider(height: 1, thickness: 1.2, color: ZT.primary.withValues(alpha: 0.2)),
  ]);
}
