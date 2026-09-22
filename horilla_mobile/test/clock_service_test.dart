import 'package:flutter_test/flutter_test.dart';
import 'package:nira/core/clock_service.dart';

void main() {
  test('state mismatch matches the server wording, with or without hyphen', () {
    for (final m in [
      'Already clocked-in',
      'Already clocked-out',
      'already clocked in',
      'Already Clocked Out',
    ]) {
      expect(ClockResult(false, message: m).isStateMismatch, isTrue, reason: m);
    }
  });

  test('other failures are not a state mismatch', () {
    expect(ClockResult(false, message: 'Outside allowed area').isStateMismatch,
        isFalse);
    expect(ClockResult(false).isStateMismatch, isFalse);
  });
}
