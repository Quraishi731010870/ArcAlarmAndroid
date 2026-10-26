import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

const bg = Color(0xff070d1d),
    card = Color(0xff121a2c),
    blue = Color(0xff168bff),
    violet = Color(0xff6d54ff);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  await Notifications.instance.init();
  final store = AlarmStore();
  await store.load();
  runApp(ArcAlarmApp(store));
}

class ArcAlarmApp extends StatelessWidget {
  const ArcAlarmApp(this.store, {super.key});
  final AlarmStore store;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Arc Alarm',
    themeMode: ThemeMode.dark,
    darkTheme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: blue,
        brightness: Brightness.dark,
        surface: card,
      ),
    ),
    home: AlarmList(store),
  );
}

class Alarm {
  Alarm({
    required this.id,
    required this.hour,
    required this.minute,
    this.label = 'Morning Alarm',
    Set<int>? days,
    this.vibration = true,
    this.sound = 'Aurora',
    this.snooze = true,
    this.snoozeMinutes = 9,
    this.fade = true,
    this.preAlarm = false,
    this.enabled = true,
  }) : days = days ?? {};
  final int id;
  int hour, minute;
  String label;
  Set<int> days;
  bool vibration, snooze, fade, enabled;
  bool preAlarm;
  String sound;
  int snoozeMinutes;
  Map<String, dynamic> toJson() => {
    'id': id,
    'hour': hour,
    'minute': minute,
    'label': label,
    'days': days.toList(),
    'vibration': vibration,
    'sound': sound,
    'snooze': snooze,
    'snoozeMinutes': snoozeMinutes,
    'fade': fade,
    'preAlarm': preAlarm,
    'enabled': enabled,
  };
  factory Alarm.fromJson(Map<String, dynamic> j) => Alarm(
    id: j['id'],
    hour: j['hour'],
    minute: j['minute'],
    label: j['label'] ?? 'Alarm',
    days: ((j['days'] ?? []) as List).cast<int>().toSet(),
    vibration: j['vibration'] ?? true,
    sound: j['sound'] ?? 'Aurora',
    snooze: j['snooze'] ?? true,
    snoozeMinutes: j['snoozeMinutes'] ?? 9,
    fade: j['fade'] ?? true,
    preAlarm: j['preAlarm'] ?? false,
    enabled: j['enabled'] ?? true,
  );
  Alarm copy() => Alarm.fromJson(toJson());
}

class AlarmStore extends ChangeNotifier {
  final alarms = <Alarm>[];
  bool use24 = false;
  String? lastNotificationError;
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    use24 = p.getBool('use24') ?? false;
    for (final s in p.getStringList('alarms') ?? []) {
      try {
        alarms.add(Alarm.fromJson(jsonDecode(s)));
      } catch (_) {}
    }
    _sort();
  }

  Future<void> save(Alarm a) async {
    final i = alarms.indexWhere((x) => x.id == a.id);
    if (i < 0) {
      alarms.add(a);
    } else {
      alarms[i] = a;
    }
    _sort();
    await _persist();
    notifyListeners();
    try {
      await Notifications.instance.schedule(a);
      lastNotificationError = null;
    } catch (error) {
      // The alarm must remain saved even when Android denies a notification
      // capability. The UI can explain that scheduling needs attention.
      lastNotificationError = error.toString();
    }
  }

  Future<void> toggle(Alarm a, bool v) async {
    a.enabled = v;
    await _persist();
    notifyListeners();
    try {
      await Notifications.instance.schedule(a);
      lastNotificationError = null;
    } catch (error) {
      lastNotificationError = error.toString();
    }
  }

  Future<void> remove(Alarm a) async {
    alarms.removeWhere((x) => x.id == a.id);
    await _persist();
    await Notifications.instance.cancel(a);
    notifyListeners();
  }

  Future<void> set24(bool v) async {
    use24 = v;
    (await SharedPreferences.getInstance()).setBool('use24', v);
    notifyListeners();
  }

  void _sort() => alarms.sort(
    (a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute),
  );
  Future<void> _persist() async =>
      (await SharedPreferences.getInstance()).setStringList(
        'alarms',
        alarms.map((a) => jsonEncode(a.toJson())).toList(),
      );
}

