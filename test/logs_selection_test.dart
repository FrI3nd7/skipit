import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/log_store.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Выделенный в журнале текст остаётся выделенным, когда приходят новые строки, — а не «переезжает»
/// на строки, оказавшиеся на том же месте; на другой вкладке выделения нет.
void main() {
  setUpAll(AppPaths.init);

  testWidgets('пока журнал читают (прокрутили вверх), новые строки его не двигают', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState();
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    state.log.startSession('Сервер');
    for (var i = 0; i < 80; i++) {
      state.log.add('app', 'line-${i.toString().padLeft(2, '0')}');
    }
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const Shell()),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.receipt_long_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));

    // Внизу списка он следует за новыми строками.
    final last = find.textContaining('line-79');
    expect(last, findsOneWidget);
    state.log.add('app', 'tail-a');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('tail-a'), findsOneWidget);
    expect(find.textContaining('К последним записям'), findsNothing);

    // Прокрутили вверх — читаем.
    await tester.drag(find.textContaining('line-70'), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 400));
    final read = find.textContaining('line-60');
    expect(read, findsOneWidget);
    final before = tester.getRect(read);
    expect(find.text('К последним записям'), findsOneWidget);

    // Пришли новые строки: читаемая строка на месте, новые ждут кнопки.
    state.log
      ..add('app', 'tail-b')
      ..add('app', 'tail-c')
      ..add('app', 'tail-d');
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(read), before);
    expect(find.textContaining('tail-d'), findsNothing);
    expect(find.text('Новые строки: 3'), findsOneWidget);

    // Кнопка возвращает к концу журнала, и список снова следует за новыми строками.
    await tester.tap(find.text('Новые строки: 3'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('tail-d'), findsOneWidget);
    expect(find.textContaining('Новые строки'), findsNothing);
    state.log.endSession();
  });

  testWidgets('выделение в журнале держится за текст, а не за место в списке', (tester) async {
    C.use(Palette.dark);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final state = AppState();
    state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
    state.log.startSession('Сервер');
    for (var i = 0; i < 12; i++) {
      state.log.add('app', 'line-${i.toString().padLeft(2, '0')}');
    }
    final picked = state.log.lines[7];

    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(), home: const Shell()),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.receipt_long_rounded).first);
    await tester.pump(const Duration(milliseconds: 400));

    Future<String?> copy() async {
      copied = null;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      return copied;
    }

    // Выделяем мышью одну строку целиком.
    final row = tester.getRect(find.byKey(ValueKey<LogLine>(picked)));
    final mouse = await tester.startGesture(row.centerLeft + const Offset(1, 0), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await mouse.moveTo(row.center);
    await tester.pump();
    await mouse.moveTo(row.centerRight - const Offset(1, 0));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(await copy(), contains('line-07'));

    // Пришли новые строки: список сдвинулся, выделенной осталась та же строка.
    state.log
      ..add('app', 'new-a')
      ..add('app', 'new-b')
      ..add('app', 'new-c');
    await tester.pump(const Duration(milliseconds: 100));
    final after = await copy();
    expect(after, contains('line-07'));
    expect(after, isNot(contains('line-04')));
    expect(tester.getRect(find.byKey(ValueKey<LogLine>(picked))).top, lessThan(row.top));

    // На другой вкладке выделения нет: копировать нечего.
    await tester.tap(find.textContaining('Приложение  '));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await copy(), isNull);
    state.log.endSession();
  });
}
