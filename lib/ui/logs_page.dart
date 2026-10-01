import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_manager.dart';
import '../core/log_explain.dart';
import '../core/paths.dart';
import '../state/app_scope.dart';
import 'flag_text.dart';
import 'smooth_scroll.dart';
import 'theme.dart';
import 'widgets.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

/// Фильтр строк: события приложения отдельно от вывода ядер.
enum _LogTab { all, app, xray, singbox, connections }

extension on _LogTab {
  String get label => switch (this) {
        _LogTab.all => 'Все',
        _LogTab.app => 'Приложение',
        _LogTab.xray => 'Xray',
        _LogTab.singbox => 'sing-box',
        _LogTab.connections => 'Соединения',
      };

  bool matches(String source) => switch (this) {
        _LogTab.all => true,
        _LogTab.xray => source == 'xray' || source == 'test',
        _LogTab.singbox => source == 'sing-box',
        // Соединения — отдельный список (LogSession.connections), а не строки журнала.
        _LogTab.connections => false,
        _LogTab.app => source != 'xray' && source != 'test' && source != 'sing-box',
      };
}

String _two(int n) => n.toString().padLeft(2, '0');
String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

const _months = [
  'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
  'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
];

/// «Сегодня», «Вчера» или «29 сентября».
String _dayLabel(DateTime day) {
  final now = DateTime.now();
  final diff = DateTime(now.year, now.month, now.day).difference(DateTime(day.year, day.month, day.day)).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  return '${day.day} ${_months[day.month - 1]}';
}

/// Длительность отрезка коротко: «меньше минуты», «44 мин», «2 ч 5 мин».
String _span(Duration d) {
  if (d.inMinutes < 1) return 'меньше минуты';
  if (d.inHours < 1) return '${d.inMinutes} мин';
  final m = d.inMinutes % 60;
  return m == 0 ? '${d.inHours} ч' : '${d.inHours} ч $m мин';
}

class _LogsPageState extends State<LogsPage> {
  _LogTab _tab = _LogTab.all;

  /// Отрезок, выбранный пользователем. null — показываем самый свежий и следуем за новыми.
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final log = state.log;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        final sessions = log.sessions;
        final selected = sessions.where((s) => s.id == _selectedId).firstOrNull ?? sessions.lastOrNull;
        if (selected != null && selected.lines == null) log.load(selected);

