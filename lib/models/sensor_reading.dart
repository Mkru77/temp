class SensorReading {
  final double? temperature;
  final double? humidity;
  final int? battery;

  const SensorReading({this.temperature, this.humidity, this.battery});

  SensorReading copyWith({
    double? temperature,
    double? humidity,
    int? battery,
  }) {
    return SensorReading(
      temperature: temperature ?? this.temperature,
      humidity: humidity ?? this.humidity,
      battery: battery ?? this.battery,
    );
  }

  bool get hasData =>
      temperature != null || humidity != null || battery != null;

  @override
  String toString() {
    return 'SensorReading(temp: $temperature, hum: $humidity, batt: $battery)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SensorReading &&
        other.temperature == temperature &&
        other.humidity == humidity &&
        other.battery == battery;
  }

  @override
  int get hashCode => Object.hash(temperature, humidity, battery);
}
