import 'dart:async';

import 'package:flutter/material.dart';

import '../core/util.dart';
import '../models/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'app_menu.dart';
import 'flag_text.dart';
import 'servers_panel.dart';
import 'shell.dart';
import 'smooth_scroll.dart';
import 'theme.dart';
import 'widgets.dart';

/// Главная: слева кнопка подключения и режимы, справа список серверов.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && AppScope.read(context).isConnected) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final connected = state.isConnected;

    final statusText = switch (state.status) {
      ConnStatus.connected => 'Защищено',
      ConnStatus.connecting => 'Подключаемся…',
      ConnStatus.disconnecting => 'Отключаемся…',
      ConnStatus.disconnected => 'Не подключено',
    };

    final stage = Column(mainAxisSize: MainAxisSize.min, children: [
      ConnectGlow(
        active: connected,
        child: ConnectButton(
          connected: connected,
          // Стрелки «летят» только при подключении; отключение мгновенное, для него анимация не нужна.
          busy: state.status == ConnStatus.connecting,
          onTap: () => connectOrToggle(context),
        ),
      ),
      const SizedBox(height: 22),
      Text(statusText.toUpperCase(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
            color: connected ? C.text : C.muted,
          )),
      const SizedBox(height: 6),
      Text(
        connected && state.connectedAt != null
            ? formatDuration(DateTime.now().difference(state.connectedAt!))
            : 'Нажмите, чтобы подключиться',
        style: TextStyle(
          color: connected ? (C.isDark ? C.orangeLight : C.orange) : C.muted,
          fontSize: connected ? 18 : 13,
          fontWeight: connected ? FontWeight.w700 : FontWeight.w400,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      const SizedBox(height: 22),
      Segmented<ConnectionMode>(
        value: state.settings.mode,
        items: {
          for (final m in const [
            ConnectionMode.mixed,
            ConnectionMode.tun,
            ConnectionMode.systemProxy,
            ConnectionMode.proxyOnly,
          ])
            m: m.label,
        },
        onChanged: (m) => state.setMode(m),
      ),
      const SizedBox(height: 10),
      // Фиксированная высота: при смене режима колонка не «прыгает».
      SizedBox(
        width: 360,
        height: 34,
        child: Text(
          switch (state.settings.mode) {
            ConnectionMode.tun => 'Весь трафик компьютера через VPN',
            ConnectionMode.mixed => 'Браузеры — через прокси, остальное — через TUN',
            ConnectionMode.systemProxy => 'Только браузеры и программы с поддержкой прокси',
            ConnectionMode.proxyOnly =>
              'Система не меняется · SOCKS :${state.settings.socksPort} · HTTP :${state.settings.httpPort}',
          },
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: C.muted, fontSize: 12),
        ),
      ),
      // Чем поднимать адаптер — только в режимах с TUN; строка плавно выезжает и прячется.
      Reveal(
        open: state.usesTun,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _TunCorePicker(value: state.settings.tunCore, onChanged: state.setTunCore),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        width: 360,
        child: Row(children: [
          Expanded(child: _Speed(icon: Icons.arrow_upward_rounded, label: 'Отдача', speed: state.stats.upSpeed, total: state.stats.up, active: connected)),
          const SizedBox(width: 10),
          Expanded(child: _Speed(icon: Icons.arrow_downward_rounded, label: 'Загрузка', speed: state.stats.downSpeed, total: state.stats.down, active: connected)),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(width: 360, child: _RoutingInfo(summary: state.routingSummary, onTap: () => state.openPage(AppState.routingPage))),
      if (state.lastError != null) ...[
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: _ErrorBox(
            state.lastError!,
            key: ValueKey(state.lastError),
            onClose: state.clearError,
            // Адаптер TUN не поднялся — предлагаем сразу подключиться в режиме, которому он не нужен.
            actionLabel: state.tunFailed ? 'Подключиться в режиме «Прокси»' : null,
            onAction: () async {
              await state.setMode(ConnectionMode.systemProxy);
              if (context.mounted) await connectOrToggle(context);
            },
          ),
        ),
      ],
    ]);

    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 860
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 400,
                // Свой контроллер плавной прокрутки: основной контроллер страницы занят списком серверов.
                child: SmoothScroll(
                  builder: (context, controller) => SingleChildScrollView(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
                    child: stage,
                  ),
                ),
              ),
              const Expanded(
                child: Padding(padding: EdgeInsets.fromLTRB(4, 24, 24, 0), child: ServersPanel()),
              ),
            ])
          : ListView(
              primary: true,
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              children: [Center(child: stage), const SizedBox(height: 28), const ServersPanel(scrollable: false)],
            ),
    );
  }
}

/// Выбор ядра, которое поднимает TUN-адаптер: небольшая кнопка с выпадающим меню.
class _TunCorePicker extends StatelessWidget {
  const _TunCorePicker({required this.value, required this.onChanged});
  final TunCore value;
  final ValueChanged<TunCore> onChanged;

