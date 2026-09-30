import 'dart:io';

import 'package:flutter/material.dart';

import '../core/icons.dart';
import '../core/windows.dart';
import '../models/app_rules.dart';
import '../models/settings.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import 'smooth_scroll.dart';
import 'theme.dart';
import 'widgets.dart';

class AppsPage extends StatefulWidget {
  const AppsPage({super.key, this.tabs});

  /// Вкладки раздела «Маршрутизация» (показываются под заголовком).
  final Widget? tabs;

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _loadIcons();
  }

  Future<void> _loadIcons() async {
    await IconCache.ensure(
        AppScope.read(context).appRules.entries.where((e) => e.isPath && !e.isFolder).map((e) => e.match));
    if (mounted) setState(() {});
  }

  void _touch(AppState state) {
    state.changed();
    setState(() => _dirty = state.isConnected && state.usesTun);
  }

  /// Добавляет программы в список; уже добавленные пропускает. Возвращает, сколько добавлено.
  int _addEntries(AppState state, List<({String match, String label})> items) {
    var added = 0;
    for (final item in items) {
      if (state.appRules.entries.any((e) => e.match.toLowerCase() == item.match.toLowerCase())) continue;
      state.appRules.entries.add(AppEntry(match: item.match, label: item.label));
      added++;
    }
    if (added == 0) {
      state.toast('Уже в списке');
    } else {
      _touch(state);
      _loadIcons();
    }
    return added;
  }

  Future<void> _pickRunning(AppState state) async {
    final apps = await WinSys.runningApps();
    if (!mounted) return;
    final already = {for (final e in state.appRules.entries) e.match.toLowerCase()};
    final chosen = await showDialog<List<({String name, String path})>>(
      context: context,
      builder: (ctx) => _RunningAppsDialog(
        apps: apps,
        isAdded: (a) => already.contains(AppEntry.normalizePath(a.path).toLowerCase()),
      ),
    );
    if (chosen != null && chosen.isNotEmpty) {
      _addEntries(state, [for (final a in chosen) (match: AppEntry.normalizePath(a.path), label: a.name)]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final rules = state.appRules;

    final hint = switch (rules.mode) {
      AppRoutingMode.off => 'Все программы идут через VPN. Список ниже не используется.',
      AppRoutingMode.allExcept => 'Все программы идут через VPN, а программы из списка — напрямую.',
      AppRoutingMode.onlySelected => 'Через VPN идут только программы из списка, остальные — напрямую.',
    };

    return Column(children: [
      PageHeader('Маршрутизация', below: widget.tabs, actions: [
        GhostButton(label: 'Из запущенных', icon: Icons.memory_rounded, onPressed: () => _pickRunning(state)),
        GhostButton(
          label: 'Папка',
          icon: Icons.folder_open_rounded,
          onPressed: () async {
            final dir = await WinSys.pickFolder();
            if (dir != null) _addEntries(state, [(match: AppEntry.normalizeFolder(dir), label: dir)]);
          },
        ),
        GhostButton(
          label: 'По имени',
          icon: Icons.text_fields_rounded,
          onPressed: () async {
            final name = await promptText(context, title: 'Имя процесса', hint: 'Например: Telegram или chrome.exe');
            if (name != null && name.trim().isNotEmpty) {
              _addEntries(state, [(match: AppEntry.nameFromPath(name.trim()), label: name.trim())]);
            }
          },
        ),
        GradientButton(
          label: 'Выбрать .exe',
          icon: Icons.add_rounded,
          onPressed: () async {
            final path = await WinSys.pickFile(filter: 'Программы (*.exe)|*.exe');
            if (path != null) {
              _addEntries(state, [(match: AppEntry.normalizePath(path), label: AppEntry.nameFromPath(path))]);
            }
          },
        ),
      ]),
      Expanded(
        child: ListView(
          primary: true,
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
          children: [
            if (!state.usesTun)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Panel(
                  child: Row(children: [
                    Icon(Icons.info_outline_rounded, color: C.cyan),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Правила по приложениям работают в режимах «Смешанный» и TUN.',
                          style: TextStyle(color: C.cyan)),
                    ),
                    TextButton(
                      onPressed: () => state.setMode(ConnectionMode.mixed),
                      child: const Text('Включить «Смешанный»'),
                    ),
                  ]),
                ),
              ),
            Center(
              child: Segmented<AppRoutingMode>(
                value: rules.mode,
                items: const {
                  AppRoutingMode.off: 'Выключено',
                  AppRoutingMode.allExcept: 'Все через VPN, кроме списка',
                  AppRoutingMode.onlySelected: 'Только выбранные через VPN',
                },
                onChanged: (m) {
                  rules.mode = m;
                  _touch(state);
                },
              ),
            ),
            const SizedBox(height: 10),
            Text(hint, textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12.5)),
            const SizedBox(height: 16),
            if (_dirty)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(children: [
                  Expanded(
                    child: Text('Изменения вступят в силу после переподключения',
                        style: TextStyle(color: C.isDark ? C.orangeLight : C.orange)),
                  ),
                  GradientButton(
                    label: 'Применить',
                    icon: Icons.refresh_rounded,
                    onPressed: () async {
                      setState(() => _dirty = false);
                      await state.reconnect();
                    },
                  ),
                ]),
              ),
            if (rules.entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('Список пуст. Добавьте программу, папку или имя процесса.',
                      style: TextStyle(color: C.muted)),
                ),
              ),
            Opacity(
              opacity: rules.mode == AppRoutingMode.off ? 0.45 : 1,
              child: Column(children: [
                for (final e in rules.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Panel(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(children: [
                        Opacity(
                          opacity: e.enabled ? 1 : 0.4,
                          child: AppIcon(path: e.isPath ? e.match : null, folder: e.isFolder),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(e.label,
                                style: TextStyle(fontWeight: FontWeight.w600, color: e.enabled ? C.text : C.muted)),
                            Text(e.match.replaceAll('/', '\\'),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: C.muted, fontSize: 12)),
                          ]),
                        ),
                        Tooltip(
                          message: e.enabled ? 'Правило включено' : 'Правило выключено',
                          child: Switch(
                            value: e.enabled,
                            onChanged: (v) {
                              e.enabled = v;
                              _touch(state);
                            },
                          ),
                        ),
                        IconButton(
                          tooltip: 'Убрать из списка',
                          icon: Icon(Icons.close_rounded, color: C.muted),
                          onPressed: () {
                            rules.entries.remove(e);
                            _touch(state);
                          },
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// Выбор запущенных программ: можно отметить несколько и добавить разом.
class _RunningAppsDialog extends StatefulWidget {
  const _RunningAppsDialog({required this.apps, required this.isAdded});
  final List<({String name, String path})> apps;
  final bool Function(({String name, String path})) isAdded;

  @override
  State<_RunningAppsDialog> createState() => _RunningAppsDialogState();
}

class _RunningAppsDialogState extends State<_RunningAppsDialog> {
  String _q = '';
  final _selected = <String>{};
  final _scroll = SmoothScrollController();

  @override
  void initState() {
    super.initState();
    IconCache.ensure(widget.apps.map((a) => a.path)).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.apps
        .where((a) => _q.isEmpty || a.name.toLowerCase().contains(_q) || a.path.toLowerCase().contains(_q))
        .toList();
    final chosen = widget.apps.where((a) => _selected.contains(a.path)).toList();

    return Dialog(
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(
                child: Text('Запущенные программы', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              ),
              IconButton(
                tooltip: 'Закрыть',
                icon: Icon(Icons.close_rounded, color: C.muted),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Поиск'),
              onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text('Ничего не найдено', style: TextStyle(color: C.muted)))
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final a = list[i];
                        final added = widget.isAdded(a);
                        final checked = _selected.contains(a.path);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Hover(
                            enabled: !added,
                            builder: (context, hovered) => GestureDetector(
                              onTap: added
                                  ? null
                                  : () => setState(() => checked ? _selected.remove(a.path) : _selected.add(a.path)),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 140),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                                decoration: BoxDecoration(
                                  color: checked
                                      ? C.orange.withValues(alpha: 0.12)
                                      : (hovered ? C.hover : Colors.transparent),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: checked ? C.orange.withValues(alpha: 0.6) : Colors.transparent),
                                ),
                                child: Opacity(
                                  opacity: added ? 0.45 : 1,
                                  child: Row(children: [
                                    AppIcon(path: a.path),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                        Text(a.path,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(color: C.muted, fontSize: 12)),
                                      ]),
                                    ),
                                    const SizedBox(width: 10),
                                    if (added)
                                      Text('в списке', style: TextStyle(color: C.muted, fontSize: 12))
                                    else
                                      // Без анимации: галочка и оранжевая подложка появляются вместе.
                                      Container(
                                        width: 22,
                                        height: 22,
                                        decoration: BoxDecoration(
                                          gradient: checked ? C.gradient : null,
                                          borderRadius: BorderRadius.circular(7),
                                          border: checked ? null : Border.all(color: C.border, width: 1.5),
                                        ),
                                        child: checked
                                            ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                                            : null,
                                      ),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Text(chosen.isEmpty ? 'Отметьте программы' : 'Выбрано: ${chosen.length}',
                  style: TextStyle(color: C.muted, fontSize: 12.5)),
              const Spacer(),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
              const SizedBox(width: 8),
              GradientButton(
                label: chosen.isEmpty ? 'Добавить' : 'Добавить (${chosen.length})',
                icon: Icons.add_rounded,
                onPressed: chosen.isEmpty ? null : () => Navigator.pop(context, chosen),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Иконка программы из кеша; пока не извлечена — фирменная заглушка.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, this.path, this.folder = false, this.size = 28});
  final String? path;
  final bool folder;
  final double size;

  @override
  Widget build(BuildContext context) {
    Widget fallback() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(8)),
          child: Icon(folder ? Icons.folder_rounded : Icons.web_asset_rounded, size: size * 0.62, color: C.orange),
        );
    final p = path;
    if (folder || p == null || !IconCache.has(p)) return fallback();
    return Image.file(
      File(IconCache.fileFor(p)),
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => fallback(),
    );
  }
}
