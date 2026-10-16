import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Lightweight, privacy-safe diagnostics for synchronization work.
///
/// Events contain operation names, timings, branch decisions, and aggregate
/// counts only. They must never contain patient identifiers, photo paths,
/// tokens, or image data.
class SyncDiagnostics {
  static const Object _traceZoneKey = #clinicPhotoSyncTrace;
  static int _nextSequence = 0;

  static SyncTrace? get current => Zone.current[_traceZoneKey] as SyncTrace?;

  static SyncTrace start(String operation, {required String trigger}) {
    final sequence = ++_nextSequence;
    final id =
        '${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}-$sequence';
    return SyncTrace._(id: id, operation: operation, trigger: trigger);
  }

  static Future<T> run<T>(SyncTrace trace, Future<T> Function() action) {
    return runZoned(
      action,
      zoneValues: <Object, Object?>{_traceZoneKey: trace},
    );
  }

  static void networkRequest(String service, String operation) {
    current?.networkRequest(service, operation);
  }

  static void databaseOperation(String operation) {
    current?.databaseOperation(operation);
  }
}

class SyncTrace {
  final String id;
  final String operation;
  final String trigger;
  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, int> _counts = <String, int>{};
  bool _finished = false;

  SyncTrace._({
    required this.id,
    required this.operation,
    required this.trigger,
  }) {
    _emit('start', <String, Object?>{'trigger': trigger});
  }

  Future<T> stage<T>(
    String name,
    Future<T> Function() action, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) async {
    final stageClock = Stopwatch()..start();
    _emit('stage_start', <String, Object?>{'stage': name, ...fields});
    try {
      final value = await action();
      _emit('stage_end', <String, Object?>{
        'stage': name,
        'outcome': 'success',
        'stageElapsedMs': stageClock.elapsedMilliseconds,
        ...fields,
      });
      return value;
    } catch (error) {
      _emit('stage_end', <String, Object?>{
        'stage': name,
        'outcome': 'error',
        'stageElapsedMs': stageClock.elapsedMilliseconds,
        'errorType': error.runtimeType.toString(),
        ...fields,
      });
      rethrow;
    }
  }

  void networkRequest(String service, String operation) {
    addCount('networkRequests');
    _emit('network_request', <String, Object?>{
      'service': service,
      'request': operation,
    });
  }

  void databaseOperation(String operation) {
    addCount('databaseOperations');
    _emit('database_operation', <String, Object?>{'operationName': operation});
  }

  void addCount(String name, [int amount = 1]) {
    _counts[name] = (_counts[name] ?? 0) + amount;
  }

  void setCount(String name, int value) {
    _counts[name] = value;
  }

  void finish({
    required String outcome,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    if (_finished) return;
    _finished = true;
    _emit('finish', <String, Object?>{
      'outcome': outcome,
      'elapsedMs': _clock.elapsedMilliseconds,
      'counts': Map<String, int>.from(_counts),
      ...fields,
    });
    _clock.stop();
  }

  void _emit(String event, Map<String, Object?> fields) {
    final payload = <String, Object?>{
      'event': event,
      'traceId': id,
      'operation': operation,
      'elapsedMs': _clock.elapsedMilliseconds,
      ...fields,
    };
    debugPrint('SYNC_TRACE ${jsonEncode(payload)}');
  }
}
