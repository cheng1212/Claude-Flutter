import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/notify.dart';

void main() {
  group('notifyDecision', () {
    test('complete/error:前后台、任意会话都通知(用户 2026-09-12 需求)', () {
      for (final lc in ['resumed', 'hidden', 'paused', 'inactive']) {
        for (final cur in [true, false]) {
          expect(
              notifyDecision(lifecycleState: lc, kind: 'complete', forCurrentSession: cur),
              cur ? '任务完成' : '后台任务完成',
              reason: 'complete 前后台/任意会话都弹');
          expect(
              notifyDecision(lifecycleState: lc, kind: 'error', forCurrentSession: cur),
              isNotNull,
              reason: 'error 前后台/任意会话都弹');
        }
      }
    });
    test('审批:仅当前会话弹', () {
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'permission_request', forCurrentSession: true), '等待你的审批');
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'permission_request', forCurrentSession: false), isNull);
    });
    test('其他事件一律不通知', () {
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'stream_delta', forCurrentSession: true), isNull);
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'usage', forCurrentSession: true), isNull);
    });
  });
}
