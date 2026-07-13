import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'connection_service.dart';
import 'package:intl/intl.dart';
import 'logger.dart';

/// Three responsive tiers used throughout the dashboard.
enum _ScreenSize { compact, medium, wide }

class _Palette {
  static const bg = Color(0xFF10131A);
  static const surface = Color(0xFF1A1E27);
  static const surfaceRaised = Color(0xFF222733);
  static const hairline = Color(0xFF2B303C);

  static const textPrimary = Color(0xFFEDEFF3);
  static const textSecondary = Color(0xFF8D95A5);
  static const textTertiary = Color(0xFF5B6272);

  static const signalUp = Color(0xFF3DDC97);
  static const signalDown = Color(0xFFFF5C5C);
  static const accentWan = Color(0xFF5B9DF9);
  static const accentLan = Color(0xFFB18CFF);
}

const _monoFeatures = [ui.FontFeature.tabularFigures()];

class ConnectionStatusApp extends StatefulWidget {
  const ConnectionStatusApp({super.key});

  @override
  ConnectionStatusAppState createState() => ConnectionStatusAppState();
}

class ConnectionStatusAppState extends State<ConnectionStatusApp> {
  final ConnectionService _connectionService = ConnectionService();

  final List<StreamSubscription> _subscriptions = [];
  bool _isConnected = true;
  double _averageDisconnectDuration = 0;
  double _averageConnectionDuration = 0;
  List<Map<String, dynamic>> _disconnectHistory = [];
  List<Map<String, dynamic>> _disconnectHistoryToday = [];

