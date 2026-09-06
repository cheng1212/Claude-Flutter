import 'package:flutter/material.dart';

import '../panel_utils.dart';
import '../state/reducer.dart';
import '../theme.dart';
// ---------------------------------------------------------------- 面板弹层

/// 子代理面板:Task/Agent 发起的子代理 + 各自活动数。
class SubagentsSheet extends StatelessWidget {
  final List<ToolRow> rows;

  const SubagentsSheet({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final subs = deriveSubagents(rows);
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sheetHandle(),
            const SizedBox(height: 10),
            const Row(
              children: [
                Icon(Icons.hub_rounded, size: 18, color: ZT.grape),
                SizedBox(width: 8),
                Text(
                  '子代理',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(
              child: subs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        '还没有子代理。对话里让它"派一个子代理去查 X"就会出现。',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: ZT.inkFaint,
                          height: 1.6,
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: subs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final sub = subs[i];
                        final leading = sub.done
                            ? const Icon(
                                Icons.check_circle_rounded,
                                size: 16,
                                color: ZT.aqua,
                              )
                            : const SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: ZT.grape,
                                ),
                              );
                        final card = Container(
                          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                          decoration: ShapeDecoration(
                            color: ZT.bg,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(ZT.radius),
                              side: ZT.inkSide(
                                w: 1.2,
                                color: ZT.grape.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              leading,
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  sub.description,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${sub.activityCount} 次活动',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: ZT.inkFaint,
                                ),
                              ),
                            ],
                          ),
                        );
                        return card;
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 后台任务面板:Bash(run_in_background)命令 + 状态 + 输出尾部。
class BackgroundsSheet extends StatelessWidget {
  final List<ToolRow> rows;

  const BackgroundsSheet({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final bgs = deriveBackgrounds(rows);
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sheetHandle(),
            const SizedBox(height: 10),
            const Row(
              children: [
                Icon(Icons.memory_rounded, size: 18, color: ZT.aqua),
                SizedBox(width: 8),
                Text(
                  '后台任务',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(
              child: bgs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        '没有后台任务。对话里让它"后台跑 flutter build"就会出现。',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: ZT.inkFaint,
                          height: 1.6,
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: bgs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final b = bgs[i];
                        final statusColor = b.running ? ZT.aqua : ZT.inkFaint;
                        final card = Container(
                          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                          decoration: ShapeDecoration(
                            color: ZT.bg,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(ZT.radius),
                              side: ZT.inkSide(
                                w: 1.2,
                                color: statusColor.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    b.running
                                        ? Icons.circle_rounded
                                        : Icons.check_circle_rounded,
                                    size: 11,
                                    color: statusColor,
                                  ),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Text(
                                      b.command,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        fontFamily: ZT.mono,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    b.running ? '运行中' : '已结束',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: statusColor,
                                    ),
                                  ),
                                ],
                              ),
                              if (b.outputTail.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 110,
                                    ),
                                    child: SingleChildScrollView(
                                      child: SelectableText(
                                        b.outputTail,
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontFamily: ZT.mono,
                                          color: ZT.inkFaint,
                                          height: 1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                        return card;
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
