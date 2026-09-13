// 聊天列表滚动锚定:纯函数层(对齐 zremote lib/ui/composer_logic.dart L362-501)。
// 不依赖 Flutter,可直接单测。设计文档:D:\tools\zremote-new\docs\SCROLL-STABILITY-RESEARCH.md
//
// 核心思想:滚动锚定的单位是「哪条消息 + 它在视口哪里」,不是裸像素偏移/总高增量。
// 总高增量方案的方向性缺陷:历史端内容长高(图片解码/markdown 重排)时,屏幕内容
// 纹丝没动、总高却多了 G,按增量补会把用户往历史端推整个 G —— 「飘来飘去」的根因。

/// 单阈值在流式期间会反复翻转——maxScrollExtent 一直在变,
/// 用户停在临界带附近时判定会横跳,每次翻转都重建整页。
class AnchorThresholds {
  /// 进入「在底部」的门槛:距最新端 ≤ 此值才算到位。
  static const double enterPx = 100;

  /// 离开「在底部」的门槛:超过它才认为用户滑走了。
  static const double exitPx = 180;

  /// [atBottomGap] = 距最新端的像素距离;[wasAtBottom] = 上一状态。
  /// 未完成首帧布局(gap 无法计算时传 null)恒视为在底部。
  static bool resolve({required double? atBottomGap, required bool wasAtBottom}) {
    if (atBottomGap == null) return wasAtBottom;
    return wasAtBottom ? atBottomGap <= exitPx : atBottomGap <= enterPx;
  }
}

/// 视口顶(最旧端)可见历史行的采样:行身份 + 视口内位置。
/// 对应 Telegram `scrollToMessageObject`、tdesktop `ScrollTopState{item, shift}`、
/// 浏览器 scroll anchoring 的 anchor node。
/// [rowKey] 用行对象本身 Dart `identical` 判身份(reducer 复制改语义下,
/// 未变的行跨帧保持同一引用,天然稳定);null = 顶部不是历史行,不可锚。
class AnchorSample {
  final Object? rowKey;
  final double topY;

  const AnchorSample(this.rowKey, this.topY);
}

/// 锚行补偿的纯计算:两次采样定一次补偿量。
///
/// 方向推导(y 向下为正):
/// - 新端内容长高 → 锚行被往上推(topY 变小)→ delta 正 → 往历史端滚,钉回原位;
/// - 历史端内容长高 → 锚行被往下推(topY 变大)→ delta 负 → 往回钉;
/// - 锚行自身长高(顶边不动)→ 0,不补;
/// - 锚行身份变了(翻页/resync/滑出视口)→ null:重定基线,一分不补。
abstract final class ViewportAnchor {
  static double? compensate({required AnchorSample? prev, required AnchorSample next}) {
    if (prev == null || prev.rowKey == null || !identical(prev.rowKey, next.rowKey)) {
      return null;
    }
    return prev.topY - next.topY;
  }
}

/// 锚定补偿的纯计算:阈值过滤 + 单步上限 + 时长缩放。
/// 这些数字是「闪不闪」的关键:流式每 tick 长十几像素是常态,阈值太小会让
/// 每帧一次位移合成肉眼可见的闪;欠账一次跳完是弹跳,分步走完是追上去。
abstract final class AnchorMath {
  static const double minStepPx = 1.5;
  static const double maxStepPx = 600;
  static const int minDurationMs = 60;
  static const int maxDurationMs = 110;

  /// 返回 (delta, durationMs, leftover):|delta| 超上限截断,剩余留给下一帧。
  static ({double delta, int durationMs, double leftover}) plan(double deltaAbs) {
    if (deltaAbs < minStepPx) {
      return (delta: 0, durationMs: 0, leftover: 0);
    }
    final capped = deltaAbs > maxStepPx ? maxStepPx : deltaAbs;
    final leftover = deltaAbs - capped;
    final ms = (minDurationMs + capped * 0.15)
        .clamp(minDurationMs.toDouble(), maxDurationMs.toDouble())
        .round();
    return (delta: capped, durationMs: ms, leftover: leftover < minStepPx ? 0 : leftover);
  }
}

/// 「用户正在看历史」的跟随锁存。
///
/// 为什么需要状态锁而不是每次用位置判定:内容每 tick 长高,用户看的那个
/// 位置对应的距离每帧都在变;只要他停得离底部近一点,新行一到就被拽走。
/// 语义:用户**主动**滚离底部 → 锁定;直到**主动**滚回最新端附近(releasePx
/// 死区,比 enterPx 更严,避免 100~40 带内反复解锁)才解锁。
class FollowLock {
  static const double releasePx = 40;

  /// [atBottomGap] 距最新端距离;[locked] 当前锁存态;[maxScrollExtent] ≤0(未布局)恒不锁。
  static bool shouldLock({required double? atBottomGap, required bool locked, required double maxScrollExtent}) {
    if (locked) return false;
    if (atBottomGap == null || maxScrollExtent <= 0) return false;
    return atBottomGap > AnchorThresholds.exitPx;
  }

  static bool shouldRelease({required double? atBottomGap, required double maxScrollExtent}) {
    if (maxScrollExtent <= 0) return true;
    if (atBottomGap == null) return true;
    return atBottomGap <= releasePx;
  }
}
