import 'package:flutter/material.dart';
import 'dart:async';
// Fix 1: Add required imports for Notifications
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:typed_data';
import 'package:provider/provider.dart';

// --- Global Service Access ---
// We use a global variable to access the service instance from the static notification handler.
BreakTimerService? globalBreakTimerService;

// --- Notification Setup (Android Specific) ---

// Global plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Define the high-priority Android channel once
// FIX: Changed 'const' to 'final' because the constructor is not a constant.
final AndroidNotificationChannel androidChannel = AndroidNotificationChannel(
  'break_channel_id', // Unique ID
  'Break Reminders (High Priority)',
  description: 'Alerts you to take a mandatory break.',
  importance: Importance.max, // VERY IMPORTANT: Use max importance for intrusive popups
  sound: RawResourceAndroidNotificationSound('alert_sound'), // Custom sound, must be in android/app/src/main/res/raw/
  // Vibrate pattern: wait 0ms, vibrate 1000ms, pause 1000ms, vibrate 1000ms
  // Fix 2: Use Int64List.fromList which resolves the compilation error
  vibrationPattern: Int64List.fromList([0, 1000, 1000, 1000]), 
);

// Function to initialize the notification system
Future<void> _initializeNotifications() async {
  // 1. Android Initialization Settings (for the default icon)
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    // Since we are Android-only, we omit iOS settings.
  );

  // 2. Initialize the plugin
  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse response) async {
      // Logic for notification tap when the app is in the foreground/resumed
      if (response.payload == 'work_done' || response.actionId == 'start_break_action') {
        // If the notification payload/action is to start the break, call the method on the running service.
        globalBreakTimerService?.startBreak();
        debugPrint('Notification action processed: Break started.');
      }
      debugPrint('Notification action tapped: ${response.payload}');
    },
  );

  // 3. Create the notification channel (mandatory for Android 8.0+)
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(androidChannel);
}


// --- Modular Service: The Core Logic Module (Can be enabled/disabled) ---

enum TimerState { idle, working, notifying, breaking }

class BreakTimerService extends ChangeNotifier {
  // Constants for Work and Break Durations
  static const int workDurationMinutes = 45;
  static const int breakDurationMinutes = 2;

  Timer? _timer;
  TimerState _currentState = TimerState.idle;
  Duration _currentDuration = Duration.zero;
  bool _isRunning = false;

  TimerState get currentState => _currentState;
  Duration get currentDuration => _currentDuration;
  bool get isRunning => _isRunning;

  // Total seconds for work and break
  final int _workTimeSeconds = workDurationMinutes * 60;
  final int _breakTimeSeconds = breakDurationMinutes * 60;

  // Updated function to show a persistent, intrusive notification
  void _triggerNotification(String message, [String? payload]) async {
    // Notification Details (using the high-priority channel defined globally)
    final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      androidChannel.id,
      androidChannel.name,
      channelDescription: androidChannel.description,
      importance: Importance.max, // Ensure high priority
      priority: Priority.max,
      ticker: 'Break Reminder',
      fullScreenIntent: true, // IMPORTANT: Attempts to show over the lock screen/other apps
      // Note: The actions here need native background handler (like workmanager) to work when the app is closed.
      actions: <AndroidNotificationAction>[
        const AndroidNotificationAction(
            'start_break_action', 'Start Break',
            showsUserInterface: true, // This can trigger a full-screen activity
            // To make this fully functional when the app is killed, you'd integrate with workmanager.
        ),
      ],
    );

    // FIX: Changed 'const' to 'final' since androidDetails is not a constant value
    final NotificationDetails platformDetails =
        NotificationDetails(android: androidDetails);

