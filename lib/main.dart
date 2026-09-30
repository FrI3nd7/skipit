import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'core/paths.dart';
import 'core/tray.dart';
import 'models/settings.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';
import 'ui/flag_text.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

const _instancePort = 47813;

/// Второй запуск (например, по ссылке skipit://…) передаёт аргументы первому и выходит.
Future<ServerSocket?> _acquireSingleInstance(List<String> args) async {
  // `SkipIt.exe --quit` (так делает установщик перед обновлением/удалением): попросить запущенную
  // копию корректно выйти — отключить VPN и вернуть системный прокси — и завершиться самим.
  if (args.contains('--quit')) {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, _instancePort, timeout: const Duration(seconds: 1));
      s.write(jsonEncode(['--quit']));
      await s.flush();
      await s.close();
    } catch (_) {}
    exit(0);
  }
  final elevated = args.contains('--elevated');
  final deadline = DateTime.now().add(Duration(seconds: elevated ? 8 : 0));
  while (true) {
    try {
      return await ServerSocket.bind(InternetAddress.loopbackIPv4, _instancePort);
    } catch (_) {}
    if (!elevated) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, _instancePort,
            timeout: const Duration(seconds: 1));
        s.write(jsonEncode(args));
        await s.flush();
        await s.close();
        exit(0);
      } catch (_) {
        return null; // Порт занят кем-то другим — просто работаем без защиты от дублей.
      }
    }
    if (DateTime.now().isAfter(deadline)) return null;
    await Future.delayed(const Duration(milliseconds: 250));
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final server = await _acquireSingleInstance(args);
  await AppPaths.init();

  final state = AppState();
  server?.listen((socket) async {
    try {
      final text = await utf8.decoder.bind(socket).join();
      final forwarded = (jsonDecode(text) as List).map((e) => e.toString()).toList();
      if (forwarded.contains('--quit')) {
        await state.shutdown();
        await Tray.quit();
        exit(0);
      }
      await state.handleArgs(forwarded);
    } catch (_) {}
    // Повторный запуск (ярлык, ссылка skipit://) — показываем окно, даже если оно в трее.
    await Tray.show();
  });

  Tray.init(
    onToggle: () async {
      try {
        await state.toggle();
      } on NeedAdminException catch (e) {
        await Tray.show();
        state.toast('$e — нажмите кнопку подключения в окне');
      }
    },
    onExit: () async {
      await state.shutdown();
      await Tray.quit();
    },
  );
  // Подсказка и меню трея следят за состоянием подключения.
  var lastTray = '';
  void syncTray() {
    final name = state.selectedServer?.name;
    final server = name == null ? null : Flags.toPlain(name);
    final status = switch (state.status) {
      ConnStatus.connected => 'Подключено',
      ConnStatus.connecting => 'Подключение…',
      ConnStatus.disconnecting => 'Отключение…',
      ConnStatus.disconnected => 'Не подключено',
    };
    final tooltip = 'SkipIt — $status${server != null ? '\n$server' : ''}';
    final key = '$tooltip|${state.isConnected}|${state.settings.closeToTray}';
    if (key == lastTray) return;
    lastTray = key;
    Tray.update(tooltip: tooltip, connected: state.isConnected, closeToTray: state.settings.closeToTray);
  }

  state.addListener(syncTray);
  syncTray();

  runApp(SkipItApp(state: state));
  unawaited(state.init(args));
}

class SkipItApp extends StatefulWidget {
  const SkipItApp({super.key, required this.state});
  final AppState state;

  @override
  State<SkipItApp> createState() => _SkipItAppState();
}

class _SkipItAppState extends State<SkipItApp> with WidgetsBindingObserver {
  late final AppLifecycleListener _lifecycle;
  late Palette _palette = _resolvePalette();

  Palette _resolvePalette() => switch (widget.state.settings.theme) {
        AppTheme.dark => Palette.dark,
        AppTheme.light => Palette.light,
        AppTheme.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light
            ? Palette.light
            : Palette.dark,
      };

  /// Тема меняется в настройках или в Windows («Как в системе») — перестраиваем окно целиком.
  void _syncTheme() {
    final p = _resolvePalette();
    if (!identical(p, _palette)) setState(() => _palette = p);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_syncTheme);
    // При закрытии окна обязательно гасим ядро и возвращаем системный прокси.
    _lifecycle = AppLifecycleListener(onExitRequested: () async {
      await widget.state.shutdown();
      return AppExitResponse.exit;
    });
  }

  @override
  void didChangePlatformBrightness() => _syncTheme();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_syncTheme);
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    C.use(_palette);
    // Цвета читаются при построении виджетов, поэтому при смене темы окно пересоздаётся (ключ).
    return AppScope(
      key: ValueKey(_palette.brightness),
      state: widget.state,
      child: MaterialApp(
        title: 'SkipIt',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const Shell(),
      ),
    );
  }
}