import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/notify.dart';

void main() {
  group('notifyDecision', () {
    test('前台一律不通知', () {
      expect(notifyDecision(lifecycleState: 'resumed', kind: 'complete', forCurrentSession: true), isNull);
      expect(notifyDecision(lifecycleState: 'resumed', kind: 'error', forCurrentSession: true), isNull);
    });
    test('后台:complete/error/审批 才通知', () {
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'complete', forCurrentSession: true), '任务完成');
      expect(notifyDecision(lifecycleState: 'paused', kind: 'error', forCurrentSession: true), '会话出错');
      expect(notifyDecision(lifecycleState: 'inactive', kind: 'permission_request', forCurrentSession: true), '等待你的审批');
    });
    test('后台:非当前会话只报 complete,不报 error/审批', () {
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'complete', forCurrentSession: false), '后台任务完成');
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'error', forCurrentSession: false), isNull);
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'permission_request', forCurrentSession: false), isNull);
    });
    test('其他事件一律不通知', () {
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'stream_delta', forCurrentSession: true), isNull);
      expect(notifyDecision(lifecycleState: 'hidden', kind: 'usage', forCurrentSession: true), isNull);
    });
  });
}
