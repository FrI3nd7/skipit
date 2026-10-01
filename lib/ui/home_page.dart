import 'dart:async';

import 'package:flutter/material.dart';

import '../core/util.dart';
import '../models/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'flag_text.dart';
import 'servers_panel.dart';
import 'shell.dart';
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
          busy: state.isBusy,
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
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: _ErrorBox(state.lastError!)),
      ],
    ]);

    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 860
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 400,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
                  child: stage,
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

/// Какая маршрутизация сейчас действует; клик открывает раздел «Маршрутизация».
class _RoutingInfo extends StatelessWidget {
  const _RoutingInfo({required this.summary, required this.onTap});
  final ({String sites, String? apps}) summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
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
                    // Правила по программам — отдельной строкой, чтобы ничего не обрезалось.
                    if (summary.apps != null) ...[
                      const SizedBox(height: 2),
                      Text(summary.apps!, style: TextStyle(color: C.muted, fontSize: 12)),
                    ],
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: hovered ? C.orange : C.muted),
              ]),
            ),
          ),
        ),
      );
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: C.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.red.withValues(alpha: 0.4)),
        ),
        child: SelectableText(text, style: TextStyle(color: C.red, fontSize: 13)),
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
