import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/location_sample.dart';
import '../services/tracking_controller.dart';

class MeasurementsScreen extends StatefulWidget {
  final TrackingController trackingController;

  const MeasurementsScreen({super.key, required this.trackingController});

  @override
  State<MeasurementsScreen> createState() => _MeasurementsScreenState();
}

class _MeasurementsScreenState extends State<MeasurementsScreen> {
  static const MethodChannel _downloadChannel =
      MethodChannel('jorat/downloads');

  bool _isUpdatingCollection = false;
  bool _isUpdatingLocationMode = false;
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mesures de position'),
        actions: [
          IconButton(
            icon: _isExporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download),
            tooltip: 'Exporter CSV',
            onPressed: _isExporting
                ? null
                : () => _exportCsv(widget.trackingController.samples),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.trackingController,
        builder: (context, _) {
          final samples = widget.trackingController.samples.reversed.toList();
          final isCollecting = widget.trackingController.isCollecting;
          final useNetworkAssisted =
              widget.trackingController.useNetworkAssisted;

          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Card(
                  elevation: 1,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SwitchListTile(
                        title: const Text('Localisation active'),
                        subtitle: Text(
                          isCollecting
                              ? 'Collecte GPS en cours'
                              : 'Collecte GPS arrêtée',
                        ),
                        value: isCollecting,
                        onChanged: _isUpdatingCollection
                            ? null
                            : (value) async {
                                setState(() => _isUpdatingCollection = true);
                                await widget.trackingController
                                    .setCollecting(value);
                                if (!mounted) return;
                                setState(() => _isUpdatingCollection = false);
                              },
                      ),
                      const Divider(height: 0),
                      SwitchListTile(
                        title: const Text('Localisation assistée par réseau'),
                        subtitle: Text(
                          useNetworkAssisted
                              ? 'Mode rapide (réseau + GNSS)'
                              : 'Mode GPS pur',
                        ),
                        value: useNetworkAssisted,
                        onChanged: _isUpdatingLocationMode
                            ? null
                            : (value) async {
                                setState(() => _isUpdatingLocationMode = true);
                                await widget.trackingController
                                    .setUseNetworkAssisted(value);
                                if (!mounted) return;
                                setState(() => _isUpdatingLocationMode = false);
                              },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Card(
                    elevation: 1,
                    child: samples.isEmpty
                        ? const Center(
                            child: Text('Aucune mesure disponible pour le moment'),
                          )
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SingleChildScrollView(
                              child: DataTable(
                                columns: const [
                                  DataColumn(label: Text('Latitude')),
                                  DataColumn(label: Text('Longitude')),
                                  DataColumn(label: Text('Heure')),
                                  DataColumn(label: Text('Précision')),
                                  DataColumn(label: Text('Qualité')),
                                  DataColumn(label: Text('Réseau')),
                                  DataColumn(label: Text('Aide réseau')),
                                ],
                                rows: samples.asMap().entries.map((entry) {
                                  final index = entry.key;
                                  final sample = entry.value;
                                  return DataRow.byIndex(
                                    index: index,
                                    onSelectChanged: (_) =>
                                        Navigator.of(context).pop(sample),
                                    cells: [
                                      DataCell(
                                        Text(sample.latitude.toStringAsFixed(6)),
                                      ),
                                      DataCell(
                                        Text(sample.longitude.toStringAsFixed(6)),
                                      ),
                                      DataCell(Text(_formatLocalTime(sample))),
                                      DataCell(
                                        Text(
                                          sample.accuracyMeters.toStringAsFixed(2),
                                        ),
                                      ),
                                      DataCell(Text(sample.quality)),
                                      DataCell(
                                        Text(sample.wasNetworkAvailable ? 'Oui' : 'Non'),
                                      ),
                                      DataCell(
                                        Text(sample.usedNetworkAssisted ? 'Oui' : 'Non'),
                                      ),
                                    ],
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatLocalTime(LocationSample sample) {
    final d = sample.measuredAtUtc.toLocal();
    final hour = d.hour.toString().padLeft(2, '0');
    final minute = d.minute.toString().padLeft(2, '0');
    final second = d.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  Future<void> _exportCsv(List<LocationSample> samples) async {
    if (samples.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune donnée à exporter.')),
      );
      return;
    }

    setState(() => _isExporting = true);
    try {
      final buffer = StringBuffer()
        ..writeln(
          'measured_at_utc,latitude,longitude,accuracy,altitude_m,speed_mps,heading_deg,is_mocked,network_available,network_assisted',
        );

      for (final sample in samples) {
        buffer.writeln([
          _csv(sample.measuredAtUtc.toIso8601String()),
          sample.latitude.toStringAsFixed(6),
          sample.longitude.toStringAsFixed(6),
          sample.accuracyMeters.toStringAsFixed(2),
          _num(sample.altitudeMeters),
          _num(sample.speedMps),
          _num(sample.headingDegrees),
          sample.isMocked ? 'true' : 'false',
          sample.wasNetworkAvailable ? 'yes' : 'no',
          sample.usedNetworkAssisted ? 'yes' : 'no',
        ].join(','));
      }

      final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      final fileName = 'jorat_measurements_$ts.csv';
      String savedLocation;

      if (Platform.isAndroid) {
        savedLocation = await _saveCsvToAndroidDownloads(
          fileName: fileName,
          content: buffer.toString(),
        );
      } else {
        final dir = await _resolveExportDirectory();
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(buffer.toString(), flush: true);
        savedLocation = file.path;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV exporté: $savedLocation')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur export CSV: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
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
          if (downloadDir != null &&
              await _isWritableDirectory(downloadDir)) {
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

  String _num(double? value) => value == null ? '' : value.toStringAsFixed(2);

  String _csv(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }
}
