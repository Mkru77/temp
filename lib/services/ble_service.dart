import 'dart:async';
import 'dart:io' show Platform;
import '../models/sensor_reading.dart';
import 'ble_service_mobile.dart';
import 'ble_service_windows.dart';

/// Adapter state exposed to the UI layer.
enum BleAdapterState { on, off, unknown }

abstract class BleService {
  factory BleService() {
    if (Platform.isAndroid || Platform.isIOS) return BleServiceMobile();
    if (Platform.isWindows) return BleServiceWindows();
    return _BleServiceStub();
  }

  Stream<SensorReading> get readings;
  Stream<BleAdapterState> get adapterState;

  void init();
  Future<void> startScan();
  void stopScan();
  Future<void> turnOnBluetooth();
  Future<void> refresh();
  void dispose();
}

/// Shared Mi Beacon parser used by all implementations.
class MiBeaconParser {
  static const int typeTemperature = 0x1004;
  static const int typeHumidity = 0x1006;
  static const int typeTempHumidity = 0x100D;
  static const int typeBattery = 0x100A;

  static SensorReading parse(List<int> data) {
    if (data.length < 5) return const SensorReading();
    final frameCtrl = data[0] | (data[1] << 8);
    final hasMac = (frameCtrl & 0x10) != 0;
    final hasCapability = (frameCtrl & 0x20) != 0;
    final hasPayload = (frameCtrl & 0x40) != 0;
    if (!hasPayload) return const SensorReading();

    int offset = 5;
    if (hasMac) offset += 6;
    if (hasCapability) offset += 1;

    double? temperature;
    double? humidity;
    int? battery;

    while (offset + 3 <= data.length) {
      final dataType = data[offset] | (data[offset + 1] << 8);
      final dataLen = data[offset + 2];
      offset += 3;
      if (offset + dataLen > data.length) break;
      final payload = data.sublist(offset, offset + dataLen);
      switch (dataType) {
        case typeTemperature:
          if (payload.length >= 2) {
            final raw = payload[0] | (payload[1] << 8);
            temperature = (raw > 32767 ? raw - 65536 : raw) / 10.0;
          }
          break;
        case typeHumidity:
          if (payload.length >= 2) {
            final raw = payload[0] | (payload[1] << 8);
            humidity = raw / 10.0;
          }
          break;
        case typeTempHumidity:
          if (payload.length >= 4) {
            final rawT = payload[0] | (payload[1] << 8);
            final rawH = payload[2] | (payload[3] << 8);
            temperature = (rawT > 32767 ? rawT - 65536 : rawT) / 10.0;
            humidity = rawH / 10.0;
          }
          break;
        case typeBattery:
          if (payload.isNotEmpty) {
            battery = payload[0];
          }
          break;
        default:
          break;
      }
      offset += dataLen;
    }

    return SensorReading(
      temperature: temperature,
      humidity: humidity,
      battery: battery,
    );
  }

  static bool isSensorName(String name) {
    final upper = name.toUpperCase();
    return upper.contains('LYWSD') || upper.contains('MJ_HT_V1');
  }
}

/// No-op stub for unsupported platforms (Linux, macOS, web).
class _BleServiceStub implements BleService {
  final _readingController = StreamController<SensorReading>.broadcast();
  final _adapterController = StreamController<BleAdapterState>.broadcast();

  @override
  Stream<SensorReading> get readings => _readingController.stream;
  @override
  Stream<BleAdapterState> get adapterState => _adapterController.stream;
  @override
  void init() {}
  @override
  Future<void> startScan() async {}
  @override
  void stopScan() {}
  @override
  Future<void> turnOnBluetooth() async {}
  @override
  Future<void> refresh() async {}
  @override
  void dispose() {
    _readingController.close();
    _adapterController.close();
  }
}
