import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/location_sample.dart';
import '../services/tracking_controller.dart';
import '../../../theme/jorapp_theme.dart';

class MeasurementsScreen extends StatefulWidget {
  final TrackingController trackingController;

  const MeasurementsScreen({super.key, required this.trackingController});

  @override
  State<MeasurementsScreen> createState() => _MeasurementsScreenState();
}

class _MeasurementsScreenState extends State<MeasurementsScreen> {
  bool _isUpdatingCollection = false;
  bool _isUpdatingLocationMode = false;
  bool _isSharing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/branding/jorapp_logo.png',
                width: 26,
                height: 26,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 8),
            const Text('Tableau des mesures'),
          ],
        ),
        actions: [
          IconButton.filledTonal(
            style: IconButton.styleFrom(
              backgroundColor: JorappColors.surfaceStrong,
              foregroundColor: JorappColors.tealDark,
            ),
            icon: _isSharing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share_rounded),
            tooltip: 'Partager CSV',
            onPressed: _isSharing
                ? null
                : () => _shareCsv(widget.trackingController.samples),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.trackingController,
        builder: (context, _) {
          final samples = widget.trackingController.samples.reversed.toList();
          final isCollecting = widget.trackingController.isCollecting;
          final useNetworkAssisted =
              widget.trackingController.useNetworkAssisted;

          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFF8FAF5), Color(0xFFEAF2E3)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: JorappColors.surfaceStrong,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.timeline_rounded,
                              color: JorappColors.tealDark,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Points collectes: ${samples.length}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  samples.isEmpty
                                      ? 'Aucun point pour le moment'
                                      : 'Derniere mesure: ${_formatLocalTime(samples.first)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF50616A),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Card(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SwitchListTile(
                          title: const Text('Localisation active'),
                          subtitle: Text(
                            isCollecting
                                ? 'Collecte GPS en cours'
                                : 'Collecte GPS arretee',
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
                          title: const Text('Localisation assistee par reseau'),
                          subtitle: Text(
                            useNetworkAssisted
                                ? 'Mode rapide (reseau + GNSS)'
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
                      child: samples.isEmpty
                          ? const Center(
                              child: Text(
                                'Aucune mesure disponible pour le moment',
                              ),
                            )
                          : SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SingleChildScrollView(
                                child: DataTable(
                                  headingRowColor: MaterialStateProperty.all(
                                    JorappColors.surfaceStrong,
                                  ),
                                  dataRowMinHeight: 44,
                                  columns: const [
                                    DataColumn(label: Text('Latitude')),
                                    DataColumn(label: Text('Longitude')),
                                    DataColumn(label: Text('Heure')),
                                    DataColumn(label: Text('Precision')),
                                    DataColumn(label: Text('Qualite')),
                                    DataColumn(label: Text('Reseau')),
                                    DataColumn(label: Text('Aide reseau')),
                                    DataColumn(label: Text('Batterie %')),
                                    DataColumn(label: Text('Charge')),
                                    DataColumn(label: Text('Radio')),
                                    DataColumn(label: Text('Signal dBm')),
                                    DataColumn(label: Text('Voix')),
                                    DataColumn(label: Text('Usage')),
                                    DataColumn(label: Text('Latence ms')),
                                    DataColumn(label: Text('Debit Mbps')),
                                  ],
                                  rows: samples.asMap().entries.map((entry) {
                                    final index = entry.key;
                                    final sample = entry.value;
                                    final network = sample.networkMeasurement;
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
                                          Text(
                                            _formatNetworkType(sample.networkType),
                                          ),
                                        ),
                                        DataCell(
                                          Text(
                                            sample.usedNetworkAssisted
                                                ? 'Oui'
                                                : 'Non',
                                          ),
                                        ),
                                        DataCell(
                                          Text(
                                            _formatMetric(
                                              sample.batteryLevelPercent,
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          Text(_boolToOuiNon(sample.isCharging)),
                                        ),
                                        DataCell(
                                          Text(
                                            _formatNetworkType(
                                              network?.declaredNetworkType ??
                                                  sample.networkType,
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          Text(
                                            network?.signalDbm?.toString() ?? '',
                                          ),
                                        ),
                                        DataCell(
                                          Text(_boolToOuiNon(network?.voiceCapable)),
                                        ),
                                        DataCell(Text(network?.usageLabel ?? '')),
                                        DataCell(
                                          Text(_formatMetric(network?.tcpLatencyMedianMs)),
                                        ),
                                        DataCell(
                                          Text(
                                            _formatMetric(
                                              _kbpsToMbps(network?.downlinkKbps),
                                            ),
                                          ),
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

  String _formatNetworkType(String value) {
    switch (value.toLowerCase()) {
      case '2g':
        return '2G';
      case '3g':
        return '3G';
      case '4g':
        return '4G';
      case '5g':
        return '5G';
      case 'wifi':
        return 'Wi-Fi';
      case 'ethernet':
        return 'Ethernet';
      case 'none':
        return 'Aucun';
      case 'mobile':
        return 'Mobile';
      default:
        return 'Inconnu';
    }
  }

  Future<void> _shareCsv(List<LocationSample> samples) async {
    if (samples.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune donnée à partager.')),
      );
      return;
    }

    setState(() => _isSharing = true);
    try {
      final buffer = StringBuffer()
        ..writeln(
          'measured_at_utc,latitude,longitude,accuracy,altitude_m,speed_mps,heading_deg,is_mocked,network_available,network_type,network_assisted,battery_level_percent,battery_charging,declared_network_type,signal_dbm,voice_capable,network_usage,tcp_latency_median_ms,downlink_mbps',
        );

      for (final sample in samples) {
        final network = sample.networkMeasurement;
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
          sample.networkType,
          sample.usedNetworkAssisted ? 'yes' : 'no',
          _num(sample.batteryLevelPercent),
          _boolToYesNo(sample.isCharging),
          network?.declaredNetworkType ?? '',
          network?.signalDbm?.toString() ?? '',
          _boolToYesNo(network?.voiceCapable),
          network?.usageLabel ?? '',
          _num(network?.tcpLatencyMedianMs),
          _num(_kbpsToMbps(network?.downlinkKbps)),
        ].join(','));
      }

      final ts = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
      final fileName = 'jorat_measurements_$ts.csv';
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(buffer.toString(), flush: true);

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Mesures GPS Jorat',
        text: 'Mesures GPS exportées ($fileName)',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Partage ouvert.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur partage CSV: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isSharing = false);
      }
    }
  }

  String _num(double? value) => value == null ? '' : value.toStringAsFixed(2);

  double? _kbpsToMbps(double? valueKbps) {
    if (valueKbps == null) return null;
    return valueKbps / 1000.0;
  }

  String _formatMetric(double? value) {
    if (value == null) return '';
    return value.toStringAsFixed(1);
  }

  String _boolToOuiNon(bool? value) {
    if (value == null) return '';
    return value ? 'Oui' : 'Non';
  }

  String _boolToYesNo(bool? value) {
    if (value == null) return '';
    return value ? 'yes' : 'no';
  }

  String _csv(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }
}
