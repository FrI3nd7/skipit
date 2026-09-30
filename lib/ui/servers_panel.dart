import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/util.dart';
import '../core/windows.dart';
import '../models/server.dart';
import '../models/subscription.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'flag_text.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Список серверов на главной (как в Happ): поиск, группы подписок с информацией, строки серверов.
class ServersPanel extends StatefulWidget {
  const ServersPanel({super.key, this.scrollable = true});

  /// false — панель встроена в общий прокручиваемый список (узкое окно).
  final bool scrollable;

  @override
  State<ServersPanel> createState() => _ServersPanelState();
}

class _ServersPanelState extends State<ServersPanel> {
  String _query = '';

  bool _match(ServerProfile s) =>
      _query.isEmpty ||
      s.name.toLowerCase().contains(_query) ||
      s.address.toLowerCase().contains(_query) ||
      s.protocolLabel.toLowerCase().contains(_query);

  Future<void> _add(BuildContext context) async {
    final text = await promptText(
      context,
      title: 'Добавить подписку',
      hint: 'Ссылка на подписку или сервера: https://…, vless://, vmess://, trojan://, ss://, hy2://, happ://…',
      maxLines: 5,
      ok: 'Добавить',
    );
    if (text != null && text.trim().isNotEmpty && context.mounted) {
      await AppScope.read(context).importText(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final groups = <(Subscription?, List<ServerProfile>)>[
      for (final sub in state.subscriptions) (sub, state.serversOf(sub.id).where(_match).toList()),
      if (state.serversOf(null).isNotEmpty) (null, state.serversOf(null).where(_match).toList()),
    ];

    final header = Row(children: [
      Expanded(
        child: TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Поиск серверов'),
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
      ),
      const SizedBox(width: 6),
      _IconAction(
        tooltip: 'Проверить задержку всех',
        icon: Icons.speed_rounded,
        busy: state.pinging,
        onTap: () => state.ping(state.servers),
      ),
      _MenuAction(
        tooltip: 'Ещё',
        items: const {
          'add': 'Добавить подписку',
          'paste': 'Вставить из буфера (Ctrl+V)',
          'update': 'Обновить все подписки',
        },
        onSelected: (v) {
          switch (v) {
            case 'add':
              _add(context);
            case 'paste':
              importFromClipboard(context);
            case 'update':
              state.updateAllSubscriptions();
          }
        },
      ),
    ]);

    final children = <Widget>[
      header,
      const SizedBox(height: 14),
      if (groups.isEmpty)
        _EmptyState(onAdd: () => _add(context))
      else
        for (final (sub, list) in groups)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _GroupCard(key: ValueKey(sub?.id ?? 'manual'), subscription: sub, servers: list),
          ),
    ];

    return widget.scrollable
        ? ListView(primary: true, padding: const EdgeInsets.only(bottom: 24), children: children)
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Column(children: [
          const AppBadge(size: 56),
          const SizedBox(height: 16),
          const Text('Пока нет серверов', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Скопируйте ссылку на подписку и нажмите Ctrl+V',
              textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
          const SizedBox(height: 18),
          GradientButton(label: 'Добавить подписку', icon: Icons.add_rounded, onPressed: onAdd),
        ]),
      );
}

/// Маленькая круглая кнопка-иконка с подсветкой при наведении.
class _IconAction extends StatelessWidget {
  const _IconAction({required this.tooltip, required this.icon, required this.onTap, this.busy = false});
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Hover(
          enabled: !busy && onTap != null,
          builder: (context, hovered) => GestureDetector(
            onTap: busy ? null : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: hovered ? C.hover : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: C.orange))
                    : Icon(icon, size: 20, color: hovered ? C.orange : C.muted),
              ),
            ),
          ),
        ),
      );
}

/// Кнопка «…» с выпадающим меню.
class _MenuAction extends StatelessWidget {
  const _MenuAction({required this.tooltip, required this.items, required this.onSelected});
  final String tooltip;
  final Map<String, String> items;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Builder(
        builder: (btn) => _IconAction(
          tooltip: tooltip,
          icon: Icons.more_horiz_rounded,
          onTap: () async {
            final v = await showMenuAt(btn, items);
            if (v != null) onSelected(v);
          },
        ),
      );
}

/// Меню под виджетом (или у курсора, если передана позиция).
Future<String?> showMenuAt(BuildContext context, Map<String, String> items, {Offset? at, Set<String> danger = const {}}) {
  final box = context.findRenderObject() as RenderBox;
  final pos = at ?? box.localToGlobal(Offset(0, box.size.height + 4));
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
    items: [
      for (final e in items.entries)
        PopupMenuItem(
          value: e.key,
          child: Text(e.value, style: danger.contains(e.key) ? TextStyle(color: C.red) : null),
        ),
    ],
  );
}

