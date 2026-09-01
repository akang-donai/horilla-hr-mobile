import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'attendance_views/attendance_attendance.dart';
import 'attendance_views/attendance_overview.dart';
import 'attendance_views/attendance_request.dart';
import 'attendance_views/hour_account.dart';
import 'attendance_views/my_attendance_view.dart';
import 'checkin_checkout/checkin_checkout_views/checkin_checkout_form.dart';
import 'package:camera/camera.dart';
import 'checkin_checkout/checkin_checkout_views/setup_imageface.dart';
import 'employee_views/employee_form.dart';
import 'employee_views/employee_list.dart';
import 'horilla_leave/all_assigned_leave.dart';
import 'horilla_leave/leave_allocation_request.dart';
import 'horilla_leave/leave_overview.dart';
import 'horilla_leave/leave_request.dart';
import 'horilla_leave/leave_types.dart';
import 'horilla_leave/my_leave_request.dart';
import 'horilla_leave/selected_leave_type.dart';
import 'horilla_main/login.dart';
import 'horilla_main/home.dart';
import 'horilla_main/notifications_list.dart';
import 'core/api_client.dart';
import 'core/session.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
FlutterLocalNotificationsPlugin();

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
int currentPage = 1;
bool isFirstFetch = true;
Set<int> seenNotificationIds = {};
List<Map<String, dynamic>> notifications = [];
int notificationsCount = 0;
bool isLoading = true;
Timer? _notificationTimer;
late Map<String, dynamic> arguments = {};
List<Map<String, dynamic>> fetchedNotifications = [];
Map<String, dynamic> newNotificationList = {};
bool isAuthenticated = false;

@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse notificationResponse) async {
  if (!isAuthenticated) return;

  print('notification(${notificationResponse.id}) action tapped: '
      '${notificationResponse.actionId} with'
      ' payload: ${notificationResponse.payload}');
  if (notificationResponse.input?.isNotEmpty ?? false) {
    final context = await navigatorKey.currentState?.context;
    if (context != null) {
      _onSelectNotification(context);
    }
    print('notification action tapped with input: ${notificationResponse.input}');
  }
}

void _startNotificationTimer() {
  _notificationTimer?.cancel();
  _notificationTimer = Timer.periodic(Duration(seconds: 60), (timer) {
    if (isAuthenticated) {
      fetchNotifications();
      unreadNotificationsCount();
    } else {
      timer.cancel();
      _notificationTimer = null;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const AndroidInitializationSettings initializationSettingsAndroid =
  AndroidInitializationSettings('@mipmap/horilla_logo');

  final DarwinInitializationSettings initializationSettingsIOS =
  DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );

  final InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse details) async {
      final context = await navigatorKey.currentState?.context;
      if (context != null && isAuthenticated) {
        _onSelectNotification(context);
      }
    },
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  await ApiClient.instance.init();
  ApiClient.instance.onSessionExpired = () async {
    isAuthenticated = false;
    await Session.instance.clear();
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (route) => false);
  };

  final access = await Session.instance.access;
  isAuthenticated = access != null;

  if (isAuthenticated) {
    _startNotificationTimer();
    prefetchData();
  }

  runApp(LoginApp());
  clearSharedPrefs();
}

void clearSharedPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('clockCheckedIn');
  await prefs.remove('checkout');
  await prefs.remove('checkin');
}

void _onSelectNotification(BuildContext context) {
  Navigator.pushNamed(context, '/notifications_list');
  markAllReadNotification();
}

void _showNotification() async {
  if (!isAuthenticated) return;
  FlutterRingtonePlayer().playNotification();
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
  AndroidNotificationDetails(
      'your_channel_id',
      'your_channel_name',
      channelDescription: 'your_channel_description',
      importance: Importance.max,
      priority: Priority.high,
      playSound: false,
      silent: true
  );

  const NotificationDetails platformChannelSpecifics =
  NotificationDetails(android: androidPlatformChannelSpecifics);
  final timestamp = DateTime.parse(newNotificationList['timestamp']);
  final timeAgo = timeago.format(timestamp);
  final user = arguments['employee_name'];
  print('$timeAgo by User $user');

  await flutterLocalNotificationsPlugin.show(
    newNotificationList['id'],
    newNotificationList['verb'],
    '$timeAgo by User',
    platformChannelSpecifics,
    payload: 'your_payload',
  );
}

Future<void> prefetchData() async {
  if (!isAuthenticated) return;

  final prefs = await SharedPreferences.getInstance();
  var employeeId = prefs.getInt("employee_id");

  if (employeeId == null) return;

  var response = await ApiClient.instance.get('/api/employee/employees/$employeeId');

  if (response.statusCode == 200) {
    final responseData = jsonDecode(response.body);
    arguments = {
      'employee_id': responseData['id'],
      'employee_name': responseData['employee_first_name'] +
          ' ' +
          responseData['employee_last_name'],
      'badge_id': responseData['badge_id'],
      'email': responseData['email'],
      'phone': responseData['phone'],
      'date_of_birth': responseData['dob'],
      'gender': responseData['gender'],
      'address': responseData['address'],
      'country': responseData['country'],
      'state': responseData['state'],
      'city': responseData['city'],
      'qualification': responseData['qualification'],
      'experience': responseData['experience'],
      'marital_status': responseData['marital_status'],
      'children': responseData['children'],
      'emergency_contact': responseData['emergency_contact'],
      'emergency_contact_name': responseData['emergency_contact_name'],
      'employee_work_info_id': responseData['employee_work_info_id'],
      'employee_bank_details_id': responseData['employee_bank_details_id'],
      'employee_profile': responseData['employee_profile'],
      'job_position_name': responseData['job_position_name']
    };
  }
}

