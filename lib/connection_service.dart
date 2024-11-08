import 'dart:async';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'database_helper.dart';

class ConnectionService {
  final InternetConnection connectivity =
      InternetConnection.createInstance(checkInterval: Duration(seconds: 1));
  final DatabaseHelper _dbHelper = DatabaseHelper();
  late StreamSubscription _subscription;

  DateTime? _lastDisconnectedTime;
  Timer? _countdownTimer;
  Timer? _disconnectedCountdownTimer;
  final StreamController<int> _countdownStreamController =
      StreamController<int>.broadcast();

  final StreamController<int> _disconnectedCountdownStreamController =
      StreamController<int>.broadcast();

  Stream<int> get countdownStream => _countdownStreamController.stream;

  Stream<int> get disconnectedCountdownStream =>
      _disconnectedCountdownStreamController.stream;

  Future<void> init() async {
    _subscription = connectivity.onStatusChange.listen(_updateConnectionStatus);
    _startCountdown();
  }

  Future<void> _updateConnectionStatus(InternetStatus status) async {
    DateTime now = DateTime.now();
    if (status == InternetStatus.disconnected) {
      _lastDisconnectedTime = now;
      await _dbHelper.logDisconnect(now);
      _startDisconnectedCountdown();
      _resetCountdown();
    } else if (status == InternetStatus.connected) {
      if (_lastDisconnectedTime != null) {
        await _dbHelper.logReconnect(now);
      }
      _lastDisconnectedTime = null;
      _startCountdown();
      _resetDisconnectedCountdown();
    }
  }

  Future<List<Map<String, dynamic>>> getDisconnectHistory() async {
    return await _dbHelper.getAllLogs();
  }

  Future<double> calculateAverageDisconnectDuration() async {
    final logs = await _dbHelper.getAllLogs();
    int totalDuration = 0;
    int disconnectCount = 0;

    for (var log in logs) {
      if (log['reconnectTime'] != null) {
        int disconnectTime = log['disconnectTime'] as int;
        int reconnectTime = log['reconnectTime'] as int;
        totalDuration += (reconnectTime - disconnectTime);
        disconnectCount++;
      }
    }

    return disconnectCount == 0 ? 0 : totalDuration / disconnectCount / 1000;
  }

  Future<double> calculateAverageConnectionDuration() async {
    final logs = await _dbHelper.getAllLogs();
    int totalDuration = 0;
    int connectionCount = 0;

    DateTime? lastConnect;
    for (var log in logs) {
      if (log['disconnectTime'] != null && log['reconnectTime'] != null) {
        if (lastConnect != null) {
          int connectDuration = (log['disconnectTime'] as int) -
              lastConnect.millisecondsSinceEpoch;
          totalDuration += connectDuration;
          connectionCount++;
        }
        lastConnect =
            DateTime.fromMillisecondsSinceEpoch(log['reconnectTime'] as int);
      }
    }

    return connectionCount == 0 ? 0 : totalDuration / connectionCount / 1000;
  }

  void _startCountdown() async {
    double avgConnectionDuration = await calculateAverageConnectionDuration();
    if (avgConnectionDuration == 0) return;

    int countdownSeconds = avgConnectionDuration.toInt();
    _countdownTimer?.cancel();
    _countdownStreamController.add(countdownSeconds);

    _countdownTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      countdownSeconds--;
      if (countdownSeconds <= 0) {
        _countdownStreamController.add(0);
        timer.cancel();
      } else {
        _countdownStreamController.add(countdownSeconds);
      }
    });
  }

  void _startDisconnectedCountdown() async {
    double avgDisconnectionDuration =
        await calculateAverageDisconnectDuration();
    if (avgDisconnectionDuration == 0) return;
    int countdownSeconds = avgDisconnectionDuration.toInt();
    _disconnectedCountdownTimer?.cancel();
    _disconnectedCountdownStreamController.add(countdownSeconds);

    _disconnectedCountdownTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      countdownSeconds--;
      if (countdownSeconds <= 0) {
        _disconnectedCountdownStreamController.add(0);
        timer.cancel();
      } else {
        _disconnectedCountdownStreamController.add(countdownSeconds);
      }
    });
  }

  void _resetDisconnectedCountdown() {
    _disconnectedCountdownTimer?.cancel();
    _disconnectedCountdownStreamController.add(0);
  }

  void _resetCountdown() {
    _countdownTimer?.cancel();
    _countdownStreamController.add(0);
  }

  void dispose() {
    _subscription.cancel();
    _countdownTimer?.cancel();
    _countdownStreamController.close();
  }
}
