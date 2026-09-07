// 任务中心:子代理 / 后台任务 / 定时任务 三 Tab 弹窗,底部「任务」磁贴呼出。
import 'package:flutter/material.dart';

import '../state/reducer.dart';
import '../state/zapp.dart';
import '../theme.dart';
import 'chat_panels.dart';
import 'crons_sheet.dart';

class TasksSheet extends StatelessWidget {
  final ZApp app;
  final String sessionId;
  final List<ToolRow> rows;

  const TasksSheet({super.key, required this.app, required this.sessionId, required this.rows});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: SafeArea(
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.72),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            sheetHandle(),
            const SizedBox(height: 4),
            TabBar(
              indicatorColor: ZT.primary,
              labelColor: ZT.primary,
              unselectedLabelColor: ZT.inkSoft,
              labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
              tabs: const [
                Tab(height: 40, icon: Icon(Icons.hub_rounded, size: 17), text: '子代理'),
                Tab(height: 40, icon: Icon(Icons.memory_rounded, size: 17), text: '后台任务'),
                Tab(height: 40, icon: Icon(Icons.alarm_rounded, size: 17), text: '定时任务'),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: TabBarView(children: [
                SubagentsPanel(app: app, sessionId: sessionId, rows: rows),
                BackgroundsPanel(app: app, sessionId: sessionId),
                CronsPanel(app: app, sessionId: sessionId),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
