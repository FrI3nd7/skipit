import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/paths.dart';
import '../core/updates.dart';
import '../core/util.dart';
import '../core/tray.dart';
import '../core/windows.dart';
import '../models/settings.dart';
import '../state/app_scope.dart';
import '../version.dart';
import 'theme.dart';
import 'widgets.dart';

/// Скачивает установщик новой версии, запускает его и закрывает программу (чтобы файлы можно было заменить).
/// Если установщика в релизе нет — открывает страницу релиза.
Future<void> installAppUpdate(BuildContext context) async {
  final state = AppScope.read(context);
  final release = state.availableUpdates['app'];
  if (release == null) return;
  String? installer;
  try {
    installer = await state.downloadAppUpdate();
  } catch (e) {
    state.toast('Не удалось скачать обновление: $e');
    return;
  }
  if (installer == null) {
    await WinSys.openUrl(release.pageUrl);
    return;
  }
  if (!context.mounted) return;
  final ok = await confirm(context, 'Обновить SkipIt до ${release.version}?',
      'VPN отключится, программа закроется и откроется установщик новой версии.',
      ok: 'Установить');
  if (!ok) return;
  await Process.start(installer, const ['/SP-'], mode: ProcessStartMode.detached);
  await state.shutdown();
  await Tray.quit();
  exit(0);
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final s = state.settings;

    Widget toggle(String title, String subtitle, bool value, void Function(bool) set) => _Row(
          title: title,
          subtitle: subtitle,
          trailing: Switch(
            value: value,
            onChanged: (v) {
              set(v);
              state.changed();
            },
          ),
        );

    Widget number(String title, String subtitle, int value, void Function(int) set) => _Row(
          title: title,
          subtitle: subtitle,
          trailing: SizedBox(
            width: 110,
            child: TextFormField(
              initialValue: '$value',
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (v) {
                final n = asInt(v);
                if (n != null && n > 0 && n < 65536) {
                  set(n);
                  state.changed();
                }
              },
            ),
          ),
        );

    Widget text(String title, String subtitle, String value, void Function(String) set, {double width = 340}) => _Row(
          title: title,
          subtitle: subtitle,
          trailing: SizedBox(
            width: width,
            child: TextFormField(
              initialValue: value,
              onChanged: (v) {
                set(v.trim());
                state.changed();
              },
            ),
          ),
        );

    return ListView(
      primary: true,
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const PageHeader('Настройки', subtitle: 'Изменения портов и ядра применяются при следующем подключении'),
        _Section('Оформление', [
          _Row(
            title: 'Тема',
            subtitle: '«Как в системе» следует за настройкой Windows',
            trailing: Segmented<AppTheme>(
              value: s.theme,
              items: const {AppTheme.dark: 'Тёмная', AppTheme.light: 'Светлая', AppTheme.system: 'Как в системе'},
              onChanged: (v) {
                s.theme = v;
                state.changed();
              },
            ),
          ),
        ]),
        _Section('Система', [
          _Row(
            title: 'Права администратора',
            subtitle: state.isAdmin ? 'Есть — режим TUN доступен' : 'Нет — для режима TUN нужен перезапуск',
            trailing: state.isAdmin
                ? Icon(Icons.verified_user_rounded, color: C.green)
                : GhostButton(
                    label: 'Перезапустить',
                    icon: Icons.admin_panel_settings_rounded,
                    onPressed: () async {
                      if (await WinSys.relaunchAsAdmin(const [])) {
                        await state.shutdown();
                        await Tray.quit();
                        exit(0);
                      }
                    },
                  ),
          ),
          toggle('Запускать вместе с Windows', 'Запускать приложение при входе в Windows', state.autostart,
              (v) => state.setAutostart(v)),
          toggle('Сворачивать в трей при закрытии', 'Крестик прячет окно в трей, VPN продолжает работать. Выход — через меню значка в трее',
              s.closeToTray, (v) => s.closeToTray = v),
          toggle('Подключаться при запуске', 'Автоматически включать VPN при автозапуске', s.connectOnStart,
              (v) => s.connectOnStart = v),
          toggle('Переподключаться при сбое', 'Перезапускать ядро, если оно упало', s.autoReconnect,
              (v) => s.autoReconnect = v),
        ]),
        _Section('Подключение', [
          toggle('Автовыбор сервера', 'Перед подключением выбирать самый быстрый сервер подписки', s.autoSelect,
              (v) => s.autoSelect = v),
          toggle('Разрешить подключения из локальной сети', 'Раздавать прокси другим устройствам (0.0.0.0)', s.allowLan,
              (v) => s.allowLan = v),
        ]),
        _Section('Проверка задержки', [
          _Row(
            title: 'Тип проверки',
            subtitle: 'Реальная — запрос через сервер, TCP — только доступность порта',
            trailing: Segmented<PingType>(
              value: s.pingType,
              items: const {PingType.realDelay: 'Реальная', PingType.tcp: 'TCP'},
              onChanged: (v) {
                s.pingType = v;
                state.changed();
              },
            ),
          ),
        ]),
        _Section('Подписки', [
          toggle('Обновлять при запуске', 'Загружать свежий список серверов при старте', s.updateSubsOnStart,
              (v) => s.updateSubsOnStart = v),
          toggle('Обновлять через VPN', 'Если подключено — качать подписку через туннель', s.updateViaProxy,
              (v) => s.updateViaProxy = v),        ]),
        _CollapsibleSection('Дополнительно', 'Порты, MTU, сниффинг, логи, адрес проверки, User-Agent и HWID — обычно менять не нужно', [
          number('SOCKS-порт', 'Локальный SOCKS5-прокси', s.socksPort, (v) => s.socksPort = v),
          number('HTTP-порт', 'Используется системным прокси', s.httpPort, (v) => s.httpPort = v),
          number('Порт API статистики', 'Для счётчиков трафика', s.apiPort, (v) => s.apiPort = v),
          toggle('IPv6', 'Включить IPv6 в туннеле и DNS', s.ipv6, (v) => s.ipv6 = v),
          toggle('Сниффинг', 'Определять домен по TLS/HTTP/QUIC — нужен для маршрутизации по сайтам', s.sniffing,
              (v) => s.sniffing = v),
          number('MTU TUN-адаптера', 'Обычно 9000 или 1500', s.mtu, (v) => s.mtu = v),
          _Row(
            title: 'Уровень логов',
            subtitle: 'debug — максимум подробностей',
            trailing: AppDropdown<String>(
              value: s.logLevel,
              items: const {'debug': 'debug', 'info': 'info', 'warning': 'warning', 'error': 'error', 'none': 'none'},
              onChanged: (v) {
                s.logLevel = v;
                state.changed();
              },
            ),
          ),
          text('Адрес для проверки', 'Должен отвечать быстро (204)', s.testUrl, (v) => s.testUrl = v),
          text('User-Agent', 'Некоторые панели отдают разный формат по User-Agent', s.userAgent,
              (v) => s.userAgent = v),
          toggle('Отправлять HWID', 'Заголовки x-hwid / x-device-os для лимита устройств у провайдера', s.sendHwid,
              (v) => s.sendHwid = v),
          _Row(
            title: 'HWID устройства',
            subtitle: s.hwid,
            trailing: IconButton(
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => Clipboard.setData(ClipboardData(text: s.hwid)),
            ),
          ),
        ]),
        _Section('О приложении', [
          _Row(
            title: 'Папка данных',
            subtitle: 'Настройки, подписки и журнал app.log',
            trailing: GhostButton(
              label: 'Открыть',
              icon: Icons.folder_open_rounded,
              onPressed: () => Process.run('explorer', [AppPaths.dataDir.path]),
            ),
          ),
          _Row(
            title: 'Версия SkipIt',
            subtitle: [
              appVersion,
              if (state.availableUpdates['app'] != null) 'доступна ${state.availableUpdates['app']!.version}',
              if (appRepo.isEmpty) 'обновления приложения появятся после публикации на GitHub',
              if (state.lastUpdateCheck != null) 'проверено ${formatDateTime(state.lastUpdateCheck!)}',
            ].join(' · '),
            trailing: Wrap(spacing: 8, children: [
              if (state.availableUpdates['app'] != null)
                state.downloadingAppUpdate
                    ? const SizedBox(
                        width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: C.orange))
                    : GradientButton(
                        label: 'Обновить',
                        icon: Icons.download_rounded,
                        onPressed: () => installAppUpdate(context),
                      ),
              GhostButton(
                label: 'Проверить обновления',
                icon: Icons.system_update_alt_rounded,
                busy: state.checkingUpdates,
                onPressed: state.checkUpdates,
              ),
            ]),
          ),
          _Row(
            title: 'Канал обновлений',
            subtitle: s.updateChannel == UpdateChannel.beta
                ? 'Бета: вместе с релизами приходят и пре-релизы — новые функции раньше, но возможны ошибки'
                : 'Стабильный: только стабильные версии',
            trailing: Segmented<UpdateChannel>(
              value: s.updateChannel,
              items: const {UpdateChannel.stable: 'Стабильный', UpdateChannel.beta: 'Бета'},
              onChanged: (v) {
                s.updateChannel = v;
                state.availableUpdates.remove('app');
                state.changed();
                state.checkUpdates(silent: true);
              },
            ),
          ),
          for (final core in CoreSpec.all)
            _Row(
              title: core.name,
              subtitle: [
                state.coreVersions[core.name] ?? 'не установлено',
                if (state.availableUpdates[core.name] != null)
                  'доступна ${state.availableUpdates[core.name]!.version}',
              ].join(' · '),
              trailing: state.availableUpdates[core.name] != null
                  ? const Tag('обновление', color: C.orangeLight)
                  : (state.coreVersions[core.name] != null
                      ? Icon(Icons.check_circle_rounded, color: C.green, size: 20)
                      : Icon(Icons.error_rounded, color: C.red, size: 20)),
            ),
          if (CoreSpec.all.any((c) => state.availableUpdates.containsKey(c.name)))
            _Row(
              title: 'Обновить ядра',
              subtitle: state.isConnected ? 'VPN ненадолго отключится и включится снова' : 'Скачать и установить новые версии',
              trailing: state.installingCores
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: C.orange))
                  : GradientButton(label: 'Обновить', icon: Icons.download_rounded, onPressed: state.installCoreUpdates),
            ),
        ]),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title.toUpperCase(),
                style: const TextStyle(color: C.orange, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
          ),
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            child: Column(children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                children[i],
              ],
            ]),
          ),
        ]),
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.title, required this.subtitle, required this.trailing});
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              SelectableText(subtitle, style: TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 16),
          trailing,
        ]),
      );
}

/// Секция, свёрнутая по умолчанию — для технических параметров.
class _CollapsibleSection extends StatefulWidget {
  const _CollapsibleSection(this.title, this.hint, this.children);
  final String title;
  final String hint;
  final List<Widget> children;

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Panel(
            onTap: () => setState(() => _open = !_open),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.title.toUpperCase(),
                      style: const TextStyle(color: C.orange, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
                  const SizedBox(height: 3),
                  Text(widget.hint, style: TextStyle(color: C.muted, fontSize: 12)),
                ]),
              ),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.expand_more_rounded, color: C.muted),
              ),
            ]),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Panel(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                      child: Column(children: [
                        for (var i = 0; i < widget.children.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          widget.children[i],
                        ],
                      ]),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ]),
      );
}