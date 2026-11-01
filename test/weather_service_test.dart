import 'package:flutter_test/flutter_test.dart';
import 'package:temp/services/weather_service.dart';

void main() {
  group('WeatherConditionPresentation.fromWmoCode', () {
    test('maps clear and cloudy weather', () {
      expect(
        WeatherConditionPresentation.fromWmoCode(0),
        WeatherCondition.clear,
      );
      expect(
        WeatherConditionPresentation.fromWmoCode(2),
        WeatherCondition.partlyCloudy,
      );
      expect(
        WeatherConditionPresentation.fromWmoCode(3),
        WeatherCondition.cloudy,
      );
    });

    test('maps precipitation and severe weather', () {
      expect(
        WeatherConditionPresentation.fromWmoCode(45),
        WeatherCondition.fog,
      );
      expect(
        WeatherConditionPresentation.fromWmoCode(61),
        WeatherCondition.rain,
      );
      expect(
        WeatherConditionPresentation.fromWmoCode(71),
        WeatherCondition.snow,
      );
      expect(
        WeatherConditionPresentation.fromWmoCode(95),
        WeatherCondition.thunderstorm,
      );
    });

    test('rejects unknown weather codes', () {
      expect(
        () => WeatherConditionPresentation.fromWmoCode(-1),
        throwsFormatException,
      );
    });

    test('scales precipitation intensity by WMO severity', () {
      expect(
        WeatherConditionPresentation.intensityFromWmoCode(51),
        lessThan(WeatherConditionPresentation.intensityFromWmoCode(65)),
      );
      expect(
        WeatherConditionPresentation.intensityFromWmoCode(71),
        lessThan(WeatherConditionPresentation.intensityFromWmoCode(75)),
      );
      expect(WeatherConditionPresentation.intensityFromWmoCode(0), 0.5);
    });
  });
}
