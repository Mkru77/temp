import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

enum WeatherCondition {
  clear,
  partlyCloudy,
  cloudy,
  fog,
  rain,
  snow,
  thunderstorm,
}

class WeatherSnapshot {
  final WeatherCondition condition;
  final double intensity;
  final double? currentTemperature;
  final List<WeatherForecastDay> forecast;
  final double latitude;
  final double longitude;
  final String? approximateLocality;

  const WeatherSnapshot({
    required this.condition,
    required this.intensity,
    required this.currentTemperature,
    required this.forecast,
    required this.latitude,
    required this.longitude,
    required this.approximateLocality,
  });

  String get animationKey => '${condition.name}_${(intensity * 10).round()}';
}

class WeatherForecastDay {
  final DateTime date;
  final WeatherCondition condition;
  final double minimumTemperature;
  final double maximumTemperature;

  const WeatherForecastDay({
    required this.date,
    required this.condition,
    required this.minimumTemperature,
    required this.maximumTemperature,
  });
}

extension WeatherConditionPresentation on WeatherCondition {
  String get label => switch (this) {
    WeatherCondition.clear => 'Pogodnie',
    WeatherCondition.partlyCloudy => 'Lekkie zachmurzenie',
    WeatherCondition.cloudy => 'Pochmurno',
    WeatherCondition.fog => 'Mgła',
    WeatherCondition.rain => 'Deszcz',
    WeatherCondition.snow => 'Śnieg',
    WeatherCondition.thunderstorm => 'Burza',
  };

  String get animationKey => name;

  bool get hasOverlay => switch (this) {
    WeatherCondition.rain ||
    WeatherCondition.snow ||
    WeatherCondition.fog ||
    WeatherCondition.thunderstorm => true,
    _ => false,
  };

  static WeatherCondition fromWmoCode(int code) => switch (code) {
    0 => WeatherCondition.clear,
    1 || 2 => WeatherCondition.partlyCloudy,
    3 => WeatherCondition.cloudy,
    45 || 48 => WeatherCondition.fog,
    51 ||
    53 ||
    55 ||
    56 ||
    57 ||
    61 ||
    63 ||
    65 ||
    66 ||
    67 ||
    80 ||
    81 ||
    82 => WeatherCondition.rain,
    71 || 73 || 75 || 77 || 85 || 86 => WeatherCondition.snow,
    95 || 96 || 99 => WeatherCondition.thunderstorm,
    _ => throw FormatException('Nieobsługiwany kod pogody: $code'),
  };

  static double intensityFromWmoCode(int code) => switch (code) {
    51 || 56 || 71 || 77 => 0.38,
    53 || 57 || 73 || 85 || 80 => 0.52,
    55 || 61 || 66 || 81 || 86 => 0.68,
    63 || 67 || 96 => 0.78,
    65 || 75 || 82 || 99 => 0.92,
    95 => 0.72,
    _ => 0.5,
  };
}

class WeatherServiceException implements Exception {
  final String message;

  const WeatherServiceException(this.message);

  @override
  String toString() => message;
}

class WeatherService {
  static String? _cachedLocality;
  static String? _cachedLocationKey;
  static DateTime? _lastGeocodingRequest;

