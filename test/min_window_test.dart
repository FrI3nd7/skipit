import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_scope.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/ui/shell.dart';
import 'package:skipit/ui/theme.dart';

/// Окно наименьшего размера (windows/runner/flutter_window.cpp: kMinWidth × kMinHeight): на каждой
/// странице ничего не вылезает за края, а заголовок страницы остаётся в одну строку.
void main() {
  // Те же числа, что в оболочке окна; клиентская область чуть меньше окна (рамка и заголовок).
  const minClient = Size(960 - 16, 600 - 39);

  setUpAll(() async {
    await AppPaths.init();
    final loader = FontLoader('Segoe UI');
    for (final file in ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf', 'seguibl.ttf']) {
      final f = File('${Platform.environment['WINDIR']}\\Fonts\\$file');
      if (f.existsSync()) loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  });

  for (final collapsed in [false, true]) {
    testWidgets('наименьшее окно, меню ${collapsed ? 'свёрнуто' : 'развёрнуто'}', (tester) async {
      C.use(Palette.dark);
      tester.view.physicalSize = minClient;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = AppState()..settings.sidebarCollapsed = collapsed;
      state.routingProfiles.addAll([RoutingProfile.global(), ...RoutingProfile.templates()]);
      final sub = Subscription(url: 'https://panel.example/sub', name: 'SkipIt VPN')
        ..total = 650 * 1024 * 1024 * 1024
        ..download = 228 * 1024 * 1024 * 1024
        ..expire = DateTime.now().add(const Duration(days: 12))
        ..announce = 'Перед подключением обновите список. Для мобильного интернета — сервера 🇷🇺 RU';
      state.subscriptions.add(sub);
      final parsed = LinkParser.parseText([
        'vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?type=tcp&security=reality&pbk=x&sni=a.com#%F0%9F%87%A9%F0%9F%87%AAGermany',
        'trojan://pw@t.com:443#Russia%20-%201%20%5B%D0%A1%D0%BE%D1%82%D0%BE%D0%B2%D0%B0%D1%8F%20%D1%81%D0%B2%D1%8F%D0%B7%D1%8C%5D',
      ].join('\n'));
      for (final s in parsed.servers) {
        s.subscriptionId = sub.id;
      }
      state.servers.addAll(parsed.servers);
      state.settings.selectedServerId = parsed.servers.first.id;
      state.log
        ..startSession(parsed.servers.first.name, detail: 'Смешанный')
        ..add('app', 'Ошибка подключения: порт занят')
        ..endSession();

      await tester.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(theme: buildTheme(), home: const RepaintBoundary(child: Shell())),
      ));
      await tester.pump(const Duration(milliseconds: 400));

      // Заголовок страницы в одну строку: при кегле 28 это меньше 50 точек высоты.
      void titleOnOneLine(String title) {
        final box = tester.getSize(find.text(title).last);
        expect(box.height, lessThan(50), reason: 'заголовок «$title» не поместился в строку');
      }

      // Картинки страниц для просмотра глазами: flutter test --update-goldens --dart-define=SKIPIT_SHOTS=<папка>.
      const shots = String.fromEnvironment('SKIPIT_SHOTS');
      Future<void> shot(String name) async {
        if (shots.isEmpty) return;
        await expectLater(find.byType(RepaintBoundary).first,
            matchesGoldenFile(Uri.file('$shots\\${collapsed ? 'collapsed' : 'expanded'}_$name.png')));
      }

      await shot('home');
      for (final (icon, title) in [
        (Icons.alt_route_rounded, 'Маршрутизация'),
        (Icons.receipt_long_rounded, 'Логи'),
        (Icons.tune_rounded, 'Настройки'),
      ]) {
        await tester.tap(find.byIcon(icon).first);
        await tester.pump(const Duration(milliseconds: 400));
        titleOnOneLine(title);
        await shot(title);
      }
    });
  }
}
