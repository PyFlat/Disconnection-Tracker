import 'dart:async';
import 'dart:io';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'database_helper.dart';
import 'logger.dart';

enum TrackingMode { external, internal }

class ConnectionService {
  static final ConnectionService _instance = ConnectionService._internal();
  factory ConnectionService() => _instance;
  ConnectionService._internal();

  late final SingleModeTracker externalTracker;
  late final SingleModeTracker internalTracker;

  TrackingMode _activeViewMode = TrackingMode.external;

  TrackingMode get activeViewMode => _activeViewMode;
  SingleModeTracker get activeTracker =>
      _activeViewMode == TrackingMode.external
      ? externalTracker
      : internalTracker;

  Future<void> init() async {
    externalTracker = SingleModeTracker(TrackingMode.external);
    internalTracker = SingleModeTracker(TrackingMode.internal);
    await externalTracker.init();
    await internalTracker.init();
  }

  void switchViewMode(TrackingMode mode) {
    _activeViewMode = mode;
  }

  void dispose() {
    externalTracker.dispose();
    internalTracker.dispose();
  }
}

class SingleModeTracker {
  final TrackingMode mode;
  final DatabaseHelper _dbHelper = DatabaseHelper();

  StreamSubscription? _externalSubscription;
  Timer? _internalPingTimer;

  String internalSwitchIp = '192.168.2.34';
  final int internalPingThresholdMs = 200;
  int _highLatencyCounter = 0;

  int _currentSeriesId = 1;

  // Canonical, synchronously-readable connection state. This is the single
  // source of truth the UI should consult (e.g. right after switching tabs)
  // instead of guessing.
  bool _isCurrentlyConnected = true;
  bool get isConnected => _isCurrentlyConnected;

  // Timestamps of the last transition into each state. Used both to log to
  // the DB and to compute "how long have we been in this state" on demand,
  // synchronously, without waiting on a DB round trip.
  DateTime? _lastDisconnectedTime;
  DateTime? _lastReconnectedTime;

  /// Seconds elapsed since the tracker entered its *current* state
  /// (connected or disconnected). Safe to call at any time, e.g. immediately
  /// after switching the active tab, to seed the UI with a correct value
  /// instead of 0.
  int get elapsedInCurrentStateSeconds {
    final reference = _isCurrentlyConnected
        ? _lastReconnectedTime
        : _lastDisconnectedTime;
    if (reference == null) return 0;
    final elapsed = DateTime.now().difference(reference).inSeconds;
    return elapsed < 0 ? 0 : elapsed;
  }

  Timer? _countdownTimer;
  Timer? _disconnectedCountdownTimer;
  Timer? _elapsedTimer;

  final StreamController<Map<String, dynamic>> _countdownStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<int> _disconnectedCountdownStreamController =
      StreamController<int>.broadcast();
  // Emits seconds elapsed in the *current* state, whatever it is. Renamed
  // conceptually from "last disconnected counter" -> it now runs
  // continuously, covering both uptime and downtime, so it's always correct
  // however long you've been on a given tab.
  final StreamController<int> _elapsedStreamController =
      StreamController<int>.broadcast();
  final StreamController<InternetStatus> _statusStreamController =
      StreamController<InternetStatus>.broadcast();

  SingleModeTracker(this.mode);

  Stream<Map<String, dynamic>> get countdownStream =>
      _countdownStreamController.stream;
  Stream<int> get disconnectedCountdownStream =>
      _disconnectedCountdownStreamController.stream;
  Stream<int> get lastDisconnectedCounterStream =>
      _elapsedStreamController.stream;
  Stream<InternetStatus> get statusStream => _statusStreamController.stream;
  int get currentSeriesId => _currentSeriesId;
  String get modeName => mode.name;

  Future<void> init() async {
    _currentSeriesId = await _dbHelper.getCurrentSeriesId(modeName);
    _startTracking();
  }

  Future<void> startNewSeries() async {
    _currentSeriesId++;
    _lastDisconnectedTime = null;
    _resetCountdown();
    _resetDisconnectedCountdown();
    _startCountdown();
    talker.info(
      "Started new tracking series for ${modeName.toUpperCase()}: $_currentSeriesId",
    );
  }

  Future<bool> deleteLogEntry(Map<String, dynamic> log) async {
    return await _dbHelper.deleteLogEntry(log['id'] as int);
  }

