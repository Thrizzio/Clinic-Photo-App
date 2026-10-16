import 'package:clinic_photos/services/sync_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('trace carries correlation context through async stages', () async {
    final trace = SyncDiagnostics.start('test_sync', trigger: 'unit_test');

    final result = await SyncDiagnostics.run(trace, () async {
      expect(SyncDiagnostics.current, same(trace));
      SyncDiagnostics.current?.addCount('rows', 2);
      return trace.stage('bounded_stage', () async => 42);
    });

    expect(result, 42);
    expect(SyncDiagnostics.current, isNull);
    trace.finish(outcome: 'success');
    // Finishing twice must remain harmless for error/finally paths.
    trace.finish(outcome: 'error');
  });
}
