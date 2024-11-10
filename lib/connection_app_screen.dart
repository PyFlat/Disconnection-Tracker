import 'package:flutter/material.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'connection_service.dart';
import 'package:intl/intl.dart';
import 'logger.dart';

class ConnectionStatusApp extends StatefulWidget {
  const ConnectionStatusApp({super.key});

  @override
  ConnectionStatusAppState createState() => ConnectionStatusAppState();
}

class ConnectionStatusAppState extends State<ConnectionStatusApp> {
  final ConnectionService _connectionService = ConnectionService();
  bool _isConnected = true;
  double _averageDisconnectDuration = 0;
  double _averageConnectionDuration = 0;
  List<Map<String, dynamic>> _disconnectHistory = [];
  List<Map<String, dynamic>> _disconnectHistoryToday = [];
  int _countdown = 0;
  int _countdownLowest = 0;
  int _disconnectedCountdown = 0;
  int _disconnectedCounter = 0;

  @override
  void initState() {
    super.initState();
    _connectionService.init();
    _updateAverages();
    _loadDisconnectHistory();

    _connectionService.connectivity.onStatusChange.listen((status) async {
      setState(() {
        _isConnected = status == InternetStatus.connected;
      });
      await Future.delayed(Duration(milliseconds: 200));
      _updateAverages();
      _loadDisconnectHistory();
    });

    _connectionService.countdownStream.listen((data) {
      setState(() {
        _countdown = data["average"];
        _countdownLowest = data["lowest"];
      });
    });

    _connectionService.disconnectedCountdownStream.listen((seconds) {
      setState(() {
        _disconnectedCountdown = seconds;
      });
    });

    _connectionService.lastDisconnectedCounterStream.listen((seconds) {
      setState(() {
        _disconnectedCounter = seconds;
      });
    });
  }

  Future<void> _updateAverages() async {
    double avgDisconnect =
        await _connectionService.calculateAverageDisconnectDuration();
    double avgConnection =
        await _connectionService.calculateAverageConnectionDuration();
    setState(() {
      _averageDisconnectDuration = avgDisconnect;
      _averageConnectionDuration = avgConnection;
    });
  }

  Future<void> _loadDisconnectHistory() async {
    final history = await _connectionService.getDisconnectHistory();
    setState(() {
      _disconnectHistory = history;
      _disconnectHistoryToday =
          _disconnectHistory.where((test) {
            return DateUtils.isSameDay(
              DateTime.fromMillisecondsSinceEpoch(
                test['disconnectTime'] as int,
              ),
              DateTime.now(),
            );
          }).toList();
    });
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final remainingSeconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m ${remainingSeconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${remainingSeconds}s';
    } else {
      return '${remainingSeconds}s';
    }
  }

  String _formatTimeDifference(DateTime from, DateTime to) {
    final duration = to.difference(from);
    return '${duration.inHours}h ${duration.inMinutes % 60}m ${duration.inSeconds % 60}s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Connection Status Tracker"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: IconButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => TalkerScreen(talker: talker),
                  ),
                );
              },
              icon: Icon(Icons.my_library_books_rounded),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              _isConnected
                  ? "Connected to the Internet"
                  : "No Internet Connection",
              style: TextStyle(
                fontSize: 24,
                color: _isConnected ? Colors.green : Colors.red,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "Average Disconnection Duration: ${_formatDuration(_averageDisconnectDuration.toInt())}",
              style: TextStyle(fontSize: 18),
            ),
            Text(
              "Average Connection Duration: ${_formatDuration(_averageConnectionDuration.toInt())}",
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 20),
            if (_isConnected)
              Text(
                "Time since last disconnect: ${_formatDuration(_disconnectedCounter)}",
                style: TextStyle(fontSize: 18, color: Colors.pinkAccent),
              ),
            if (_isConnected) const SizedBox(height: 20),
            if (_isConnected)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Estimated time until next disconnect: ${_countdown > 0 ? _formatDuration(_countdown) : 0}",
                    style: TextStyle(
                      fontSize: 18,
                      color: _countdown > 0 ? Colors.blue : Colors.red,
                    ),
                  ),
                  SizedBox(width: 10),
                  if (_countdownLowest > 0)
                    Text(
                      "(minimum: ${_formatDuration(_countdownLowest)})",
                      style: TextStyle(fontSize: 18, color: Colors.blue),
                    ),
                ],
              ),

            if (!_isConnected)
              Text(
                "Estimated time until reconnect: ${_disconnectedCountdown > 0 ? _formatDuration(_disconnectedCountdown) : 0}",
                style: TextStyle(
                  fontSize: 18,
                  color: _disconnectedCountdown > 0 ? Colors.red : Colors.blue,
                ),
              ),
            const SizedBox(height: 20),
            Text(
              "Total Disconnects: ${_disconnectHistory.length} (Today: ${_disconnectHistoryToday.length})",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                itemCount: _disconnectHistory.length,
                itemBuilder: (context, index) {
                  final reversedOrder = _disconnectHistory.reversed.toList();
                  final log = reversedOrder[index];
                  final disconnectTime = DateTime.fromMillisecondsSinceEpoch(
                    log['disconnectTime'] as int,
                  );
                  final reconnectTime =
                      log['reconnectTime'] != null
                          ? DateTime.fromMillisecondsSinceEpoch(
                            log['reconnectTime'] as int,
                          )
                          : null;
                  final duration =
                      reconnectTime != null
                          ? _formatTimeDifference(disconnectTime, reconnectTime)
                          : 'Ongoing';

                  String timeBetweenDisconnects = '';
                  if (index < reversedOrder.length - 1) {
                    if (reversedOrder[index + 1]['reconnectTime'] != null) {
                      final previousReconnectTime =
                          DateTime.fromMillisecondsSinceEpoch(
                            reversedOrder[index + 1]['reconnectTime'] as int,
                          );
                      timeBetweenDisconnects = _formatTimeDifference(
                        previousReconnectTime,
                        disconnectTime,
                      );
                    }
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: 400),
                          child: Card(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10.0),
                            ),
                            elevation: 4,
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.wifi_off, color: Colors.red),
                                      const SizedBox(width: 8),
                                      Text(
                                        "Disconnected at: ${DateFormat("dd.MM.yyyy HH:mm:ss").format(disconnectTime)}",
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.wifi, color: Colors.green),
                                      const SizedBox(width: 8),
                                      reconnectTime != null
                                          ? Text(
                                            "Reconnected at: ${DateFormat("dd.MM.yyyy HH:mm:ss").format(reconnectTime)}",
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          )
                                          : const Text("Not yet reconnected"),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Center(
                                    child: Text(
                                      "Duration: $duration",
                                      style: TextStyle(color: Colors.grey[700]),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (timeBetweenDisconnects.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12.0),
                          child: Text(
                            "Time between disconnects: $timeBetweenDisconnects",
                            style: TextStyle(
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.bold,
                              color: Colors.blueGrey,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _connectionService.dispose();
    super.dispose();
  }
}