  int _countdown = 0;
  int _disconnectedCountdown = 0;
  int _disconnectedCounter = 0;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    await _connectionService.init();
    _syncStateFromActiveTracker();
    _hookUpStreams();
    _refreshData();
  }

  void _syncStateFromActiveTracker() {
    final tracker = _connectionService.activeTracker;
    _isConnected = tracker.isConnected;
    _disconnectedCounter = tracker.elapsedInCurrentStateSeconds;
    _countdown = 0;
    _disconnectedCountdown = 0;
  }

  void _hookUpStreams() {
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    final activeTracker = _connectionService.activeTracker;

    _subscriptions.add(
      activeTracker.statusStream.listen((status) async {
        if (mounted) {
          setState(() => _isConnected = status == InternetStatus.connected);
          await Future.delayed(const Duration(milliseconds: 200));
          _refreshData();
        }
      }),
    );

    _subscriptions.add(
      activeTracker.countdownStream.listen((data) {
        if (mounted) {
          setState(() {
            _countdown = data["average"];
          });
        }
      }),
    );

    _subscriptions.add(
      activeTracker.disconnectedCountdownStream.listen((seconds) {
        if (mounted) setState(() => _disconnectedCountdown = seconds);
      }),
    );

    _subscriptions.add(
      activeTracker.lastDisconnectedCounterStream.listen((seconds) {
        if (mounted) setState(() => _disconnectedCounter = seconds);
      }),
    );
  }

  Future<void> _refreshData() async {
    final activeTracker = _connectionService.activeTracker;
    double avgDisconnect = await activeTracker
        .calculateAverageDisconnectDuration();
    double avgConnection = await activeTracker
        .calculateAverageConnectionDuration();
    final history = await activeTracker.getDisconnectHistory();

    if (mounted) {
      setState(() {
        _averageDisconnectDuration = avgDisconnect;
        _averageConnectionDuration = avgConnection;
        _disconnectHistory = history;
        _disconnectHistoryToday = _disconnectHistory.where((log) {
          return DateUtils.isSameDay(
            DateTime.fromMillisecondsSinceEpoch(log['disconnectTime'] as int),
            DateTime.now(),
          );
        }).toList();
      });
    }
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m ${secs}s';
    if (minutes > 0) return '${minutes}m ${secs}s';
    return '${secs}s';
  }

  String _formatTimeDiff(DateTime from, DateTime to) {
    final diff = to.difference(from);
    return '${diff.inHours}h ${diff.inMinutes % 60}m ${diff.inSeconds % 60}s';
  }

  void _switchView(TrackingMode mode) {
    if (_connectionService.activeViewMode == mode) return;
    _connectionService.switchViewMode(mode);
    setState(_syncStateFromActiveTracker);
    _hookUpStreams();
    _refreshData();
  }

  Future<void> _confirmDeleteLog(Map<String, dynamic> log) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _Palette.surfaceRaised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "Delete event?",
          style: TextStyle(
            color: _Palette.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: const Text(
          "This removes it from the log and recalculates your averages from "
          "what's left. Can't be undone.",
          style: TextStyle(color: _Palette.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              "Cancel",
              style: TextStyle(color: _Palette.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              "Delete",
              style: TextStyle(
                color: _Palette.signalDown,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final success = await _connectionService.activeTracker.deleteLogEntry(log);
    if (!mounted) return;

    if (success) {
      await _refreshData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _Palette.surfaceRaised,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          content: const Text(
            "Event deleted",
            style: TextStyle(color: _Palette.textPrimary),
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _Palette.surfaceRaised,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          content: const Text(
            "Couldn't delete that event — see logs",
            style: TextStyle(color: _Palette.signalDown),
          ),
        ),
      );
    }
  }

  _ScreenSize _sizeOf(double width) {
    if (width >= 1080) return _ScreenSize.wide;
    if (width >= 640) return _ScreenSize.medium;
    return _ScreenSize.compact;
  }

  ThemeData _buildOpsTheme(BuildContext context) {
    final base = Theme.of(context);
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _Palette.bg,
      splashFactory: NoSplash.splashFactory,
      colorScheme: const ColorScheme.dark(
        surface: _Palette.surface,
        onSurface: _Palette.textPrimary,
        primary: _Palette.signalUp,
        error: _Palette.signalDown,
        outline: _Palette.hairline,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: _Palette.textPrimary,
        displayColor: _Palette.textPrimary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _buildOpsTheme(context),
      child: Builder(
        builder: (context) {
          return Scaffold(
            backgroundColor: _Palette.bg,
            appBar: AppBar(
              backgroundColor: _Palette.bg,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              titleSpacing: 20,
              title: const Text(
                "NETWORK MONITOR",
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  letterSpacing: 2.2,
                  color: _Palette.textPrimary,
                ),
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Container(height: 1, color: _Palette.hairline),
              ),
              actions: [
                IconButton(
                  tooltip: "Application Logs",
                  icon: const Icon(
                    Icons.terminal_rounded,
                    color: _Palette.textSecondary,
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => TalkerScreen(talker: talker),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = _sizeOf(constraints.maxWidth);
                  if (size == _ScreenSize.wide) {
                    return _buildWideLayout();
                  }
                  return _buildStackedLayout(size);
                },
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Layouts
  // ---------------------------------------------------------------------

  /// Wide: a fixed-width status rail (controls + the merged status/stats
  /// panel) next to an expanded, independently scrolling event log. The
  /// rail doesn't need to grow with the window — only the log does — so it
  /// gets a fixed width instead of a flex share, which is what made the
  /// old two-pane view feel unbalanced.
  Widget _buildWideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 380,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              children: [
                _buildControlPanel(_ScreenSize.wide),
                _buildStatusPanel(_ScreenSize.wide),
              ],
            ),
          ),
        ),
        Container(width: 1, color: _Palette.hairline),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _buildHistoryHeader()),
              _buildHistoryTimeline(),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStackedLayout(_ScreenSize size) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildControlPanel(size)),
        SliverToBoxAdapter(child: _buildStatusPanel(size)),
        SliverToBoxAdapter(child: _buildHistoryHeader()),
        _buildHistoryTimeline(),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Control panel
  // ---------------------------------------------------------------------

  Widget _buildControlPanel(_ScreenSize size) {
    final compact = size == _ScreenSize.compact;
    final toggle = _ModeToggle(
      value: _connectionService.activeViewMode,
      onChanged: _switchView,
    );
    final button = _newSeriesButton();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: compact
          ? Column(
              children: [
                SizedBox(width: double.infinity, child: toggle),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: button),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [toggle, const SizedBox(height: 10), button],
            ),
    );
  }

  Widget _newSeriesButton() {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: _Palette.textPrimary,
        backgroundColor: _Palette.surface,
        side: const BorderSide(color: _Palette.hairline),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: () async {
        await _connectionService.activeTracker.startNewSeries();
        _refreshData();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: _Palette.surfaceRaised,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              content: Text(
                "New ${_connectionService.activeViewMode.name.toUpperCase()} series started",
                style: const TextStyle(color: _Palette.textPrimary),
              ),
            ),
          );
        }
      },
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text(
        "NEW SERIES",
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Status panel: hero readout + stats ribbon, one physical card.
  // Replaces the old separate hero card + boxed 2x2 stats grid — this is
  // the "what's placed where" fix: related numbers live in one panel with
  // a clear primary/secondary hierarchy, instead of being scattered across
  // differently-styled blocks of similar visual weight.
  // ---------------------------------------------------------------------

  Widget _buildStatusPanel(_ScreenSize size) {
    final compact = size == _ScreenSize.compact;
    final signal = _isConnected ? _Palette.signalUp : _Palette.signalDown;
    final modeLabel = _connectionService.activeViewMode == TrackingMode.external
        ? "EXTERNAL — WAN"
        : "INTERNAL — LAN";
    final statusWord = _isConnected ? "ONLINE" : "OFFLINE";
    final heroLabel = _isConnected ? "CURRENT UPTIME" : "CURRENT DOWNTIME";
    final subLabel = _isConnected ? "EST. NEXT DROP" : "EST. RECONNECT";
    final subValue = _isConnected
        ? (_countdown > 0 ? _formatDuration(_countdown) : '—')
        : (_disconnectedCountdown > 0
              ? _formatDuration(_disconnectedCountdown)
              : '—');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: _Palette.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: signal.withValues(alpha: 0.35), width: 1),
        ),
        child: Column(
          children: [
            // --- Primary readout ---
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 20 : 24,
                compact ? 18 : 22,
                compact ? 20 : 24,
                compact ? 16 : 18,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _PulseDot(color: signal),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          modeLabel,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                            color: _Palette.textSecondary,
                          ),
                        ),
                      ),
                      Text(
                        statusWord,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          color: signal,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 14 : 18),
                  Text(
                    heroLabel,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                      color: _Palette.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatDuration(_disconnectedCounter),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontFeatures: _monoFeatures,
                      fontSize: compact ? 32 : 40,
                      fontWeight: FontWeight.w700,
                      color: _Palette.textPrimary,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        "$subLabel  ",
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: _Palette.textTertiary,
                        ),
                      ),
                      Text(
                        subValue,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontFeatures: _monoFeatures,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _Palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Container(height: 1, color: _Palette.hairline),
            // --- Secondary metrics ribbon ---
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 16 : 20,
                vertical: compact ? 14 : 16,
              ),
              child: _statsRibbon(compact),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statsRibbon(bool compact) {
    final cells = [
      _ribbonCell(
        "AVG UPTIME",
        _formatDuration(_averageConnectionDuration.toInt()),
        _Palette.signalUp,
      ),
      _ribbonCell(
        "AVG DOWNTIME",
        _formatDuration(_averageDisconnectDuration.toInt()),
        _Palette.signalDown,
      ),
      _ribbonCell(
        "TOTAL DROPS",
        "${_disconnectHistory.length}",
        _Palette.accentLan,
      ),
      _ribbonCell(
        "DROPS TODAY",
        "${_disconnectHistoryToday.length}",
        _Palette.accentWan,
      ),
    ];

    if (compact) {
      return Column(
        children: [
          Row(
            children: [
              Expanded(child: cells[0]),
              _ribbonDivider(),
              Expanded(child: cells[1]),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: cells[2]),
              _ribbonDivider(),
              Expanded(child: cells[3]),
            ],
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: cells[0]),
        _ribbonDivider(),
        Expanded(child: cells[1]),
        _ribbonDivider(),
        Expanded(child: cells[2]),
        _ribbonDivider(),
        Expanded(child: cells[3]),
      ],
    );
  }

  Widget _ribbonDivider() => Container(
    width: 1,
    height: 30,
    margin: const EdgeInsets.symmetric(horizontal: 12),
    color: _Palette.hairline,
  );

  Widget _ribbonCell(String label, String value, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.9,
            color: _Palette.textTertiary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'monospace',
            fontFeatures: _monoFeatures,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: accent,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Event log
  // ---------------------------------------------------------------------

  Widget _buildHistoryHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            "EVENT LOG",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
              color: _Palette.textSecondary,
            ),
          ),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: _Palette.surfaceRaised,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _Palette.hairline),
                ),
                child: Text(
                  "SERIES #${_connectionService.activeTracker.currentSeriesId}",
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontFeatures: _monoFeatures,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _Palette.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryTimeline() {
    if (_disconnectHistory.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(40.0),
          child: Center(
            child: Column(
              children: const [
                Icon(Icons.dns_rounded, size: 26, color: _Palette.textTertiary),
                SizedBox(height: 10),
                Text(
                  "No events recorded in this series yet.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _Palette.textTertiary, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final reversedOrder = _disconnectHistory.reversed.toList();

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final log = reversedOrder[index];
          final tDisconnect = DateTime.fromMillisecondsSinceEpoch(
            log['disconnectTime'] as int,
          );
          final tReconnect = log['reconnectTime'] != null
              ? DateTime.fromMillisecondsSinceEpoch(log['reconnectTime'] as int)
              : null;
          final ongoing = tReconnect == null;
          final dotColor = ongoing ? _Palette.signalDown : _Palette.signalUp;

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
            decoration: BoxDecoration(
              color: _Palette.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: ongoing
                    ? _Palette.signalDown.withValues(alpha: 0.35)
                    : _Palette.hairline,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dotColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              DateFormat(
                                'MMM dd · HH:mm:ss',
                              ).format(tDisconnect),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontFeatures: _monoFeatures,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _Palette.textPrimary,
                              ),
                            ),
                          ),
                          if (ongoing)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: _Palette.signalDown.withValues(
                                  alpha: 0.12,
                                ),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text(
                                "ONGOING",
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1,
                                  color: _Palette.signalDown,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (!ongoing)
                        Text(
                          "→ restored ${DateFormat('HH:mm:ss').format(tReconnect)}  ·  down ${_formatTimeDiff(tDisconnect, tReconnect)}",
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontFeatures: _monoFeatures,
                            fontSize: 12,
                            color: _Palette.textSecondary,
                          ),
                        )
                      else
                        const Text(
                          "connection has not recovered",
                          style: TextStyle(
                            fontSize: 12,
                            color: _Palette.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: "Delete this event",
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: _Palette.textTertiary,
                  ),
                  onPressed: () => _confirmDeleteLog(log),
                ),
              ],
            ),
          );
        }, childCount: reversedOrder.length),
      ),
    );
  }

  @override
  void dispose() {
    for (var sub in _subscriptions) {
      sub.cancel();
    }
    _connectionService.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------
// Small bespoke widgets
// ---------------------------------------------------------------------

class _ModeToggle extends StatelessWidget {
  final TrackingMode value;
  final ValueChanged<TrackingMode> onChanged;

  const _ModeToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isExternal = value == TrackingMode.external;
    return Container(
      height: 42,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _Palette.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: _Palette.hairline),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: isExternal
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: _Palette.surfaceRaised,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        (isExternal ? _Palette.accentWan : _Palette.accentLan)
                            .withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _segment(
                  selected: isExternal,
                  icon: Icons.public_rounded,
                  label: "WAN",
                  accent: _Palette.accentWan,
                  onTap: () => onChanged(TrackingMode.external),
                ),
              ),
              Expanded(
                child: _segment(
                  selected: !isExternal,
                  icon: Icons.router_rounded,
                  label: "LAN",
                  accent: _Palette.accentLan,
                  onTap: () => onChanged(TrackingMode.internal),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _segment({
    required bool selected,
    required IconData icon,
    required String label,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 16,
            color: selected ? accent : _Palette.textTertiary,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: selected ? _Palette.textPrimary : _Palette.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;

  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.35 + t * 0.35),
                blurRadius: 6 + t * 10,
                spreadRadius: 1 + t * 2,
              ),
            ],
          ),
        );
      },
    );
  }
}
