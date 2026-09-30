import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import 'theme.dart';
import 'widgets.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

/// Вкладки логов: события приложения отдельно от вывода ядер.
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

class _LogsPageState extends State<LogsPage> {
  _LogTab _tab = _LogTab.all;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state.log,
      builder: (context, _) {
        final all = state.log.lines;
        final lines = all.where((l) => _tab.matches(l.source)).toList().reversed.toList();
        return Column(children: [
          PageHeader('Логи', subtitle: 'События приложения и вывод ядер Xray и sing-box', actions: [
            GhostButton(
              label: 'Копировать',
              icon: Icons.copy_rounded,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(
                    text: lines.reversed.map((l) => '${l.time.toIso8601String()} [${l.source}] ${l.text}').join('\n')));
                state.toast('Логи скопированы');
              },
            ),
            GhostButton(label: 'Очистить', icon: Icons.delete_sweep_rounded, onPressed: state.log.clear),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Segmented<_LogTab>(
                value: _tab,
                items: {
                  for (final t in _LogTab.values)
                    t: '${t.label}  ${all.where((l) => t.matches(l.source)).length}',
                },
                onChanged: (t) => setState(() => _tab = t),
              ),
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(28, 0, 28, 28),
              decoration: BoxDecoration(
                color: C.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: C.border),
              ),
              child: lines.isEmpty
                  ? Center(child: Text('Здесь пока пусто', style: TextStyle(color: C.muted)))
                  : SelectionArea(
                      child: ListView.builder(
                        primary: true,
                        reverse: true,
                        padding: const EdgeInsets.all(14),
                        itemCount: lines.length,
                        itemBuilder: (_, i) {
                          final l = lines[i];
                          final t = l.time;
                          final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
                              '${t.second.toString().padLeft(2, '0')}';
                          final lower = l.text.toLowerCase();
                          final color = lower.contains('error') || lower.contains('fatal') || lower.contains('ошибк')
                              ? C.red
                              : lower.contains('warn')
                                  ? C.orangeLight
                                  : C.text;
                          return Text.rich(
                            TextSpan(children: [
                              TextSpan(text: '$ts ', style: TextStyle(color: C.muted)),
                              TextSpan(text: '[${l.source}] ', style: TextStyle(color: C.cyan)),
                              TextSpan(text: l.text, style: TextStyle(color: color)),
                            ]),
                            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.5),
                          );
                        },
                      ),
                    ),
            ),
          ),
        ]);
      },
    );
  }
}
