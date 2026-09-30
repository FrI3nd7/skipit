import 'dart:async';

import 'package:flutter/material.dart';

import '../core/util.dart';
import '../models/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'servers_panel.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Главная: слева кнопка подключения и режимы, справа список серверов (как в Happ).
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
        items: const {
          ConnectionMode.mixed: 'Смешанный',
          ConnectionMode.tun: 'TUN',
          ConnectionMode.systemProxy: 'Прокси',
          ConnectionMode.proxyOnly: 'Только порты',
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
