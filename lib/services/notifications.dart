// Android 消息推送：本地通知（新消息提醒）+ 前台服务保活（进程常驻）。
//
// - flutter_local_notifications：应用在后台（非活跃会话）收到新消息时
//   弹出通知，点击通知携带会话 id 以便打开对应会话。
// - flutter_foreground_task：保持进程前台优先级，主 isolate 的 Tailscale 连接
//   在后台继续存活（tailscale_dart 的 Go 引擎在其自身的 worker isolate 中，
//   不受前台服务独立引擎影响）。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 应用内通知图标资源名（AndroidManifest 中已声明为 launcher 图标）。
const _kNotificationIcon = '@mipmap/ic_launcher';

// ─── 前台服务保活 ─────────────────────────────────────────────────────

/// 前台服务常驻通知的渠道（低重要性，不打扰用户）。
const _kKeepAliveChannelId = 'tl_chat_keepalive';
const _kKeepAliveChannelName = 'TL Chat 后台保活';
const _kKeepAliveChannelDesc = '保持 TL Chat 在后台持续接收消息';

/// 前台服务常驻通知的图标 meta-data 名（必须与 Manifest 中的声明一致）。
const _kKeepAliveIconMeta = 'ic_launcher_foreground';

/// 后台 isolate 入口：前台服务启动时在独立的 FlutterEngine 中执行。
/// 仅注册一个空 TaskHandler 把进程托住 —— 真正的连接由主 isolate 维护。
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

/// 最小保活任务：不做实际工作，只让前台服务持续运行。
class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

// ─── 聊天通知 ─────────────────────────────────────────────────────────

/// 新消息通知渠道（高重要性，需要用户可见）。
const _kChatChannelId = 'tl_chat_messages';
const _kChatChannelName = '聊天消息';
const _kChatChannelDesc = '新消息、群聊消息提醒';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();

  /// 前台服务是否已启动（避免重复启动）。
  bool _serviceStarted = false;

  /// 应用是否在前台（在前台且会话已打开时不再弹通知）。
  bool _appForegrounded = true;

  final Map<int, void Function(String conversationId)> _tapListeners = {};
  int _tapListenerId = 0;

  /// 注册通知点击回调，返回可用于注销的 id。
  int addTapListener(void Function(String conversationId) listener) {
    final id = ++_tapListenerId;
    _tapListeners[id] = listener;
    return id;
  }

  void removeTapListener(int id) {
    _tapListeners.remove(id);
  }

  /// 通知点击 / 冷启动点击 —— 通知所有监听者（UI 打开对应会话）。
  void _onTap(String? payload) {
    final convId = payload;
    if (convId == null || convId.isEmpty) return;
    // 迭代快照：回调内可能移除监听器（如路由导航触发 dispose），避免
    // ConcurrentModificationError。
    for (final cb in _tapListeners.values.toList()) {
      cb(convId);
    }
  }

  /// 必须在 runApp 前调用（main() 中）。
  Future<void> init() async {
    WidgetsFlutterBinding.ensureInitialized();

    const androidInit = AndroidInitializationSettings(_kNotificationIcon);
    const settings = InitializationSettings(android: androidInit);
    await _fln.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (resp) => _onTap(resp.payload),
    );

    // Android 13+ 需要运行时通知权限（用于显示新消息通知）。
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _fln
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    // 初始化前台服务配置（仅 Android 使用）。失败不阻塞聊天（桌面端/测试
    // 环境无对应实现，捕获 MissingPluginException 等）。
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        FlutterForegroundTask.init(
          androidNotificationOptions: AndroidNotificationOptions(
            channelId: _kKeepAliveChannelId,
            channelName: _kKeepAliveChannelName,
            channelDescription: _kKeepAliveChannelDesc,
            channelImportance: NotificationChannelImportance.LOW,
            priority: NotificationPriority.LOW,
          ),
          iosNotificationOptions: const IOSNotificationOptions(
            showNotification: false,
          ),
          foregroundTaskOptions: ForegroundTaskOptions(
            eventAction: ForegroundTaskEventAction.nothing(),
            allowWakeLock: true,
            allowWifiLock: true,
          ),
        );
      } catch (_) {
        // 保活不可用不阻塞聊天
      }
    }

    // 记录前后台切换，前台打开对应会话时不弹通知。
    WidgetsBinding.instance.addObserver(_LifecycleObserver(this));
  }

  /// 连接成功后启动前台服务保活。失败静默降级（保活不可用不影响聊天）。
  Future<void> startKeepAlive() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_serviceStarted) return;
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      // 先确保通知权限（Android 13+），否则前台服务无法展示常驻通知。
      if (await FlutterForegroundTask.checkNotificationPermission() !=
          NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: 256,
        serviceTypes: const [ForegroundServiceTypes.dataSync],
        notificationTitle: 'TL Chat 运行中',
        notificationText: '正在后台保持连接，随时接收消息',
        notificationIcon: NotificationIcon(metaDataName: _kKeepAliveIconMeta),
        callback: _foregroundTaskCallback,
      );
      _serviceStarted = result is ServiceRequestSuccess;
    } catch (_) {
      // 静默降级
    }
  }

  /// 断开连接后停止前台服务。
  Future<void> stopKeepAlive() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (!_serviceStarted) return;
    _serviceStarted = false;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // 静默
    }
  }

  /// 收到新消息时弹出通知。payload 携带会话 id，点击后打开对应会话。
  Future<void> showMessageNotification({
    required String conversationId,
    required String title,
    required String body,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_appForegrounded) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _kChatChannelId,
        _kChatChannelName,
        channelDescription: _kChatChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        icon: _kNotificationIcon,
      ),
    );
    // 用会话 id 的哈希保证同会话的后续消息替换旧通知，避免通知栏堆叠。
    final id = conversationId.hashCode & 0x7fffffff;
    await _fln.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: conversationId,
    );
  }
}

class _LifecycleObserver extends WidgetsBindingObserver {
  _LifecycleObserver(this._service);

  final NotificationService _service;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _service._appForegrounded = state == AppLifecycleState.resumed;
  }
}
