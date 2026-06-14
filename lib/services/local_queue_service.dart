import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// Offline-first encrypted queue for emergency telemetry.
///
/// This implementation uses SQLCipher-backed sqflite database encryption so the
/// queue is stored locally at rest in encrypted form.
class LocalQueueService {
  LocalQueueService._();

  static final LocalQueueService instance = LocalQueueService._();

  static const String _databaseName = 'hermove_queue.db';
  static const int _databaseVersion = 1;
  static const String _tableName = 'emergency_telemetry';

  Database? _database;
  bool _networkAvailable = true;
  bool _uploadInProgress = false;
  Future<String>? _encryptionKeyFuture;

  /// Initializes the encrypted queue database.
  Future<void> initialize() async {
    await _openDatabase();
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
    final database = await _openDatabase();

    final payload = <String, Object?>{
      'latitude': lat,
      'longitude': lng,
      'trigger_type': trigger,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    return database.insert(_tableName, payload,
        conflictAlgorithm: ConflictAlgorithm.abort);
  }

  /// Returns all queued telemetry items ordered by oldest first.
  Future<List<QueuedTelemetryItem>> getQueuedItems() async {
    final database = await _openDatabase();
    final rows = await database.query(
      _tableName,
      orderBy: 'timestamp ASC, id ASC',
    );

    return rows
        .map(QueuedTelemetryItem.fromMap)
        .toList(growable: false);
  }

  /// Deletes a set of queued item ids after a successful upload.
  Future<int> deleteItems(List<int> ids) async {
    if (ids.isEmpty) {
      return 0;
    }

    final database = await _openDatabase();
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    return database.delete(
      _tableName,
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  /// Runs a callback while controlling queue draining.
  ///
  /// The upload callback should throw if the server rejects the batch; queued
  /// telemetry is only removed if the callback completes without error.
  Future<int> flushIfOnline(
    Future<void> Function(List<QueuedTelemetryItem> items) uploadCallback,
  ) async {
    if (!_networkAvailable) {
      return 0;
    }

    if (_uploadInProgress) {
      return 0;
    }

    _uploadInProgress = true;
    try {
      final items = await getQueuedItems();
      if (items.isEmpty) {
        return 0;
      }

      await uploadCallback(items);
      await deleteItems(items.map((item) => item.id).whereType<int>().toList());
      return items.length;
    } finally {
      _uploadInProgress = false;
    }
  }

  Future<Database> _openDatabase() async {
    final existing = _database;
    if (existing != null) {
      return existing;
    }

    final key = await _resolveEncryptionKey();
    final path = join(await getDatabasesPath(), _databaseName);
    final database = await openDatabase(
      path,
      password: key,
      version: _databaseVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            trigger_type TEXT NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_${_tableName}_timestamp ON $_tableName(timestamp)',
        );
      },
    );

    _database = database;
    return database;
  }

  Future<String> _resolveEncryptionKey() async {
    final cached = _encryptionKeyFuture;
    if (cached != null) {
      return cached;
    }

    final future = _loadOrCreateEncryptionKey();
    _encryptionKeyFuture = future;
    return future;
  }

  Future<String> _loadOrCreateEncryptionKey() async {
    // Replace with a secure source such as flutter_secure_storage in the app.
    // A stable fallback is used here so the file stays self-contained.
    const fallbackKey = 'hermove-local-queue-key-v1-change-in-production';
    return fallbackKey;
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    await database?.close();
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

  factory QueuedTelemetryItem.fromMap(Map<String, Object?> map) {
    return QueuedTelemetryItem(
      id: map['id'] as int,
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