class Notifications {
  Notifications._();
  static final instance = Notifications._();
  final plugin = FlutterLocalNotificationsPlugin();
  Future<void> init() => plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  Future<void> schedule(Alarm a) async {
    await cancel(a);
    if (!a.enabled) return;
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    final d = NotificationDetails(
      android: AndroidNotificationDetails(
        'arc_alarm',
        'Arc alarms',
        channelDescription: 'Scheduled alarms',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        enableVibration: a.vibration,
      ),
    );
    final baseId = a.id.abs() % 10000000;
    if (a.days.isEmpty) {
      final n = DateTime.now();
      var t = DateTime(n.year, n.month, n.day, a.hour, a.minute);
      if (!t.isAfter(n)) t = t.add(const Duration(days: 1));
      await plugin.zonedSchedule(
        id: baseId * 100,
        title: a.label,
        body: 'Your alarm is ringing',
        scheduledDate: tz.TZDateTime.from(t.toUtc(), tz.UTC),
        notificationDetails: d,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
      if (a.preAlarm) {
        final early = t.subtract(const Duration(minutes: 10));
        if (early.isAfter(DateTime.now())) {
          await plugin.zonedSchedule(
            id: baseId * 100 + 20,
            title: 'Alarm in 10 minutes',
            body: a.label,
            scheduledDate: tz.TZDateTime.from(early.toUtc(), tz.UTC),
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'arc_alarm_reminders',
                'Upcoming alarm reminders',
                channelDescription: 'Gentle reminders before an alarm',
                importance: Importance.defaultImportance,
                priority: Priority.defaultPriority,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
        }
      }
    } else {
      for (final day in a.days) {
        final t = _next(a.hour, a.minute, day);
        await plugin.zonedSchedule(
          id: baseId * 100 + day,
          title: a.label,
          body: 'Your alarm is ringing',
          scheduledDate: tz.TZDateTime.from(t.toUtc(), tz.UTC),
          notificationDetails: d,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        );
        if (a.preAlarm) {
          var early = t.subtract(const Duration(minutes: 10));
          if (!early.isAfter(DateTime.now())) {
            early = early.add(const Duration(days: 7));
          }
          await plugin.zonedSchedule(
            id: baseId * 100 + 20 + day,
            title: 'Alarm in 10 minutes',
            body: a.label,
            scheduledDate: tz.TZDateTime.from(early.toUtc(), tz.UTC),
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'arc_alarm_reminders',
                'Upcoming alarm reminders',
                channelDescription: 'Gentle reminders before an alarm',
                importance: Importance.defaultImportance,
                priority: Priority.defaultPriority,
              ),
            ),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          );
        }
      }
    }
  }

  DateTime _next(int h, int m, int day) {
    final n = DateTime.now();
    var t = DateTime(n.year, n.month, n.day, h, m);
    while (t.weekday != day || !t.isAfter(n)) {
      t = t.add(const Duration(days: 1));
    }
    return t;
  }

  Future<void> cancel(Alarm a) async {
    final baseId = a.id.abs() % 10000000;
    await plugin.cancel(id: baseId * 100);
    await plugin.cancel(id: baseId * 100 + 20);
    for (var i = 1; i <= 7; i++) {
      await plugin.cancel(id: baseId * 100 + i);
      await plugin.cancel(id: baseId * 100 + 20 + i);
    }
  }
}

class AlarmList extends StatefulWidget {
  const AlarmList(this.store, {super.key});
  final AlarmStore store;
  @override
  State<AlarmList> createState() => _AlarmListState();
}

