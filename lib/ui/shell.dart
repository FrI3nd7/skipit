import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/link_parser.dart';
import '../core/tray.dart';
import '../core/windows.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../version.dart';
import 'home_page.dart';
import 'logs_page.dart';
import 'routing_hub_page.dart';
import 'settings_page.dart';
import 'smooth_scroll.dart';
import 'flag_text.dart';
import 'theme.dart';
import 'widgets.dart';

/// Подключение с запросом прав администратора для TUN.
Future<void> connectOrToggle(BuildContext context) async {
  final state = AppScope.read(context);
  try {
    await state.toggle();
  } on NeedAdminException {
    if (!context.mounted) return;
    final ok = await confirm(
      context,
      'Нужны права администратора',
      'Режим TUN создаёт виртуальный сетевой адаптер — для этого Windows требует права администратора.\n\n'
          'Перезапустить приложение от имени администратора? Либо переключитесь на режим «Прокси».',
      ok: 'Перезапустить',
    );
    if (!ok) return;
    if (await WinSys.relaunchAsAdmin(['--connect'])) {
      await state.shutdown();
      await Tray.quit();
      exit(0);
    }
  }
}

Future<void> importFromClipboard(BuildContext context) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text?.trim() ?? '';
  if (!context.mounted) return;
  if (text.isEmpty) {
    AppScope.read(context).toast('Буфер обмена пуст');
    return;
  }
  await AppScope.read(context).importText(text);
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  StreamSubscription<String>? _sub;

  static const _items = [
    (Icons.bolt_rounded, 'Главная'),
    (Icons.alt_route_rounded, 'Маршрутизация'),
    (Icons.receipt_long_rounded, 'Логи'),
    (Icons.tune_rounded, 'Настройки'),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= AppScope.read(context).messages.listen((msg) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          // Уведомление закрывается кликом по нему или по крестику.
          content: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: messenger.hideCurrentSnackBar,
            child: MouseRegion(cursor: SystemMouseCursors.click, child: Text(msg)),
          ),
          showCloseIcon: true,
          closeIconColor: C.muted,
          width: 520,
          // И сами исчезают через 4 секунды.
          persist: false,
          duration: const Duration(seconds: 4),
        ));
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _state = AppScope.read(context)..addListener(_askPendingLinks);
      _askPendingLinks();
    });
  }

  AppState? _state;
  bool _asking = false;

  /// Ссылка пришла извне (skipit:// с сайта, второй запуск) — спрашиваем, прежде чем что-то добавлять.
  Future<void> _askPendingLinks() async {
    final state = _state;
    if (state == null || _asking || state.pendingLinks.isEmpty || !mounted) return;
    _asking = true;
    final link = state.pendingLinks.first;
    final parsed = LinkParser.parseText(link);
    final what = [
      for (final u in parsed.subscriptionUrls) 'подписка: ${Uri.tryParse(u)?.host ?? u}',
      if (parsed.servers.isNotEmpty) 'серверов: ${parsed.servers.length}',
      for (final r in parsed.routing) r.off ? 'отключение маршрутизации' : 'профиль маршрутизации «${r.profile?.name}»',
    ];
    await Tray.show();
    if (!mounted) return;
    final ok = await confirm(
      context,
      'Добавить из ссылки?',
      '${what.isEmpty ? 'Ссылка не распознана.' : what.join('\n')}\n\n'
          'Добавляйте только то, что вы открыли сами — например, ссылку от своего VPN-провайдера.',
      ok: 'Добавить',
    );
    await state.resolvePendingLink(link, accept: ok);
    _asking = false;
    _askPendingLinks();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _state?.removeListener(_askPendingLinks);
    super.dispose();
  }

  int get _index => AppScope.read(context).pageIndex.clamp(0, _items.length - 1);

  void go(int i) => setState(() => AppScope.read(context).pageIndex = i);

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomePage(),
      const RoutingHubPage(),
      const LogsPage(),
      const SettingsPage(),
    ];
    return Scaffold(
      backgroundColor: C.bg,
      // Ctrl+V (и Ctrl+Shift+V) в любом месте окна — импорт ссылки или конфига из буфера.
      body: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.keyV, control: true): _PasteIntent(),
          SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true): _PasteIntent(),
        },
        child: Actions(
          actions: {_PasteIntent: _PasteAction(() => importFromClipboard(context))},
          child: Focus(
            autofocus: true,
            child: Row(children: [
          _Sidebar(index: _index, items: _items, onSelect: go),
          Expanded(child: IndexedStack(index: _index, children: [for (final p in pages) _SmoothPage(child: p)])),
        ]),
          ),
        ),
      ),
    );
  }
}