        return Column(children: [
          PageHeader(
            'Логи',
            subtitle: 'Журнал разбит по подключениям и хранится ${LogBuffer.keepDays} дней. '
                'Под строками ядра — пояснения простыми словами',
            actions: [
              GhostButton(
                label: 'Папка',
                icon: Icons.folder_open_rounded,
                onPressed: () => Process.run('explorer', [AppPaths.logDir.path]),
              ),
              GhostButton(
                label: 'Очистить историю',
                icon: Icons.delete_sweep_rounded,
                onPressed: sessions.any((s) => !s.live)
                    ? () async {
                        if (await confirm(context, 'Очистить историю?',
                            'Журналы прошлых подключений будут удалены. Текущий журнал останется.')) {
                          setState(() => _selectedId = null);
                          log.clearHistory();
                        }
                      }
                    : null,
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
              child: sessions.isEmpty
                  ? _card(Center(child: Text('Здесь пока пусто', style: TextStyle(color: C.muted))))
                  : LayoutBuilder(
                      builder: (context, c) => Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        SizedBox(
                          width: c.maxWidth < 860 ? 250 : 310,
                          child: _card(_SessionList(
                            sessions: sessions,
                            selected: selected,
                            onSelect: (s) => setState(() => _selectedId = identical(s, sessions.last) ? null : s.id),
                          )),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _card(_SessionView(
                            session: selected!,
                            tab: _tab,
                            onTab: (t) => setState(() => _tab = t),
                            onCopied: () => state.toast('Журнал скопирован'),
                            onDelete: () {
                              setState(() => _selectedId = null);
                              log.remove(selected);
                            },
                          )),
                        ),
                      ]),
                    ),
            ),
          ),
        ]);
      },
    );
  }

  Widget _card(Widget child) => Container(
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: C.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

/// Слева: отрезки журнала по дням, свежие сверху. Каждый день сворачивается кликом по заголовку;
/// по умолчанию развёрнут только сегодняшний.
class _SessionList extends StatefulWidget {
  const _SessionList({required this.sessions, required this.selected, required this.onSelect});
  final List<LogSession> sessions;
  final LogSession? selected;
  final ValueChanged<LogSession> onSelect;

  @override
  State<_SessionList> createState() => _SessionListState();
}

class _SessionListState extends State<_SessionList> {
  /// Дни, которые пользователь развернул или свернул сам (ключ — дата). Остальные — по умолчанию.
  final _opened = <String, bool>{};

  static String _key(DateTime d) => '${d.year}-${d.month}-${d.day}';

  @override
  Widget build(BuildContext context) {
    // Отрезки по дням, свежие сверху.
    final days = <(DateTime, List<LogSession>)>[];
    for (final s in widget.sessions.reversed) {
      if (days.isEmpty || _key(days.last.$1) != _key(s.start)) days.add((s.start, []));
      days.last.$2.add(s);
    }
    final today = _key(DateTime.now());
    final rows = <Widget>[
      for (final (day, list) in days)
        _DayGroup(
          key: ValueKey(_key(day)),
          label: _dayLabel(day),
          count: list.length,
          first: identical(list, days.first.$2),
          open: _opened[_key(day)] ?? _key(day) == today,
          onToggle: (open) => setState(() => _opened[_key(day)] = open),
          selectedIndex: list.indexWhere((s) => identical(s, widget.selected)),
          children: [
            for (final s in list)
              _SessionTile(session: s, selected: identical(s, widget.selected), onTap: () => widget.onSelect(s)),
          ],
        ),
    ];
    // Свой контроллер плавной прокрутки: основной контроллер страницы занят списком строк справа.
    return SmoothScroll(
      builder: (context, controller) =>
          ListView(controller: controller, padding: const EdgeInsets.only(bottom: 10), children: rows),
    );
  }
}

/// Журналы одного дня: заголовок-переключатель и плавно раскрывающийся список отрезков.
class _DayGroup extends StatefulWidget {
  const _DayGroup({
    super.key,
    required this.label,
    required this.count,
    required this.first,
    required this.open,
    required this.onToggle,
    required this.selectedIndex,
    required this.children,
  });
  final String label;
  final int count;
  final bool first;
  final bool open;
  final ValueChanged<bool> onToggle;

  /// Номер выбранного журнала в этом дне; -1 — выбран журнал другого дня.
  final int selectedIndex;
  final List<Widget> children;

  @override
  State<_DayGroup> createState() => _DayGroupState();
}

class _DayGroupState extends State<_DayGroup> {
  /// Где подсветка стояла в последний раз: там она и гаснет, когда выбран журнал другого дня.
  int _last = 0;

  String get label => widget.label;
  int get count => widget.count;
  bool get first => widget.first;
  bool get open => widget.open;
  ValueChanged<bool> get onToggle => widget.onToggle;

  @override
  Widget build(BuildContext context) {
    final here = widget.selectedIndex >= 0;
    if (here) _last = widget.selectedIndex;
    return _build(context, here);
  }

  Widget _build(BuildContext context, bool here) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Заголовок дня — отдельная плашка: видно, что на неё можно нажать. Если выбранный журнал
        // спрятан внутри свёрнутого дня, плашка отмечена оранжевым.
        Hover(
          builder: (context, hovered) {
            final marked = here && !open;
            final accent = marked ? C.orange : (hovered ? C.text : C.muted);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onToggle(!open),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                margin: EdgeInsets.fromLTRB(8, first ? 8 : 4, 8, 4),
                padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
                decoration: BoxDecoration(
                  color: hovered ? C.hover : C.surface2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: marked ? C.orange.withValues(alpha: 0.55) : C.border),
                ),
                child: Row(children: [
                  Expanded(
                    child: Text(label.toUpperCase(),
                        style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                  ),
                  // Сколько журналов в этом дне.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(
                      color: (marked ? C.orange : C.muted).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('$count',
                        style: TextStyle(color: marked ? C.orange : C.muted, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.expand_more_rounded, size: 18, color: hovered || marked ? C.orange : C.muted),
                  ),
                ]),
              ),
            );
          },
        ),
        Reveal(
          open: open,
          // Подсветка выбранного журнала — одна на день и «скользит» к новому, как в боковом меню.
          child: Stack(fit: StackFit.passthrough, children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              top: _last * _SessionTile.height,
              left: 0,
              right: 0,
              height: _SessionTile.height,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: here ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Container(
                    alignment: Alignment.centerLeft,
                    color: C.orange.withValues(alpha: 0.10),
                    // Оранжевая метка слева — как у выбранного сервера на главной.
                    child: Container(width: 3, color: C.orange),
                  ),
                ),
              ),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
          ]),
        ),
      ]);
}
class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.selected, required this.onTap});
  final LogSession session;
  final bool selected;
  final VoidCallback onTap;

  static const height = 56.0;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final (country, name) = Flags.leading(s.title);
    final time = s.live ? 'с ${_clock(s.start)}' : '${_clock(s.start)} – ${_clock(s.end)}';
    return Hover(
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          // Фон и метку выбранного отрезка рисует скользящая подсветка дня (см. _DayGroup).
          color: !selected && hovered ? C.hover : Colors.transparent,
          child: Row(children: [
            const SizedBox(width: 3, height: height),
            const SizedBox(width: 11),
            if (!s.connection)
              _RoundIcon(Icons.more_horiz_rounded)
            else if (country != null)
              FlagIcon.round(country, size: 26)
            else
              _RoundIcon(Icons.public_rounded),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FlagText(s.connection ? name : s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                      color: s.connection ? C.text : C.muted,
                    )),
                const SizedBox(height: 3),
                Row(children: [
                  if (s.live) ...[
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(color: C.green, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      [time, if (s.detail.isNotEmpty) s.detail].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: C.muted, fontSize: 11.5, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                ]),
              ]),
            ),
            if (s.errors > 0) _Count(s.errors, C.red, 'Ошибок: ${s.errors}'),
            if (s.warnings > 0) _Count(s.warnings, C.isDark ? C.orangeLight : C.orange, 'Предупреждений: ${s.warnings}'),
            const SizedBox(width: 12),
          ]),
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(color: C.surface2, shape: BoxShape.circle, border: Border.all(color: C.border)),
        child: Icon(icon, size: 15, color: C.muted),
      );
}