class _AlarmListState extends State<AlarmList> {
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.store.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _open([Alarm? a]) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => SetAlarm(widget.store, alarm: a?.copy())),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [bg, Color(0xff120a22)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 14, 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Alarms',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: () => _open(),
                    icon: const Icon(Icons.add),
                    tooltip: 'Add alarm',
                  ),
                ],
              ),
            ),
            Expanded(
              child: widget.store.alarms.isEmpty
                  ? _empty()
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: widget.store.alarms.length,
                      itemBuilder: (_, i) => _row(widget.store.alarms[i]),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.alarm_rounded, size: 78, color: Color(0xff52617b)),
          const SizedBox(height: 18),
          const Text(
            'No alarms yet',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Build a calmer morning with your first custom alarm.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _open(),
            icon: const Icon(Icons.add_alarm),
            label: const Text('Set an Alarm'),
          ),
        ],
      ),
    ),
  );
  Widget _row(Alarm a) => Dismissible(
    key: ValueKey(a.id),
    direction: DismissDirection.endToStart,
    onDismissed: (_) => widget.store.remove(a),
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      decoration: BoxDecoration(
        color: Colors.red.shade700,
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Icon(Icons.delete_outline),
    ),
    child: Card(
      color: card,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: InkWell(
        onTap: () => _open(a),
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      timeText(a.hour, a.minute, widget.store.use24),
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w300,
                        color: a.enabled ? Colors.white : Colors.white38,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      a.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      daysText(a.days),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: a.enabled,
                onChanged: (v) => widget.store.toggle(a, v),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum DialMode { hours, minutes }

class SetAlarm extends StatefulWidget {
  const SetAlarm(this.store, {super.key, this.alarm});
  final AlarmStore store;
  final Alarm? alarm;
  @override
  State<SetAlarm> createState() => _SetAlarmState();
}

class _SetAlarmState extends State<SetAlarm> {
  late Alarm alarm;
  late TextEditingController label;
  DialMode mode = DialMode.minutes;
  bool saving = false;
  final sounds = ['Aurora', 'Chimes', 'Daybreak', 'Horizon', 'Silence'];
  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    alarm =
        widget.alarm ??
        Alarm(
          id: n.microsecondsSinceEpoch.remainder(100000000),
          hour: n.hour,
          minute: n.minute,
        );
    label = TextEditingController(text: alarm.label);
  }

  @override
  void dispose() {
    label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [bg, Color(0xff140b26)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 120),
                child: Column(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        timeText(alarm.hour, alarm.minute, widget.store.use24),
                        key: ValueKey(
                          '${alarm.hour}:${alarm.minute}:${widget.store.use24}',
                        ),
                        style: const TextStyle(
                          fontSize: 47,
                          fontWeight: FontWeight.w200,
                        ),
                      ),
                    ),
                    Text(
                      '${alarmInText(alarm.hour, alarm.minute, alarm.days)}  ·  ${daysText(alarm.days)}',
                      style: const TextStyle(color: Colors.white54),
                    ),
                    const SizedBox(height: 18),
                    _modes(),
                    const SizedBox(height: 10),
                    LayoutBuilder(
                      builder: (_, b) {
                        final s = math.min(b.maxWidth, 380.0);
                        return SizedBox(
                          width: s,
                          height: s,
                          child: ArcDial(
                            hour: alarm.hour,
                            minute: alarm.minute,
                            mode: mode,
                            use24: widget.store.use24,
                            onChanged: (h, m) => setState(() {
                              alarm.hour = h;
                              alarm.minute = m;
                            }),
                          ),
                        );
                      },
                    ),
                    _precisionControls(),
                    if (!widget.store.use24) _period(),
                    const SizedBox(height: 22),
                    _options(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    bottomSheet: Container(
      color: bg.withValues(alpha: .96),
      padding: EdgeInsets.fromLTRB(
        18,
        10,
        18,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: FilledButton.icon(
          onPressed: saving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: blue,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          icon: Icon(saving ? Icons.check_circle : Icons.alarm),
          label: Text(saving ? 'Saved' : 'Save Alarm'),
        ),
      ),
    ),
  );
  Widget _header() => Padding(
    padding: const EdgeInsets.all(8),
    child: Row(
      children: [
        IconButton.filledTonal(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        const Expanded(
          child: Text(
            'Set Alarm',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        PopupMenuButton<bool>(
          icon: const Icon(Icons.settings_outlined),
          onSelected: (v) => setState(() => widget.store.set24(v)),
          itemBuilder: (_) => const [
            PopupMenuItem(value: false, child: Text('12-hour time')),
            PopupMenuItem(value: true, child: Text('24-hour time')),
          ],
        ),
      ],
    ),
  );
  Widget _modes() => Container(
    constraints: const BoxConstraints(maxWidth: 310),
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      children: DialMode.values
          .map(
            (m) => Expanded(
              child: InkWell(
                onTap: () => setState(() => mode = m),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: mode == m ? violet : Colors.transparent,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Text(
                    m == DialMode.hours ? 'Hours' : 'Minutes',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          )
          .toList(),
    ),
  );
  Widget _period() => SegmentedButton<int>(
    segments: const [
      ButtonSegment(value: 0, label: Text('AM')),
      ButtonSegment(value: 1, label: Text('PM')),
    ],
    selected: {alarm.hour >= 12 ? 1 : 0},
    onSelectionChanged: (s) =>
        setState(() => alarm.hour = alarm.hour % 12 + (s.first == 1 ? 12 : 0)),
  );
  Widget _precisionControls() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton.outlined(
          tooltip: mode == DialMode.hours ? 'Previous hour' : 'Previous minute',
          onPressed: () => _nudge(-1),
          icon: const Icon(Icons.remove),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            mode == DialMode.hours ? '1 hour steps' : '1 minute steps',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        IconButton.outlined(
          tooltip: mode == DialMode.hours ? 'Next hour' : 'Next minute',
          onPressed: () => _nudge(1),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
  );
  void _nudge(int delta) {
    setState(() {
      if (mode == DialMode.hours) {
        alarm.hour = (alarm.hour + delta + 24) % 24;
      } else {
        alarm.minute = (alarm.minute + delta + 60) % 60;
      }
    });
    HapticFeedback.selectionClick();
  }

  Widget _options() => Column(
    children: [
      _card(
        TextField(
          controller: label,
          decoration: const InputDecoration(
            border: InputBorder.none,
            prefixIcon: Icon(Icons.edit_outlined),
            hintText: 'Alarm label',
          ),
        ),
      ),
      const SizedBox(height: 12),
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.repeat),
                SizedBox(width: 10),
                Text('Repeat', style: TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _repeatPreset('Once', <int>{}),
                  _repeatPreset('Weekdays', {1, 2, 3, 4, 5}),
                  _repeatPreset('Weekends', {6, 7}),
                  _repeatPreset('Every day', {1, 2, 3, 4, 5, 6, 7}),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: List.generate(7, (i) {
                final d = i + 1, s = alarm.days.contains(d);
                return Expanded(
                  child: InkWell(
                    onTap: () => setState(
                      () => s ? alarm.days.remove(d) : alarm.days.add(d),
                    ),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: s
                              ? violet
                              : Colors.white.withValues(alpha: .07),
                        ),
                        child: Text(
                          'MTWTFSS'[i],
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _card(
        Column(
          children: [
            _toggle(
              Icons.vibration,
              'Vibration',
              alarm.vibration,
              (v) => setState(() => alarm.vibration = v),
            ),
            const Divider(),
            Row(
              children: [
                const Icon(Icons.volume_up_outlined),
                const SizedBox(width: 12),
                const Text('Sound'),
                const Spacer(),
                DropdownButton(
                  value: alarm.sound,
                  underline: const SizedBox(),
                  items: sounds
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (v) => setState(() => alarm.sound = v!),
                ),
              ],
            ),
            const Divider(),
            _toggle(
              Icons.notifications_active_outlined,
              'Remind me 10 minutes before',
              alarm.preAlarm,
              (v) => setState(() => alarm.preAlarm = v),
            ),
            const Divider(),
            _toggle(
              Icons.snooze,
              'Snooze',
              alarm.snooze,
              (v) => setState(() => alarm.snooze = v),
            ),
            if (alarm.snooze) ...[
              const Divider(),
              Row(
                children: [
                  const Text('Snooze duration'),
                  const Spacer(),
                  IconButton(
                    onPressed: alarm.snoozeMinutes > 1
                        ? () => setState(() => alarm.snoozeMinutes--)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('${alarm.snoozeMinutes} min'),
                  IconButton(
                    onPressed: alarm.snoozeMinutes < 30
                        ? () => setState(() => alarm.snoozeMinutes++)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
            ],
            const Divider(),
            _toggle(
              Icons.trending_up,
              'Gradual volume',
              alarm.fade,
              (v) => setState(() => alarm.fade = v),
            ),
          ],
        ),
      ),
    ],
  );
  Widget _toggle(IconData i, String t, bool v, ValueChanged<bool> c) => Row(
    children: [
      Icon(i),
      const SizedBox(width: 12),
      Expanded(child: Text(t)),
      Switch(value: v, onChanged: c),
    ],
  );
  Widget _repeatPreset(String title, Set<int> value) {
    final selected =
        alarm.days.length == value.length && alarm.days.containsAll(value);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(title),
        selected: selected,
        onSelected: (_) => setState(() => alarm.days = {...value}),
      ),
    );
  }

  Widget _card(Widget c) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .065),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: Colors.white.withValues(alpha: .06)),
    ),
    child: c,
  );
  Future<void> _save() async {
    if (saving) return;
    setState(() => saving = true);
    alarm.label = label.text.trim().isEmpty ? 'Alarm' : label.text.trim();
    try {
      await widget.store.save(alarm);
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      final message = widget.store.lastNotificationError == null
          ? 'Alarm saved and scheduled'
          : 'Alarm saved. Allow notifications in Android Settings to receive alerts.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
      await Future.delayed(const Duration(milliseconds: 700));
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save this alarm. Please try again.'),
        ),
      );
    }
  }
}

class ArcDial extends StatefulWidget {
  const ArcDial({
    super.key,
    required this.hour,
    required this.minute,
    required this.mode,
    required this.use24,
    required this.onChanged,
  });
  final int hour, minute;
  final DialMode mode;
  final bool use24;
  final void Function(int, int) onChanged;
  @override
  State<ArcDial> createState() => _ArcDialState();
}

class _ArcDialState extends State<ArcDial> {
  int last = -1;
  bool dragActive = false;

  void _update(Offset p, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    var a = math.atan2(p.dy - c.dy, p.dx - c.dx) + math.pi / 2;
    if (a < 0) a += math.pi * 2;
    final q = a / (math.pi * 2);
    int h = widget.hour, m = widget.minute, v;
    if (widget.mode == DialMode.minutes) {
      v = (q * 60).round() % 60;
      m = v;
    } else if (widget.use24) {
      v = (q * 24).round() % 24;
      h = v;
    } else {
      v = (q * 12).round() % 12;
      h = v + (widget.hour >= 12 ? 12 : 0);
    }
    widget.onChanged(h, m);
    if (v != last && (widget.mode == DialMode.hours || v % 5 == 0)) {
      HapticFeedback.selectionClick();
    }
    last = v;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, b) {
      final s = Size(b.maxWidth, b.maxHeight);
      return Semantics(
        label: widget.mode == DialMode.hours ? 'Hour dial' : 'Minute dial',
        value: widget.mode == DialMode.hours
            ? '${widget.hour}'
            : '${widget.minute}',
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (d) {
            if (isPointOnDialRing(d.localPosition, s)) {
              _update(d.localPosition, s);
            }
          },
          onPanStart: (d) {
            dragActive = isPointOnDialRing(d.localPosition, s);
            if (dragActive) _update(d.localPosition, s);
          },
          onPanUpdate: (d) {
            if (dragActive) _update(d.localPosition, s);
          },
          onPanEnd: (_) => dragActive = false,
          onPanCancel: () => dragActive = false,
          child: CustomPaint(
            painter: DialPainter(
              widget.hour,
              widget.minute,
              widget.mode,
              widget.use24,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.mode == DialMode.hours ? 'HOUR' : 'MINUTE',
                    style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 2,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    widget.mode == DialMode.hours
                        ? (widget.use24
                              ? '${widget.hour}'.padLeft(2, '0')
                              : '${widget.hour % 12 == 0 ? 12 : widget.hour % 12}'
                                    .padLeft(2, '0'))
                        : '${widget.minute}'.padLeft(2, '0'),
                    style: const TextStyle(
                      fontSize: 66,
                      fontWeight: FontWeight.w200,
                    ),
                  ),
                  const Text(
                    'drag the ring to adjust',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class DialPainter extends CustomPainter {
  DialPainter(this.h, this.m, this.mode, this.use24);
  final int h, m;
  final DialMode mode;
  final bool use24;
  @override
  void paint(Canvas c, Size s) {
    final o = Offset(s.width / 2, s.height / 2),
        r = s.shortestSide * .41,
        p = mode == DialMode.minutes
            ? m / 60
            : (use24 ? h / 24 : (h % 12) / 12);
    c.drawCircle(
      o,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: .1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12,
    );
    c.drawArc(
      Rect.fromCircle(center: o, radius: r),
      -math.pi / 2,
      p * math.pi * 2,
      false,
      Paint()
        ..shader = const SweepGradient(
          colors: [Color(0xff24c8ff), violet, Color(0xff24c8ff)],
        ).createShader(Rect.fromCircle(center: o, radius: r))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round,
    );
    final n = mode == DialMode.minutes ? 60 : (use24 ? 24 : 12);
    for (var i = 0; i < n; i++) {
      final a = i / n * math.pi * 2 - math.pi / 2,
          big = mode == DialMode.hours || i % 5 == 0,
          u = Offset(math.cos(a), math.sin(a));
      c.drawLine(
        o + u * (r - (big ? 28 : 22)),
        o + u * (r - 16),
        Paint()
          ..color = Colors.white.withValues(alpha: big ? .65 : .22)
          ..strokeWidth = big ? 2.2 : 1,
      );
    }
    final a = p * math.pi * 2 - math.pi / 2,
        x = o + Offset(math.cos(a), math.sin(a)) * r;
    c.drawCircle(x, 13, Paint()..color = Colors.white);
    c.drawCircle(
      x,
      9,
      Paint()
        ..color = const Color(0xff40c8ff)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
  }

  @override
  bool shouldRepaint(DialPainter o) =>
      o.h != h || o.m != m || o.mode != mode || o.use24 != use24;
}

String timeText(int h, int m, bool use24) => use24
    ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}'
    : '${(h % 12 == 0 ? 12 : h % 12).toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')} ${h >= 12 ? 'PM' : 'AM'}';
bool isPointOnDialRing(Offset point, Size size) {
  final center = Offset(size.width / 2, size.height / 2);
  final distance = (point - center).distance;
  final radius = size.shortestSide * .41;
  // A generous 52 px band is comfortable without making the entire dial hot.
  return (distance - radius).abs() <= 26;
}

String alarmInText(int hour, int minute, [Set<int>? repeatDays]) {
  final now = DateTime.now();
  var next = DateTime(now.year, now.month, now.day, hour, minute);
  final days = repeatDays ?? const <int>{};
  while (!next.isAfter(now) ||
      (days.isNotEmpty && !days.contains(next.weekday))) {
    next = next.add(const Duration(days: 1));
  }
  final difference = next.difference(now);
  final totalMinutes =
      difference.inMinutes + (difference.inSeconds % 60 > 0 ? 1 : 0);
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return 'Alarm in $minutes min';
  if (minutes == 0) return 'Alarm in ${hours}h';
  return 'Alarm in ${hours}h ${minutes}m';
}

String daysText(Set<int> d) {
  if (d.isEmpty) return 'Once';
  if (d.length == 7) return 'Every day';
  if (d.length == 5 && d.containsAll({1, 2, 3, 4, 5})) return 'Weekdays';
  const n = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final s = d.toList()..sort();
  return s.map((x) => n[x - 1]).join(' · ');
}