/// Боковое меню — «плавающая» карточка; сворачивается до полоски с иконками.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.index, required this.items, required this.onSelect});
  final int index;
  final List<(IconData, String)> items;
  final ValueChanged<int> onSelect;

  static const _expandedWidth = 224.0;
  static const _collapsedWidth = 72.0;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final collapsed = state.settings.sidebarCollapsed;
    final (dotColor, statusText) = switch (state.status) {
      ConnStatus.connected => (C.green, 'Подключено'),
      ConnStatus.connecting => (C.orangeLight, 'Подключение…'),
      ConnStatus.disconnecting => (C.orangeLight, 'Отключение…'),
      ConnStatus.disconnected => (C.muted, 'Не подключено'),
    };
    void toggle() {
      state.settings.sidebarCollapsed = !collapsed;
      state.changed();
    }

    final dot = Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: dotColor,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: dotColor.withValues(alpha: 0.7), blurRadius: 8)],
      ),
    );

    // Меню + «ручка» сворачивания на его правой границе. Ручка всегда на одной высоте (напротив значка),
    // поэтому при сворачивании ничего не переезжает. Внешняя рамка шире меню на половину ручки,
    // чтобы ручка целиком принимала клики.
    const handle = 32.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: (collapsed ? _collapsedWidth : _expandedWidth) + 12 + handle / 2,
      child: Stack(children: [
        Positioned.fill(
          left: 12,
          right: handle / 2,
          top: 12,
          bottom: 12,
          child: _panel(context, state, collapsed, dot, statusText),
        ),
        Positioned(
          top: 12 + 18 + (36 - handle) / 2,
          right: 0,
          child: _CollapseButton(collapsed: collapsed, onTap: toggle, size: handle),
        ),
      ]),
    );
  }

  Widget _panel(BuildContext context, AppState state, bool collapsed, Widget dot, String statusText) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 18, 11, 14),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: C.border),
      ),
      // Подписи показываем только когда места достаточно — иначе во время анимации текст переполнится.
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 160;
        return ClipRect(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Значок стоит на месте в обоих состояниях, надпись «выезжает» из-под него.
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Row(children: [
                const AppBadge(size: 36),
                // Свернули и анимация закончилась — надпись убираем совсем, чтобы не выглядывала.
                if (!collapsed || wide)
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: 0,
                      maxWidth: double.infinity,
                      child: AnimatedSlide(
                        offset: collapsed ? const Offset(-0.6, 0) : Offset.zero,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: collapsed ? 0 : 1,
                          duration: const Duration(milliseconds: 200),
                          child: const Padding(
                            padding: EdgeInsets.only(left: 11),
                            child: Text('SkipIt',
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900, letterSpacing: -0.3)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ),
                ),
              ]),
            ),
            // Одинаковый отступ в обоих состояниях — пункты меню не сдвигаются при сворачивании.
            const SizedBox(height: 26),
            for (var i = 0; i < items.length; i++)
              _NavItem(
                icon: items[i].$1,
                label: items[i].$2,
                selected: i == index,
                collapsed: collapsed,
                onTap: () => onSelect(i),
              ),
            const Spacer(),
            // Статус: одна раскладка в обоих состояниях — точка на месте, текст выезжает.
            Tooltip(
              // В подсказке флаг — картинкой (в тексте Windows вместо него показала бы буквы «DE»).
              message: collapsed ? null : '',
              richMessage: collapsed
                  ? TextSpan(children: [
                      TextSpan(text: '$statusText\n'),
                      Flags.span(state.selectedServer?.name ?? 'Сервер не выбран', size: 12),
                    ])
                  : null,
              child: Container(
                height: 54,
                padding: const EdgeInsets.only(left: 19, right: 10),
                decoration: BoxDecoration(
                  color: C.surface2,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: state.isConnected ? C.green.withValues(alpha: 0.45) : C.border),
                ),
                child: Row(children: [
                  dot,
                  Expanded(
                    child: SlideLabel(
                      collapsed: collapsed,
                      height: 54,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(statusText,
                                maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            SizedBox(
                              width: 150,
                              child: FlagText(
                                state.selectedServer?.name ?? 'Сервер не выбран',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: C.muted, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            // Фиксированная высота: в свёрнутом меню строка складывается в столбик, а блок статуса
            // над ней не должен смещаться.
            SizedBox(
              height: 46,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _VersionRow(wide: wide),
              ),
            ),
          ]),
        );
      }),
    );
  }
}

