import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _start = 1000;

({List<double> rr, List<double> ts}) _session(
    {int windows = 6,
    int tailSeconds = 0,
    bool Function(int second)? skip,
    double Function(int second)? rrAt}) {
  final rr = <double>[], ts = <double>[];
  for (var i = 0; i < windows * 300 + tailSeconds; i++) {
    if (skip?.call(i) == true) continue;
    rr.add(rrAt?.call(i) ?? 1000 + 30 * math.sin(2 * math.pi * i / 16));
    ts.add((_start + i) * 1000.0);
  }
  return (rr: rr, ts: ts);
}

void main() {
  group('nightly HRV completeness', () {
    test('clean complete data exposes measurement and actual coverage', () {
      final s = _session();
      final a = assessSleepSessionRmssd(s.rr, s.ts,
          startSec: _start, endSec: _start + 1800);
      expect(a.metric.present, isTrue);
      expect(a.quality.acceptedWindows, 6);
      expect(a.quality.totalWindows, 6);
      expect(a.quality.rawBeats, 1800);
      expect(a.quality.cleanBeats, 1800);
      expect(a.quality.qualifyingDurationSec, inInclusiveRange(1770, 1794));
      expect(a.quality.coverageFraction, greaterThan(0.98));
      expect(a.quality.toJson()['min_window_coverage'], 0.8);
      expect(a.quality.toJson()['min_accepted_windows'], 6);
      expect(a.quality.toJson()['required_window_duration_sec'], 1800);
      expect(
          sleepSessionWindowedRmssd(s.rr, s.ts,
                  startSec: _start, endSec: _start + 1800)
              .value,
          a.metric.value);
    });

    test('many sparse bins cannot masquerade as a nightly measurement', () {
      final s = _session(windows: 30, skip: (i) => i % 300 >= 10);
      final a = assessSleepSessionRmssd(s.rr, s.ts,
          startSec: _start, endSec: _start + 9000);
      expect(a.metric.present, isFalse);
      expect(a.metric.confidence, 0);
      expect(a.quality.totalWindows, 30);
      expect(a.quality.acceptedWindows, 0);
      expect(a.quality.rawBeats, 300);
      expect(a.quality.cleanBeats, 300);
      expect(a.quality.coveredDurationSec, lessThan(300));
      expect(a.quality.qualifyingDurationSec, 0);
      expect(() => jsonEncode(a.quality.toJson()), returnsNormally);
    });

    test('endpoint span cannot hide a large gap inside every window', () {
      final s = _session(skip: (i) => i % 300 >= 60 && i % 300 < 240);
      final a = assessSleepSessionRmssd(s.rr, s.ts,
          startSec: _start, endSec: _start + 1800);
      expect(a.metric.present, isFalse);
      expect(a.quality.coverageWindows, 0);
      expect(a.quality.coveredDurationSec, lessThan(720));
    });

    test('removed artifacts consume coverage rather than joining neighbors',
        () {
      final s = _session(rrAt: (i) => i % 3 == 0 ? 200 : 1000);
      final a = assessSleepSessionRmssd(s.rr, s.ts,
          startSec: _start, endSec: _start + 1800);
      expect(a.metric.present, isFalse);
      expect(a.quality.cleanBeats, 1200);
      expect(a.quality.rawBeats, 1800);
      expect(a.quality.coveredDurationSec, 600);
      expect(a.quality.coverageWindows, 0);
    });

    test('a complete short night still needs six accepted windows', () {
      final s = _session(windows: 5);
      final a = assessSleepSessionRmssd(s.rr, s.ts,
          startSec: _start, endSec: _start + 1500);
      expect(a.metric.present, isFalse);
      expect(a.quality.acceptedWindows, 5);
      expect(a.quality.qualifyingDurationSec, greaterThan(1400));
      expect(a.metric.note, contains('need_hrv_windows:have=5,need=6'));
    });

    test('an incomplete tail is visible but cannot become the sixth window',
        () {
      final s = _session(windows: 5, tailSeconds: 290);
      final a = assessSleepSessionRmssd(s.rr, s.ts,
          startSec: _start, endSec: _start + 1790);
      expect(a.metric.present, isFalse);
      expect(a.quality.totalWindows, 6);
      expect(a.quality.acceptedWindows, 5);
      expect(a.quality.coveredDurationSec,
          greaterThan(a.quality.qualifyingDurationSec));
    });

    test('duplicate timestamps cannot invent qualifying duration', () {
      final s = _session();
      final duplicateTs = [for (final _ in s.ts) _start * 1000.0];
      final a = assessSleepSessionRmssd(s.rr, duplicateTs,
          startSec: _start, endSec: _start + 1800);
      expect(a.metric.present, isFalse);
      expect(a.quality.coveredDurationSec, 0);
    });

    test('WHOOP-style multiple beats per whole-second record retain coverage',
        () {
      // Intervals retain millisecond precision, while the packet timestamp is
      // shared by every beat it contains. At HR 100 many timestamps are equal.
      final rr = <double>[], ts = <double>[];
      var t = 0.0;
      var i = 0;
      while (t < 1800000) {
        final interval = 600 + 20 * math.sin(2 * math.pi * i++ / 16);
        t += interval;
        if (t >= 1800000) break;
        rr.add(interval);
        ts.add((_start + (t / 1000).floor()) * 1000.0);
      }
      expect(ts.toSet().length, lessThan(ts.length));
      final a = assessSleepSessionRmssd(rr, ts,
          startSec: _start, endSec: _start + 1800);
      expect(a.metric.present, isTrue);
      expect(a.quality.acceptedWindows, 6);
      expect(a.quality.coverageFraction, greaterThan(0.98));
      expect(a.metric.value, inInclusiveRange(4, 7));
    });

    test('non-finite RR is rejected without poisoning or bridging the result',
        () {
      final s = _session(rrAt: (i) => i % 300 == 150 ? double.nan : 1000);
      final a = assessSleepSessionRmssd(s.rr, s.ts,
          startSec: _start, endSec: _start + 1800);
      expect(a.metric.present, isTrue);
      expect(a.metric.value, 0);
      expect(a.quality.cleanBeats, 1794);
      expect(() => jsonEncode(a.quality.toJson()), returnsNormally);
    });

    test('bad bounds, lengths or timestamp order refuse without throwing', () {
      final s = _session();
      final badOrder = List<double>.from(s.ts)..[4] = s.ts[2];
      final badTime = List<double>.from(s.ts)..[4] = double.infinity;
      for (final ts in [badOrder, badTime, s.ts.sublist(1)]) {
        final a = assessSleepSessionRmssd(s.rr, ts,
            startSec: _start, endSec: _start + 1800);
        expect(a.metric.present, isFalse);
        expect(a.metric.confidence, 0);
        expect(() => jsonEncode(a.quality.toJson()), returnsNormally);
      }
      for (final window in [0, -300]) {
        expect(
            assessSleepSessionRmssd(s.rr, s.ts,
                    startSec: _start, endSec: _start, windowSec: window)
                .metric
                .present,
            isFalse);
      }
    });

    test('repeated assessment is stable and never mutates input', () {
      final s = _session();
      final before = jsonEncode([s.rr, s.ts]);
      final first = assessSleepSessionRmssd(s.rr, s.ts,
          startSec: _start, endSec: _start + 1800);
      for (var i = 0; i < 3; i++) {
        final again = assessSleepSessionRmssd(s.rr, s.ts,
            startSec: _start, endSec: _start + 1800);
        expect(again.metric.toJson(), first.metric.toJson());
        expect(again.quality.toJson(), first.quality.toJson());
      }
      expect(jsonEncode([s.rr, s.ts]), before);
    });
  });
}