  static Future<WeatherSnapshot> fetchCurrentCondition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const WeatherServiceException(
        'Włącz lokalizację w telefonie, aby pobrać pogodę.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      throw const WeatherServiceException(
        'Zezwól aplikacji na lokalizację w ustawieniach telefonu.',
      );
    }
    if (permission == LocationPermission.denied) {
      throw const WeatherServiceException(
        'Zezwól aplikacji na lokalizację, aby pobrać pogodę.',
      );
    }

    final Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } on TimeoutException {
      throw const WeatherServiceException(
        'Nie udało się ustalić lokalizacji na czas.',
      );
    } on LocationServiceDisabledException {
      throw const WeatherServiceException(
        'Włącz lokalizację w telefonie, aby pobrać pogodę.',
      );
    }

    final localityFuture = _lookupApproximateLocality(
      position.latitude,
      position.longitude,
    );
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': position.latitude.toString(),
      'longitude': position.longitude.toString(),
      'current': 'weather_code,temperature_2m',
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min',
      'forecast_days': '4',
      'timezone': 'auto',
    });

    final http.Response response;
    try {
      response = await http.get(uri).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const WeatherServiceException(
        'Serwis pogody nie odpowiedział na czas.',
      );
    } on http.ClientException {
      throw const WeatherServiceException(
        'Nie udało się połączyć z serwisem pogody.',
      );
    }

    if (response.statusCode != 200) {
      throw WeatherServiceException(
        'Serwis pogody zwrócił błąd (${response.statusCode}).',
      );
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
      final current = body['current'] as Map<String, dynamic>;
      final currentWeatherCode = (current['weather_code'] as num).toInt();
      final currentTemperature = current['temperature_2m'] as num;
      final daily = body['daily'] as Map<String, dynamic>;
      final dates = daily['time'] as List<dynamic>;
      final weatherCodes = daily['weather_code'] as List<dynamic>;
      final maximums = daily['temperature_2m_max'] as List<dynamic>;
      final minimums = daily['temperature_2m_min'] as List<dynamic>;
      if (dates.length != weatherCodes.length ||
          dates.length != maximums.length ||
          dates.length != minimums.length) {
        throw const WeatherServiceException(
          'Prognoza pogody ma nieprawidłowy format.',
        );
      }

      final approximateLocality = await localityFuture;
      final forecast = <WeatherForecastDay>[];
      for (var i = 0; i < dates.length; i++) {
        final date = DateTime.tryParse(dates[i] as String);
        if (date == null) {
          throw const WeatherServiceException(
            'Data prognozy pogody jest nieprawidłowa.',
          );
        }
        forecast.add(
          WeatherForecastDay(
            date: date,
            condition: WeatherConditionPresentation.fromWmoCode(
              (weatherCodes[i] as num).toInt(),
            ),
            minimumTemperature: (minimums[i] as num).toDouble(),
            maximumTemperature: (maximums[i] as num).toDouble(),
          ),
        );
      }
      return WeatherSnapshot(
        condition: WeatherConditionPresentation.fromWmoCode(currentWeatherCode),
        intensity: WeatherConditionPresentation.intensityFromWmoCode(
          currentWeatherCode,
        ),
        currentTemperature: currentTemperature.toDouble(),
        forecast: forecast,
        latitude: position.latitude,
        longitude: position.longitude,
        approximateLocality: approximateLocality,
      );
    } on FormatException {
      rethrow;
    } on WeatherServiceException {
      rethrow;
    } on TypeError {
      throw const WeatherServiceException(
        'Odpowiedź serwisu pogody ma nieprawidłowy format.',
      );
    }
  }

  static Future<String?> _lookupApproximateLocality(
    double latitude,
    double longitude,
  ) async {
    final locationKey =
        '${latitude.toStringAsFixed(2)},${longitude.toStringAsFixed(2)}';
    if (_cachedLocationKey == locationKey) return _cachedLocality;

    final lastRequest = _lastGeocodingRequest;
    if (lastRequest != null) {
      final elapsed = DateTime.now().difference(lastRequest);
      if (elapsed < const Duration(seconds: 1)) {
        await Future<void>.delayed(const Duration(seconds: 1) - elapsed);
      }
    }

    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': latitude.toString(),
      'lon': longitude.toString(),
      'format': 'jsonv2',
      'zoom': '10',
      'addressdetails': '1',
      'accept-language': 'pl',
    });

    try {
      _lastGeocodingRequest = DateTime.now();
      final response = await http
          .get(uri, headers: const {'User-Agent': 'TempSensorWidget/1.0'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        debugPrint(
          'Reverse geocoding failed with HTTP ${response.statusCode}.',
        );
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final address = body['address'] as Map<String, dynamic>?;
      if (address == null) {
        debugPrint('Reverse geocoding response did not contain an address.');
        return null;
      }

      String? locality;
      for (final field in [
        address['city'],
        address['town'],
        address['village'],
        address['municipality'],
        address['county'],
      ]) {
        if (field is String && field.isNotEmpty) {
          locality = field;
          break;
        }
      }
      if (locality == null || locality.isEmpty) {
        debugPrint('Reverse geocoding did not find a nearby locality.');
        return null;
      }

      _cachedLocationKey = locationKey;
      _cachedLocality = locality;
      return locality;
    } on TimeoutException {
      debugPrint('Reverse geocoding request timed out.');
      return null;
    } on http.ClientException catch (error) {
      debugPrint('Reverse geocoding request failed: $error');
      return null;
    } on FormatException catch (error) {
      debugPrint('Reverse geocoding returned invalid JSON: $error');
      return null;
    } on TypeError catch (error) {
      debugPrint('Reverse geocoding returned an invalid response: $error');
      return null;
    }
  }
}