class _CollapseButton extends StatelessWidget {
  const _CollapseButton({required this.collapsed, required this.onTap, this.size = 32});
  final bool collapsed;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: collapsed ? 'Развернуть меню' : 'Свернуть меню',
        child: Hover(
          builder: (context, hovered) => GestureDetector(
            onTap: onTap,
            // Круглая «ручка» на границе меню; фон непрозрачный, чтобы перекрывать рамку.
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: hovered ? Color.alphaBlend(C.orange.withValues(alpha: 0.15), C.surface2) : C.surface2,
                shape: BoxShape.circle,
                border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.7) : C.border),
                boxShadow: [BoxShadow(color: C.palette.shadow, blurRadius: 8)],
              ),
              child: Icon(
                collapsed ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
                size: 20,
                color: hovered ? C.orange : C.muted,
              ),
            ),
          ),
        ),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.collapsed = false,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Одна раскладка для обоих состояний: метка и иконка стоят на месте (иконка ровно по центру
    // свёрнутого меню), а название выезжает из-под иконки.
    final item = Hover(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected ? C.orange.withValues(alpha: 0.14) : (hovered ? C.hover : Colors.transparent),
          ),
          child: Row(children: [
            // Оранжевая метка слева у выбранного пункта.
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 3,
              height: 18,
              decoration: BoxDecoration(
                color: selected ? C.orange : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 11),
            Icon(icon, size: 20, color: selected || hovered ? C.orange : C.muted),
            Expanded(
              child: SlideLabel(
                collapsed: collapsed,
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(label,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 14.5,
                        // Толщина одна для всех состояний — выбор и наведение меняют только цвет,
                        // иначе текст «прыгает» по толщине и ширине.
                        fontWeight: FontWeight.w700,
                        color: selected || hovered ? C.text : C.muted,
                      )),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message: collapsed ? label : '',
        waitDuration: const Duration(milliseconds: 300),
        child: item,
      ),
    );
  }
}

/// Подпись, которая «выезжает» из-под иконки при разворачивании меню и прячется обратно.
/// Место под ней обрезается, поэтому во время анимации ширины ничего не переполняется.
class SlideLabel extends StatelessWidget {
  const SlideLabel({super.key, required this.collapsed, required this.height, required this.child});
  final bool collapsed;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            // Своя высота у подписи — иначе её растягивает на весь пункт и текст прилипает к верху.
            minHeight: 0,
            maxHeight: height,
            child: AnimatedSlide(
              offset: collapsed ? const Offset(-0.35, 0) : Offset.zero,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: collapsed ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: child,
              ),
            ),
          ),
        ),
      );
}

/// У каждой страницы свой контроллер плавной прокрутки (списки берут его через primary: true).
class _SmoothPage extends StatelessWidget {
  const _SmoothPage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SmoothScroll(
        builder: (context, controller) => PrimaryScrollController(controller: controller, child: child),
      );
}

/// Версия внизу меню + проверка обновлений. Если что-то нашлось — оранжевая пометка, клик ставит обновление.
class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.wide});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final hasUpdate = state.availableUpdates.isNotEmpty;
    final tooltip = state.checkingUpdates
        ? 'Проверяю обновления…'
        : hasUpdate
            ? 'Доступно обновление: ${state.availableUpdates.keys.map((k) => k == 'app' ? 'SkipIt' : k).join(', ')}'
            : 'Проверить обновления';

    final button = Tooltip(
      message: tooltip,
      child: Hover(
        builder: (context, hovered) => GestureDetector(
          // Есть обновление — кнопка сразу его ставит (с подтверждением), а не уводит в настройки.
          onTap: state.checkingUpdates
              ? null
              : !hasUpdate
                  ? state.checkUpdates
                  : state.availableUpdates.containsKey('app')
                      ? () => installAppUpdate(context)
                      : state.installCoreUpdates,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 28,
            padding: EdgeInsets.symmetric(horizontal: hasUpdate && wide ? 10 : 6),
            decoration: BoxDecoration(
              color: hasUpdate ? C.orange.withValues(alpha: 0.14) : (hovered ? C.hover : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: hasUpdate || hovered ? C.orange.withValues(alpha: 0.5) : Colors.transparent),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (state.checkingUpdates)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: C.orange))
              else
                Icon(hasUpdate ? Icons.download_rounded : Icons.sync_rounded,
                    size: 16, color: hasUpdate || hovered ? C.orange : C.muted),
              if (hasUpdate && wide) ...[
                const SizedBox(width: 6),
                const Text('Обновление',
                    style: TextStyle(color: C.orange, fontSize: 11, fontWeight: FontWeight.w700)),
              ],
            ]),
          ),
        ),
      ),
    );

    final version = Text(wide ? 'v$appVersion' : appVersion,
        maxLines: 1,
        style: TextStyle(color: C.muted, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.4));

    return wide
        ? Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Row(children: [version, const Spacer(), button]),
          )
        : Column(children: [button, const SizedBox(height: 4), version]);
  }
}
class _PasteIntent extends Intent {
  const _PasteIntent();
}

/// Вставка из буфера. Если фокус в поле ввода — действие «выключено»,
/// и Ctrl+V уходит полю как обычная вставка текста.
class _PasteAction extends Action<_PasteIntent> {
  _PasteAction(this.onPaste);
  final VoidCallback onPaste;

  @override
  bool isEnabled(_PasteIntent intent) {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused == null || focused.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  Object? invoke(_PasteIntent intent) {
    onPaste();
    return null;
  }
}