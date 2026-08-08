import 'dart:io' show Platform;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Android 前台保活 + 新消息本地通知。
///
/// 职责：
///   - [init]：初始化通知插件、请求 Android 13+ 通知权限、配置保活服务
///   - [startKeepAlive]：启动常驻前台服务（specialUse 类型，无时长限制），
///     防止 tsnet 与 TCP 连接被系统在后台杀掉
///   - [showMessageNotification]：收到新消息时弹出系统通知
///
/// 非 Android 平台（Linux 桌面等）全部调用自动跳过，不影响主流程。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 通知 id 单调递增，避免同一毫秒多条消息互相覆盖。
  int _nextNotificationId = 0;

  static const _messageChannel = AndroidNotificationDetails(
    'tl_chat_messages',
    '新消息',
    channelDescription: '收到的聊天新消息',
    importance: Importance.max,
    priority: Priority.high,
    onlyAlertOnce: true,
  );

  /// 初始化（幂等）。在 main() 启动时调用；失败静默降级。
  Future<void> init() async {
    if (_initialized || !Platform.isAndroid) return;
    try {
      // 1) 前台保活服务配置。
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'tl_chat_keepalive',
          channelName: 'TL Chat 连接保活',
          channelDescription: '保持与聊天服务器的连接，以便后台接收消息',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
          showWhen: false,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnMyPackageReplaced: true,
          allowWakeLock: true,
          allowAutoRestart: true,
        ),
      );
      // 2) 消息通知插件。
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      // 3) Android 13+ 运行时通知权限。
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      _initialized = true;
    } catch (_) {
      // 插件/权限不可用：静默降级，不影响聊天功能。
    }
  }

  /// 启动常驻前台服务（连接成功、进程在前台时调用）。
  Future<void> startKeepAlive() async {
    if (!_initialized || !Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 256,
          // specialUse：常驻消息应用，规避 Android 15+ 对 dataSync 的 6h 限制。
          serviceTypes: const [ForegroundServiceTypes.specialUse],
          notificationTitle: 'TL Chat',
          notificationText: '保持连接以接收消息',
          notificationIcon: null,
          callback: _keepAliveCallback,
        );
      }
    } catch (_) {
      // 个别机型不允许特殊类型服务：降级为不保活，App 前台仍可用。
    }
  }

  /// 后台 isolate 回调：保活服务只需让进程存活，连接逻辑在主 isolate 中。
  @pragma('vm:entry-point')
  static void _keepAliveCallback() {}

  /// 弹出一条新消息通知。
  Future<void> showMessageNotification({
    required String title,
    required String body,
  }) async {
    if (!_initialized || !Platform.isAndroid) return;
    try {
      await _plugin.show(
        id: ++_nextNotificationId,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: _messageChannel,
        ),
      );
    } catch (_) {}
  }
}