class _GroupCard extends StatefulWidget {
  const _GroupCard({super.key, required this.subscription, required this.servers});
  final Subscription? subscription;
  final List<ServerProfile> servers;

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _manualExpanded = true;

  Future<void> _edit(AppState state, Subscription sub) async {
    final name = TextEditingController(text: sub.name);
    final url = TextEditingController(text: sub.url);
    final interval = TextEditingController(text: '${sub.updateIntervalHours}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Подписка'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Название')),
            const SizedBox(height: 12),
            TextField(controller: url, decoration: const InputDecoration(labelText: 'URL')),
            const SizedBox(height: 12),
            TextField(
              controller: interval,
              decoration: const InputDecoration(labelText: 'Автообновление, часов (0 — выключено)'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          GradientButton(label: 'Сохранить', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    sub.name = name.text.trim();
    sub.url = url.text.trim();
    sub.updateIntervalHours = asInt(interval.text) ?? sub.updateIntervalHours;
    state.changed();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final sub = widget.subscription;
    final expanded = sub?.expanded ?? _manualExpanded;
    final updating = sub != null && state.updatingSubs.contains(sub.id);

    void toggle() {
      if (sub == null) {
        setState(() => _manualExpanded = !_manualExpanded);
      } else {
        sub.expanded = !sub.expanded;
        state.changed();
      }
    }

    final subtitle = sub == null
        ? '${widget.servers.length} серв.'
        : [
            if (sub.lastUpdated != null) formatDateTime(sub.lastUpdated!),
            sub.updateIntervalHours > 0 ? 'Автообновление — ${sub.updateIntervalHours} ч.' : 'Без автообновления',
          ].join('  |  ');

    return Container(
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: C.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Заголовок группы.
        Hover(
          builder: (context, hovered) => GestureDetector(
            onTap: toggle,
            child: Container(
              color: hovered ? C.hover : Colors.transparent,
              padding: const EdgeInsets.fromLTRB(10, 12, 8, 12),
              child: Row(children: [
                AnimatedRotation(
                  turns: expanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(Icons.expand_more_rounded, color: C.muted),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    FlagText(sub?.displayName ?? 'Мои серверы',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(subtitle, maxLines: 1, style: TextStyle(color: C.muted, fontSize: 11.5)),
                  ]),
                ),
                if (sub != null)
                  _IconAction(
                    tooltip: 'Обновить подписку',
                    icon: Icons.sync_rounded,
                    busy: updating,
                    onTap: () => state.updateSubscription(sub),
                  ),
                _IconAction(
                  tooltip: 'Проверить задержку',
                  icon: Icons.speed_rounded,
                  busy: state.pinging,
                  onTap: () => state.ping(widget.servers),
                ),
                _MenuAction(
                  tooltip: 'Ещё',
                  items: {
                    'best': 'Выбрать самый быстрый',
                    if (sub != null) ...{
                      'edit': 'Изменить',
                      'copy': 'Скопировать ссылку',
                      'delete': 'Удалить подписку',
                    },
                  },
                  onSelected: (v) async {
                    switch (v) {
                      case 'best':
                        await state.selectBest(widget.servers);
                      case 'edit':
                        await _edit(state, sub!);
                      case 'copy':
                        await Clipboard.setData(ClipboardData(text: sub!.url));
                        state.toast('Ссылка скопирована');
                      case 'delete':
                        if (context.mounted &&
                            await confirm(context, 'Удалить подписку?', 'Все её серверы тоже будут удалены.')) {
                          state.deleteSubscription(sub!);
                        }
                    }
                  },
                ),
              ]),
            ),
          ),
        ),
        if (sub != null) _SubscriptionBar(sub),
        if (sub?.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(sub!.error!, style: TextStyle(color: C.red, fontSize: 12)),
          ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Column(children: [for (final s in widget.servers) _ServerRow(server: s)])
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

/// Трафик, срок действия, поддержка и объявление провайдера.
class _SubscriptionBar extends StatelessWidget {
  const _SubscriptionBar(this.sub);
  final Subscription sub;

  @override
  Widget build(BuildContext context) {
    final total = sub.total ?? 0;
    final hasTraffic = sub.total != null || sub.upload != null || sub.download != null;
    final progress = total > 0 ? (sub.used / total).clamp(0.0, 1.0) : 0.0;
    final expire = sub.expire;
    final daysLeft = expire?.difference(DateTime.now()).inDays;
    final announce = sub.announce;
    if (!hasTraffic && expire == null && sub.supportUrl == null && (announce == null || announce.isEmpty)) {
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        if (hasTraffic || expire != null || sub.supportUrl != null)
          Row(children: [
            if (hasTraffic)
              Expanded(
                child: Stack(alignment: Alignment.center, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: total > 0 ? progress : 0,
                      minHeight: 18,
                      backgroundColor: C.border,
                      color: progress > 0.9 ? C.red : C.orange.withValues(alpha: 0.75),
                    ),
                  ),
                  Text(
                    total > 0 ? '${formatBytes(sub.used)} / ${formatBytes(total)}' : '${formatBytes(sub.used)} · безлимит',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: C.text),
                  ),
                ]),
              )
            else
              const Spacer(),
            if (expire != null) ...[
              const SizedBox(width: 12),
              Text(
                'Истекает: ${formatDate(expire)}',
                style: TextStyle(fontSize: 12, color: (daysLeft ?? 99) < 3 ? C.red : C.muted),
              ),
            ],
            if (sub.supportUrl != null)
              _IconAction(
                tooltip: 'Поддержка',
                icon: Icons.support_agent_rounded,
                onTap: () => WinSys.openUrl(sub.supportUrl!),
              ),
          ]),
        if (announce != null && announce.isNotEmpty) ...[
          if (hasTraffic || expire != null || sub.supportUrl != null) const SizedBox(height: 8),
          FlagText(announce, textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12, height: 1.4)),
        ],
      ]),
    );
  }
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({required this.server});
  final ServerProfile server;