  void _startTracking() {
    _isCurrentlyConnected = true;
    _lastReconnectedTime = DateTime.now();
    _lastDisconnectedTime = null;
    _highLatencyCounter = 0;

    // Runs continuously for the lifetime of the tracker (both modes, both
    // connection states) so whichever tab is active always has an accurate
    // "time in current state" figure, even if you switch to it mid-outage.
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedStreamController.add(elapsedInCurrentStateSeconds);
    });

    if (mode == TrackingMode.external) {
      final connectivity = InternetConnection.createInstance(
        checkInterval: const Duration(seconds: 1),
      );
      _externalSubscription = connectivity.onStatusChange.listen(
        _updateConnectionStatus,
      );
    } else {
      _internalPingTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _pingInternalSwitch(),
      );
    }
  }

  Future<void> _pingInternalSwitch() async {
    final sw = Stopwatch()..start();
    bool success = false;
    try {
      final socket = await Socket.connect(
        internalSwitchIp,
        80,
        timeout: const Duration(milliseconds: 1000),
      );
      socket.destroy();
      success = true;
    } catch (_) {}
    sw.stop();

    if (!success || sw.elapsedMilliseconds > internalPingThresholdMs) {
      _highLatencyCounter++;
      if (_highLatencyCounter >= 3 && _isCurrentlyConnected) {
        _updateConnectionStatus(InternetStatus.disconnected);
      }
    } else {
      _highLatencyCounter = 0;
      if (!_isCurrentlyConnected) {
        _updateConnectionStatus(InternetStatus.connected);
      }
    }
  }

  Future<void> _updateConnectionStatus(InternetStatus status) async {
    // Guard against redundant events (e.g. duplicate "connected" callbacks)
    // re-stamping the reference time and resetting elapsed-time to 0.
    final bool nowConnected = status == InternetStatus.connected;
    if (nowConnected == _isCurrentlyConnected) {
      _statusStreamController.add(status);
      return;
    }

    _isCurrentlyConnected = nowConnected;
    _statusStreamController.add(status);
    DateTime now = DateTime.now();

    if (!nowConnected) {
      _lastDisconnectedTime = now;
      await _dbHelper.logDisconnect(now, _currentSeriesId, modeName);
      _startDisconnectedCountdown();
      _resetCountdown();
    } else {
      if (_lastDisconnectedTime != null) {
        await _dbHelper.logReconnect(now, _currentSeriesId, modeName);
      }
      _lastReconnectedTime = now;
      _lastDisconnectedTime = null;
      _startCountdown();
      _resetDisconnectedCountdown();
    }

    // Reflect the state change immediately rather than waiting up to 1s
    // for the next elapsed-timer tick.
    _elapsedStreamController.add(elapsedInCurrentStateSeconds);
  }

  Future<List<Map<String, dynamic>>> getDisconnectHistory() async {
    return await _dbHelper.getLogsForSeries(_currentSeriesId, modeName);
  }

  Future<DateTime?> getLast({bool disconnect = false}) async {
    final lastLog = await _dbHelper.getLastLog(_currentSeriesId, modeName);
    if (lastLog == null) return null;
    final timeKey = disconnect ? "disconnectTime" : "reconnectTime";
    if (lastLog[timeKey] == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(lastLog[timeKey] as int);
  }

  Future<double> calculateAverageDisconnectDuration() async {
    final logs = await getDisconnectHistory();
    int totalDuration = 0, count = 0;
    for (var log in logs) {
      if (log['reconnectTime'] != null) {
        totalDuration +=
            (log['reconnectTime'] as int) - (log['disconnectTime'] as int);
        count++;
      }
    }
    return count == 0 ? 0 : (totalDuration / count) / 1000;
  }

  Future<double> calculateAverageConnectionDuration() async {
    final logs = await getDisconnectHistory();
    int totalDuration = 0, count = 0;
    DateTime? lastConnect;
    for (var log in logs) {
      if (log['disconnectTime'] != null && log['reconnectTime'] != null) {
        if (lastConnect != null) {
          totalDuration +=
              (log['disconnectTime'] as int) -
              lastConnect.millisecondsSinceEpoch;
          count++;
        }
        lastConnect = DateTime.fromMillisecondsSinceEpoch(
          log['reconnectTime'] as int,
        );
      }
    }
    return count == 0 ? 0 : (totalDuration / count) / 1000;
  }

  Future<double> calculateLowestConnectionDuration() async {
    final logs = await getDisconnectHistory();
    int? minDuration;
    DateTime? lastConnect;
    for (var log in logs) {
      if (log['disconnectTime'] != null && log['reconnectTime'] != null) {
        if (lastConnect != null) {
          int duration =
              (log['disconnectTime'] as int) -
              lastConnect.millisecondsSinceEpoch;
          if (minDuration == null || duration < minDuration) {
            minDuration = duration;
          }
        }
        lastConnect = DateTime.fromMillisecondsSinceEpoch(
          log['reconnectTime'] as int,
        );
      }
    }
    return minDuration == null ? 0 : minDuration / 1000;
  }

  void _startCountdown() async {
    double avg = await calculateAverageConnectionDuration();
    double lowest = await calculateLowestConnectionDuration();
    if (avg == 0 || lowest == 0) return;

    DateTime? lastReconnectedTime = await getLast();
    if (lastReconnectedTime == null) return;

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      int avgSec = lastReconnectedTime
          .add(Duration(seconds: avg.toInt()))
          .difference(DateTime.now())
          .inSeconds;
      int lowSec = lastReconnectedTime
          .add(Duration(seconds: lowest.toInt()))
          .difference(DateTime.now())
          .inSeconds;
      _countdownStreamController.add({
        "average": avgSec > 0 ? avgSec : 0,
        "lowest": lowSec > 0 ? lowSec : 0,
      });
    });
  }

  void _startDisconnectedCountdown() async {
    double avg = await calculateAverageDisconnectDuration();
    if (avg == 0) return;
    int countdownSeconds = avg.toInt();
    _disconnectedCountdownTimer?.cancel();
    _disconnectedCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
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
    _countdownStreamController.add({"average": 0, "lowest": 0});
  }

  void dispose() {
    _externalSubscription?.cancel();
    _internalPingTimer?.cancel();
    _countdownTimer?.cancel();
    _disconnectedCountdownTimer?.cancel();
    _elapsedTimer?.cancel();
    _countdownStreamController.close();
    _disconnectedCountdownStreamController.close();
    _elapsedStreamController.close();
    _statusStreamController.close();
  }
}
