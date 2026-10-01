import 'package:flutter/services.dart';

import 'paths.dart';

/// Значок в системном трее. Сам значок и меню живут в C++-оболочке окна
/// (windows/runner/flutter_window.cpp), здесь — только канал управления.
class Tray {
  static const _channel = MethodChannel('skipit/tray');

  /// [onToggle] — пункт «Подключить/Отключить», [onExit] — «Выход».
  static void init({required Future<void> Function() onToggle, required Future<void> Function() onExit}) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'toggle':
          await onToggle();
        case 'exit':
          await onExit();
      }
      return null;
    });
  }

  static Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // В тестах нет нативной оболочки — трей просто отсутствует.
    }
  }

  static Future<void> update({
    required String tooltip,
    required bool connected,
    required bool closeToTray,
  }) =>
      _call('update', {
        // У Windows ограничение подсказки — 127 символов.
        'tooltip': tooltip.length > 120 ? '${tooltip.substring(0, 119)}…' : tooltip,
        'open': 'Открыть ${AppPaths.appName}',
        'toggle': connected ? 'Отключить' : 'Подключить',
        'exit': 'Выход',
        'closeToTray': closeToTray,
      });

  static Future<void> show() => _call('show');

  /// Убирает значок и закрывает окно. Перед вызовом всё уже должно быть остановлено.
  static Future<void> quit() => _call('quit');
}