  Future<void> _menu(BuildContext context, AppState state, Offset at) async {
    final v = await showMenuAt(context, {
      'ping': 'Проверить задержку',
      'copy': 'Скопировать ссылку',
      'rename': 'Переименовать',
      if (server.subscriptionId == null) 'delete': 'Удалить',
    }, at: at, danger: {'delete'});
    if (!context.mounted) return;
    switch (v) {
      case 'ping':
        await state.ping([server]);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: server.link));
        state.toast('Ссылка скопирована');
      case 'rename':
        final name = await promptText(context, title: 'Название', initial: server.name);
        if (name != null && name.trim().isNotEmpty) {
          server.name = name.trim();
          state.changed();
        }
      case 'delete':
        state.deleteServer(server);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final selected = state.settings.selectedServerId == server.id;
    final (country, name) = Flags.leading(server.name);
    return Hover(
      builder: (context, hovered) => GestureDetector(
        onTap: () => state.selectServer(server.id),
        onSecondaryTapUp: (d) => _menu(context, state, d.globalPosition),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: selected ? C.orange.withValues(alpha: 0.10) : (hovered ? C.hover : Colors.transparent),
            border: Border(top: BorderSide(color: C.border)),
          ),
          child: Row(children: [
            // Оранжевая метка слева у выбранного сервера.
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 3,
              height: 60,
              color: selected ? C.orange : Colors.transparent,
            ),
            const SizedBox(width: 13),
            country != null ? FlagIcon.round(country, size: 26) : _NoFlag(server: server),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FlagText(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  Tag(server.protocolLabel, color: C.isDark ? C.orangeLight : C.orange),
                  if (server.transportLabel.isNotEmpty) Tag(server.transportLabel),
                  if (server.isJson) Tag('JSON', color: C.cyan),
                ]),
              ]),
            ),
            if (server.warning != null)
              Tooltip(
                message: server.warning!,
                child: const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.warning_amber_rounded, size: 16, color: C.orangeLight),
                ),
              ),
            if (server.delayMs != null || state.pinging) DelayBadge(server.delayMs, testing: state.pinging),
            Builder(
              builder: (btn) => AnimatedOpacity(
                opacity: hovered ? 1 : 0.35,
                duration: const Duration(milliseconds: 140),
                child: IconButton(
                  tooltip: 'Действия',
                  icon: Icon(Icons.more_vert_rounded, size: 18, color: C.muted),
                  onPressed: () {
                    final box = btn.findRenderObject() as RenderBox;
                    _menu(btn, state, box.localToGlobal(Offset(0, box.size.height)));
                  },
                ),
              ),
            ),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }
}

/// Сервер без флага в названии — кружок с глобусом.
class _NoFlag extends StatelessWidget {
  const _NoFlag({required this.server});
  final ServerProfile server;

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(color: C.surface2, shape: BoxShape.circle, border: Border.all(color: C.border)),
        child: Icon(Icons.public_rounded, size: 16, color: C.muted),
      );
}
