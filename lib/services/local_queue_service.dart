import 'dart:convert';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Offline-first encrypted queue for emergency telemetry.
///
/// This implementation uses an encrypted Hive box so the queue works on mobile
/// and desktop without a platform-specific SQLite plugin.
class LocalQueueService {
  LocalQueueService._();

  static final LocalQueueService instance = LocalQueueService._();

  static const String _boxName = 'emergency_telemetry';

  Box<dynamic>? _box;
  bool _networkAvailable = true;
  bool _uploadInProgress = false;

  /// Initializes the encrypted queue store.
  Future<void> initialize() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.initFlutter();
      _box = await Hive.openBox<dynamic>(
        _boxName,
        encryptionCipher: HiveAesCipher(_resolveEncryptionKey()),
      );
    } else {
      _box = Hive.box<dynamic>(_boxName);
    }
  }

  /// Marks whether the app currently has network connectivity.
  ///
  /// Telemetry stays queued while offline and is only drained when both network
  /// is available and an explicit upload completes successfully.
  void setNetworkAvailable(bool isAvailable) {
    _networkAvailable = isAvailable;
  }

  /// Adds a telemetry row to the local encrypted queue.
  Future<int> enqueueTelemetry(double lat, double lng, String trigger) async {
    final box = await _openBox();

    final key = await box.add(<String, Object?>{
      'latitude': lat,
      'longitude': lng,
      'trigger_type': trigger,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    return key as int;
  }

  /// Returns all queued telemetry items ordered by oldest first.
  Future<List<QueuedTelemetryItem>> getQueuedItems() async {
    final box = await _openBox();
    final entries = box.toMap().entries.toList(growable: false);
    entries.sort((left, right) {
      final leftItem = QueuedTelemetryItem.fromMap(left.key as int, left.value);
      final rightItem = QueuedTelemetryItem.fromMap(right.key as int, right.value);
      return leftItem.timestamp.compareTo(rightItem.timestamp);
    });

    return entries
        .map((entry) => QueuedTelemetryItem.fromMap(entry.key as int, entry.value))
        .toList(growable: false);
  }

  /// Deletes a set of queued item ids after a successful upload.
  Future<int> deleteItems(List<int> ids) async {
    if (ids.isEmpty) {
      return 0;
    }

    final box = await _openBox();
    await box.deleteAll(ids);
    return ids.length;
  }

  /// Runs a callback while controlling queue draining.
  ///
  /// The upload callback should throw if the server rejects the batch; queued
  /// telemetry is only removed if the callback completes without error.
  Future<int> flushIfOnline(
    Future<void> Function(List<QueuedTelemetryItem> items) uploadCallback,
  ) async {
    if (!_networkAvailable || _uploadInProgress) {
      return 0;
    }

    _uploadInProgress = true;
    try {
      final items = await getQueuedItems();
      if (items.isEmpty) {
        return 0;
      }

      await uploadCallback(items);
      await deleteItems(items.map((item) => item.id).toList(growable: false));
      return items.length;
    } finally {
      _uploadInProgress = false;
    }
  }

  Future<Box<dynamic>> _openBox() async {
    final existing = _box;
    if (existing != null) {
      return existing;
    }

    await initialize();
    final box = _box;
    if (box == null) {
      throw StateError('Emergency telemetry queue failed to initialize');
    }
    return box;
  }

  Uint8List _resolveEncryptionKey() {
    const source = 'hermove-local-queue-key-v2-change-in-production';
    final bytes = utf8.encode(source);
    final key = List<int>.filled(32, 0);
    for (var index = 0; index < key.length; index += 1) {
      key[index] = bytes[index % bytes.length];
    }
    return Uint8List.fromList(key);
  }

  Future<void> close() async {
    final box = _box;
    _box = null;
    await box?.close();
  }
}

class QueuedTelemetryItem {
  const QueuedTelemetryItem({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.triggerType,
    required this.timestamp,
  });

  final int id;
  final double latitude;
  final double longitude;
  final String triggerType;
  final int timestamp;

  factory QueuedTelemetryItem.fromMap(int id, Object? value) {
    final map = Map<String, dynamic>.from(value as Map);
    return QueuedTelemetryItem(
      id: id,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      triggerType: map['trigger_type'] as String,
      timestamp: map['timestamp'] as int,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'latitude': latitude,
      'longitude': longitude,
      'trigger_type': triggerType,
      'timestamp': timestamp,
    };
  }

  String toEncodedJson() => jsonEncode(toJson());
}
