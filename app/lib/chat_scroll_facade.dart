// 滚动层外观类(标准工程方案 §4):贴底检测、视口补偿、回到底部。
// 只服务 reverse 聊天列表(offset 0 = 视觉底部)。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// 贴底判定阈值(reverse 列表 offset <= 此值视为贴底)
const double kAtBottomThreshold = 80.0;

/// 视口补偿+贴底+回到底部的统一外观。页面只持有这一个对象。
class ChatScrollFacade {
  ChatScrollFacade({required this.controller});

  final ScrollController controller;

  /// 贴底状态变化时通知(驱动「回到底部」按钮显隐)
  final ValueNotifier<bool> atBottom = ValueNotifier<bool>(true);

  /// 上一次流式行高度(测高差值的基准);null = 无基准,只记录不补偿
  double? _lastStreamingHeight;

  /// 用户拖动中(补偿跳过,防 jumpTo 杀手势)
  bool userDragging = false;


  /// 接入列表的滚动通知(由页面的 NotificationListener 转发滚动通知进来)
  bool handleNotification(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical || !controller.hasClients) return false;
    final away = controller.offset > kAtBottomThreshold;
    if (away != atBottom.value) atBottom.value = away;
    // 回贴底瞬间:重置测高基准,防旧基准造成一次跳变(标准 §4.3)
    if (!away) _lastStreamingHeight = null;
    return false;
  }

  /// 每次流式 flush 渲染完成后调用(postFrameCallback 里)。
  /// [streamKey] 为流式行的 GlobalKey;行不在缓存内时跳过(对视口无真实影响)。
  void compensateAfterFrame(GlobalKey streamKey) {
    if (!controller.hasClients) return;
    final ctx = streamKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      _lastStreamingHeight = null; // 无基准:重入树那帧只重记不补偿
      return;
    }
    final h = box.size.height;
    final prev = _lastStreamingHeight;
    _lastStreamingHeight = h;
    if (prev == null) return;
    final delta = h - prev;
    if (delta <= 0 || atBottom.value) return;
    final pos = controller.position;
    // 用户拖动中禁止 jumpTo——jumpTo 会 goIdle 杀掉进行中的手势
    if (pos.userScrollDirection != ScrollDirection.idle) return;
    controller.jumpTo(math.min(pos.pixels + delta, pos.maxScrollExtent));
  }

  /// 回到底部(220ms easeOutCubic,标准 §4.4)
  void toBottom() {
    if (!controller.hasClients) return;
    controller.animateTo(0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic);
  }
}

/// 用法辅助:把 facade 挂到 NotificationListener。
bool handleScrollNotifications(ChatScrollFacade f, ScrollNotification n) {
  if (n is ScrollEndNotification) f.userDragging = false;
  return false;
}
