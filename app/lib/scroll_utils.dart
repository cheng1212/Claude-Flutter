// 流式输出滚动补偿纯逻辑:与 Flutter 解耦,可单测。
// 背景:聊天列表是 reverse ListView(锚点钉在底部边缘),流式区(index 0)每长高 δ,
// 其上历史内容整体上移 δ 而视口不动 → 用户视野相对内容下滑,表现为「被往下拉」。
// 补偿 = 用户不在底部时,把滚动位置加上同样的 δ,锁住视觉位置。

/// 流式区渲染高度从 [prevH] 变为 [currH](可负=收起)时,应跳到的目标 offset。
/// [offset] 为当前滚动位置(reverse 列表:距底部锚点的距离,0=底部);
/// [atBottomPx] 为「视为在底部」的容差:60px,约三行正文——既容忍布局微抖和
/// 轻微滚动,也保证用户稍一上滑即脱离跟随(与「回到底部」药丸同一阈值)。
/// 返回 null = 不动(在底部跟随最新 / 高度无变化)。
double? compensateStreamScroll({
  required double prevH,
  required double currH,
  required double offset,
  double atBottomPx = 60,
}) {
  final delta = currH - prevH;
  if (delta == 0) return null;
  if (offset <= atBottomPx) return null;
  final target = offset + delta;
  if (target < 0) return 0;
  return target;
}
