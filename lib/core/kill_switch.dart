import 'package:flutter/services.dart';

import 'core_manager.dart';
import 'paths.dart';
import 'xray_config.dart';

/// Kill Switch: пока он включён, Windows не выпускает трафик мимо VPN. В сеть могут выходить только
/// ядра, соединения через адаптер VPN и локальная сеть (без DNS). Если адаптер пропал — ядро упало —
/// программы остаются без интернета, а не идут напрямую со своего настоящего адреса.
///
/// Сами фильтры Windows ставит C++-оболочка окна (windows/runner/kill_switch.cpp), здесь — канал
/// управления. Фильтры живут, пока работает программа: при выходе, даже аварийном, Windows убирает их сама.
class KillSwitch {
  static const _channel = MethodChannel('skipit/killswitch');

  /// Фильтры сейчас стоят.
  static bool active = false;

  /// Ставит фильтры. Нужны права администратора (они же нужны для TUN).
  static Future<void> engage() async {
    if (active) return;
    try {
      await _channel.invokeMethod<void>('engage', {
        'apps': [AppPaths.xrayExe, AppPaths.singboxExe],
        'v4': XrayConfig.tunV4,
        'v6': XrayConfig.tunV6,
      });
      active = true;
    } on PlatformException catch (e) {
      throw CoreException('Не удалось включить Kill Switch (${e.message}). '
          'Подключение остановлено, чтобы не работать без обещанной защиты. '
          'Выключить его можно в Настройки → Подключение.');
    } on MissingPluginException {
      throw CoreException('Kill Switch недоступен в этой сборке.');
    }
  }

  /// Снимает фильтры: интернет снова открыт и без VPN.
  static Future<void> release() async {
    if (!active) return;
    active = false;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }
}
