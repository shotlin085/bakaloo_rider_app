import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/app_logger.dart';
import '../../firebase_options.dart';

/// Background message handler — must be a top-level function (Firebase requirement).
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundMessageHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  AppLogger.info(
    LogTopic.notifications,
    'Background FCM message: ${message.messageId}',
  );
}

/// Manages Firebase Cloud Messaging (FCM) setup and foreground notification
/// display for the Bakaloo Rider app.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const String _channelId   = 'bakaloo_rider_high';
  static const String _channelName = 'Bakaloo Rider Notifications';
  static const String _channelDesc =
      'Order offers, delivery updates and approval alerts';

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  final StreamController<RemoteMessage> _messageController =
      StreamController<RemoteMessage>.broadcast();

  String? _fcmToken;
  bool _initialized = false;

  /// Latest FCM registration token. Null until [initialize] completes.
  String? get fcmToken => _fcmToken;

  /// Stream of foreground [RemoteMessage]s.
  Stream<RemoteMessage> get onMessage => _messageController.stream;

  /// Initializes Firebase, requests permissions, sets up local notifications.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }

      final FirebaseMessaging fcm = FirebaseMessaging.instance;

      await fcm.requestPermission(
        alert: true, badge: true, sound: true,
      );

      await fcm.setForegroundNotificationPresentationOptions(
        alert: true, badge: true, sound: true,
      );

      // Android notification channel
      if (Platform.isAndroid) {
        const AndroidNotificationChannel channel = AndroidNotificationChannel(
          _channelId, _channelName,
          description: _channelDesc,
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        );
        final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
            _local.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(channel);
      }

      // Initialize local notifications
      const InitializationSettings initSettings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      await _local.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (_) {},
      );

      // Background handler
      FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundMessageHandler);

      // Foreground message handler
      FirebaseMessaging.onMessage.listen(_handleForeground);

      // FCM token
      _fcmToken = await fcm.getToken();
      AppLogger.info(
        LogTopic.notifications,
        'FCM initialized. Token: ${_fcmToken != null ? "obtained" : "null"}',
      );

      fcm.onTokenRefresh.listen((String newToken) {
        _fcmToken = newToken;
        AppLogger.info(LogTopic.notifications, 'FCM token refreshed');
      });
    } catch (e, st) {
      AppLogger.warn(
        LogTopic.notifications,
        'NotificationService.initialize failed — push disabled',
        error: e, stackTrace: st,
      );
    }
  }

  Future<void> _handleForeground(RemoteMessage message) async {
    AppLogger.info(
      LogTopic.notifications,
      'Foreground FCM: ${message.notification?.title}',
    );
    _messageController.add(message);

    final RemoteNotification? notification = message.notification;
    if (notification == null) return;

    // Show local notification so foreground messages are visible.
    const NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId, _channelName,
        channelDescription: _channelDesc,
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true, presentBadge: true, presentSound: true,
      ),
    );

    await _local.show(
      id: notification.hashCode,
      title: notification.title ?? 'Bakaloo Rider',
      body: notification.body ?? '',
      notificationDetails: details,
      payload: message.data['type'],
    );
  }

  void dispose() {
    _messageController.close();
  }
}

/// Registers the FCM token with the Bakaloo backend.
Future<void> registerFcmTokenWithBackend({
  required String token,
  required Future<void> Function(String token, String platform) onRegister,
}) async {
  if (token.isEmpty) return;
  try {
    final String platform = Platform.isIOS ? 'ios' : 'android';
    await onRegister(token, platform);
    AppLogger.info(LogTopic.notifications, 'FCM token registered with backend');
  } catch (e, st) {
    AppLogger.warn(
      LogTopic.notifications, 'FCM token registration failed',
      error: e, stackTrace: st,
    );
  }
}
