import 'package:arc_alarm_android/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats 12 and 24 hour time', () {
    expect(timeText(0, 5, false), '12:05 AM');
    expect(timeText(13, 45, false), '01:45 PM');
    expect(timeText(23, 9, true), '23:09');
  });

  test('summarizes repeat schedules', () {
    expect(daysText({}), 'Once');
    expect(daysText({1, 2, 3, 4, 5}), 'Weekdays');
    expect(daysText({1, 2, 3, 4, 5, 6, 7}), 'Every day');
  });
}