  static const _coreStyle = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700);

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Чем поднимать TUN-адаптер: sing-box — отдельным ядром, Xray — тем же ядром, что и подключение',
        waitDuration: const Duration(milliseconds: 500),
        child: Hover(
          builder: (context, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              final picked = await showAppMenu<TunCore>(context, matchWidth: true, items: [
                AppMenuItem(TunCore.singbox, 'sing-box', checked: value == TunCore.singbox),
                AppMenuItem(TunCore.xray, 'Xray', checked: value == TunCore.xray),
              ]);
              if (picked != null) onChanged(picked);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              decoration: BoxDecoration(
                color: hovered ? C.surface2 : C.surface,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.5) : C.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Ядро TUN', style: TextStyle(color: C.muted, fontSize: 12)),
                const SizedBox(width: 8),
                // Сначала гаснет старое название, затем проявляется новое; ширина кнопки меняется
                // всё это время — так длинная надпись не обрезается на глазах.
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 320),
                  sizeCurve: Curves.easeInOutCubic,
                  firstCurve: const Interval(0.55, 1),
                  secondCurve: const Interval(0.55, 1),
                  alignment: Alignment.centerLeft,
                  crossFadeState: value == TunCore.xray ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                  firstChild: const Text('sing-box', maxLines: 1, softWrap: false, style: _coreStyle),
                  secondChild: const Text('Xray', maxLines: 1, softWrap: false, style: _coreStyle),
                ),
                const SizedBox(width: 4),
                Icon(Icons.expand_more_rounded, size: 18, color: hovered ? C.orange : C.muted),
              ]),
            ),
          ),
        ),
      );
}

/// Какая маршрутизация сейчас действует; клик открывает раздел «Маршрутизация».
class _RoutingInfo extends StatefulWidget {
  const _RoutingInfo({required this.summary, required this.onTap});
  final ({String sites, String? apps}) summary;
  final VoidCallback onTap;

  @override
  State<_RoutingInfo> createState() => _RoutingInfoState();
}

class _RoutingInfoState extends State<_RoutingInfo> {
  /// Последний текст про программы: пока строка плавно прячется, он ещё нужен на экране.
  String _apps = '';

  ({String sites, String? apps}) get summary => widget.summary;
  VoidCallback get onTap => widget.onTap;

  @override
  Widget build(BuildContext context) {
    if (summary.apps != null) _apps = summary.apps!;
    return _tile(context);
  }

  Widget _tile(BuildContext context) => Tooltip(
        message: 'Открыть маршрутизацию',
        waitDuration: const Duration(milliseconds: 500),
        child: Hover(
          builder: (context, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: hovered ? C.surface2 : C.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.5) : C.border),
              ),
              child: Row(children: [
                Icon(Icons.alt_route_rounded, size: 18, color: hovered ? C.orange : C.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Маршрутизация', style: TextStyle(color: C.muted, fontSize: 11)),
                    FlagText(summary.sites,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    // Правила по программам — отдельной строкой; она плавно выезжает и прячется
                    // при смене режима (в режимах без TUN эти правила не действуют).
                    Reveal(
                      open: summary.apps != null,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_apps, style: TextStyle(color: C.muted, fontSize: 12)),
                        ),
                      ),
                    ),
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: hovered ? C.orange : C.muted),
              ]),
            ),
          ),
        ),
      );
}

/// Сообщение об ошибке подключения. Закрывается крестиком и само исчезает через 10 секунд;
/// пока на нём курсор (читают или выделяют текст) — не исчезает.
class _ErrorBox extends StatefulWidget {
  const _ErrorBox(this.text, {super.key, required this.onClose, this.actionLabel, this.onAction});
  final String text;
  final VoidCallback onClose;

  /// Кнопка быстрого выхода из ситуации под текстом ошибки (например, сменить режим).
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_ErrorBox> createState() => _ErrorBoxState();
}

class _ErrorBoxState extends State<_ErrorBox> {
  Timer? _timer;

  void _arm() {
    _timer?.cancel();
    // С кнопкой действия сообщение живёт дольше: нужно успеть прочитать и решить.
    _timer = Timer(Duration(seconds: widget.actionLabel != null ? 25 : 10), () {
      if (mounted) widget.onClose();
    });
  }

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => _timer?.cancel(),
        onExit: (_) => _arm(),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: BoxDecoration(
            color: C.red.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: C.red.withValues(alpha: 0.4)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SelectableText(widget.text, style: TextStyle(color: C.red, fontSize: 13)),
                if (widget.actionLabel != null) ...[
                  const SizedBox(height: 10),
                  GhostButton(label: widget.actionLabel!, icon: Icons.bolt_rounded, onPressed: widget.onAction),
                ],
              ]),
            ),
            Tooltip(
              message: 'Закрыть',
              child: Hover(
                builder: (context, hovered) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Icon(Icons.close_rounded, size: 18, color: hovered ? C.text : C.red),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
}
class _Speed extends StatelessWidget {
  const _Speed({required this.icon, required this.label, required this.speed, required this.total, required this.active});
  final IconData icon;
  final String label;
  final int speed;
  final int total;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.border),
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: active ? C.orange : C.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(color: C.muted, fontSize: 11)),
              Text(active ? formatSpeed(speed) : '—',
                  maxLines: 1, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              if (active) Text(formatBytes(total), style: TextStyle(color: C.muted, fontSize: 10.5)),
            ]),
          ),
        ]),
      );
}
