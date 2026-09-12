import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// 通知判定:哪些 WS 事件值得弹系统通知(仅 App 在后台时)。
// 纯函数可单测;实际弹出由 lib/notify.dart 的插件封装执行。

/// App 是否在前台:'resumed' = 前台,其余(background/inactive/hidden/detached)算后台。
String? notifyDecision({
  required String lifecycleState,
  required String kind, // WS 事件 kind
  required bool forCurrentSession,
}) {
  if (lifecycleState == 'resumed') return null; // 前台不看通知
  switch (kind) {
    case 'complete':
      return forCurrentSession ? '任务完成' : '后台任务完成';
    case 'error':
      return forCurrentSession ? '会话出错' : null; // 非当前会话的 error 不打扰
    case 'permission_request':
      return forCurrentSession ? '等待你的审批' : null;
    default:
      return null;
  }
}

// ---------------------------------------------------------------- 插件封装
/// 系统通知薄封装:初始化失败全程静默降级(不弹,不影响主流程)。
/// 点击通知 → [onTap] 回调带 payload(会话 id),由 app 导航到对应会话。
class Notify {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _idSeq = 1;

  /// 点击通知的回调(payload = 通知附带的会话 id);main 里接线导航。
  static void Function(String sessionId)? onTap;

  static Future<void> init() async {
    if (_ready) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(
        settings: const InitializationSettings(android: android),
        onDidReceiveNotificationResponse: _onResponse,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _ready = true;
    } on Object {
      _ready = false;
    }
  }

  static void _onResponse(NotificationResponse resp) {
    final payload = resp.payload;
    if (payload != null && payload.isNotEmpty) onTap?.call(payload);
  }

  static void show(String title, String body, {String? sessionId, bool isError = false}) {
    if (!_ready) return;
    try {
      // 错误走独立渠道(用户可按渠道关掉某一类,视觉也有区分)
      final details = isError
          ? NotificationDetails(
              android: AndroidNotificationDetails(
                'zcode_errors',
                '会话错误',
                channelDescription: '任务失败 / 执行错误',
                importance: Importance.high,
                priority: Priority.high,
                color: const Color(0xFFE5484D),
              ),
            )
          : const NotificationDetails(
              android: AndroidNotificationDetails(
                'zcode_events',
                '会话事件',
                channelDescription: '任务完成 / 等待审批',
                importance: Importance.high,
                priority: Priority.high,
              ),
            );
      _plugin.show(
        id: _idSeq++,
        title: title,
        body: body,
        payload: sessionId,
        notificationDetails: details,
      );
    } on Object {
      // 静默:通知失败不该影响任何主流程
    }
  }
}
