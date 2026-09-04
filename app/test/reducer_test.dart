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

  test('text 事件按 role 分流:user → UserRow,assistant → TextRow', () {
    var s = const ChatState();
    s = applyEvent(s, ev('text', seq: 1, extra: {'role': 'user', 'content': '我的问题'}));
    expect((s.rows[0] as UserRow).content, '我的问题');
    s = applyEvent(s, ev('text', seq: 2, extra: {'role': 'assistant', 'content': '回答'}));
    expect((s.rows[1] as TextRow).content, '回答');
  });

  test('subscribed.isProcessing 驱动 running;本地 user 行不入 seq 流', () {
    var s = const ChatState();
    s = applyEvent(s, ev('subscribed', extra: {'sessionId': 'x', 'isProcessing': true, 'lastSeq': 9}));
    expect(s.running, isTrue);
    expect(s.lastSeq, 9); // subscribed 的 lastSeq 是服务器视角
    s = applyLocalUser(s, '帮我看看');
    expect(s.rows.last, isA<UserRow>());
    expect(s.lastSeq, 9); // 本地行不动 seq
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
}
