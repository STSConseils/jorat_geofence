import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../models/location_sample.dart';
import '../models/network_measurement.dart';

class LocationCollectionService {
  static const MethodChannel _networkChannel = MethodChannel('jorat/network');
  static const int _tcpAttemptsPerHost = 4;
  static const int _tcpWarmupAttemptsPerHost = 1;
  static const Duration _tcpProbeTimeout = Duration(seconds: 3);
  static const List<String> _tcpProbeHosts = ['8.8.8.8', '1.1.1.1', '9.9.9.9'];
  static const int _downlinkAttemptsPerEndpoint = 1;
  static const int _downlinkParallelStreams = 2;
  static const List<String> _downlinkProbeUrlTemplates = [
    'https://speed.cloudflare.com/__down?bytes={bytes}',
    'https://proof.ovh.net/files/1Mb.dat',
  ];
  static const Duration _downlinkProbeTimeout = Duration(seconds: 16);
  static const int _downlinkProbeWarmupBytes = 256 * 1024;
  static const Duration _downlinkProbeWarmupDuration = Duration(seconds: 1);
  static const int _downlinkProbeMinBytes = 1024 * 1024;
  static const int _downlinkProbeMaxBytes = 6 * 1024 * 1024;
  static const Duration _downlinkProbeMaxTransferDuration =
      Duration(seconds: 10);

  final Duration interval;
  final Duration fixWindow;
  bool _useNetworkAssisted;

  LocationCollectionService({
    this.interval = const Duration(minutes: 1),
    this.fixWindow = const Duration(seconds: 20),
    bool useNetworkAssisted = true,
  }) : _useNetworkAssisted = useNetworkAssisted;

  final StreamController<LocationSample> _sampleController =
      StreamController<LocationSample>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  Stream<LocationSample> get samples => _sampleController.stream;
  Stream<String> get errors => _errorController.stream;
  bool get useNetworkAssisted => _useNetworkAssisted;

  StreamSubscription<Position>? _positionSubscription;
  Timer? _samplingTimer;
  Timer? _windowTimer;

  final List<Position> _windowPositions = <Position>[];
  Position? _latestPosition;

  bool _windowOpen = false;
  bool _isEmittingSample = false;

  Future<bool> setUseNetworkAssisted(bool enabled) async {
    if (_useNetworkAssisted == enabled) return true;

    _useNetworkAssisted = enabled;
    developer.log(
      '[LocationCollectionService] mode changed: '
      '${_useNetworkAssisted ? "network-assisted" : "gps-only"}',
    );

    final wasRunning = _positionSubscription != null;
    if (!wasRunning) return true;

    await stop();
    return start();
  }

