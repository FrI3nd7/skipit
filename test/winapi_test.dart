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
}
