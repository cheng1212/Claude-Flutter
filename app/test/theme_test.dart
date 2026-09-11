import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zcode_app/theme.dart';

void main() {
  tearDown(() {
    // ZT 调色板是全局静态,每个用例结束回退默认,避免串扰。
    ZThemeController.use(ZTheme.cream);
    ZThemeController.notifier.value = ZTheme.cream;
  });

  group('柑橘晨光调色板(zremote 移植)', () {
    test('核心色值与 zremote theme.dart 完全一致', () {
      expect(kZCitrus.bg, const Color(0xFFFFF6E9)); // 奶油底
      expect(kZCitrus.surface, const Color(0xFFFFFCF5)); // 卡片
      expect(kZCitrus.ink, const Color(0xFF241C15)); // 墨色
      expect(kZCitrus.primary, const Color(0xFFFF6B1A)); // 蜜橘主色
      expect(kZCitrus.primaryDeep, const Color(0xFFE05500)); // 深橘
      expect(kZCitrus.aqua, const Color(0xFF0FB5A3)); // 青(done)
      expect(kZCitrus.lemon, const Color(0xFFFFC93C)); // 柠檬黄(queued)
      expect(kZCitrus.rose, const Color(0xFFE5484D)); // 玫红(error)
      expect(kZCitrus.grape, const Color(0xFF7C5CFF)); // 葡萄紫(thinking)
      expect(kZCitrus.onInk, const Color(0xFFFFF6E9)); // 墨底上的奶油字
      expect(kZCitrus.radius, 14);
      expect(kZCitrus.neoShadow, isTrue); // neo-brutalist 硬阴影
      expect(kZCitrus.edge, kZCitrus.ink); // 描边 = 墨线(zremote 骨架的关键)
      expect(kZCitrus.borderWidth, 1.6); // 墨线更粗
    });

    test('原版奶油调色板保持原值不变', () {
      expect(kZCream.bg, const Color(0xFFFAF6EF));
      expect(kZCream.primary, const Color(0xFFE8590C));
      expect(kZCream.primaryDeep, const Color(0xFFC74405));
      expect(kZCream.radius, 12);
      expect(kZCream.neoShadow, isFalse);
      expect(kZCream.borderWidth, 1.3);
    });
  });

  group('墨线贴纸调色板(方案 A)', () {
    test('色值与 docs/ui-mockups/style-A-neo-sticker.html 一致', () {
      expect(kZSticker.bg, const Color(0xFFFFE9CC)); // 原型 body 底色
      expect(kZSticker.ink, const Color(0xFF241C15));
      expect(kZSticker.primary, const Color(0xFFFF6B1A));
      expect(kZSticker.aqua, const Color(0xFF0FB5A3));
      expect(kZSticker.lemon, const Color(0xFFFFC93C));
      expect(kZSticker.rose, const Color(0xFFE5484D));
      expect(kZSticker.grape, const Color(0xFF7C5CFF));
      expect(kZSticker.radius, 16); // 原型 .bub 圆角 16
      expect(kZSticker.borderWidth, 2.0); // 原型 2px 墨线
      expect(kZSticker.neoShadow, isTrue); // 与 citrus 同属 neo-brutalist
      expect(kZSticker.edge, kZSticker.ink); // 描边 = 墨线
    });

    test('是柑橘的"加大号":底色更深、墨线更粗、圆角更大', () {
      expect(kZSticker.bg, isNot(kZCitrus.bg));
      expect(kZSticker.borderWidth, greaterThan(kZCitrus.borderWidth));
      expect(kZSticker.radius, greaterThan(kZCitrus.radius));
      // 状态色语义与 citrus 同源,分流点才能共用
      expect(kZSticker.primary, kZCitrus.primary);
      expect(kZSticker.aqua, kZCitrus.aqua);
      expect(kZSticker.grape, kZCitrus.grape);
    });

    test('圆点纹理只在本主题开启;另两套保持纯平底色', () {
      expect(kZSticker.bgDot, const Color(0xFFE8B98A));
      expect(kZSticker.bgDotStep, 16);
      expect(kZCream.bgDot, isNull);
      expect(kZCitrus.bgDot, isNull);
    });
  });

  group('ZT 委托读取', () {
    test('use() 切换后所有 token 跟随当前调色板', () {
      ZThemeController.use(ZTheme.cream);
      expect(ZT.primary, kZCream.primary);
      expect(ZT.radius, 12);

      ZThemeController.use(ZTheme.citrus);
      expect(ZT.palette, same(kZCitrus));
      expect(ZT.primary, const Color(0xFFFF6B1A));
      expect(ZT.bg, const Color(0xFFFFF6E9));
      expect(ZT.radius, 14);

      ZThemeController.use(ZTheme.sticker);
      expect(ZT.palette, same(kZSticker));
      expect(ZT.bg, const Color(0xFFFFE9CC));
      expect(ZT.radius, 16);
      expect(ZT.cardBorderWidth, 2.0);
    });

    test('阴影风格随主题切换:cream 柔影 / citrus,sticker 墨线硬阴影(blur 0)', () {
      ZThemeController.use(ZTheme.cream);
      final soft = ZT.hard(dx: 2.5, dy: 2.5);
      expect(soft.length, 2);
      expect(soft.first.blurRadius, 16);

      for (final t in [ZTheme.citrus, ZTheme.sticker]) {
        ZThemeController.use(t);
        final hard = ZT.hard(dx: 3, dy: 3);
        expect(hard.length, 1, reason: '${t.name} 应是单层硬阴影');
        expect(hard.first.blurRadius, 0, reason: '${t.name} 硬阴影 blur 应为 0');
        expect(hard.first.offset, const Offset(3, 3));
        expect(hard.first.color, ZThemeController.paletteOf(t).ink,
            reason: '${t.name} 硬阴影 = 纯墨不透明');
      }
    });

    test('所有主题都产出亮色 ThemeData', () {
      for (final t in ZTheme.values) {
        ZThemeController.use(t);
        expect(ZT.theme().colorScheme.brightness, Brightness.light,
            reason: '${t.name} 也应是亮色主题');
      }
    });

    test('paletteOf() 覆盖全部主题,且 use() 与之同源', () {
      for (final t in ZTheme.values) {
        ZThemeController.use(t);
        expect(ZT.palette, same(ZThemeController.paletteOf(t)),
            reason: '${t.name}: use() 必须与 paletteOf() 指向同一 const 实例');
      }
    });
  });

  group('ZDotBg 圆点纹理', () {
    testWidgets('有 bgDot 的主题铺 CustomPaint;无 bgDot 的主题透明直通', (tester) async {
      const child = SizedBox(key: Key('child'), width: 10, height: 10);

      ZThemeController.use(ZTheme.sticker);
      await tester.pumpWidget(const ZDotBg(child: child));
      expect(find.byType(CustomPaint), findsWidgets, reason: 'sticker 应铺纹理');

      ZThemeController.use(ZTheme.cream);
      await tester.pumpWidget(const ZDotBg(child: child));
      expect(find.byKey(const Key('child')), findsOneWidget);
      // cream 下 ZDotBg 直接返回 child,不引入自己的 CustomPaint
      expect(find.ancestor(of: find.byKey(const Key('child')), matching: find.byType(ZDotBg)),
          findsOneWidget);
    });
  });

  group('ZThemeController 持久化', () {
    test('set() 即时生效并写盘', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await ZThemeController.set(ZTheme.citrus);
      expect(ZT.palette, same(kZCitrus));
      expect(ZThemeController.notifier.value, ZTheme.citrus);
      final p = await SharedPreferences.getInstance();
      expect(p.getString('zcode.theme'), 'citrus');
    });

    test('load() 读回存档;未知名/缺档回退 cream', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'zcode.theme': 'citrus'});
      await ZThemeController.load();
      expect(ZT.palette, same(kZCitrus));

      SharedPreferences.setMockInitialValues(<String, Object>{'zcode.theme': 'sticker'});
      await ZThemeController.load();
      expect(ZT.palette, same(kZSticker), reason: '新增主题也要能持久化读回');

      SharedPreferences.setMockInitialValues(<String, Object>{'zcode.theme': 'hacker-dark'});
      await ZThemeController.load();
      expect(ZT.palette, same(kZCream), reason: '未知名回退 cream,不崩');

      SharedPreferences.setMockInitialValues(<String, Object>{});
      await ZThemeController.load();
      expect(ZT.palette, same(kZCream));
    });
  });
}
