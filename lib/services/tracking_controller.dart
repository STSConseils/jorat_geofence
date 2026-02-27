import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/location_sample.dart';
import 'location_collection_service.dart';

class TrackingController extends ChangeNotifier {
  static const MethodChannel _downloadChannel =
      MethodChannel('jorat/downloads');
  static const String _autoSaveFileName = 'jorat_measurements_autosave.csv';

  final LocationCollectionService _locationService;
  final List<LocationSample> _samples = [];
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  StreamSubscription<LocationSample>? _sampleSubscription;
  StreamSubscription<String>? _errorSubscription;

  bool _isCollecting = false;
  bool _initialized = false;
  bool _isAutoSaving = false;
  bool _autoSavePending = false;

  TrackingController({LocationCollectionService? locationService})
      : _locationService = locationService ?? LocationCollectionService();

  List<LocationSample> get samples => List.unmodifiable(_samples);
  LocationSample? get latestSample => _samples.isEmpty ? null : _samples.last;
  bool get isCollecting => _isCollecting;
  bool get useNetworkAssisted => _locationService.useNetworkAssisted;
  Stream<String> get errors => _errorController.stream;

  Future<void> initialize({bool autoStart = true}) async {
    if (_initialized) return;
    _initialized = true;

    _sampleSubscription = _locationService.samples.listen((sample) {
      _samples.add(sample);
      notifyListeners();
      unawaited(_scheduleAutoSave());
    });

    _errorSubscription = _locationService.errors.listen((error) {
      _errorController.add(error);
    });

    if (autoStart) {
      await start();
    }
  }

  Future<void> start() async {
    if (_isCollecting) return;
    _isCollecting = await _locationService.start();
    notifyListeners();
  }

  Future<void> stop() async {
    if (!_isCollecting) return;
    await _locationService.stop();
    _isCollecting = false;
    notifyListeners();
  }

  Future<void> setCollecting(bool enabled) async {
    if (enabled) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> setUseNetworkAssisted(bool enabled) async {
    final restarted = await _locationService.setUseNetworkAssisted(enabled);
    if (!restarted && _isCollecting) {
      _isCollecting = false;
    }
    notifyListeners();
  }

  Future<void> forceAutoSave() async {
    await _scheduleAutoSave();
  }

  Future<void> _scheduleAutoSave() async {
    if (_samples.isEmpty) return;

    if (_isAutoSaving) {
      _autoSavePending = true;
      return;
    }

    _isAutoSaving = true;
    try {
      do {
        _autoSavePending = false;
        await _saveAutoCsvSnapshot();
      } while (_autoSavePending);
    } catch (e) {
      developer.log('[TrackingController] auto CSV save failed: $e');
      if (!_errorController.isClosed) {
        _errorController.add('Sauvegarde auto CSV échouée: $e');
      }
    } finally {
      _isAutoSaving = false;
    }
  }

  Future<void> _saveAutoCsvSnapshot() async {
    final snapshot = List<LocationSample>.from(_samples);
    if (snapshot.isEmpty) return;

    final csv = _buildCsv(snapshot);
    if (Platform.isAndroid) {
      final savedLocation = await _saveCsvToAndroidDownloads(
        fileName: _autoSaveFileName,
        content: csv,
      );
      developer.log('[TrackingController] auto CSV saved: $savedLocation');
      return;
    }

    final dir = await _resolveExportDirectory();
    final file = File('${dir.path}/$_autoSaveFileName');
    await file.writeAsString(csv, flush: true);
    developer.log('[TrackingController] auto CSV saved: ${file.path}');
  }

  String _buildCsv(List<LocationSample> samples) {
    final buffer = StringBuffer()
      ..writeln(
        'measured_at_utc,latitude,longitude,accuracy,quality,altitude_m,speed_mps,heading_deg,is_mocked,network_available,network_assisted',
      );

    for (final sample in samples) {
      buffer.writeln([
        _csv(sample.measuredAtUtc.toIso8601String()),
        sample.latitude.toStringAsFixed(6),
        sample.longitude.toStringAsFixed(6),
        sample.accuracyMeters.toStringAsFixed(2),
        sample.quality,
        _num(sample.altitudeMeters),
        _num(sample.speedMps),
        _num(sample.headingDegrees),
        sample.isMocked ? 'true' : 'false',
        sample.wasNetworkAvailable ? 'yes' : 'no',
        sample.usedNetworkAssisted ? 'yes' : 'no',
      ].join(','));
    }

    return buffer.toString();
  }

  Future<Directory> _resolveExportDirectory() async {
    if (Platform.isAndroid) {
      final sharedDownloadDir = Directory('/storage/emulated/0/Download');
      if (await sharedDownloadDir.exists() &&
          await _isWritableDirectory(sharedDownloadDir)) {
        return sharedDownloadDir;
      }

      final androidDownloads = await getExternalStorageDirectories(
        type: StorageDirectory.downloads,
      );
      if (androidDownloads != null) {
        for (final downloadDir in androidDownloads) {
          if (downloadDir != null && await _isWritableDirectory(downloadDir)) {
            return downloadDir;
          }
        }
      }
    }

    final downloads = await getDownloadsDirectory();
    if (downloads != null && await _isWritableDirectory(downloads)) {
      return downloads;
    }

    return getApplicationDocumentsDirectory();
  }

  Future<bool> _isWritableDirectory(Directory dir) async {
    try {
      await dir.create(recursive: true);
      final probe = File('${dir.path}/.__jorat_write_probe__');
      await probe.writeAsString('ok', flush: true);
      if (await probe.exists()) {
        await probe.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _saveCsvToAndroidDownloads({
    required String fileName,
    required String content,
  }) async {
    final result = await _downloadChannel.invokeMethod<String>(
      'saveCsvToDownloads',
      {
        'fileName': fileName,
        'content': content,
      },
    );

    if (result == null || result.isEmpty) {
      throw Exception('Emplacement de sauvegarde introuvable');
    }
    return result;
  }

  String _num(double? value) => value == null ? '' : value.toStringAsFixed(2);

  String _csv(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  @override
  void dispose() {
    unawaited(forceAutoSave());
    _sampleSubscription?.cancel();
    _errorSubscription?.cancel();
    _errorController.close();
    _locationService.dispose();
    super.dispose();
  }
}
