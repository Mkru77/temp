import 'dart:async';
import 'dart:math';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/sensor_reading.dart';
import 'ble_service.dart';

class BleServiceMobile implements BleService {
  static final _batteryCharUuid = Guid('00002a19-0000-1000-8000-00805f9b34fb');

  final _readingController = StreamController<SensorReading>.broadcast();
  final _adapterController = StreamController<BleAdapterState>.broadcast();

  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanning = false;
  bool _batteryRead = false;
  bool _waitingForBattery = false;
  Timer? _batteryRefreshTimer;
  Timer? _batteryWaitTimer;
  DateTime? _lastSensorTimestamp;

  var _state = const SensorReading();

  @override
  Stream<SensorReading> get readings => _readingController.stream;
  @override
  Stream<BleAdapterState> get adapterState => _adapterController.stream;

  @override
  void init() {
    _listenAdapterState();
    startScan();
  }

  void _listenAdapterState() {
    _adapterStateSub = FlutterBluePlus.adapterState
        .handleError((error) {})
        .listen((state) {
          if (state == BluetoothAdapterState.on) {
            _adapterController.add(BleAdapterState.on);
            startScan();
          } else {
            _adapterController.add(BleAdapterState.off);
            stopScan();
          }
        });
  }

  @override
  Future<void> startScan() async {
    if (_scanning) return;
    _scanning = true;

    try {
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _scanning = false;
        _adapterController.add(BleAdapterState.off);
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {}
        return;
      }
    } on UnsupportedError {
      _scanning = false;
      return;
    } catch (_) {
      _scanning = false;
      return;
    }

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (_isSensor(r)) {
          if (_lastSensorTimestamp != null &&
              !r.timeStamp.isAfter(_lastSensorTimestamp!)) {
            continue;
          }
          _lastSensorTimestamp = r.timeStamp;
          _parseAdvertisement(r);
          if (!_batteryRead) {
            _batteryRead = true;
            _waitingForBattery = true;
            final dev = r.device;
            _readBatteryViaGatt(dev);
            _batteryWaitTimer = Timer(const Duration(seconds: 4), () {
              if (_waitingForBattery) {
                _waitingForBattery = false;
                _dispatch();
              }
            });
          }
        }
      }
    });

    try {
      FlutterBluePlus.startScan(
        timeout: const Duration(minutes: 10),
        androidUsesFineLocation: true,
        continuousUpdates: true,
      );
    } catch (e) {
      _scanning = false;
      final retry = min(30, 3 * pow(2, 0).toInt());
      Future.delayed(Duration(seconds: retry), startScan);
    }
  }

  @override
  void stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    _scanning = false;
    try {
      FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  bool _isSensor(ScanResult r) {
    final name = r.device.platformName.toUpperCase();
    return name.contains('LYWSD') || name.contains('MJ_HT_V1');
  }

  void _parseAdvertisement(ScanResult r) {
    for (final entry in r.advertisementData.serviceData.entries) {
      if (entry.key.toString().toLowerCase().contains('fe95')) {
        final reading = MiBeaconParser.parse(entry.value);
        if (reading.hasData) {
          _state = _state.copyWith(
            temperature: reading.temperature ?? _state.temperature,
            humidity: reading.humidity ?? _state.humidity,
            battery: reading.battery ?? _state.battery,
          );
          _dispatch();
        }
        return;
      }
    }
  }

  Future<void> _readBatteryViaGatt(BluetoothDevice device) async {
    try {
      await device.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
        license: License.nonprofit,
      );
      await Future.delayed(const Duration(milliseconds: 100));
      final services = await device.discoverServices();
      for (final service in services) {
        for (final char in service.characteristics) {
          if (char.uuid == _batteryCharUuid) {
            final value = await char.read();
            if (value.isNotEmpty) {
              _state = _state.copyWith(battery: value[0]);
              _waitingForBattery = false;
              _batteryWaitTimer?.cancel();
              _dispatch();
            }
          }
        }
      }
    } catch (_) {
      if (_waitingForBattery) {
        _waitingForBattery = false;
        _batteryWaitTimer?.cancel();
        _dispatch();
      }
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
    }

    _batteryRefreshTimer?.cancel();
    _batteryRefreshTimer = Timer(const Duration(minutes: 10), () {
      _batteryRead = false;
    });
  }

  DateTime _lastDispatch = DateTime.fromMillisecondsSinceEpoch(0);

  void _dispatch() {
    if (_waitingForBattery) return;

    final now = DateTime.now();
    if (now.difference(_lastDispatch) < const Duration(milliseconds: 200)) {
      return;
    }
    _lastDispatch = now;

    if (!_readingController.isClosed) {
      _readingController.add(_state);
    }
  }

  @override
  Future<void> turnOnBluetooth() async {
    try {
      await FlutterBluePlus.turnOn();
    } catch (_) {}
  }

  @override
  Future<void> refresh() async {
    stopScan();
    _batteryRead = false;
    _waitingForBattery = false;
    _batteryWaitTimer?.cancel();
    _lastSensorTimestamp = null;
    await startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _adapterStateSub?.cancel();
    _batteryRefreshTimer?.cancel();
    _batteryWaitTimer?.cancel();
    _readingController.close();
    _adapterController.close();
    stopScan();
  }
}
