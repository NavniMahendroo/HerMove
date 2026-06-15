import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:location/location.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'local_queue_service.dart';

class HardwareBridge {
  HardwareBridge._();

  static final HardwareBridge instance = HardwareBridge._();

  static const MethodChannel _methodChannel = MethodChannel(
    'hermove/ambient_guardian/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'hermove/ambient_guardian/events',
  );

  final StreamController<Map<String, dynamic>> _alertController =
      StreamController<Map<String, dynamic>>.broadcast();

  StreamSubscription<dynamic>? _nativeEventSubscription;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  bool _initialized = false;
  bool _sensorMonitoringEnabled = false;
  bool _locationServiceChecked = false;

  Stream<Map<String, dynamic>> get alerts => _alertController.stream;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    _nativeEventSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: (Object error, StackTrace stackTrace) {
        _emitAlert({
          'event': 'native_event_error',
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      },
    );

    await _startSensorFusionMonitor();
    _initialized = true;
  }

  Future<bool> startAmbientGuardian() async {
    await initialize();
    final result = await _methodChannel.invokeMethod<bool>('startMonitoring');
    return result ?? false;
  }

  Future<bool> stopAmbientGuardian() async {
    final result = await _methodChannel.invokeMethod<bool>('stopMonitoring');
    return result ?? false;
  }

  Future<bool> checkIsMonitoring() async {
    final result = await _methodChannel.invokeMethod<bool>('isMonitoring');
    return result ?? false;
  }

  Future<void> dispose() async {
    await _nativeEventSubscription?.cancel();
    _nativeEventSubscription = null;

    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;

    if (!_alertController.isClosed) {
      await _alertController.close();
    }

    _initialized = false;
    _sensorMonitoringEnabled = false;
  }

  void _handleNativeEvent(dynamic event) {
    if (event is Map) {
      final payload = Map<String, dynamic>.from(event);
      _emitAlert(payload);

      final eventType = payload['event']?.toString();
      if (eventType == 'bluetooth_acl_disconnected') {
        _cacheTriggerForOfflineDelivery(payload);
      }
    }
  }

  void _emitAlert(Map<String, dynamic> payload) {
    if (!_alertController.isClosed) {
      _alertController.add(payload);
    }
  }

  Future<void> _startSensorFusionMonitor() async {
    if (_sensorMonitoringEnabled) {
      return;
    }

    _sensorMonitoringEnabled = true;
    _accelerometerSubscription = accelerometerEventStream().listen(
      _handleAccelerometerEvent,
      onError: (Object error, StackTrace stackTrace) {
        _emitAlert({
          'event': 'accelerometer_error',
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      },
      cancelOnError: false,
    );
  }

  void _handleAccelerometerEvent(AccelerometerEvent event) {
    final magnitude = math.sqrt(
      (event.x * event.x) + (event.y * event.y) + (event.z * event.z),
    );

    if (magnitude < 30.0) {
      return;
    }

    _captureHighGBurst(magnitude);
  }

  Future<void> _captureHighGBurst(double magnitude) async {
    final location = await _safeGetLocation();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final latitude = location?.latitude;
    final longitude = location?.longitude;

    final triggerPayload = <String, dynamic>{
      'event': 'high_g_burst',
      'trigger_type': 'high_g_burst',
      'magnitude': magnitude,
      'timestamp': timestamp,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (location != null) 'accuracy': location.accuracy,
      if (location != null) 'altitude': location.altitude,
    };

    _emitAlert(triggerPayload);

    if (latitude != null && longitude != null) {
      await LocalQueueService.instance.enqueueTelemetry(
        latitude,
        longitude,
        'high_g_burst',
      );
    }
  }

  Future<LocationData?> _safeGetLocation() async {
    try {
      final location = Location();
      final enabled = await location.serviceEnabled();
      if (!enabled) {
        final requested = await location.requestService();
        if (!requested) {
          return null;
        }
      }

      final permission = await location.hasPermission();
      if (permission == PermissionStatus.denied) {
        final requested = await location.requestPermission();
        if (requested != PermissionStatus.granted &&
            requested != PermissionStatus.grantedLimited) {
          return null;
        }
      }

      if (!_locationServiceChecked) {
        _locationServiceChecked = true;
      }

      return await location.getLocation();
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheTriggerForOfflineDelivery(Map<String, dynamic> payload) async {
    final latitude = payload['latitude'];
    final longitude = payload['longitude'];

    if (latitude is num && longitude is num) {
      await LocalQueueService.instance.enqueueTelemetry(
        latitude.toDouble(),
        longitude.toDouble(),
        payload['event']?.toString() ?? 'bluetooth_acl_disconnected',
      );
    }
  }
}
