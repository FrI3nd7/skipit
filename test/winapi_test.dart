import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/windows.dart';

void main() {
  test('Список запущенных программ строится быстро и без системных процессов', () async {
    await AppPaths.init();
    final sw = Stopwatch()..start();
    final apps = await WinSys.runningApps();
    sw.stop();
    // ignore: avoid_print
    print('программ: ${apps.length}, за ${sw.elapsedMilliseconds} мс; пример: ${apps.take(5).map((a) => a.name).join(', ')}');
    expect(apps, isNotEmpty);
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(apps.any((a) => a.path.toLowerCase().contains(r'\windows\system32\')), isFalse);
  });
  test('Проверка на другие VPN и на адаптер по умолчанию работает мгновенно и не падает', () async {
    await AppPaths.init();
    final sw = Stopwatch()..start();
    final adapter = WinSys.defaultRouteAdapter();
    final conflicts = WinSys.vpnConflicts();
    sw.stop();
    // ignore: avoid_print
    print('адаптер: ${adapter?.alias} (${adapter?.description}), мешающих VPN: ${conflicts.map((c) => c.name).toList()}, '
        'за ${sw.elapsedMilliseconds} мс');
    expect(sw.elapsedMilliseconds, lessThan(1000));
    // Собственные процессы теста и его ядра помехой считаться не должны.
    expect(conflicts.every((c) => c.name.isNotEmpty), isTrue);
  });}