  Future<bool> start() async {
    if (_positionSubscription != null) return true;

    final ready = await _ensureLocationReady();
    if (!ready) return false;

    try {
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: _streamLocationSettings(),
      ).listen(
        (position) {
          _latestPosition = position;
          if (_windowOpen) {
            _windowPositions.add(position);
          }
        },
        onError: (error) {
          _errorController.add('Flux GPS interrompu: $error');
        },
      );

      developer.log(
        '[LocationCollectionService] stream started '
        'interval=$interval window=$fixWindow mode='
        '${_useNetworkAssisted ? "network-assisted" : "gps-only"}',
      );

      _openSamplingWindow();
      _samplingTimer = Timer.periodic(interval, (_) {
        _openSamplingWindow();
      });

      return true;
    } catch (e) {
      _errorController.add('Impossible de demarrer le suivi GPS: $e');
      await stop();
      return false;
    }
  }

  Future<void> stop() async {
    _samplingTimer?.cancel();
    _samplingTimer = null;

    _windowTimer?.cancel();
    _windowTimer = null;

    await _positionSubscription?.cancel();
    _positionSubscription = null;

    _windowPositions.clear();
    _latestPosition = null;
    _windowOpen = false;
    _isEmittingSample = false;

    developer.log('[LocationCollectionService] stream stopped');
  }

  void _openSamplingWindow() {
    if (_windowOpen || _isEmittingSample) {
      return;
    }

    _windowOpen = true;
    _windowPositions.clear();

    developer.log(
      '[LocationCollectionService] sampling window open for ${fixWindow.inSeconds}s',
    );

    _windowTimer?.cancel();
    _windowTimer = Timer(fixWindow, () {
      unawaited(_closeSamplingWindowAndEmit());
    });
  }

  Future<void> _closeSamplingWindowAndEmit() async {
    if (!_windowOpen) return;

    _windowOpen = false;
    _windowTimer?.cancel();
    _windowTimer = null;

    if (_isEmittingSample) return;
    _isEmittingSample = true;

    try {
      Position? selected = _bestAccuracyPosition(_windowPositions);
      selected ??= _latestPosition;

      selected ??= await Geolocator.getCurrentPosition(
        locationSettings: _currentLocationSettings(),
        timeLimit: const Duration(seconds: 15),
      );

      final measuredAt = DateTime.now().toUtc();
      final networkSnapshotFuture = _readNetworkSnapshot();
      final networkMeasurementFuture = _readNetworkMeasurement();
      final batterySnapshotFuture = _readBatterySnapshot();
      final networkSnapshot = await networkSnapshotFuture;
      final networkMeasurement = await networkMeasurementFuture;
      final batterySnapshot = await batterySnapshotFuture;
      final usedNetworkAssisted = _useNetworkAssisted;

      _sampleController.add(
        LocationSample(
          measuredAtUtc: measuredAt,
          latitude: selected.latitude,
          longitude: selected.longitude,
          accuracyMeters: selected.accuracy,
          altitudeMeters: selected.altitude,
          speedMps: selected.speed,
          headingDegrees: selected.heading,
          isMocked: selected.isMocked,
          wasNetworkAvailable: networkSnapshot.available,
          usedNetworkAssisted: usedNetworkAssisted,
          networkType: networkSnapshot.type,
          batteryLevelPercent: batterySnapshot?.levelPercent,
          isCharging: batterySnapshot?.isCharging,
          networkMeasurement: networkMeasurement,
        ),
      );

      developer.log(
        '[LocationCollectionService] sample emitted '
        'lat=${selected.latitude}, lon=${selected.longitude}, '
        'acc=${selected.accuracy}, points=${_windowPositions.length}, '
        'net=${networkSnapshot.available}, netType=${networkSnapshot.type}, '
        'radio=${networkMeasurement?.declaredNetworkType}, '
        'dbm=${networkMeasurement?.signalDbm}, '
        'voice=${networkMeasurement?.voiceCapable}, '
        'tcp=${networkMeasurement?.tcpLatencyMedianMs}, '
        'down=${networkMeasurement?.downlinkKbps}, '
        'usage=${networkMeasurement?.usageLabel}, '
        'battery=${batterySnapshot?.levelPercent}, '
        'charging=${batterySnapshot?.isCharging}, '
        'assisted=$usedNetworkAssisted',
      );
    } catch (e) {
      _errorController.add('Echec collecte GPS: $e');
    } finally {
      _windowPositions.clear();
      _isEmittingSample = false;
    }
  }

  Position? _bestAccuracyPosition(List<Position> positions) {
    if (positions.isEmpty) return null;

    Position best = positions.first;
    for (final position in positions.skip(1)) {
      if (position.accuracy < best.accuracy) {
        best = position;
      }
    }
    return best;
  }

  LocationSettings _streamLocationSettings() {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      );
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: _useNetworkAssisted
              ? LocationAccuracy.high
              : LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1),
          forceLocationManager: !_useNetworkAssisted,
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Collecte GPS active',
            notificationText: 'Mesures en cours en arriere-plan',
            enableWakeLock: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
        );
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        );
    }
  }

  LocationSettings _currentLocationSettings() {
    if (kIsWeb) {
      return const LocationSettings(accuracy: LocationAccuracy.best);
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: _useNetworkAssisted
              ? LocationAccuracy.high
              : LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
          forceLocationManager: !_useNetworkAssisted,
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Collecte GPS active',
            notificationText: 'Mesures en cours en arriere-plan',
            enableWakeLock: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
        );
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return const LocationSettings(accuracy: LocationAccuracy.best);
    }
  }

  Future<_NetworkSnapshot> _readNetworkSnapshot() async {
    try {
      final dynamic raw = await Connectivity().checkConnectivity();
      final List<ConnectivityResult> values;

      if (raw is ConnectivityResult) {
        values = [raw];
      } else if (raw is List) {
        values = raw.whereType<ConnectivityResult>().toList();
      } else {
        values = const [];
      }

      if (values.isEmpty || values.contains(ConnectivityResult.none)) {
        return const _NetworkSnapshot(available: false, type: 'none');
      }

      if (values.contains(ConnectivityResult.wifi)) {
        return const _NetworkSnapshot(available: true, type: 'wifi');
      }

      if (values.contains(ConnectivityResult.ethernet)) {
        return const _NetworkSnapshot(available: true, type: 'ethernet');
      }

      if (values.contains(ConnectivityResult.mobile)) {
        final mobileType = await _readMobileGeneration();
        return _NetworkSnapshot(available: true, type: mobileType);
      }

      return const _NetworkSnapshot(available: true, type: 'other');
    } catch (_) {
      return const _NetworkSnapshot(available: false, type: 'unknown');
    }
  }

  Future<String> _readMobileGeneration() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return 'mobile';
    }

    try {
      final result = await _networkChannel.invokeMethod<String>('getNetworkType');
      if (result == null || result.isEmpty) return 'mobile';
      return result.toLowerCase();
    } on PlatformException {
      return 'mobile';
    }
  }

  Future<NetworkMeasurement?> _readNetworkMeasurement() async {
    final radioFuture = _readRadioSnapshot();
    final tcpFuture = _probeTcpLatencyMedianMs();
    final downlinkFuture = _probeDownlinkKbps();

    final radio = await radioFuture;
    final tcpLatency = await tcpFuture;
    final downlink = await downlinkFuture;

    if (radio == null && tcpLatency == null && downlink == null) {
      return null;
    }

    final declaredType = radio?.declaredNetworkType ?? 'unknown';
    final signalDbm = radio?.signalDbm;
    final voiceCapable = radio?.voiceCapable;

    return NetworkMeasurement(
      declaredNetworkType: declaredType,
      signalDbm: signalDbm,
      voiceCapable: voiceCapable,
      tcpLatencyMedianMs: tcpLatency,
      downlinkKbps: downlink,
      usageLevel: NetworkMeasurement.deriveUsageLevel(
        declaredNetworkType: declaredType,
        voiceCapable: voiceCapable,
        tcpLatencyMedianMs: tcpLatency,
        downlinkKbps: downlink,
      ),
    );
  }

  Future<_BatterySnapshot?> _readBatterySnapshot() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    try {
      final result = await _networkChannel.invokeMapMethod<String, dynamic>(
        'getBatterySnapshot',
      );
      if (result == null) return null;

      final level = _toDoubleOrNull(result['batteryLevelPercent']);
      final charging = result['isCharging'] as bool?;

      if (level == null && charging == null) return null;
      return _BatterySnapshot(levelPercent: level, isCharging: charging);
    } on PlatformException {
      return null;
    }
  }

  Future<_RadioSnapshot?> _readRadioSnapshot() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    try {
      final result = await _networkChannel.invokeMapMethod<String, dynamic>(
        'getRadioSnapshot',
      );
      if (result == null) return null;

      final declaredType =
          (result['declaredNetworkType'] as String? ?? 'unknown').toLowerCase();

      final signalDbm = _toIntOrNull(result['signalDbm']);
      final voiceCapable = result['voiceCapable'] as bool?;

      return _RadioSnapshot(
        declaredNetworkType: declaredType,
        signalDbm: signalDbm,
        voiceCapable: voiceCapable,
      );
    } on PlatformException {
      return null;
    }
  }

  Future<double?> _probeTcpLatencyMedianMs() async {
    final futures = _tcpProbeHosts
        .map(
          (host) => _probeTcpHostMedianLatencyMs(
            host: host,
            port: 53,
            timeout: _tcpProbeTimeout,
          ),
        )
        .toList();

    final samples = await Future.wait<double?>(futures);
    final valid = samples.whereType<double>().toList()..sort();
    if (valid.isEmpty) return null;
    return _median(valid);
  }

  Future<double?> _probeTcpHostMedianLatencyMs({
    required String host,
    required int port,
    required Duration timeout,
  }) async {
    final values = <double>[];
    final totalAttempts = _tcpWarmupAttemptsPerHost + _tcpAttemptsPerHost;
    for (var i = 0; i < totalAttempts; i++) {
      final value = await _probeTcpHostLatencyMs(
        host: host,
        port: port,
        timeout: timeout,
      );
      if (i >= _tcpWarmupAttemptsPerHost && value != null) {
        values.add(value);
      }
    }
    if (values.isEmpty) return null;
    values.sort();
    return _median(values);
  }

  Future<double?> _probeTcpHostLatencyMs({
    required String host,
    required int port,
    required Duration timeout,
  }) async {
    Socket? socket;
    final stopwatch = Stopwatch()..start();
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      stopwatch.stop();
      return stopwatch.elapsedMicroseconds / 1000.0;
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  Future<double?> _probeDownlinkKbps() async {
    final globalCandidates = <double>[];

    for (final template in _downlinkProbeUrlTemplates) {
      final endpointCandidates = <double>[];

      for (var attempt = 0; attempt < _downlinkAttemptsPerEndpoint; attempt++) {
        final kbps = await _measureParallelDownlinkKbps(
          url: _resolveDownlinkProbeUrl(template, _downlinkProbeMaxBytes),
          timeout: _downlinkProbeTimeout,
          minBytes: _downlinkProbeMinBytes,
          maxBytes: _downlinkProbeMaxBytes,
          maxTransferDuration: _downlinkProbeMaxTransferDuration,
        );
        if (kbps != null) {
          endpointCandidates.add(kbps);
        }
      }

      if (endpointCandidates.isNotEmpty) {
        endpointCandidates.sort();
        final endpointBest = endpointCandidates.last;
        globalCandidates.add(endpointBest);
        developer.log(
          '[LocationCollectionService] downlink endpoint best '
          'template=$template kbps=$endpointBest',
        );
      }
    }

    if (globalCandidates.isEmpty) return null;
    globalCandidates.sort();
    return globalCandidates.last;
  }

  String _resolveDownlinkProbeUrl(String template, int bytes) {
    return template.replaceAll('{bytes}', bytes.toString());
  }

  Future<double?> _measureParallelDownlinkKbps({
    required String url,
    required Duration timeout,
    required int minBytes,
    required int maxBytes,
    required Duration maxTransferDuration,
  }) async {
    final futures = <Future<double?>>[];
    for (var i = 0; i < _downlinkParallelStreams; i++) {
      futures.add(
        _measureDownlinkKbps(
          url: _appendCacheBust(url, i),
          timeout: timeout,
          minBytes: minBytes,
          maxBytes: maxBytes,
          maxTransferDuration: maxTransferDuration,
          logResult: i == 0,
        ),
      );
    }

    final values = (await Future.wait<double?>(futures)).whereType<double>().toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b);
  }

  String _appendCacheBust(String url, int streamIndex) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}cb=${DateTime.now().microsecondsSinceEpoch}_$streamIndex';
  }

  Future<double?> _measureDownlinkKbps({
    required String url,
    required Duration timeout,
    required int minBytes,
    required int maxBytes,
    required Duration maxTransferDuration,
    bool logResult = true,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;

    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-${maxBytes - 1}',
      );

      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      var received = 0;
      final transferStopwatch = Stopwatch();
      final measurementStopwatch = Stopwatch();
      var measurementStartBytes = 0;
      var measuredBytes = 0;
      await for (final chunk in response.timeout(timeout)) {
        if (!transferStopwatch.isRunning) {
          transferStopwatch.start();
        }
        received += chunk.length;

        // Ignore early ramp-up bytes/time before computing throughput.
        if (!measurementStopwatch.isRunning &&
            (received >= _downlinkProbeWarmupBytes ||
                transferStopwatch.elapsed >= _downlinkProbeWarmupDuration)) {
          measurementStopwatch.start();
          measurementStartBytes = received;
        }

        if (measurementStopwatch.isRunning) {
          measuredBytes = received - measurementStartBytes;
        }

        if (received >= maxBytes) {
          break;
        }
        if (measurementStopwatch.isRunning &&
            measurementStopwatch.elapsed >= maxTransferDuration &&
            measuredBytes >= minBytes) {
          break;
        }
      }
      if (transferStopwatch.isRunning) {
        transferStopwatch.stop();
      }
      if (measurementStopwatch.isRunning) {
        measurementStopwatch.stop();
      }

      if (measuredBytes <= 0) return null;
      final seconds = measurementStopwatch.elapsedMicroseconds / 1000000.0;
      if (seconds <= 0) return null;

      final kbps = (measuredBytes * 8.0) / 1000.0 / seconds;
      if (kbps.isNaN || kbps.isInfinite) return null;
      if (logResult) {
        developer.log(
          '[LocationCollectionService] downlink probe url=$url rawBytes=$received '
          'measuredBytes=$measuredBytes seconds=$seconds kbps=$kbps',
        );
      }
      return kbps;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  double _median(List<double> sortedValues) {
    if (sortedValues.isEmpty) return 0;
    final middle = sortedValues.length ~/ 2;
    if (sortedValues.length.isOdd) {
      return sortedValues[middle];
    }
    return (sortedValues[middle - 1] + sortedValues[middle]) / 2.0;
  }

  int? _toIntOrNull(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  double? _toDoubleOrNull(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Future<bool> _ensureLocationReady() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _errorController.add('Service de localisation desactive.');
      return false;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _errorController.add('Permission de localisation refusee.');
      return false;
    }

    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        permission == LocationPermission.whileInUse) {
      final upgradedPermission = await Geolocator.requestPermission();
      if (upgradedPermission != LocationPermission.denied &&
          upgradedPermission != LocationPermission.deniedForever) {
        permission = upgradedPermission;
      }
      _errorController.add(
        'Permission en arriere-plan recommandee: Android > App > Autorisations > Localisation > Toujours autoriser.',
      );
    }

    return true;
  }

  void dispose() {
    unawaited(stop());
    _sampleController.close();
    _errorController.close();
  }
}

class _NetworkSnapshot {
  final bool available;
  final String type;

  const _NetworkSnapshot({
    required this.available,
    required this.type,
  });
}

class _RadioSnapshot {
  final String declaredNetworkType;
  final int? signalDbm;
  final bool? voiceCapable;

  const _RadioSnapshot({
    required this.declaredNetworkType,
    required this.signalDbm,
    required this.voiceCapable,
  });
}

class _BatterySnapshot {
  final double? levelPercent;
  final bool? isCharging;

  const _BatterySnapshot({
    required this.levelPercent,
    required this.isCharging,
  });
}
