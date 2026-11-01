import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:temp/models/sensor_reading.dart';
import 'package:temp/services/ble_service.dart';
import 'package:temp/services/weather_service.dart';
import 'package:temp/widgets/first_run_guide.dart';

const _windowsChannel = MethodChannel('temp/windows');

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
  }
  runApp(
    SensorApp(
      initialWidgetMode:
          args.contains('--widget') ||
          (Platform.isWindows && !args.contains('--full')),
    ),
  );
}

class SensorApp extends StatelessWidget {
  const SensorApp({super.key, this.initialWidgetMode = false});

  final bool initialWidgetMode;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Czujnik',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: HomePage(initialWidgetMode: initialWidgetMode),
    );
  }
}

// =============================================================================
// HomePage
// =============================================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.initialWidgetMode = false});

  final bool initialWidgetMode;

  @override
  State<HomePage> createState() => _HomePageState();
}

enum ScanStatus { searching, connected, disconnected, bluetoothOff }

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final BleService _bleService = BleService();

  bool _isWidgetMode = false;
  bool _launchAtStartup = false;
  double? _temperature;
  double? _humidity;
  int? _batteryLevel;
  bool _hasData = false;
  ScanStatus _scanStatus = ScanStatus.searching;

  SensorReading? _lastReading;
  DateTime? _lastReadingTime;
  DateTime _lastSetState = DateTime.fromMillisecondsSinceEpoch(0);
  late final StreamSubscription<SensorReading> _readingSub;
  StreamSubscription? _adapterSub;
  Timer? _timeUpdateTimer;
  Timer? _staleTimer;
  Timer? _uiHideTimer;
  Timer? _weatherRefreshTimer;
  late LinearGradient _currentGradient;
  WeatherSnapshot? _weather;
  String? _weatherError;
  bool _isWeatherLoading = false;

  // --- animations ---

  // waiting: rotating ring
  late final AnimationController _scanRingCtrl;
  // waiting: scale pulse on icon
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseScale;

  // entrance stagger (data view)
  late final AnimationController _entranceCtrl;
  late final Animation<double> _heroScale;
  late final Animation<double> _heroFade;
  late final Animation<double> _cardScale;
  late final Animation<double> _cardFade;
  late final Animation<Offset> _cardSlide;

  // animated background
  late final AnimationController _bgCtrl;
  late final AnimationController _skyCtrl;
  late final Ticker _bgTicker;
  late final Ticker _skyTicker;

  // wave theme: 0 = ocean, 1 = forest/mountains
  int _waveTheme = 1;
  AnimationController? _themeBlendCtrl;

  @override
  void initState() {
    super.initState();
    _isWidgetMode = widget.initialWidgetMode;

    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showFirstRunGuide();
      });
    }

    if (Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadStartupSetting();
      });
    }

    // --- waiting animations ---
    _scanRingCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _pulseScale = Tween(
      begin: 0.92,
      end: 1.08,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // --- entrance stagger ---
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _heroFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.0, 0.35, curve: Curves.easeOut),
      ),
    );
    _heroScale = Tween(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.0, 0.55, curve: Curves.elasticOut),
      ),
    );
    _cardFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.35, 0.7, curve: Curves.easeOut),
      ),
    );
    _cardScale = Tween(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.35, 0.85, curve: Curves.elasticOut),
      ),
    );
    _cardSlide = Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0.3, 0.75, curve: Curves.easeOutCubic),
      ),
    );

    // --- animated background ---
    _bgCtrl = AnimationController.unbounded(vsync: this);
    _skyCtrl = AnimationController.unbounded(vsync: this);
    _bgTicker = createTicker((elapsed) {
      _bgCtrl.value = elapsed.inMicroseconds / 120000000;
    })..start();
    _skyTicker = createTicker((elapsed) {
      _skyCtrl.value = elapsed.inMicroseconds / 24000000;
    })..start();

    _themeBlendCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      value: 1.0, // start at forest
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readingSub = _bleService.readings.listen((r) {
        if (!mounted) return;
        _onReading(r);
      });
      _adapterSub = _bleService.adapterState.listen((state) {
        if (!mounted) return;
        setState(() {
          if (state != BleAdapterState.on) {
            _scanStatus = ScanStatus.bluetoothOff;
          } else if (!_hasData) {
            _scanStatus = ScanStatus.searching;
          }
        });
      });
      _bleService.init();
      _loadWeather();
    });

    _weatherRefreshTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _loadWeather(),
    );
    _timeUpdateTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _updateGradient(),
    );
    _currentGradient = _getGradientForTime();
  }

  Future<void> _showFirstRunGuide() async {
    try {
      await showFirstRunGuide(context);
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Nie można wyświetlić instrukcji: ${error.message ?? error.code}',
          ),
        ),
      );
    }

    // auto-hide system bars after 10 s when they appear
    SystemChrome.setSystemUIChangeCallback((systemOverlaysAreVisible) async {
      if (systemOverlaysAreVisible) {
        _uiHideTimer?.cancel();
        _uiHideTimer = Timer(const Duration(seconds: 10), () {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
        });
      }
    });
  }

  @override
  void dispose() {
    _readingSub.cancel();
    _adapterSub?.cancel();
    _bleService.dispose();
    _staleTimer?.cancel();
    _scanRingCtrl.dispose();
    _pulseCtrl.dispose();
    _entranceCtrl.dispose();
    _bgTicker.dispose();
    _skyTicker.dispose();
    _bgCtrl.dispose();
    _skyCtrl.dispose();
    _themeBlendCtrl?.dispose();
    _timeUpdateTimer?.cancel();
    _weatherRefreshTimer?.cancel();
    _uiHideTimer?.cancel();
    SystemChrome.setSystemUIChangeCallback(null);
    super.dispose();
  }

  // Gradient keyframes: hour → colors
  static const _gradientStops = <int, List<Color>>{
    0: [
      Color(0xFF0E1C2E),
      Color(0xFF162942),
      Color(0xFF1F3552),
      Color(0xFF263A4E),
      Color(0xFF121A25),
    ],
    5: [
      Color(0xFF0E1C2E),
      Color(0xFF162942),
      Color(0xFF1F3552),
      Color(0xFF263A4E),
      Color(0xFF121A25),
    ],
    6: [
      Color(0xFF253856),
      Color(0xFF4A5E78),
      Color(0xFF8A6A4A),
      Color(0xFFA07A58),
      Color(0xFF5A708A),
    ],
    8: [
      Color(0xFF3A4A66),
      Color(0xFF5A6878),
      Color(0xFF9A7050),
      Color(0xFFB08A68),
      Color(0xFF7A8A9A),
    ],
    12: [
      Color(0xFF2A4A72),
      Color(0xFF4A7099),
      Color(0xFF6A8AAA),
      Color(0xFF7A9AB0),
      Color(0xFF5A7A90),
    ],
    17: [
      Color(0xFF2A4A72),
      Color(0xFF4A7099),
      Color(0xFF6A8AAA),
      Color(0xFF7A9AB0),
      Color(0xFF5A7A90),
    ],
    19: [
      Color(0xFF2A3A58),
      Color(0xFF5A4554),
      Color(0xFF8A5A4A),
      Color(0xFF9A7058),
      Color(0xFF4A3530),
    ],
    21: [
      Color(0xFF2A3858),
      Color(0xFF5A4F5E),
      Color(0xFF8A6A62),
      Color(0xFF6A4F4B),
      Color(0xFF1E2A3A),
    ],
    22: [
      Color(0xFF0E1C2E),
      Color(0xFF162942),
      Color(0xFF1F3552),
      Color(0xFF263A4E),
      Color(0xFF121A25),
    ],
  };

  LinearGradient _getGradientForTime() {
    final now = DateTime.now();
    final minuteOfDay = now.hour * 60 + now.minute;
    final hourFrac = minuteOfDay / 60.0; // 0.0 – 24.0

    final keys = _gradientStops.keys.toList()..sort();

    // find the two keyframes we're between
    int loIdx = 0;
    int hiIdx = 0;
    for (var i = 0; i < keys.length - 1; i++) {
      if (hourFrac >= keys[i] && hourFrac < keys[i + 1]) {
        loIdx = i;
        hiIdx = i + 1;
        break;
      }
      if (i == keys.length - 2) {
        loIdx = keys.length - 1;
        hiIdx = 0;
      }
    }

    final loHour = keys[loIdx];
    final hiHour = keys[hiIdx];
    final span = hiHour > loHour
        ? (hiHour - loHour).toDouble()
        : (24 - loHour + hiHour).toDouble();
    final elapsed = hourFrac >= loHour
        ? hourFrac - loHour
        : hourFrac + 24 - loHour;
    final frac = (elapsed / span).clamp(0.0, 1.0);

    final loColors = _gradientStops[loHour]!;
    final hiColors = _gradientStops[hiHour]!;
    final blended = List.generate(
      loColors.length,
      (i) => Color.lerp(loColors[i], hiColors[i], frac)!,
    );

    return LinearGradient(
      begin: const Alignment(-0.35, -1),
      end: const Alignment(0.35, 1),
      colors: blended,
    );
  }

  void _updateGradient() {
    final newGradient = _getGradientForTime();
    if (!mounted) return;
    setState(() {
      _currentGradient = newGradient;
    });
  }

  // Continuous opacity for sky layers (0.0–1.0)
  double _nightOpacity() {
    final now = DateTime.now();
    final m = now.hour * 60 + now.minute;
    // fade in: 19:00→20:30, full: 20:30→4:30, fade out: 4:30→6:00
    if (m >= 20 * 60 + 30 || m < 4 * 60 + 30) return 1.0;
    if (m >= 19 * 60 && m < 20 * 60 + 30) return (m - 19 * 60) / 90.0;
    if (m >= 4 * 60 + 30 && m < 6 * 60) return 1.0 - (m - 4 * 60 - 30) / 90.0;
    return 0.0;
  }

  double _dayOpacity() {
    final now = DateTime.now();
    final m = now.hour * 60 + now.minute;
    // fade in: 5:30→7:00, full: 7:00→17:30, fade out: 17:30→19:00
    if (m >= 7 * 60 && m < 17 * 60 + 30) return 1.0;
    if (m >= 5 * 60 + 30 && m < 7 * 60) return (m - 5 * 60 - 30) / 90.0;
    if (m >= 17 * 60 + 30 && m < 19 * 60) {
      return 1.0 - (m - 17 * 60 - 30) / 90.0;
    }
    return 0.0;
  }

  double _daylightProgress() {
    final now = DateTime.now();
    final minutes = now.hour * 60 + now.minute;
    const start = 6 * 60;
    const end = 19 * 60;
    if (minutes <= start) return 0;
    if (minutes >= end) return 1;
    return (minutes - start) / (end - start);
  }

  double _nightProgress() {
    final now = DateTime.now();
    final minutes = now.hour * 60 + now.minute;
    const sunset = 19 * 60;
    const sunrise = 6 * 60;
    if (minutes >= sunset) {
      return (minutes - sunset) / (24 * 60 - sunset + sunrise);
    }
    return (minutes + (24 * 60 - sunset)) / (24 * 60 - sunset + sunrise);
  }

  Widget _skyEffectsLayer() {
    final dayProgress = _daylightProgress();
    final nightProgress = _nightProgress();
    final dayAlpha = _dayOpacity();
    final nightAlpha = _nightOpacity();

    return RepaintBoundary(
      child: IgnorePointer(
        child: Stack(
          children: [
            // day layer
            if (dayAlpha > 0)
              Opacity(
                opacity: dayAlpha,
                child: AnimatedBuilder(
                  animation: _skyCtrl,
                  builder: (context, _) => CustomPaint(
                    isComplex: true,
                    willChange: true,
                    painter: _DaySunPainter(
                      progress: _skyCtrl.value,
                      dayProgress: dayProgress,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            // night layer
            if (nightAlpha > 0)
              Opacity(
                opacity: nightAlpha,
                child: AnimatedBuilder(
                  animation: _skyCtrl,
                  builder: (context, _) => CustomPaint(
                    isComplex: true,
                    willChange: true,
                    painter: _NightSkyPainter(
                      progress: _skyCtrl.value,
                      nightProgress: nightProgress,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            // clouds layer
            AnimatedBuilder(
              animation: _skyCtrl,
              builder: (context, _) => CustomPaint(
                isComplex: true,
                willChange: true,
                painter: _CloudsPainter(
                  progress: _skyCtrl.value,
                  nightAlpha: nightAlpha,
                  weatherCondition: _weather?.condition,
                ),
                child: const SizedBox.expand(),
              ),
            ),
            _weatherEffectsLayer(),
          ],
        ),
      ),
    );
  }

  Widget _weatherEffectsLayer() {
    final weather = _weather;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 1400),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: weather != null && weather.condition.hasOverlay
          ? AnimatedBuilder(
              key: ValueKey(weather.animationKey),
              animation: _skyCtrl,
              builder: (context, _) => CustomPaint(
                painter: _WeatherPainter(
                  weather: weather,
                  progress: _skyCtrl.value,
                ),
                child: const SizedBox.expand(),
              ),
            )
          : const SizedBox.expand(key: ValueKey('no-weather-overlay')),
    );
  }

  Widget _gradientLayer() {
    return AnimatedBuilder(
      animation: _bgCtrl,
      builder: (context, child) {
        final t = _bgCtrl.value * 2 * math.pi;
        final dx = 1.0 * math.sin(t * 0.22);
        final dy = 0.8 * math.cos(t * 0.17);
        final scale = 1.004 + 0.0015 * math.sin(t * 0.12);
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: AnimatedContainer(
        duration: const Duration(seconds: 2),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(gradient: _currentGradient),
      ),
    );
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    if (_isWidgetMode) return _widgetView();

    return Scaffold(
      body: Stack(
        children: [
          // base gradient
          Positioned.fill(child: _gradientLayer()),

          Positioned.fill(child: _skyEffectsLayer()),

          // diagonal wave layers
          Positioned.fill(
            child: AnimatedBuilder(
              animation: Listenable.merge([_bgCtrl, ?_themeBlendCtrl]),
              builder: (context, _) => CustomPaint(
                painter: _DiagonalWavesPainter(
                  animValue: _bgCtrl.value,
                  nightAlpha: _nightOpacity(),
                  themeBlend: _themeBlendCtrl?.value ?? 1.0,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),

          // scrollable content — full screen height for true centering
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                color: Colors.tealAccent,
                backgroundColor: const Color(0xFF0D2B45),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 500),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            transitionBuilder: (child, anim) =>
                                FadeTransition(opacity: anim, child: child),
                            child: _scanStatus == ScanStatus.bluetoothOff
                                ? _bluetoothOffView()
                                : _hasData
                                ? _dataView()
                                : _waitingView(),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // Status and weather stay at the top without affecting centering.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
                child: Row(
                  children: [
                    _statusChip(),
                    const Spacer(),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _weatherStatusChip(),
                      ),
                    ),
                    if (Platform.isWindows) _windowsMenuButton(),
                  ],
                ),
              ),
            ),
          ),

          if (_lastReadingTime != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _scanStatus == ScanStatus.disconnected
                              ? Icons.history_rounded
                              : Icons.check_circle_outline_rounded,
                          size: 14,
                          color: _scanStatus == ScanStatus.disconnected
                              ? const Color(0xFFFBBF24).withValues(alpha: 0.9)
                              : Colors.white.withValues(alpha: 0.52),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Ostatni odczyt: ${_formatTime(_lastReadingTime!)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: _scanStatus == ScanStatus.disconnected
                                ? const Color(0xFFFBBF24).withValues(alpha: 0.9)
                                : Colors.white.withValues(alpha: 0.62),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // theme toggle button (on top of content)
          Positioned(
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 16),
                child: GestureDetector(
                  onTap: _toggleWaveTheme,
                  child: AnimatedBuilder(
                    animation: _themeBlendCtrl ?? kAlwaysDismissedAnimation,
                    builder: (context, _) {
                      final blend = _themeBlendCtrl?.value ?? 1.0;
                      return Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                        child: Icon(
                          blend < 0.5
                              ? Icons.park_rounded
                              : Icons.water_rounded,
                          size: 18,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _widgetView() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        color: const Color(0xFF111827),
        child: SafeArea(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Expanded(
                      child: _widgetMeasurement(
                        icon: Icons.thermostat_rounded,
                        label: 'TEMPERATURA',
                        value: _temperature == null
                            ? '--'
                            : '${_temperature!.toStringAsFixed(1)}°',
                        color: _temperature == null
                            ? const Color(0xFFCBD5E1)
                            : _tempColor(_temperature!),
                      ),
                    ),
                    const SizedBox(width: 28),
                    Expanded(
                      child: _widgetMeasurement(
                        icon: Icons.water_drop_rounded,
                        label: 'WILGOTNOŚĆ',
                        value: _humidity == null
                            ? '--'
                            : '${_humidity!.toStringAsFixed(1)}%',
                        color: const Color(0xFF7DD3FC),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(top: 0, right: 0, child: _windowsMenuButton()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _widgetMeasurement({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.8),
                      blurRadius: 3,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: color,
              shadows: [
                Shadow(
                  color: Colors.black.withValues(alpha: 0.7),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _windowsMenuButton() {
    return PopupMenuButton<String>(
      tooltip: 'Menu',
      icon: Icon(
        Icons.menu_rounded,
        size: 20,
        color: _isWidgetMode
            ? Colors.white.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: 0.72),
      ),
      onSelected: (value) {
        if (value == 'toggleStartup') {
          _toggleStartupSetting();
        } else if (value == 'toggleView') {
          _toggleWidgetMode();
        } else if (value == 'close') {
          _closeWindow();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'toggleView',
          child: Row(
            children: [
              Icon(_isWidgetMode ? Icons.open_in_full : Icons.widgets_outlined),
              const SizedBox(width: 10),
              Text(_isWidgetMode ? 'Otwórz pełny widok' : 'Tryb widżetu'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'toggleStartup',
          child: Row(
            children: [
              Icon(
                _launchAtStartup
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
              ),
              const SizedBox(width: 10),
              Text(
                _launchAtStartup
                    ? 'Wyłącz start z Windows'
                    : 'Uruchamiaj z Windows',
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'close',
          child: Row(
            children: [
              Icon(Icons.close_rounded),
              SizedBox(width: 10),
              Text('Zamknij aplikację'),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _loadStartupSetting() async {
    try {
      final enabled = await _windowsChannel.invokeMethod<bool>(
        'getStartupEnabled',
      );
      if (mounted && enabled != null) {
        setState(() => _launchAtStartup = enabled);
      }
    } on PlatformException catch (error) {
      _showWindowsError('Nie można odczytać ustawienia autostartu', error);
    }
  }

  Future<void> _toggleStartupSetting() async {
    final enabled = !_launchAtStartup;
    try {
      await _windowsChannel.invokeMethod<void>('setStartupEnabled', enabled);
      if (mounted) setState(() => _launchAtStartup = enabled);
    } on PlatformException catch (error) {
      _showWindowsError('Nie można zmienić ustawienia autostartu', error);
    }
  }

  Future<void> _toggleWidgetMode() async {
    final enabled = !_isWidgetMode;
    try {
      await _windowsChannel.invokeMethod<void>('setWidgetMode', enabled);
      if (mounted) setState(() => _isWidgetMode = enabled);
    } on PlatformException catch (error) {
      _showWindowsError('Nie można zmienić rozmiaru okna', error);
    }
  }

  Future<void> _closeWindow() async {
    try {
      await _windowsChannel.invokeMethod<void>('closeWindow');
    } on PlatformException catch (error) {
      _showWindowsError('Nie można zamknąć aplikacji', error);
    }
  }

  void _showWindowsError(String message, PlatformException error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$message: ${error.message ?? error.code}')),
    );
  }

  // --------------- status chip ---------------

  Widget _statusChip() {
    final isConnected = _scanStatus == ScanStatus.connected;
    final isDisconnected = _scanStatus == ScanStatus.disconnected;
    final isBtOff = _scanStatus == ScanStatus.bluetoothOff;

    final color = isConnected
        ? const Color(0xFF4ADE80)
        : (isDisconnected || isBtOff)
        ? const Color(0xFFF87171)
        : const Color(0xFFFBBF24);

    final label = isConnected
        ? 'Połączono'
        : isBtOff
        ? 'Bluetooth wyłączony'
        : isDisconnected
        ? 'Rozłączono'
        : 'Szukam…';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: Text(
              label,
              key: ValueKey(label),
              style: TextStyle(
                color: color.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (_batteryLevel != null) ...[
            const SizedBox(width: 12),
            Icon(
              _battIcon(_batteryLevel),
              size: 13,
              color: _battColor(_batteryLevel).withValues(alpha: 0.7),
            ),
            const SizedBox(width: 3),
            Text(
              '$_batteryLevel%',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _weatherStatusChip() {
    final weather = _weather;
    if (!_isWeatherLoading && _weatherError == null && weather == null) {
      return const SizedBox.shrink();
    }

    final Widget content;
    if (_isWeatherLoading) {
      content = const Row(
        key: ValueKey('weather_loading'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Colors.white54,
            ),
          ),
          SizedBox(width: 7),
          Flexible(
            child: Text(
              'Pobieranie pogody…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else if (_weatherError != null) {
      content = Row(
        key: const ValueKey('weather_error'),
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.cloud_off_rounded, size: 14, color: Color(0xFFFBBF24)),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'Pogoda niedostępna',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: 6),
          Icon(Icons.refresh_rounded, size: 14),
        ],
      );
    } else {
      content = Row(
        key: ValueKey(weather!.animationKey),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _weatherIcon(weather.condition),
            size: 14,
            color: Colors.white.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              weather.condition.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    return Semantics(
      button: true,
      label: _weatherError == null
          ? 'Pogoda: ${weather?.condition.label ?? 'pobieranie'}. Dotknij, aby wyświetlić prognozę.'
          : 'Pogoda niedostępna. Dotknij, aby ponowić próbę.',
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: Material(
          key: ValueKey(
            _isWeatherLoading
                ? 'loading'
                : _weatherError != null
                ? 'error'
                : weather?.animationKey,
          ),
          color: Colors.black.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            onTap: _onWeatherTap,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: DefaultTextStyle(
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onWeatherTap() async {
    if (_weatherError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_weatherError!),
          action: SnackBarAction(label: 'Ponów', onPressed: _loadWeather),
        ),
      );
      await _loadWeather();
      return;
    }

    if (_weather == null) {
      await _loadWeather();
    }
    if (!mounted) return;

    final weather = _weather;
    if (weather == null) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final maxDialogHeight = MediaQuery.sizeOf(dialogContext).height * 0.82;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: maxDialogHeight,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xF21A2B40), Color(0xF20B1422)],
                    ),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 32,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Prognoza pogody',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.1,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Zamknij',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                              icon: const Icon(Icons.close_rounded, size: 20),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on_rounded,
                              size: 17,
                              color: Colors.tealAccent,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                weather.approximateLocality ??
                                    'Przybliżona lokalizacja',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.86),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 24, top: 3),
                          child: Text(
                            '${_formatCoordinate(weather.latitude, true)}, '
                            '${_formatCoordinate(weather.longitude, false)}'
                            ' · © OpenStreetMap',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.42),
                              fontSize: 10,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.055),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.075),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _weatherIcon(weather.condition),
                                size: 42,
                                color: const Color(0xFF67CFFF),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'TERAZ',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.48,
                                        ),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 1.8,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      weather.condition.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (weather.currentTemperature != null)
                                Text(
                                  '${weather.currentTemperature!.toStringAsFixed(1)}°',
                                  style: const TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w300,
                                    letterSpacing: -1,
                                    color: Color(0xFF67CFFF),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (weather.forecast.length > 1) ...[
                          const SizedBox(height: 22),
                          Text(
                            'NAJBLIŻSZE DNI',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.8,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final day in weather.forecast.skip(1).take(3))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.035),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 55,
                                      child: Text(
                                        _formatForecastDate(day.date),
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.78,
                                          ),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      _weatherIcon(day.condition),
                                      size: 19,
                                      color: const Color(0xFF9EDCF7),
                                    ),
                                    const SizedBox(width: 9),
                                    Expanded(
                                      child: Text(
                                        day.condition.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withValues(
                                            alpha: 0.62,
                                          ),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${day.maximumTemperature.toStringAsFixed(0)}°',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 7),
                                    Text(
                                      '${day.minimumTemperature.toStringAsFixed(0)}°',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.48,
                                        ),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                        const SizedBox(height: 14),
                        Center(
                          child: Text(
                            'Dane pogodowe: Open-Meteo',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.38),
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatCoordinate(double value, bool latitude) {
    final direction = latitude
        ? (value >= 0 ? 'N' : 'S')
        : (value >= 0 ? 'E' : 'W');
    return '${value.abs().toStringAsFixed(3)}°$direction';
  }

  String _formatForecastDate(DateTime date) {
    const weekdays = ['pon.', 'wt.', 'śr.', 'czw.', 'pt.', 'sob.', 'niedz.'];
    return '${weekdays[date.weekday - 1]} ${date.day.toString().padLeft(2, '0')}.'
        '${date.month.toString().padLeft(2, '0')}';
  }

  IconData _weatherIcon(WeatherCondition condition) => switch (condition) {
    WeatherCondition.clear => Icons.wb_sunny_rounded,
    WeatherCondition.partlyCloudy => Icons.wb_cloudy_rounded,
    WeatherCondition.cloudy => Icons.cloud_rounded,
    WeatherCondition.fog => Icons.foggy,
    WeatherCondition.rain => Icons.grain_rounded,
    WeatherCondition.snow => Icons.ac_unit_rounded,
    WeatherCondition.thunderstorm => Icons.thunderstorm_rounded,
  };

  // --------------- waiting view ---------------

  Widget _waitingView() {
    return Column(
      key: const ValueKey('waiting'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 100,
          height: 100,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _scanRingCtrl,
                builder: (context, child) => Transform.rotate(
                  angle: _scanRingCtrl.value * 2 * math.pi,
                  child: child,
                ),
                child: CustomPaint(
                  size: const Size(100, 100),
                  painter: _ScanArcPainter(),
                ),
              ),
              ScaleTransition(
                scale: _pulseScale,
                child: Icon(
                  Icons.bluetooth_searching,
                  size: 32,
                  color: Colors.tealAccent.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(
          'Szukam czujnika…',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 15,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: 100,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: LinearProgressIndicator(
              color: Colors.tealAccent.withValues(alpha: 0.4),
              backgroundColor: Colors.white.withValues(alpha: 0.05),
              minHeight: 2,
            ),
          ),
        ),
      ],
    );
  }

  // --------------- bluetooth off view ---------------

  Widget _bluetoothOffView() {
    return Column(
      key: const ValueKey('bt_off'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.bluetooth_disabled_rounded,
          size: 44,
          color: const Color(0xFFF87171).withValues(alpha: 0.5),
        ),
        const SizedBox(height: 20),
        Text(
          'Bluetooth wyłączony',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 16,
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Włącz Bluetooth, aby kontynuować',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.25),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1422).withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: TextButton(
            onPressed: () async {
              try {
                await _bleService.turnOnBluetooth();
              } catch (_) {}
            },
            style: TextButton.styleFrom(
              foregroundColor: Colors.tealAccent.withValues(alpha: 0.85),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(100),
              ),
            ),
            child: const Text('Włącz Bluetooth'),
          ),
        ),
      ],
    );
  }

  // --------------- data view ---------------

  Widget _dataView() {
    final temp = _temperature;
    final hum = _humidity;
    final isStale = _scanStatus == ScanStatus.disconnected;

    final tempColor = temp == null ? Colors.white54 : _tempColor(temp);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: _measurementPanel(
        Column(
          key: const ValueKey('data'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isStale)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.wifi_off_rounded,
                      size: 13,
                      color: const Color(0xFFF87171).withValues(alpha: 0.9),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Dane mogą być nieaktualne',
                      style: TextStyle(
                        color: const Color(0xFFF87171).withValues(alpha: 0.9),
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),

            // temperature
            Semantics(
              label: temp != null
                  ? 'Temperatura ${temp.toStringAsFixed(1)} stopni Celsjusza'
                  : 'Brak danych temperatury',
              child: FadeTransition(
                opacity: _heroFade,
                child: ScaleTransition(
                  scale: _heroScale,
                  child: Column(
                    children: [
                      AnimatedBuilder(
                        animation: _bgCtrl,
                        builder: (context, child) {
                          final pulse =
                              0.5 +
                              0.5 * math.sin(_bgCtrl.value * 2 * math.pi * 0.6);
                          return Container(
                            decoration: BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: tempColor.withValues(
                                    alpha: 0.07 + 0.03 * pulse,
                                  ),
                                  blurRadius: 34 + 4 * pulse,
                                  spreadRadius: 2 + pulse,
                                ),
                              ],
                            ),
                            child: child,
                          );
                        },
                        child: TweenAnimationBuilder<Color?>(
                          tween: ColorTween(end: tempColor),
                          duration: const Duration(milliseconds: 450),
                          curve: Curves.easeOutCubic,
                          builder: (context, color, _) =>
                              TweenAnimationBuilder<double>(
                                tween: Tween<double>(
                                  begin: temp ?? 0,
                                  end: temp ?? 0,
                                ),
                                duration: const Duration(milliseconds: 450),
                                curve: Curves.easeOutCubic,
                                builder: (context, value, _) => Text(
                                  temp != null
                                      ? '${value.toStringAsFixed(1)}°'
                                      : '—',
                                  style: TextStyle(
                                    fontSize: 80,
                                    fontWeight: FontWeight.w300,
                                    color: color,
                                    height: 1.0,
                                    letterSpacing: -3,
                                  ),
                                ),
                              ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'TEMPERATURA',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 4,
                          color: Colors.white.withValues(alpha: 0.5),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // divider
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Container(
                width: 32,
                height: 1,
                color: Colors.white.withValues(alpha: 0.07),
              ),
            ),

            // humidity
            Semantics(
              label: hum != null
                  ? 'Wilgotność ${hum.toStringAsFixed(1)} procent'
                  : 'Brak danych wilgotności',
              child: FadeTransition(
                opacity: _cardFade,
                child: SlideTransition(
                  position: _cardSlide,
                  child: ScaleTransition(
                    scale: _cardScale,
                    child: Column(
                      children: [
                        AnimatedBuilder(
                          animation: _bgCtrl,
                          builder: (context, child) {
                            final pulse =
                                0.5 +
                                0.5 *
                                    math.sin(
                                      _bgCtrl.value * 2 * math.pi * 0.6 + 1.0,
                                    );
                            return Container(
                              decoration: BoxDecoration(
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFF67CFFF,
                                    ).withValues(alpha: 0.07 + 0.03 * pulse),
                                    blurRadius: 34 + 4 * pulse,
                                    spreadRadius: 2 + pulse,
                                  ),
                                ],
                              ),
                              child: child,
                            );
                          },
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(
                              begin: hum ?? 0,
                              end: hum ?? 0,
                            ),
                            duration: const Duration(milliseconds: 450),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, _) => Text(
                              hum != null
                                  ? '${value.toStringAsFixed(1)}%'
                                  : '—',
                              style: const TextStyle(
                                fontSize: 80,
                                fontWeight: FontWeight.w300,
                                color: Color(0xFF67CFFF),
                                height: 1.0,
                                letterSpacing: -3,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'WILGOTNOŚĆ',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 4,
                            color: Colors.white.withValues(alpha: 0.5),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _measurementPanel(Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1422).withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  // --------------- helpers ---------------

  Color _tempColor(double t) {
    if (t < 5) return const Color(0xFF60A5FA);
    if (t < 15) return const Color(0xFF22D3EE);
    if (t < 22) return const Color(0xFF4ADE80);
    if (t < 28) return const Color(0xFFFBBF24);
    return const Color(0xFFEF4444);
  }

  Color _battColor(int? b) {
    if (b == null) return Colors.white38;
    if (b > 50) return const Color(0xFF4ADE80);
    if (b > 20) return const Color(0xFFFBBF24);
    return const Color(0xFFF87171);
  }

  IconData _battIcon(int? b) {
    if (b == null) return Icons.battery_unknown;
    if (b > 80) return Icons.battery_full;
    if (b > 50) return Icons.battery_5_bar;
    if (b > 20) return Icons.battery_3_bar;
    return Icons.battery_1_bar;
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  void _toggleWaveTheme() {
    HapticFeedback.lightImpact();
    setState(() {
      _waveTheme = _waveTheme == 0 ? 1 : 0;
    });
    if (_waveTheme == 0) {
      _themeBlendCtrl?.animateTo(0.0, curve: Curves.easeInOutCubic);
    } else {
      _themeBlendCtrl?.animateTo(1.0, curve: Curves.easeInOutCubic);
    }
  }

  Future<void> _onRefresh() async {
    HapticFeedback.mediumImpact();
    await Future.wait<void>([_bleService.refresh(), _loadWeather()]);
    // give BLE scan a moment to pick up new advertisements
    await Future.delayed(const Duration(seconds: 2));
  }

  Future<void> _loadWeather() async {
    if (_isWeatherLoading) return;
    if (mounted) {
      setState(() {
        _isWeatherLoading = true;
      });
    }

    try {
      final condition = await WeatherService.fetchCurrentCondition();
      if (!mounted) return;
      setState(() {
        _weather = condition;
        _weatherError = null;
      });
    } on WeatherServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _weatherError = error.message;
      });
    } catch (error, stackTrace) {
      debugPrint('Weather update failed: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _weatherError = 'Nie udało się pobrać pogody.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isWeatherLoading = false;
        });
      }
    }
  }

  void _onReading(SensorReading reading) {
    final now = DateTime.now();
    if (_lastReading == reading &&
        now.difference(_lastSetState) < const Duration(milliseconds: 180)) {
      return;
    }
    _lastReading = reading;
    _lastSetState = now;

    final wasEmpty = !_hasData;

    setState(() {
      _temperature = reading.temperature;
      _humidity = reading.humidity;
      _batteryLevel = reading.battery;
      _hasData = reading.hasData;
      _scanStatus = reading.hasData ? ScanStatus.connected : _scanStatus;
      if (reading.hasData) _lastReadingTime = now;
    });

    if (_hasData && wasEmpty) {
      _entranceCtrl.forward(from: 0);
    }

    // Reset stale-data timer on every fresh reading
    _staleTimer?.cancel();
    if (reading.hasData) {
      _staleTimer = Timer(const Duration(seconds: 30), () {
        if (!mounted) return;
        setState(() {
          _scanStatus = ScanStatus.disconnected;
        });
      });
    }
  }
}

class _NightSkyPainter extends CustomPainter {
  final double progress;
  final double nightProgress;

  const _NightSkyPainter({required this.progress, required this.nightProgress});

  // Pre-computed star field — generated once, reused every frame.
  // Each entry: [x01, y01, phase, radius, brightness, speed, colorIdx]
  static final List<List<double>> _stars = _initStars();
  static List<List<double>> _initStars() {
    final rng = math.Random(42);
    return List.generate(
      65,
      (_) => [
        rng.nextDouble(),
        rng.nextDouble() * 0.55,
        rng.nextDouble() * 6.28,
        0.5 + rng.nextDouble() * 1.4,
        0.3 + rng.nextDouble() * 0.7,
        0.4 + rng.nextDouble() * 0.8,
        (rng.nextInt(3)).toDouble(),
      ],
    );
  }

  static const _starColors = [
    Color(0xFFDDF2FF), // cool blue-white
    Color(0xFFFFF6E0), // warm white
    Color(0xFFE8ECFF), // cool blue
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final t = progress * 2 * math.pi;

    _paintNebula(canvas, w, h, t);
    _paintMoon(canvas, w, h, t);
    _paintStars(canvas, w, h, t);
    _paintShootingStar(canvas, w, h, progress);
  }

  void _paintNebula(Canvas canvas, double w, double h, double t) {
    final paint = Paint()..isAntiAlias = true;
    const positions = [
      [0.2, 0.16, 70.0],
      [0.78, 0.10, 55.0],
      [0.48, 0.32, 80.0],
    ];
    const colors = [Color(0xFF3A4B7A), Color(0xFF4A3A6A), Color(0xFF2A4A6A)];

    for (var i = 0; i < positions.length; i++) {
      final p = positions[i];
      final center = Offset(
        w * p[0] + 4 * math.sin(t * 0.1 + i * 1.5),
        h * p[1] + 3 * math.cos(t * 0.08 + i * 2.0),
      );
      final r = p[2];
      paint.shader = RadialGradient(
        colors: [
          colors[i].withValues(alpha: 0.07),
          colors[i].withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: r));
      canvas.drawCircle(center, r, paint);
    }
  }

  void _paintMoon(Canvas canvas, double w, double h, double t) {
    final moonX = w * (0.08 + 0.84 * nightProgress);
    final moonY = h * (0.45 - 0.30 * math.sin(nightProgress * math.pi));
    final mc = Offset(
      moonX + 1.5 * math.sin(t * 0.18),
      moonY + 1.0 * math.cos(t * 0.15),
    );

    // three-stop glow
    final glow = Paint()
      ..isAntiAlias = true
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFEFE8D8).withValues(alpha: 0.18),
          const Color(0xFFEFE8D8).withValues(alpha: 0.05),
          const Color(0xFFEFE8D8).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: mc, radius: 82));
    canvas.drawCircle(mc, 82, glow);

    // surface
    final surface = Paint()
      ..isAntiAlias = true
      ..shader = const RadialGradient(
        colors: [Color(0xFFF6F2E7), Color(0xFFD8D0BF), Color(0xFFB9B09B)],
        stops: [0.0, 0.7, 1.0],
      ).createShader(Rect.fromCircle(center: mc, radius: 26));
    canvas.drawCircle(mc, 26, surface);

    // craters
    final cp = Paint()
      ..isAntiAlias = true
      ..color = const Color(0xFF9F9685).withValues(alpha: 0.28);
    canvas.drawCircle(mc.translate(-7, -4), 3.6, cp);
    canvas.drawCircle(mc.translate(6, 3), 2.7, cp);
    canvas.drawCircle(mc.translate(-2, 8), 2.1, cp);
    canvas.drawCircle(mc.translate(10, -6), 1.8, cp);
  }

  void _paintStars(Canvas canvas, double w, double h, double t) {
    final paint = Paint()..isAntiAlias = true;

    for (final s in _stars) {
      final twinkle = s[4] * (0.5 + 0.5 * math.sin(t * s[5] + s[2]));
      final drift = 0.8 * math.sin(t * 0.15 + s[2]);
      final x = (w * s[0] + drift + w) % w;
      final y = h * (0.04 + s[1]);
      final r = s[3];
      final ci = s[6].toInt();

      // soft halo
      paint.color = Colors.white.withValues(alpha: 0.07 * twinkle);
      canvas.drawCircle(Offset(x, y), r * 3.2, paint);

      // core
      paint.color = _starColors[ci].withValues(alpha: 0.8 * twinkle);
      canvas.drawCircle(Offset(x, y), r, paint);

      // bright centre for larger stars
      if (r > 1.2) {
        paint.color = Colors.white.withValues(alpha: 0.85 * twinkle);
        canvas.drawCircle(Offset(x, y), r * 0.3, paint);
      }
    }
  }

  static final List<List<double>> _shootingStars = _makeShootingStars();

  static List<List<double>> _makeShootingStars() {
    final random = math.Random(2718);
    final events = <List<double>>[];
    var start = 0.35;
    while (start < 100) {
      final duration = 0.025 + random.nextDouble() * 0.035;
      final startX = 0.08 + random.nextDouble() * 0.78;
      final startY = 0.03 + random.nextDouble() * 0.48;
      final travelX =
          (random.nextDouble() * 0.22 + 0.08) * (random.nextBool() ? 1 : -1);
      final travelY = 0.04 + random.nextDouble() * 0.17;
      events.add([start, duration, startX, startY, travelX, travelY]);
      start += 0.35 + random.nextDouble() * 1.25;
    }
    return events;
  }

  void _paintShootingStar(Canvas canvas, double w, double h, double progress) {
    const cycleLength = 100.0;
    final cycleProgress = progress % cycleLength;

    for (final event in _shootingStars) {
      final start = event[0];
      final duration = event[1];
      if (cycleProgress < start || cycleProgress > start + duration) continue;

      final frac = (cycleProgress - start) / duration;
      final ease = Curves.easeOut.transform(frac);
      final fade = 1.0 - Curves.easeIn.transform(frac);

      final sx = w * event[2];
      final sy = h * event[3];
      final dx = w * event[4];
      final dy = h * event[5];

      final cx = sx + dx * ease;
      final cy = sy + dy * ease;

      final tailLen = (18.0 + 34.0 * event[1] / 0.06) * fade;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len == 0) continue;
      final tx = cx - dx / len * tailLen;
      final ty = cy - dy / len * tailLen;

      final trail = Paint()
        ..isAntiAlias = true
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.65 * fade),
          ],
        ).createShader(Rect.fromPoints(Offset(tx, ty), Offset(cx, cy)));
      canvas.drawLine(Offset(tx, ty), Offset(cx, cy), trail);

      final head = Paint()
        ..isAntiAlias = true
        ..color = Colors.white.withValues(alpha: 0.85 * fade);
      canvas.drawCircle(Offset(cx, cy), 1.4, head);
    }
  }

  @override
  bool shouldRepaint(covariant _NightSkyPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.nightProgress != nightProgress;
  }
}

class _DaySunPainter extends CustomPainter {
  final double progress;
  final double dayProgress;

  const _DaySunPainter({required this.progress, required this.dayProgress});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final t = progress * 2 * math.pi;

    final sunX = w * (0.08 + 0.84 * dayProgress);
    final sunY = h * (0.72 - 0.5 * math.sin(dayProgress * math.pi));
    final sc = Offset(
      sunX + 1.3 * math.sin(t * 0.15),
      sunY + 1.0 * math.cos(t * 0.12),
    );
    final coreR = 28.0 + 1.0 * math.sin(t * 0.22);

    // wide haze
    final hazePaint = Paint()
      ..isAntiAlias = true
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFFFF4CB).withValues(alpha: 0.09),
          const Color(0xFFFFF4CB).withValues(alpha: 0.02),
          const Color(0xFFFFF4CB).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: sc, radius: 200));
    canvas.drawCircle(sc, 200, hazePaint);

    // inner aura
    final auraPaint = Paint()
      ..isAntiAlias = true
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFFFE8A5).withValues(alpha: 0.22),
          const Color(0xFFFFE8A5).withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: sc, radius: 100));
    canvas.drawCircle(sc, 100, auraPaint);

    // soft rotating rays
    _paintRays(canvas, sc, coreR, t);

    // sun core
    final sunPaint = Paint()
      ..isAntiAlias = true
      ..shader = RadialGradient(
        colors: const [Color(0xFFFFF8D8), Color(0xFFFFDEA0), Color(0xFFF3BF68)],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: sc, radius: coreR));
    canvas.drawCircle(sc, coreR, sunPaint);

    // bright centre spot
    final spot = Paint()
      ..isAntiAlias = true
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFFFFFFF).withValues(alpha: 0.55),
          const Color(0xFFFFFFFF).withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: sc, radius: coreR * 0.5));
    canvas.drawCircle(sc, coreR * 0.5, spot);
  }

  void _paintRays(Canvas canvas, Offset center, double coreR, double t) {
    final paint = Paint()
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5;

    for (var i = 0; i < 12; i++) {
      final angle = (i / 12) * math.pi * 2 + t * 0.08;
      final innerR = coreR + 6;
      final outerR = coreR + 22 + 8 * math.sin(t * 0.4 + i * 0.8);
      final alpha = 0.11 + 0.05 * math.sin(t * 0.35 + i);

      final x1 = center.dx + math.cos(angle) * innerR;
      final y1 = center.dy + math.sin(angle) * innerR;
      final x2 = center.dx + math.cos(angle) * outerR;
      final y2 = center.dy + math.sin(angle) * outerR;

      paint.color = const Color(0xFFFFE8A5).withValues(alpha: alpha);
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DaySunPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.dayProgress != dayProgress;
  }
}

// =============================================================================
// Scan Arc Painter – draws a sweeping arc around the BT icon
// =============================================================================

// =============================================================================
// Diagonal flowing wave layers
// =============================================================================

class _DiagonalWavesPainter extends CustomPainter {
  final double animValue;
  final double nightAlpha;
  final double themeBlend; // 0 = ocean, 1 = forest/mountains

  const _DiagonalWavesPainter({
    required this.animValue,
    required this.nightAlpha,
    required this.themeBlend,
  });

  // === Ocean theme ===
  static const _oceanLayers = [
    [0.68, 0.76, 0.030, 2.5, 0.0],
    [0.70, 0.80, 0.025, 3.2, 1.5],
    [0.72, 0.84, 0.035, 2.0, 3.0],
    [0.74, 0.86, 0.028, 3.8, 4.5],
    [0.76, 0.88, 0.032, 2.8, 6.0],
    [0.78, 0.90, 0.025, 3.5, 7.5],
    [0.82, 0.93, 0.020, 4.2, 9.0],
    [0.87, 0.97, 0.015, 2.4, 10.5],
  ];
  static const _oceanDay = [
    Color(0xFFC0DCF0),
    Color(0xFFA0C8E8),
    Color(0xFF80B4E0),
    Color(0xFF60A0D8),
    Color(0xFF4888C8),
    Color(0xFF3070B0),
    Color(0xFF1E5A98),
    Color(0xFF104480),
  ];
  static const _oceanNight = [
    Color(0xFF37474F),
    Color(0xFF30404A),
    Color(0xFF283845),
    Color(0xFF203040),
    Color(0xFF18283A),
    Color(0xFF122035),
    Color(0xFF0C1828),
    Color(0xFF06101C),
  ];

  // === Forest theme ===
  static const _forestLayers = [
    [0.58, 0.64, 0.040, 1.8, 0.0],
    [0.62, 0.70, 0.035, 2.2, 1.5],
    [0.66, 0.76, 0.032, 2.8, 3.0],
    [0.70, 0.80, 0.028, 1.5, 4.5],
    [0.74, 0.85, 0.025, 3.2, 6.0],
    [0.78, 0.88, 0.022, 2.0, 7.5],
    [0.82, 0.92, 0.018, 3.8, 9.0],
    [0.87, 0.97, 0.014, 2.6, 10.5],
  ];
  static const _forestDay = [
    Color(0xFF8EAAB8),
    Color(0xFF6D9A8C),
    Color(0xFF4A7E6A),
    Color(0xFF3A6B52),
    Color(0xFF2D5A3E),
    Color(0xFF1F4A2E),
    Color(0xFF153B22),
    Color(0xFF0C2A16),
  ];
  static const _forestNight = [
    Color(0xFF2A3A44),
    Color(0xFF223340),
    Color(0xFF1A2B35),
    Color(0xFF15242D),
    Color(0xFF101D24),
    Color(0xFF0C171E),
    Color(0xFF081218),
    Color(0xFF040D10),
  ];

  double _lerpVal(double a, double b, double t) => a + (b - a) * t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final t = animValue * 2 * math.pi;
    final tb = themeBlend; // 0=ocean, 1=forest

    for (var i = 0; i < 8; i++) {
      final oL = _oceanLayers[i];
      final fL = _forestLayers[i];

      final leftY = h * _lerpVal(oL[0], fL[0], tb);
      final rightY = h * _lerpVal(oL[1], fL[1], tb);
      final amp = h * _lerpVal(oL[2], fL[2], tb);
      final speed = _lerpVal(oL[3], fL[3], tb);
      final phase = _lerpVal(oL[4], fL[4], tb);

      final path = Path();
      path.moveTo(0, h);
      path.lineTo(0, leftY);

      // Mountain layers (i<4) get sharper waves when in forest mode
      final sharpness = (i < 4) ? tb : 0.0;
      for (var x = 0.0; x <= w; x += 2.5) {
        final xFrac = x / w;
        final baseY = leftY + (rightY - leftY) * xFrac;
        final drift = 0.65 * math.sin(t * speed * 0.3 + phase);

        // Ocean-style smooth wave
        final oceanWave =
            amp * math.sin(xFrac * math.pi * 3 + drift * 3.0 + phase) +
            amp *
                0.4 *
                math.sin(xFrac * math.pi * 5 + drift * 2.0 + phase + 1.0) +
            amp *
                0.15 *
                math.sin(xFrac * math.pi * 8 + drift * 1.5 + phase + 2.5);

        // Mountain-style jagged wave
        final mountWave =
            amp * math.sin(xFrac * math.pi * 2.5 + drift * 2.5 + phase) +
            amp *
                0.5 *
                math.sin(xFrac * math.pi * 5.5 + drift * 1.8 + phase + 0.8) +
            amp *
                0.25 *
                math.sin(xFrac * math.pi * 11 + drift * 1.0 + phase + 2.0) +
            amp *
                0.12 *
                math.sin(xFrac * math.pi * 17 + drift * 0.6 + phase + 3.5);

        final wave = oceanWave + (mountWave - oceanWave) * sharpness;
        path.lineTo(x, baseY + wave);
      }

      path.lineTo(w, h);
      path.close();

      final dayColor = Color.lerp(_oceanDay[i], _forestDay[i], tb)!;
      final nightColor = Color.lerp(_oceanNight[i], _forestNight[i], tb)!;
      final baseColor = Color.lerp(dayColor, nightColor, nightAlpha)!;
      canvas.drawPath(path, Paint()..color = baseColor);
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalWavesPainter oldDelegate) {
    return oldDelegate.animValue != animValue ||
        oldDelegate.nightAlpha != nightAlpha ||
        oldDelegate.themeBlend != themeBlend;
  }
}

class _CloudsPainter extends CustomPainter {
  final double progress;
  final double nightAlpha;
  final WeatherCondition? weatherCondition;

  const _CloudsPainter({
    required this.progress,
    required this.nightAlpha,
    required this.weatherCondition,
  });

  // Each cloud: [x01, y01, scale, speed, phase, layer(0=back,1=front)]
  static final List<List<double>> _clouds = _initClouds();
  static List<List<double>> _initClouds() {
    final rng = math.Random(91);
    final list = <List<double>>[];
    // Broad, distant cloud banks.
    for (var i = 0; i < 3; i++) {
      list.add([
        rng.nextDouble(),
        0.06 + rng.nextDouble() * 0.58,
        0.85 + rng.nextDouble() * 0.55,
        0.08 + rng.nextDouble() * 0.12,
        rng.nextDouble() * 6.28,
        0.0,
      ]);
    }
    // Smaller foreground clouds and wisps.
    for (var i = 0; i < 4; i++) {
      list.add([
        rng.nextDouble(),
        0.1 + rng.nextDouble() * 0.68,
        0.5 + rng.nextDouble() * 0.5,
        0.18 + rng.nextDouble() * 0.22,
        rng.nextDouble() * 6.28,
        1.0,
      ]);
    }
    return list;
  }

  Path _buildCloudPath(
    double cx,
    double cy,
    double cw,
    double ch,
    double phase,
  ) {
    final leftLobe = 0.36 + 0.035 * math.sin(phase * 1.7);
    final centerLobe = 0.48 + 0.04 * math.sin(phase * 0.9 + 1.2);
    final rightLobe = 0.31 + 0.035 * math.sin(phase * 1.3 + 2.4);
    final path = Path()
      ..moveTo(cx - cw * 0.55, cy + ch * 0.16)
      ..cubicTo(
        cx - cw * 0.67,
        cy + ch * 0.11,
        cx - cw * 0.64,
        cy - ch * 0.08,
        cx - cw * 0.47,
        cy - ch * 0.12,
      )
      ..cubicTo(
        cx - cw * 0.43,
        cy - ch * leftLobe,
        cx - cw * 0.23,
        cy - ch * (leftLobe + 0.04),
        cx - cw * 0.13,
        cy - ch * 0.22,
      )
      ..cubicTo(
        cx - cw * 0.03,
        cy - ch * 0.37,
        cx + cw * 0.07,
        cy - ch * centerLobe,
        cx + cw * 0.2,
        cy - ch * 0.29,
      )
      ..cubicTo(
        cx + cw * 0.31,
        cy - ch * 0.4,
        cx + cw * 0.43,
        cy - ch * rightLobe,
        cx + cw * 0.46,
        cy - ch * 0.12,
      )
      ..cubicTo(
        cx + cw * 0.62,
        cy - ch * 0.08,
        cx + cw * 0.65,
        cy + ch * 0.09,
        cx + cw * 0.48,
        cy + ch * 0.17,
      )
      ..cubicTo(
        cx + cw * 0.26,
        cy + ch * 0.27,
        cx - cw * 0.16,
        cy + ch * 0.25,
        cx - cw * 0.34,
        cy + ch * 0.2,
      )
      ..cubicTo(
        cx - cw * 0.48,
        cy + ch * 0.23,
        cx - cw * 0.57,
        cy + ch * 0.2,
        cx - cw * 0.55,
        cy + ch * 0.16,
      )
      ..close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final t = progress * 2 * math.pi;

    // Time-of-day color
    final duskAmount = nightAlpha < 0.5
        ? nightAlpha * 2.0
        : 2.0 - nightAlpha * 2.0;
    const dayColor = Color(0xFFDCE8F4);
    const duskColor = Color(0xFFDEB8A0);
    const nightColor = Color(0xFF8292A8);

    final warmTint = Color.lerp(dayColor, duskColor, duskAmount.clamp(0, 1))!;
    final baseColor = Color.lerp(warmTint, nightColor, nightAlpha)!;

    for (final cloud in _clouds) {
      final isBack = cloud[5] < 0.5;
      final speed = cloud[3];
      final phase = cloud[4];
      final scale = cloud[2] * (isBack ? 1.4 : 1.0);

      final alpha = isBack ? 0.07 : 0.14;
      final cloudAmount = switch (weatherCondition) {
        WeatherCondition.clear => 0.62,
        WeatherCondition.partlyCloudy => 0.88,
        WeatherCondition.cloudy || WeatherCondition.fog => 1.2,
        WeatherCondition.rain || WeatherCondition.snow => 1.08,
        WeatherCondition.thunderstorm => 0.92,
        null => 1.0,
      };
      final weatherDim = switch (weatherCondition) {
        WeatherCondition.rain => 0.78,
        WeatherCondition.thunderstorm => 0.58,
        WeatherCondition.fog => 0.82,
        _ => 1.0,
      };
      final finalAlpha =
          alpha * cloudAmount * weatherDim * (1.0 - nightAlpha * 0.28);

      // Slow left-to-right drift, with distant clouds moving more slowly.
      final drift = (progress * speed * 0.65 + phase / (2 * math.pi)) % 1.3;
      final cx = ((cloud[0] + drift) % 1.3 - 0.15) * w;
      final cw = w * 0.42 * scale;
      final ch = cw * 0.3;
      final cy =
          h * cloud[1] +
          ch * 0.035 * math.sin(t * 0.08 + phase) +
          ch * 0.012 * math.sin(t * 0.17 + phase * 1.4);

      final evolvingPhase = phase + 0.08 * math.sin(t * 0.045 + phase);
      final cloudPath = _buildCloudPath(cx, cy, cw, ch, evolvingPhase);

      final diffusePaint = Paint()
        ..isAntiAlias = true
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, ch * 0.12)
        ..color = baseColor.withValues(alpha: finalAlpha * 0.3);
      canvas.drawPath(cloudPath, diffusePaint);

      final shadowPaint = Paint()
        ..isAntiAlias = true
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, ch * 0.09)
        ..color = const Color(0xFF101A28).withValues(alpha: finalAlpha * 0.2);
      canvas.save();
      canvas.translate(0, ch * 0.08);
      canvas.drawPath(cloudPath, shadowPaint);
      canvas.restore();

      // Muted vertical shading gives the cloud volume without a hard outline.
      final topColor = baseColor.withValues(alpha: finalAlpha * 0.95);
      final bottomColor = baseColor.withValues(alpha: finalAlpha * 0.48);

      final fillPaint = Paint()
        ..isAntiAlias = true
        ..shader =
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [topColor, bottomColor],
            ).createShader(
              Rect.fromCenter(
                center: Offset(cx, cy),
                width: cw,
                height: ch * 2,
              ),
            );

      canvas.drawPath(cloudPath, fillPaint);

      canvas.save();
      canvas.clipPath(cloudPath);
      final lowerShade = Rect.fromCenter(
        center: Offset(cx + cw * 0.08, cy + ch * 0.22),
        width: cw * 0.88,
        height: ch * 0.72,
      );
      canvas.drawOval(
        lowerShade,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              baseColor.withValues(alpha: finalAlpha * 0.04),
              baseColor.withValues(alpha: finalAlpha * 0.24),
            ],
          ).createShader(lowerShade),
      );
      final highlightRect = Rect.fromCenter(
        center: Offset(cx - cw * 0.12, cy - ch * 0.23),
        width: cw * 0.74,
        height: ch * 1.15,
      );
      canvas.drawOval(
        highlightRect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              baseColor.withValues(alpha: finalAlpha * 0.18),
              baseColor.withValues(alpha: 0),
            ],
          ).createShader(highlightRect),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _CloudsPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.nightAlpha != nightAlpha ||
        oldDelegate.weatherCondition != weatherCondition;
  }
}

class _WeatherPainter extends CustomPainter {
  final WeatherSnapshot weather;
  final double progress;

  const _WeatherPainter({required this.weather, required this.progress});

  static final List<List<double>> _rain = _makeParticles(58, 71);
  static final List<List<double>> _snow = _makeParticles(34, 93);

  static List<List<double>> _makeParticles(int count, int seed) {
    final random = math.Random(seed);
    return List.generate(
      count,
      (_) => [
        random.nextDouble(),
        random.nextDouble(),
        0.55 + random.nextDouble() * 1.2,
        random.nextDouble() * 2 * math.pi,
        0.45 + random.nextDouble() * 0.9,
      ],
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final intensity = weather.intensity.clamp(0.0, 1.0);
    switch (weather.condition) {
      case WeatherCondition.rain:
        _paintRain(canvas, size, progress, intensity: intensity);
      case WeatherCondition.snow:
        _paintSnow(canvas, size, progress, intensity: intensity);
      case WeatherCondition.fog:
        _paintFog(canvas, size, progress, intensity: intensity);
      case WeatherCondition.thunderstorm:
        _paintRain(canvas, size, progress, intensity: intensity * 0.72);
        _paintLightning(canvas, size, progress, intensity: intensity);
      case WeatherCondition.clear ||
          WeatherCondition.partlyCloudy ||
          WeatherCondition.cloudy:
        break;
    }
  }

  void _paintRain(
    Canvas canvas,
    Size size,
    double progress, {
    required double intensity,
  }) {
    final t = progress * 2 * math.pi;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.1;

    final visibleCount = (_rain.length * (0.25 + 0.75 * intensity)).round();
    for (var i = 0; i < visibleCount; i++) {
      final drop = _rain[i];
      final yProgress = (drop[1] + progress * drop[4] * 0.52) % 1.18;
      final y = size.height * (yProgress - 0.09);
      final wind = yProgress * size.width * 0.075;
      final x = size.width * drop[0] + wind + 4 * math.sin(t * 0.08 + drop[3]);
      final length = (10 + 16 * drop[2]) * (0.8 + 0.2 * intensity);
      paint
        ..strokeWidth = 0.65 + drop[2] * 0.55
        ..color = const Color(
          0xFFD8E9FF,
        ).withValues(alpha: (0.12 + 0.12 * drop[2]) * intensity);
      canvas.drawLine(
        Offset(x, y),
        Offset(x - length * 0.12, y + length),
        paint,
      );

      if (yProgress > 0.91 && yProgress < 1.08) {
        final splashProgress = (yProgress - 0.91) / 0.17;
        paint
          ..strokeWidth = 0.8
          ..color = const Color(
            0xFFD8E9FF,
          ).withValues(alpha: (1 - splashProgress) * 0.18 * intensity);
        final groundY = size.height * 0.94;
        canvas.drawLine(
          Offset(x - 2, groundY),
          Offset(x - 5 - splashProgress * 3, groundY - splashProgress * 3),
          paint,
        );
        canvas.drawLine(
          Offset(x + 2, groundY),
          Offset(x + 5 + splashProgress * 3, groundY - splashProgress * 3),
          paint,
        );
      }
    }
  }

  void _paintSnow(
    Canvas canvas,
    Size size,
    double progress, {
    required double intensity,
  }) {
    final t = progress * 2 * math.pi;
    final paint = Paint()..isAntiAlias = true;

    final visibleCount = (_snow.length * (0.3 + 0.7 * intensity)).round();
    for (var i = 0; i < visibleCount; i++) {
      final flake = _snow[i];
      final yProgress = (flake[1] + progress * flake[4] * 0.2) % 1.12;

      final x =
          size.width * flake[0] +
          18 * math.sin(t * 0.09 + flake[3] + yProgress * 4);
      final y = size.height * (yProgress - 0.06);
      final radius = 0.8 + flake[2] * (0.9 + 0.45 * intensity);
      paint.color = Colors.white.withValues(
        alpha: (0.2 + 0.17 * flake[2]) * intensity,
      );
      if (flake[2] > 1.15) {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.65;
        for (var arm = 0; arm < 3; arm++) {
          final angle = t * 0.025 + arm * math.pi / 3;
          final dx = math.cos(angle) * radius;
          final dy = math.sin(angle) * radius;
          canvas.drawLine(
            Offset(x - dx, y - dy),
            Offset(x + dx, y + dy),
            paint,
          );
        }
        paint.style = PaintingStyle.fill;
      } else {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  void _paintFog(
    Canvas canvas,
    Size size,
    double progress, {
    required double intensity,
  }) {
    final t = progress * 2 * math.pi;

    for (var i = 0; i < 4; i++) {
      final bandWidth = size.width * 1.2;
      final bandHeight = size.height * (0.1 + (i % 2) * 0.04);
      final y =
          size.height * (0.2 + i * 0.15) +
          size.height * 0.025 * math.sin(t * 0.06 + i * 1.9);
      final x =
          -size.width * 0.2 +
          size.width * 0.18 * math.sin(t * (0.035 + i * 0.004) + i * 1.7);
      final rect = Rect.fromLTWH(x, y, bandWidth, bandHeight);
      final paint = Paint()
        ..isAntiAlias = true
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18)
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(
              alpha: (0.025 + (i % 2) * 0.012) * intensity,
            ),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(bandHeight / 2)),
        paint,
      );
    }
  }

  void _paintLightning(
    Canvas canvas,
    Size size,
    double progress, {
    required double intensity,
  }) {
    final phase = progress % 1.0;
    var flash = 0.0;
    for (final center in const [0.27, 0.285, 0.76, 0.774]) {
      final distance = (phase - center).abs();
      flash = math.max(flash, (1 - distance / 0.009).clamp(0, 1));
    }
    if (flash <= 0) return;

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(
          0xFFDDE7FF,
        ).withValues(alpha: flash * 0.06 * intensity),
    );

    final path = Path()
      ..moveTo(size.width * 0.72, size.height * 0.12)
      ..lineTo(size.width * 0.68, size.height * 0.2)
      ..lineTo(size.width * 0.72, size.height * 0.2)
      ..lineTo(size.width * 0.65, size.height * 0.31)
      ..moveTo(size.width * 0.68, size.height * 0.2)
      ..lineTo(size.width * 0.62, size.height * 0.24)
      ..moveTo(size.width * 0.69, size.height * 0.22)
      ..lineTo(size.width * 0.75, size.height * 0.27);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: flash * 0.35 * intensity)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _WeatherPainter oldDelegate) =>
      oldDelegate.weather != weather || oldDelegate.progress != progress;
}

class _ScanArcPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          Colors.tealAccent.withValues(alpha: 0),
          Colors.tealAccent.withValues(alpha: 0.7),
          Colors.tealAccent.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.35, 0.7],
      ).createShader(rect);

    canvas.drawArc(rect.deflate(4), 0, math.pi * 1.4, false, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
