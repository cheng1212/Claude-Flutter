import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 通知判定:哪些 WS 事件值得弹系统通知(仅 App 在后台时)。
// 纯函数可单测;实际弹出由 lib/notify.dart 的插件封装执行。

/// App 是否在前台:'resumed' = 前台,其余(background/inactive/hidden/detached)算后台。
/// 状态变化通知判定(用户 2026-09-12 需求:任何会话完成/报错/停止都弹,
/// 用户可能在刷抖音干别的——按会话区分标题,不按前台后台裁剪)。
///
/// [extraTitle] 由调用方传入补充信息(如停止原因);null = 不弹。
/// 通知偏好:总开关(关=不弹任何通知)+提醒方式(声音/震动/静音)。
/// SharedPreferences 持久化,启动时 load 一次。
class NotifyPrefs {
  static bool enabled = true;

  /// 提醒方式:sound(铃声)/vibrate(震动)/silent(静音)
  static String mode = 'sound';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    enabled = p.getBool('notify.enabled') ?? true;
    mode = p.getString('notify.mode') ?? 'sound';
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('notify.enabled', enabled);
    await p.setString('notify.mode', mode);
  }

  static Future<void> setEnabled(bool v) async {
    enabled = v;
    await save();
  }

  static Future<void> setMode(String m) async {
    mode = m;
    await save();
  }
}

String? notifyDecision({
  required String lifecycleState,
  required String kind, // WS 事件 kind
  required bool forCurrentSession,
  String? extraTitle,
}) {
  // 总开关关闭:任何通知都不弹
  if (!NotifyPrefs.enabled) return null;
  switch (kind) {
    case 'complete':
      // 前台也弹:用户可能在看别的会话/页面,回合落定是关键节点
      if (forCurrentSession) return '任务完成';
      return '后台任务完成';
    case 'error':
      return forCurrentSession ? '会话出错' : '会话出错(其他会话)';
    case 'permission_request':
      return forCurrentSession ? '等待你的审批' : null;
    default:
      return extraTitle;
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
    if (!_ready || !NotifyPrefs.enabled) return;
    try {
      // 提醒方式(用户设置):铃声=默认带声;震动=无声只振;静音=low 无声无振。
      // Android 渠道一旦创建不可改属性,故按模式分渠道 id。
      final mode = NotifyPrefs.mode;
      final suffix = mode == 'sound' ? '' : '_$mode';
      final importance = mode == 'silent' ? Importance.low : Importance.high;
      final priority = mode == 'silent' ? Priority.low : Priority.high;
      final enableVibration = mode == 'vibrate';
      final playSound = mode != 'silent';
      final errDetails = NotificationDetails(
          android: AndroidNotificationDetails(
        'zcode_errors$suffix',
        '会话错误',
        channelDescription: '任务失败 / 执行错误',
        importance: importance,
        priority: priority,
        enableVibration: enableVibration,
        playSound: playSound,
        fullScreenIntent: true,
        color: const Color(0xFFE5484D),
      ));
      final evtDetails = NotificationDetails(
          android: AndroidNotificationDetails(
        'zcode_events$suffix',
        '会话事件',
        channelDescription: '任务完成 / 等待审批',
        importance: importance,
        priority: priority,
        enableVibration: enableVibration,
        playSound: playSound,
        fullScreenIntent: true,
      ));
      // 微信式弹出:高优先级渠道 + fullScreenIntent(息屏/锁屏直接弹横幅)
      final details = isError ? errDetails : evtDetails;
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