/// Счётчик ошибок или предупреждений в отрезке.
class _Count extends StatelessWidget {
  const _Count(this.value, this.color, this.tooltip);
  final int value;
  final Color color;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
          child: Text(value > 99 ? '99+' : '$value',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      );
}

/// Справа: шапка выбранного отрезка и его строки.
class _SessionView extends StatelessWidget {
  const _SessionView({
    required this.session,
    required this.tab,
    required this.onTab,
    required this.onCopied,
    required this.onDelete,
  });
  final LogSession session;
  final _LogTab tab;
  final ValueChanged<_LogTab> onTab;
  final VoidCallback onCopied;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final all = s.lines;
    final lines = (all ?? const <LogLine>[]).where((l) => tab.matches(l.source)).toList();
    final conns = s.connections;
    final showConns = tab == _LogTab.connections;
    final when = '${_dayLabel(s.start)}, ${_clock(s.start)}'
        '${s.live ? ' · идёт сейчас' : ' – ${_clock(s.end)} · ${_span(s.end.difference(s.start))}'}'
        '${s.detail.isNotEmpty ? ' · ${s.detail}' : ''}';

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FlagText(s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 3),
              Text(when, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
          IconButton(
            tooltip: 'Скопировать',
            icon: Icon(Icons.copy_rounded, size: 18, color: C.muted),
            onPressed: (showConns ? conns.isEmpty : lines.isEmpty)
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(
                        text: showConns
                            ? conns.map(_connLine).join('\n')
                            : lines.map((l) => '${l.time.toIso8601String()} [${l.source}] ${l.text}').join('\n')));
                    onCopied();
                  },
          ),
          if (!s.live)
            IconButton(
              tooltip: 'Удалить этот журнал',
              icon: Icon(Icons.delete_outline_rounded, size: 19, color: C.muted),
              onPressed: onDelete,
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          // В узком окне пять вкладок не помещаются — переключатель слегка уменьшается.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Segmented<_LogTab>(
              value: tab,
              items: {
                for (final t in _LogTab.values)
                  t: '${t.label}  ${t == _LogTab.connections ? conns.length : (all ?? const <LogLine>[]).where((l) => t.matches(l.source)).length}',
              },
              onChanged: onTab,
            ),
          ),
        ),
      ),
      Divider(height: 1, color: C.border),
      Expanded(
        child: showConns
            ? (conns.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        s.live
                            ? 'Соединений пока нет. Здесь появится, какая программа или сайт куда идёт: через VPN, напрямую или блокируется'
                            : 'Список соединений не сохраняется на диск — он виден только до закрытия программы',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: C.muted),
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      key: ValueKey('${s.id}-connections'),
                      primary: true,
                      reverse: true,
                      padding: const EdgeInsets.all(14),
                      itemCount: conns.length,
                      itemBuilder: (_, i) => _ConnText(conns[conns.length - 1 - i]),
                    ),
                  ))
            : all == null
            ? const Center(
                child: Spinner(size: 24))
            : lines.isEmpty
                ? Center(child: Text('В этом журнале таких записей нет', style: TextStyle(color: C.muted)))
                : SelectionArea(
                    // Свежие строки внизу, список «прилипает» к низу — как в консоли.
                    child: ListView.builder(
                      key: ValueKey('${s.id}-${tab.name}'),
                      primary: true,
                      reverse: true,
                      padding: const EdgeInsets.all(14),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => _LineText(lines[lines.length - 1 - i]),
                    ),
                  ),
      ),
    ]);
  }
}

