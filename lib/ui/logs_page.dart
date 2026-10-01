import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_manager.dart';
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
enum _LogTab { all, app, xray, singbox }

extension on _LogTab {
  String get label => switch (this) {
        _LogTab.all => 'Все',
        _LogTab.app => 'Приложение',
        _LogTab.xray => 'Xray',
        _LogTab.singbox => 'sing-box',
      };

  bool matches(String source) => switch (this) {
        _LogTab.all => true,
        _LogTab.xray => source == 'xray' || source == 'test',
        _LogTab.singbox => source == 'sing-box',
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
            subtitle: 'Журнал разбит по подключениям и хранится ${LogBuffer.keepDays} дней',
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

/// Слева: отрезки журнала по дням, свежие сверху.
class _SessionList extends StatelessWidget {
  const _SessionList({required this.sessions, required this.selected, required this.onSelect});
  final List<LogSession> sessions;
  final LogSession? selected;
  final ValueChanged<LogSession> onSelect;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    DateTime? day;
    for (final s in sessions.reversed) {
      if (day == null || day.day != s.start.day || day.month != s.start.month || day.year != s.start.year) {
        day = s.start;
        rows.add(Padding(
          padding: EdgeInsets.fromLTRB(16, rows.isEmpty ? 14 : 18, 16, 6),
          child: Text(_dayLabel(day).toUpperCase(),
              style: TextStyle(color: C.muted, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
        ));
      }
      rows.add(_SessionTile(session: s, selected: identical(s, selected), onTap: () => onSelect(s)));
    }
    // Свой контроллер плавной прокрутки: основной контроллер страницы занят списком строк справа.
    return SmoothScroll(
      builder: (context, controller) =>
          ListView(controller: controller, padding: const EdgeInsets.only(bottom: 10), children: rows),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.selected, required this.onTap});
  final LogSession session;
  final bool selected;
  final VoidCallback onTap;

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
          color: selected ? C.orange.withValues(alpha: 0.10) : (hovered ? C.hover : Colors.transparent),
          child: Row(children: [
            // Оранжевая метка слева у выбранного отрезка — как у выбранного сервера на главной.
            Container(width: 3, height: 56, color: selected ? C.orange : Colors.transparent),
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
            onPressed: lines.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(
                        text: lines.map((l) => '${l.time.toIso8601String()} [${l.source}] ${l.text}').join('\n')));
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
          child: Segmented<_LogTab>(
            value: tab,
            items: {
              for (final t in _LogTab.values)
                t: '${t.label}  ${(all ?? const <LogLine>[]).where((l) => t.matches(l.source)).length}',
            },
            onChanged: onTab,
          ),
        ),
      ),
      Divider(height: 1, color: C.border),
      Expanded(
        child: all == null
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
      ]),
      style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.5),
    );
  }
}
