import 'package:flutter/material.dart';
import 'package:tl_chat/app.dart';
import 'package:tl_chat/services/notifications.dart';

Future<void> main() async {
  // Android 推送：初始化本地通知 + 前台服务保活配置（失败不阻塞启动）。
  await NotificationService.instance.init();
  runApp(const ChatApp());
}