class _LineText extends StatelessWidget {
  const _LineText(this.line);
  final LogLine line;

  @override
  Widget build(BuildContext context) {
    final t = line.time;
    final hint = LogExplain.of(line.source, line.text);
    final color = switch (line.level) {
      2 => C.red,
      1 => C.isDark ? C.orangeLight : C.orange,
      _ => C.text,
    };
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} ', style: TextStyle(color: C.muted)),
        TextSpan(text: '[${line.source}] ', style: TextStyle(color: C.cyan)),
        TextSpan(text: line.text, style: TextStyle(color: color)),
        if (hint != null)
          TextSpan(
            text: '\n         ↳ $hint',
            style: TextStyle(color: C.muted, fontFamily: 'Segoe UI', fontSize: 12),
          ),
      ]),
      style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.5),
    );
  }
}

String _routeLabel(ConnRoute r) => switch (r) {
      ConnRoute.proxy => 'через VPN',
      ConnRoute.direct => 'напрямую',
      ConnRoute.block => 'заблокировано',
      ConnRoute.dns => 'DNS',
    };

/// Откуда соединение попало в ядро — по тегу входа.
String _inboundLabel(String tag) => switch (tag) {
      'socks' => 'SOCKS-порт',
      'http' => 'HTTP-прокси',
      'skipit-tun' => 'TUN',
      _ => tag,
    };

/// Соединение одной строкой — для копирования.
String _connLine(ConnEntry c) => '${c.time.toIso8601String()} ${c.network} ${c.host}:${c.port} → ${_routeLabel(c.route)}'
    '${c.outbound.isEmpty ? '' : ' (${c.outbound})'} · вход: ${_inboundLabel(c.inbound)}';

/// Строка списка соединений: куда шли → каким путём отправлено.
class _ConnText extends StatelessWidget {
  const _ConnText(this.conn);
  final ConnEntry conn;

  @override
  Widget build(BuildContext context) {
    final c = conn;
    final t = c.time;
    final color = switch (c.route) {
      ConnRoute.proxy => C.isDark ? C.orangeLight : C.orange,
      ConnRoute.direct => C.green,
      ConnRoute.block => C.red,
      ConnRoute.dns => C.muted,
    };
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} ', style: TextStyle(color: C.muted)),
        TextSpan(text: '${c.host}:${c.port}', style: TextStyle(color: C.text)),
        if (c.network == 'udp') TextSpan(text: ' udp', style: TextStyle(color: C.muted)),
        TextSpan(text: ' → ${_routeLabel(c.route)}', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        TextSpan(
          text: '${c.outbound.isEmpty ? '' : ' (${c.outbound})'} · вход: ${_inboundLabel(c.inbound)}',
          style: TextStyle(color: C.muted),
        ),
      ]),
      style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.5),
    );
  }
}