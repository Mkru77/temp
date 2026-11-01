import 'dart:async';
import 'package:universal_ble/universal_ble.dart' hide BleService;
import '../models/sensor_reading.dart';
import 'ble_service.dart';

class BleServiceWindows implements BleService {
  final _readingController = StreamController<SensorReading>.broadcast();
  final _adapterController = StreamController<BleAdapterState>.broadcast();

  StreamSubscription<AvailabilityState>? _adapterStateSub;
  StreamSubscription<BleDevice>? _scanSub;
  bool _scanning = false;
  bool _batteryRead = false;
  bool _waitingForBattery = false;
  Timer? _batteryRefreshTimer;
  Timer? _batteryWaitTimer;

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
    _adapterStateSub = UniversalBle.availabilityStream.listen((state) {
      if (state == AvailabilityState.poweredOn) {
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
      final state = await UniversalBle.getBluetoothAvailabilityState();
      if (state != AvailabilityState.poweredOn) {
        _scanning = false;
        _adapterController.add(BleAdapterState.off);
        return;
      }
    } catch (_) {
      _scanning = false;
      return;
    }

    _scanSub?.cancel();
    _scanSub = UniversalBle.scanStream.listen((device) {
      if (_isSensor(device)) {
        _parseAdvertisement(device);
        if (!_batteryRead) {
          _batteryRead = true;
          _waitingForBattery = true;
          _readBatteryViaGatt(device.deviceId);
          _batteryWaitTimer = Timer(const Duration(seconds: 4), () {
            if (_waitingForBattery) {
              _waitingForBattery = false;
              _dispatch();
            }
          });
        }
      }
    });

    try {
      await UniversalBle.startScan();
    } catch (e) {
      _scanning = false;
    }
  }

  @override
  void stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    _scanning = false;
    try {
      UniversalBle.stopScan();
    } catch (_) {}
  }

  bool _isSensor(BleDevice device) {
    final name = (device.name ?? '').toUpperCase();
    return MiBeaconParser.isSensorName(name);
  }

  void _parseAdvertisement(BleDevice device) {
    for (final entry in device.serviceData.entries) {
      if (entry.key.toLowerCase().contains('fe95')) {
        final reading = MiBeaconParser.parse(entry.value.toList());
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

  Future<void> _readBatteryViaGatt(String deviceId) async {
    try {
      await UniversalBle.connect(
        deviceId,
        timeout: const Duration(seconds: 10),
      );
      await Future.delayed(const Duration(milliseconds: 100));
      final services = await UniversalBle.discoverServices(deviceId);
      for (final service in services) {
        if (service.uuid.toLowerCase().contains('180f')) {
          for (final char in service.characteristics) {
            if (char.uuid.toLowerCase().contains('2a19')) {
              // ignore: deprecated_member_use
              final value = await UniversalBle.readValue(
                deviceId,
                service.uuid,
                char.uuid,
              );
              if (value.isNotEmpty) {
                _state = _state.copyWith(battery: value[0]);
                _waitingForBattery = false;
                _batteryWaitTimer?.cancel();
                _dispatch();
              }
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
        await UniversalBle.disconnect(deviceId);
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
    // Windows doesn't support programmatic Bluetooth toggle
  }

  @override
  Future<void> refresh() async {
    stopScan();
    _batteryRead = false;
    _waitingForBattery = false;
    _batteryWaitTimer?.cancel();
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
