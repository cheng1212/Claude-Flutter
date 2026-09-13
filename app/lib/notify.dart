import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_log.dart';
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
      ZLog.i('notify', 'initialized (权限已请求)');
    } on Object catch (e) {
      // 原来这里是纯静默:初始化一失败,之后所有通知都不弹且**查不到原因**。
      // 记进诊断日志(设置→诊断日志可复制),用户报"通知不弹"时能直接看。
      _ready = false;
      ZLog.e('notify', 'init 失败,通知将全程不弹: $e');
    }
  }

  static void _onResponse(NotificationResponse resp) {
    final payload = resp.payload;
    if (payload != null && payload.isNotEmpty) onTap?.call(payload);
  }

  /// 是否能弹(初始化成功且总开关开着)。设置页据此提示用户"为什么没响"。
  static bool get ready => _ready;

  /// 发一条测试通知:让用户当场验证铃声/震动/横幅是否正常,
  /// 不用等真实任务跑完。返回是否真的发出去了。
  static bool test() {
    if (!_ready) return false;
    if (!NotifyPrefs.enabled) return false;
    show('测试通知',
        '看到这条说明通知正常;没声音/没震动请检查系统通知设置(渠道:会话事件)\n'
        '当前提醒方式:${_modeLabel()}');
    return true;
  }

  static String _modeLabel() => switch (NotifyPrefs.mode) {
        'vibrate' => '仅震动',
        'silent' => '静音',
        _ => '铃声 + 震动',
      };

  static void show(String title, String body, {String? sessionId, bool isError = false}) {
    if (!_ready || !NotifyPrefs.enabled) return;
    try {
      // 提醒方式(用户设置):铃声=响铃+震动;震动=只振;静音=都不。
      //
      // ⚠️ 渠道 id 带 **_v2** 是一次性的**:Android 的通知渠道一旦创建,属性永久锁定
      // ——改这里的参数对手机上已存在的旧渠道**完全不生效**。用户实测"铃声从来
      // 没听到过",旧渠道就是按老参数(不震动、importance 只到 high)建的。
      // 换 id 才会按新参数重建渠道。以后要再改提醒行为,同样得升这个版本号。
      //
      // sound 模式改为**响铃+震动**、importance 提到 max:MIUI 对非最高级通知
      // 常做静默处理,high 不足以稳定抢到横幅和声音。
      final mode = NotifyPrefs.mode;
      final suffix = mode == 'sound' ? '' : '_$mode';
      final importance = mode == 'silent' ? Importance.low : Importance.max;
      final priority = mode == 'silent' ? Priority.low : Priority.max;
      final enableVibration = mode != 'silent'; // 响铃模式也震一下(提醒要有存在感)
      final playSound = mode == 'sound';
      final errDetails = NotificationDetails(
          android: AndroidNotificationDetails(
        'zcode_errors_v2$suffix',
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
        'zcode_events_v2$suffix',
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
    } on Object catch (e) {
      // 通知失败不该影响主流程,但要留痕(否则用户只看到"没弹",查不了)
      ZLog.w('notify', 'show 失败: $e', dedupeKey: 'notify-show-fail');
    }
  }
}
