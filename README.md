# Arc Alarm for Android

A premium Flutter alarm application centered around an interactive circular time dial. This Android edition accompanies the native SwiftUI Arc Alarm project while remaining a completely independent application and repository.

## Features

- Custom-painted arc dial with drag gestures, tick marks, gradient progress, and haptic feedback
- Ring-only touch handling plus precise one-step hour/minute controls
- Separate hour and minute adjustment modes
- 12-hour and 24-hour formats with independent AM/PM selection
- Alarm labels, weekday repetition, vibration, sound, snooze, and gradual-volume options
- Persistent alarm storage and scheduled Android local notifications
- Optional 10-minute upcoming-alarm reminders
- One-tap repeat presets for once, weekdays, weekends, and every day
- Create, edit, enable, disable, and swipe-to-delete alarm flows
- Responsive dark interface designed for one-handed use
- TalkBack semantics for the primary time-selection control

## Requirements

- Flutter 3.47 or later
- Dart 3.13 or later
- Android SDK with API 36 support
- Android 6.0 (API 23) or later

## Run locally

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

To create a release APK:

```bash
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

## Notification permission

Android 13 and later ask for notification permission when the first alarm is saved. Permission must be granted for alarm notifications to appear. Device battery optimization and vendor-specific background restrictions can also affect delivery.

## Architecture

The project uses a lightweight model/store/view structure with `ChangeNotifier`, `SharedPreferences`, `flutter_local_notifications`, and a custom `CustomPainter` dial. No UI component library is required.