    // Show the notification immediately
    await flutterLocalNotificationsPlugin.show(
      0, // Notification ID
      "Time to Stand Up!", // Title
      message, // Body
      platformDetails,
      payload: payload,
    );
    debugPrint("Notification Triggered: $message");
  }

  void startWorkCycle() {
    if (_currentState == TimerState.idle || _currentState == TimerState.breaking) {
      _currentState = TimerState.working;
      _currentDuration = Duration(seconds: _workTimeSeconds);
      _startTimer();
      notifyListeners();
    }
  }

  // This is called when the user hits "Start 2 Min Break" on the main UI OR via notification tap
  void startBreak() {
    if (_currentState == TimerState.notifying || _currentState == TimerState.working) {
      // We also check 'working' state in case the timer fires and the user taps the notification
      // before the state update reaches the UI.
      flutterLocalNotificationsPlugin.cancel(0); 

      _currentState = TimerState.breaking;
      _currentDuration = Duration(seconds: _breakTimeSeconds);
      _startTimer();
      notifyListeners();
    }
  }

  void pauseResume() {
    if (_isRunning) {
      _timer?.cancel();
      _isRunning = false;
    } else if (_currentState == TimerState.working || _currentState == TimerState.breaking) {
      _startTimer();
    }
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    flutterLocalNotificationsPlugin.cancel(0); // Clear any pending notification
    _currentState = TimerState.idle;
    _currentDuration = Duration.zero;
    _isRunning = false;
    notifyListeners();
  }

  void _startTimer() {
    _isRunning = true;
    _timer?.cancel(); 
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_currentDuration.inSeconds > 0) {
        _currentDuration = _currentDuration - const Duration(seconds: 1);
        notifyListeners();
      } else {
        _timer?.cancel();
        _isRunning = false;
        _handleCompletion();
      }
    });
  }

  void _handleCompletion() {
    if (_currentState == TimerState.working) {
      _currentState = TimerState.notifying;
      _triggerNotification(
          "Time for your 2-minute break! Click Start Break to begin the walk timer.",
          'work_done');
      notifyListeners();
    } else if (_currentState == TimerState.breaking) {
      // Break is over, restart the work cycle automatically
      _triggerNotification(
          "Break Over! Resuming work for $workDurationMinutes minutes.",
          'break_done');
      startWorkCycle();
    }
  }

  // Helper for UI formatting
  String get formattedTime {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String minutes = twoDigits(_currentDuration.inMinutes.remainder(60));
    String seconds = twoDigits(_currentDuration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// --- Application UI ---

void main() async {
  // Fix 3: Initialize Flutter binding and notifications before running the app
  WidgetsFlutterBinding.ensureInitialized();
  await _initializeNotifications();

  runApp(
    // Fix 4: Use Provider for better modularity and state management
    ChangeNotifierProvider(
      create: (context) {
        final service = BreakTimerService();
        globalBreakTimerService = service; // Register service instance globally
        return service;
      },
      child: const BreakReminderApp(),
    ),
  );
}

class BreakReminderApp extends StatelessWidget {
  const BreakReminderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Modular Break Reminder',
      theme: ThemeData(
        primarySwatch: Colors.blueGrey,
        useMaterial3: true,
      ),
      home: const BreakReminderHome(),
    );
  }
}

class BreakReminderHome extends StatelessWidget {
  const BreakReminderHome({super.key});

  String _getTitleText(BreakTimerService service) {
    switch (service.currentState) {
      case TimerState.idle:
        return "Ready to Start Work";
      case TimerState.working:
        return "Focus Time! (${BreakTimerService.workDurationMinutes} mins)";
      case TimerState.notifying:
        return "BREAK TIME! 🔔";
      case TimerState.breaking:
        return "2-Minute Walk";
    }
  }

  Color _getColor(BreakTimerService service) {
    switch (service.currentState) {
      case TimerState.idle:
        return Colors.blueGrey.shade700;
      case TimerState.working:
        return Colors.green.shade600;
      case TimerState.notifying:
        return Colors.red.shade600;
      case TimerState.breaking:
        return Colors.amber.shade600;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Access the service using Provider.of, reading changes
    final service = Provider.of<BreakTimerService>(context);
    final color = _getColor(service);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Modular Break Reminder'),
        backgroundColor: Colors.blueGrey,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // Status Header
            Text(
              _getTitleText(service),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 40),

            // Timer Display
            Container(
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 4),
              ),
              child: Text(
                service.formattedTime,
                style: TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.w100,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 40),

            // Control Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Start Work Button (Visible only when Idle)
                if (service.currentState == TimerState.idle)
                  ElevatedButton.icon(
                    onPressed: service.startWorkCycle,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start Work (45 min)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      textStyle: const TextStyle(fontSize: 18),
                    ),
                  ),

                // Start Break Button (Visible only when Notifying)
                if (service.currentState == TimerState.notifying)
                  ElevatedButton.icon(
                    onPressed: service.startBreak,
                    icon: const Icon(Icons.directions_walk),
                    label: const Text('Start 2 Min Break'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      textStyle: const TextStyle(fontSize: 18),
                    ),
                  ),

                // Pause/Resume Button (Visible during Work or Break)
                if (service.currentState == TimerState.working ||
                    service.currentState == TimerState.breaking)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: ElevatedButton.icon(
                      onPressed: service.pauseResume,
                      icon: Icon(service.isRunning ? Icons.pause : Icons.play_arrow),
                      label: Text(service.isRunning ? 'Pause' : 'Resume'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        textStyle: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),

                // Stop Button (Visible when not Idle)
                if (service.currentState != TimerState.idle)
                  ElevatedButton.icon(
                    onPressed: service.stop,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop Cycle'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      textStyle: const TextStyle(fontSize: 18),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 60),

            // Module Status
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Module Status: BreakTimerService is Active.',
                style: TextStyle(color: Colors.grey.shade600),
                textAlign: TextAlign.center,
              ),
            )
          ],
        ),
      ),
    );
  }
}