Future<void> markAllReadNotification() async {
  if (!isAuthenticated) return;

  var response = await ApiClient.instance.post('/api/notifications/notifications/bulk-read/');

  if (response.statusCode == 200) {
    notifications.clear();
    unreadNotificationsCount();
    fetchNotifications();
  }
}

Future<void> fetchNotifications() async {
  if (!isAuthenticated) {
    print('Notification fetch stopped - unauthenticated');
    return;
  }

  try {
    print('Fetching notifications...');
    var response = await ApiClient.instance.get(
        '/api/notifications/notifications/list/unread?page=${currentPage == 0 ? 1 : currentPage}')
        .timeout(Duration(seconds: 3));

    if (response.statusCode == 200) {
      List<Map<String, dynamic>> fetchedNotifications =
      List<Map<String, dynamic>>.from(
        jsonDecode(response.body)['results']
            .where((notification) => notification['deleted'] == false)
            .toList(),
      );

      if (fetchedNotifications.isNotEmpty) {
        newNotificationList = fetchedNotifications[0];
        List<int> newNotificationIds = fetchedNotifications
            .map((notification) => notification['id'] as int)
            .toList();

        bool hasNewNotifications = newNotificationIds.any((id) => !seenNotificationIds.contains(id));

        if (!isFirstFetch && hasNewNotifications) {
          _playNotificationSound();
        }

        seenNotificationIds.addAll(newNotificationIds);
        notifications = fetchedNotifications;
        notificationsCount = jsonDecode(response.body)['count'];
        isFirstFetch = false;
        final timestamp = DateTime.parse(newNotificationList['timestamp']);
        final timeAgo = timeago.format(timestamp);
        final user = arguments['employee_name'];
        print('$timeAgo by User $user');
        isLoading = false;
      } else {
        print("No notifications available.");
      }
    } else {
      print('Notification fetch failed with status: ${response.statusCode}');
    }
  } on SocketException catch (e) {
    print('Connection error fetching notifications: $e');
  } on TimeoutException catch (e) {
    print('Timeout fetching notifications: $e');
  } on Exception catch (e) {
    print('Error fetching notifications: $e');
  }
}

Future<void> unreadNotificationsCount() async {
  if (!isAuthenticated) return;

  var response = await ApiClient.instance.get('/api/notifications/notifications/list/unread');

  if (response.statusCode == 200) {
    notificationsCount = jsonDecode(response.body)['count'];
    isLoading = false;
  }
}

void _playNotificationSound() {
  if (!isAuthenticated) return;
  _showNotification();
}

class LoginApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Login Page',
      navigatorKey: navigatorKey,
      home: FutureBuilderPage(),
      routes: {
        '/login': (context) => LoginPage(),
        '/home': (context) => HomePage(),
        '/employees_list': (context) => EmployeeListPage(),
        '/employees_form': (context) => EmployeeFormPage(),
        '/attendance_overview': (context) => AttendanceOverview(),
        '/attendance_attendance': (context) => AttendanceAttendance(),
        '/attendance_request': (context) => AttendanceRequest(),
        '/my_attendance_view': (context) => MyAttendanceViews(),
        '/employee_hour_account': (context) => HourAccountFormPage(),
        '/employee_checkin_checkout': (context) => CheckInCheckOutFormPage(),
        '/setup_imageface': (context) => _CameraLoader(),
        '/leave_overview': (context) => LeaveOverview(),
        '/leave_types': (context) => LeaveTypes(),
        '/my_leave_request': (context) => MyLeaveRequest(),
        '/leave_request': (context) => LeaveRequest(),
        '/leave_allocation_request': (context) => LeaveAllocationRequest(),
        '/all_assigned_leave': (context) => AllAssignedLeave(),
        '/selected_leave_type': (context) => SelectedLeaveType(),
        '/notifications_list': (context) => NotificationsList(),
      },
    );
  }
}

class SplashScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'Assets/horilla-logo.png',
              width: 150,
              height: 150,
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraLoader extends StatefulWidget {
  @override
  State<_CameraLoader> createState() => _CameraLoaderState();
}

class _CameraLoaderState extends State<_CameraLoader> {
  @override
  void initState() {
    super.initState();
    _loadCameras();
  }

  Future<void> _loadCameras() async {
    final cameras = await availableCameras();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => CameraSetupPage(cameras: cameras)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class FutureBuilderPage extends StatefulWidget {
  const FutureBuilderPage({super.key});

  @override
  State<FutureBuilderPage> createState() => _FutureBuilderPageState();
}

class _FutureBuilderPageState extends State<FutureBuilderPage> {
  late Future<bool> _futurePath;

  @override
  void initState() {
    super.initState();
    _futurePath = _initialize();
  }

  Future<bool> _initialize() async {
    final access = await Session.instance.access;
    return access != null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: Future.delayed(const Duration(seconds: 2), () => _futurePath),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SplashScreen();
        }

        if (snapshot.connectionState == ConnectionState.done) {
          if (snapshot.hasData && snapshot.data == true) {
            return const HomePage();
          } else {
            return LoginPage();
          }
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
