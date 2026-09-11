// 底部导航壳:会话 / 项目 / 我的(参考稿三 tab)。
// 项目 tab 点某个项目 → 切到会话 tab 并按该项目过滤(SessionsPage 以 Key 重挂载带初始过滤)。
import 'package:flutter/material.dart';

import '../state/zapp.dart';
import '../theme.dart';
import 'sessions_page.dart';

class AppShell extends StatefulWidget {
  final ZApp app;
  final VoidCallback onLogout;

  const AppShell({super.key, required this.app, required this.onLogout});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  String? _projectFilter; // 项目 tab 选中的项目

  ZApp get app => widget.app;

  @override
  Widget build(BuildContext context) {
    final projects = <String, int>{};
    for (final s in app.sessions) {
      final arch = s['archived'];
      if (arch == 1 || arch == true) continue;
      final p = '${s['project'] ?? ''}';
      if (p.isNotEmpty) projects[p] = (projects[p] ?? 0) + 1;
    }
    final projectNames = projects.keys.toList()..sort();

    return Scaffold(
      backgroundColor: ZT.bg,
      body: ZDotBg(
        child: IndexedStack(index: _tab, children: [
          SessionsPage(
            key: ValueKey('sess-$_projectFilter'),
            app: app,
            onLogout: widget.onLogout,
            initialProject: _projectFilter,
          ),
          _projectsTab(projectNames, projects),
          _mineTab(),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: ZT.surface,
        indicatorColor: ZT.primary.withValues(alpha: 0.14),
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded, size: 21),
            selectedIcon: Icon(Icons.chat_bubble_rounded, size: 21, color: ZT.primary),
            label: '会话',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined, size: 21),
            selectedIcon: Icon(Icons.folder_rounded, size: 21, color: ZT.primary),
            label: '项目',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded, size: 21),
            selectedIcon: Icon(Icons.person_rounded, size: 21, color: ZT.primary),
            label: '我的',
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 项目 tab

  Widget _projectsTab(List<String> projectNames, Map<String, int> counts) {
    final uncategorized = app.sessions
        .where((s) {
          final arch = s['archived'];
          return !(arch == 1 || arch == true) && '${s['project'] ?? ''}'.isEmpty;
        })
        .length;
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: AppBar(
        title: const Text('项目', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
      ),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        for (final p in projectNames)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: HardCard(
              onTap: () => setState(() {
                _projectFilter = p;
                _tab = 0;
              }),
              child: Row(children: [
                Icon(Icons.folder_rounded, size: 20, color: ZT.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(p, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700))),
                Text('${counts[p]} 个会话', style: TextStyle(fontSize: 12, color: ZT.inkFaint)),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, size: 18, color: ZT.inkFaint),
              ]),
            ),
          ),
        if (uncategorized > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: HardCard(
              onTap: () => setState(() {
                _projectFilter = null;
                _tab = 0;
              }),
              child: Row(children: [
                Icon(Icons.folder_off_rounded, size: 20, color: ZT.inkFaint),
                const SizedBox(width: 10),
                const Expanded(child: Text('未分类', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700))),
                Text('$uncategorized 个会话', style: TextStyle(fontSize: 12, color: ZT.inkFaint)),
              ]),
            ),
          ),
        if (projectNames.isEmpty && uncategorized == 0)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Text('还没有可分组的项目', style: TextStyle(fontSize: 13, color: ZT.inkFaint)),
            ),
          ),
      ]),
    );
  }

  // ---------------------------------------------------------------- 我的 tab

  Widget _mineTab() {
    final link = app.linked ? '已连接' : (app.linkFailure ?? '连接中…');
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: AppBar(
        title: const Text('我的', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
      ),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        HardCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.terminal_rounded, size: 18, color: ZT.primary),
              SizedBox(width: 8),
              Text('连接', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 10),
            _row('状态', link),
            _row('会话数', '${app.sessions.length}'),
            _row('模型数', '${app.models.length}'),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: BigButton(
            label: '切换服务器(登出)',
            icon: Icons.swap_horiz_rounded,
            color: ZT.rose,
            textColor: Colors.white,
            onPressed: widget.onLogout,
          ),
        ),
      ]),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
        const Spacer(),
        Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZT.ink)),
      ]),
    );
  }
}
