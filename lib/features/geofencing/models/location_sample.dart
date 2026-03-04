import 'network_measurement.dart';

class LocationSample {
  final DateTime measuredAtUtc;
  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final double? altitudeMeters;
  final double? speedMps;
  final double? headingDegrees;
  final bool isMocked;
  final bool wasNetworkAvailable;
  final bool usedNetworkAssisted;
  final String networkType;
  final double? batteryLevelPercent;
  final bool? isCharging;
  final NetworkMeasurement? networkMeasurement;

  const LocationSample({
    required this.measuredAtUtc,
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.isMocked,
    required this.wasNetworkAvailable,
    required this.usedNetworkAssisted,
    required this.networkType,
    this.batteryLevelPercent,
    this.isCharging,
    this.networkMeasurement,
    this.altitudeMeters,
    this.speedMps,
    this.headingDegrees,
  });

  String get quality {
    if (accuracyMeters <= 5) return 'excellent';
    if (accuracyMeters <= 15) return 'good';
    return 'poor';
  }
}
