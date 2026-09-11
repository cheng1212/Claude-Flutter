import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/state/reducer.dart';

Map<String, dynamic> ev(String kind, {int? seq, Map<String, dynamic>? extra}) =>
    {'kind': kind, 'seq': ?seq, ...?extra};

void main() {
  test('stream_delta 累积到流缓冲,text 落定后清空流缓冲并成行', () {
    var s = const ChatState();
    s = applyEvent(s, ev('stream_delta', seq: 1, extra: {'content': '你好'}));
    s = applyEvent(s, ev('stream_delta', seq: 2, extra: {'content': '！'}));
    expect(s.streamingText, '你好！');
    expect(s.rows, isEmpty);
    s = applyEvent(s, ev('text', seq: 3, extra: {'role': 'assistant', 'content': '你好！'}));
    expect(s.streamingText, isNull);
    expect(s.rows.length, 1);
    expect((s.rows[0] as TextRow).content, '你好！');
  });

  test('thinking_delta 同理,thinking 落定成折叠行', () {
    var s = const ChatState();
    s = applyEvent(s, ev('thinking_delta', seq: 1, extra: {'content': '想'}));
    s = applyEvent(s, ev('thinking', seq: 2, extra: {'content': '想一下'}));
    expect(s.streamingThinking, isNull);
    expect((s.rows[0] as ThinkingRow).content, '想一下');
  });

  test('tool_use/tool_result 按 toolId 配对', () {
    var s = const ChatState();
    s = applyEvent(s, ev('tool_use', seq: 1, extra: {'toolId': 't1', 'toolName': 'Bash', 'toolInput': {'command': 'dir'}}));
    s = applyEvent(s, ev('tool_result', seq: 2, extra: {'toolId': 't1', 'content': 'a.txt', 'isError': false}));
    final tool = s.rows[0] as ToolRow;
    expect(tool.toolName, 'Bash');
    expect(tool.result, isNotNull);
    expect(tool.result!.content, 'a.txt');
    expect(tool.result!.isError, isFalse);
  });

  test('孤儿工具卡收尾:complete / subscribed(false) 落定为中断标记,运行中不动,迟到真结果可覆盖', () {
    // 构建被打断:complete 到了,tool_result 永远不会来 → 卡片必须落定,别永久转圈
    var s = const ChatState();
    s = applyEvent(s, ev('tool_use', seq: 1, extra: {'toolId': 't1', 'toolName': 'PowerShell', 'toolInput': {'command': 'flutter build apk'}}));
    expect((s.rows.single as ToolRow).result, isNull);
    s = applyEvent(s, ev('complete', seq: 2, extra: {'exitCode': 1, 'aborted': true}));
    final closed = s.rows.single as ToolRow;
    expect(closed.result?.content, kInterruptedToolMark);
    expect(closed.result?.isError, isTrue);
    expect(s.running, isFalse);

    // 服务重启后重连:subscribed(false) 也收尾悬空卡(上一世的孤儿)
    var r = const ChatState();
    r = applyEvent(r, ev('tool_use', seq: 1, extra: {'toolId': 't2', 'toolName': 'PowerShell', 'toolInput': const {}}));
    r = applyEvent(r, ev('subscribed', extra: {'sessionId': 'x', 'isProcessing': false, 'lastSeq': 5}));
    expect((r.rows.single as ToolRow).result?.content, kInterruptedToolMark);
    // 重放补发的迟到真结果覆盖中断标记(replay 在 subscribed 之后到)
    r = applyEvent(r, ev('tool_result', seq: 2, extra: {'toolId': 't2', 'content': 'Built apk (50.7MB)', 'isError': false}));
    final revived = r.rows.single as ToolRow;
    expect(revived.result?.content, 'Built apk (50.7MB)');
    expect(revived.result?.isError, isFalse);

    // 正在跑(重连到活跃 run):卡片不许动
    var a = const ChatState();
    a = applyEvent(a, ev('tool_use', seq: 1, extra: {'toolId': 't3', 'toolName': 'PowerShell', 'toolInput': const {}}));
    a = applyEvent(a, ev('subscribed', extra: {'sessionId': 'x', 'isProcessing': true, 'lastSeq': 1}));
    expect((a.rows.single as ToolRow).result, isNull);
  });

  test('RUN_IN_PROGRESS:撤回乐观行、恢复 running、给停止提示;普通错误照旧落定', () {
    var s = const ChatState();
    s = applyLocalUser(s, '帮我查');
    expect((s.rows.single as UserRow).pending, isTrue);
    s = applyEvent(s, ev('error', seq: 9, extra: {'content': 'RUN_IN_PROGRESS'}));
    expect(s.running, isTrue); // 服务器上一轮还在跑 → 停止按钮要出现
    expect(s.rows.whereType<UserRow>(), isEmpty); // 没落库的假气泡撤回
    expect(s.rows.single, isA<ErrorRow>());

    final t = applyEvent(const ChatState(), ev('error', seq: 1, extra: {'content': '上游 500'}));
    expect(t.running, isFalse);
    expect((t.rows.single as ErrorRow).content, '上游 500');
  });

  test('usage 更新;complete 结束运行并清流缓冲', () {
    var s = const ChatState(running: true, streamingText: '残流');
    s = applyEvent(s, ev('usage', seq: 1, extra: {'inputTokens': 10, 'outputTokens': 5, 'totalCostUsd': 0.05, 'durationMs': 1234}));
    expect(s.usage?.totalCostUsd, 0.05);
    s = applyEvent(s, ev('complete', seq: 2, extra: {'exitCode': 0, 'aborted': false}));
    expect(s.running, isFalse);
    expect(s.streamingText, isNull);
  });

  test('permission_request 记 pending,error 成行', () {
    var s = const ChatState();
    s = applyEvent(s, ev('permission_request', extra: {'requestId': 'r1', 'toolName': 'Bash', 'input': {}}));
    expect(s.pendingPermission?.requestId, 'r1');
    s = applyEvent(s, ev('error', seq: 1, extra: {'content': 'boom'}));
    expect((s.rows[0] as ErrorRow).content, 'boom');
  });

  test('seq 去重:重复/落后事件丢弃,lastSeq 只前进', () {
    var s = const ChatState(lastSeq: 5);
    s = applyEvent(s, ev('text', seq: 5, extra: {'role': 'assistant', 'content': '旧'}));
    s = applyEvent(s, ev('text', seq: 3, extra: {'role': 'assistant', 'content': '更旧'}));
    expect(s.rows, isEmpty);
    s = applyEvent(s, ev('text', seq: 6, extra: {'role': 'assistant', 'content': '新'}));
    expect(s.lastSeq, 6);
    expect(s.rows.length, 1);
  });

  test('replay 批量:过滤旧 seq 后逐条归约', () {
    var s = const ChatState(lastSeq: 1);
    final replay = [
      ev('text', seq: 1, extra: {'role': 'assistant', 'content': '旧'}),
      ev('text', seq: 2, extra: {'role': 'assistant', 'content': '一'}),
      ev('complete', seq: 3, extra: {'exitCode': 0, 'aborted': false}),
    ];
    s = applyReplay(s, replay);
    expect(s.lastSeq, 3);
    expect(s.rows.length, 1);
    expect(s.running, isFalse);
  });

  test('permission_resolved:同 requestId 收起审批卡,不匹配则保留', () {
    final withCard = applyEvent(const ChatState(), {
      'kind': 'permission_request',
      'requestId': 'req-1',
      'toolName': 'Bash',
      'input': {'command': 'ls'},
    });
    expect(withCard.pendingPermission?.requestId, 'req-1');

    // 不匹配的 resolved:卡片保留
    final kept = applyEvent(withCard, {'kind': 'permission_resolved', 'requestId': 'other'});
    expect(kept.pendingPermission?.requestId, 'req-1');

    // 匹配的 resolved:卡片收起
    final cleared = applyEvent(withCard, {'kind': 'permission_resolved', 'requestId': 'req-1'});
    expect(cleared.pendingPermission, isNull);
  });

  test('text 事件按 role 分流:user → UserRow,assistant → TextRow', () {
    var s = const ChatState();
    s = applyEvent(s, ev('text', seq: 1, extra: {'role': 'user', 'content': '我的问题'}));
    expect((s.rows[0] as UserRow).content, '我的问题');
    s = applyEvent(s, ev('text', seq: 2, extra: {'role': 'assistant', 'content': '回答'}));
    expect((s.rows[1] as TextRow).content, '回答');
  });

  test('subscribed.isProcessing 驱动 running;不抬 lastSeq(replay 不被毒化);本地 user 行不入 seq 流', () {
    var s = const ChatState();
    s = applyEvent(s, ev('subscribed', extra: {'sessionId': 'x', 'isProcessing': true, 'lastSeq': 9}));
    expect(s.running, isTrue);
    expect(s.lastSeq, 0); // 服务器指针 ≠ 已应用内容,抬门槛会让 replay 整批被去重
    // subscribed 之后到达的 replay(≤ 服务器指针)必须照常应用
    s = applyReplay(s, [
      ev('text', seq: 7, extra: {'role': 'assistant', 'content': '补'}),
      ev('complete', seq: 9, extra: {'exitCode': 0, 'aborted': false}),
    ]);
    expect((s.rows.single as TextRow).content, '补');
    expect(s.lastSeq, 9);
    expect(s.running, isFalse);
    s = applyLocalUser(s, '帮我看看');
    expect(s.rows.last, isA<UserRow>());
    expect(s.lastSeq, 9); // 本地行不动 seq
  });

  test('subscribed.pending 重建审批卡;空数组清旧卡;无字段保持原状', () {
    var s = const ChatState(pendingPermission: PermissionReq(requestId: 'old', toolName: 'Bash', input: {}));
    // 服务器明确说没在等审批(空数组)→ 清掉旧卡,不再挂着没人能批的僵尸卡
    s = applyEvent(s, ev('subscribed', extra: {'sessionId': 'x', 'isProcessing': false, 'lastSeq': 1, 'pending': []}));
    expect(s.pendingPermission, isNull);
    // 等审批时重连(App 重启后):pending 非空 → 确定性重建审批卡
    s = applyEvent(s, ev('subscribed', extra: {
      'sessionId': 'x', 'isProcessing': true, 'lastSeq': 2,
      'pending': [
        {'requestId': 'r1', 'toolName': 'Bash', 'input': {'command': 'flutter build apk'}},
      ],
    }));
    expect(s.pendingPermission?.requestId, 'r1');
    expect(s.pendingPermission?.toolName, 'Bash');
    expect(s.pendingPermission?.input, {'command': 'flutter build apk'});
    expect(s.running, isTrue);
    // 无 pending 字段(旧服务器)→ 不动现有卡
    s = applyEvent(s, ev('subscribed', extra: {'sessionId': 'x', 'isProcessing': true, 'lastSeq': 3}));
    expect(s.pendingPermission?.requestId, 'r1');
  });

  test('task_started/task_complete:后台任务复用工具卡,迟到真结果盖掉中断占位', () {
    var s = const ChatState();
    s = applyEvent(s, ev('task_started', seq: 1, extra: {'taskId': 'k1', 'description': '跑全量测试', 'taskType': 'local_agent'}));
    final card = s.rows.single as ToolRow;
    expect(card.toolId, 'k1');
    expect(card.toolName, '子任务'); // local_agent → 子任务,其余叫后台任务
    expect(card.result, isNull);

    // 回合先结束(complete 把没结果的卡收尾成中断占位)…
    s = applyEvent(s, ev('complete', seq: 2, extra: {'exitCode': 0, 'aborted': false}));
    expect((s.rows.single as ToolRow).result?.content, kInterruptedToolMark);

    // …后台任务迟到的完成通知盖回真结果
    s = applyEvent(s, ev('task_complete', seq: 3, extra: {'taskId': 'k1', 'status': 'completed', 'summary': '30 个测试全绿'}));
    final done = s.rows.single as ToolRow;
    expect(done.result?.content, '30 个测试全绿');
    expect(done.result?.isError, isFalse);
    expect(s.running, isTrue); // 不改运行态:后台任务收尾 ≠ 回合收尾
  });

  test('task_complete 失败状态 isError;无匹配卡只推 seq 不建行', () {
    var s = applyEvent(const ChatState(), ev('task_complete', seq: 5, extra: {'taskId': 'ghost', 'status': 'failed', 'summary': '炸了'}));
    expect(s.rows, isEmpty);
    expect(s.lastSeq, 5);
    // task_progress 等未消费事件:走 default 只推 seq,不产生行
    s = applyEvent(s, ev('task_progress', seq: 6, extra: {'taskId': 'ghost', 'description': 'x'}));
    expect(s.rows, isEmpty);
    expect(s.lastSeq, 6);
  });

  test('发图回显:纯图回显按 imageCount 占位对上,不双气泡;图片随行保留', () {
    var s = const ChatState();
    // 乐观行:纯图发送,占位文案 + 本地 data URI
    s = applyLocalUser(s, '[图片] ×2', images: ['data:image/png;base64,AAA', 'data:image/png;base64,BBB']);
    var row = s.rows.single as UserRow;
    expect(row.pending, isTrue);
    expect(row.images.length, 2);
    // 回显:实时线上图片被剥成 imageCount,content 为空 → 占位文案对上,不追加空气泡
    s = applyEvent(s, ev('text', seq: 1, extra: {'role': 'user', 'content': '', 'imageCount': 2}));
    final confirmed = s.rows.whereType<UserRow>().toList();
    expect(confirmed.length, 1);
    expect(confirmed.single.pending, isFalse);
    expect(confirmed.single.content, '[图片] ×2');
    expect(confirmed.single.images.length, 2); // 乐观行的图保留
    // 历史重建(REST meta 带完整 images):直接随行
    var h = const ChatState();
    h = applyEvent(h, ev('text', seq: 1, extra: {'role': 'user', 'content': '看这张', 'images': ['data:image/jpeg;base64,CCC']}));
    expect((h.rows.single as UserRow).images.length, 1);
  });

  test('中断类提示走中性 ErrorRow,真错误保持红色语义', () {
    var s = applyEvent(const ChatState(), ev('error', seq: 1, extra: {'content': '服务重启打断了上一轮运行,之后的输出没有记录;请重发或继续'}));
    expect((s.rows.single as ErrorRow).neutral, isTrue);
    s = applyEvent(s, ev('error', seq: 2, extra: {'content': '回合超过 10 分钟没有任何输出,已自动中断;请重发'}));
    expect((s.rows.last as ErrorRow).neutral, isTrue);
    s = applyEvent(s, ev('error', seq: 3, extra: {'content': '上游 500'}));
    expect((s.rows.last as ErrorRow).neutral, isFalse);
  });

  test('乐观用户行:pending 标记,服务器回显就地确认不重复', () {
    var s = applyLocalUser(const ChatState(), '你好');
    expect((s.rows.single as UserRow).pending, isTrue);
    // 服务器回显同内容 → 就地转正,不追加新行
    s = applyEvent(s, ev('text', seq: 1, extra: {'role': 'user', 'content': '你好'}));
    final confirmed = s.rows.single as UserRow;
    expect(confirmed.content, '你好');
    expect(confirmed.pending, isFalse);
    // 回显没有对应 pending 行 → 正常追加
    s = applyEvent(s, ev('text', seq: 2, extra: {'role': 'user', 'content': '再问'}));
    expect(s.rows.whereType<UserRow>().length, 2);
    // 应答权限后清 pendingPermission
    s = applyEvent(s, ev('permission_request', extra: {'requestId': 'r1', 'toolName': 'Bash', 'input': {}}));
    expect(s.pendingPermission, isNotNull);
    s = applyPermissionAnswer(s);
    expect(s.pendingPermission, isNull);
  });

  test('rollbackLocalUser:撤回乐观行时一并清 running(发送失败不留假运行中)', () {
    var s = applyLocalUser(const ChatState(), '发不出去');
    expect(s.running, isTrue); // 乐观置位
    s = rollbackLocalUser(s);
    expect(s.rows, isEmpty);
    expect(s.running, isFalse); // 撤回应同步清 running,否则按钮卡 STOP
  });

  test('upstream_status:落地真实相位,终态与新回合清空,无效相位忽略', () {
    var s = applyLocalUser(const ChatState(), '查一下');
    expect(s.upstreamPhase, isNull); // 新回合开始:上一回合的相位不得残留
    s = setUpstreamPhase(s, 'request');
    expect(s.upstreamPhase, 'request');
    expect(s.upstreamAt, isNotNull);
    s = setUpstreamPhase(s, 'first_byte');
    expect(s.upstreamPhase, 'first_byte');
    // done/error 相位没有展示意义,setUpstreamPhase 忽略,由回合终态统一收
    s = setUpstreamPhase(s, 'done');
    expect(s.upstreamPhase, 'first_byte');
    // 回合结束:相位清空
    s = applyEvent(s, ev('complete', seq: 1));
    expect(s.upstreamPhase, isNull);
    // error 同理
    s = setUpstreamPhase(s, 'request');
    s = applyEvent(s, ev('error', seq: 2, extra: {'content': '回合超过 10 分钟没有任何输出,已自动中断;请重发'}));
    expect(s.upstreamPhase, isNull);
  });
}
