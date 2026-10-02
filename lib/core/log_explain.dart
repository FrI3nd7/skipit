/// Расшифровка строк журнала ядер простыми словами: что произошло и нужно ли что-то делать.
/// Ядра пишут по-английски и для разработчиков; здесь — пояснения к самым частым сообщениям.
class LogExplain {
  static final _rules = <(RegExp, String Function(RegExpMatch))>[
    // Запуск и остановка.
    (RegExp(r'core: Xray .* started'), (_) => 'Ядро Xray запущено и готово к работе.'),
    (RegExp(r'sing-box started'), (_) => 'Ядро sing-box запущено: адаптер TUN работает.'),
    (RegExp(r'Reading config'), (_) => 'Ядро читает файл с настройками подключения.'),
    (RegExp(r'завершился с кодом (-?\d+)'), (m) => m.group(1) == '0'
        ? 'Ядро остановлено штатно.'
        : 'Ядро остановлено (при отключении это нормально; если само — см. строки выше).'),
    (
      RegExp(r'is deprecated'),
      (_) => 'В настройках сервера есть устаревший параметр. На работу сейчас не влияет; '
          'исчезнет, когда провайдер обновит конфиг.'
    ),

    // Адаптер TUN.
    (RegExp(r'Failed to find matching adapter name'), (_) => 'Готового адаптера VPN нет — ядро создаст новый. Это обычная строка, не ошибка.'),
    (RegExp(r'Creating adapter'), (_) => 'Ядро просит Windows создать сетевой адаптер VPN. Если следом нет строки о запуске — Windows его не создала.'),
    (RegExp(r'Removed orphaned adapter'), (_) => 'Убран брошенный адаптер, оставшийся от прошлого запуска. Работающие адаптеры не трогаются.'),
    (RegExp(r'Using existing driver'), (_) => 'Драйвер адаптера (Wintun) уже установлен в Windows.'),
    (
      RegExp(r'open interface take too much time|configure tun interface'),
      (_) => 'Windows не отдаёт сетевой адаптер VPN. Обычно помогает перезагрузка; пока можно подключиться в режиме «Прокси».'
    ),
    (RegExp(r'[Aa]ccess is denied'), (_) => 'Windows отказала в доступе — нужны права администратора.'),

    // Файрвол.
    (
      RegExp(r'\b(10057|10013)\b|forbidden by its access permissions'),
      (_) => 'Выход в сеть заблокирован файрволом (например, simplewall). Разрешите в нём ядро SkipIt.'
    ),

  ];

  /// Пояснения к сбоям: показываются только у предупреждений и ошибок — иначе обычная строка,
  /// где просто упомянут сертификат или REALITY, выглядела бы как поломка.
  static final _problems = <(RegExp, String Function(RegExpMatch))>[
    // Соединения программ через адаптер: «другая сторона» здесь — сама программа на компьютере.
    (
      RegExp(r'proxy/tun: connection reset by peer'),
      (_) => 'Программа на компьютере сама оборвала своё соединение (закрыли вкладку, отменили загрузку, '
          'программа передумала). Обычная строка — на работу VPN не влияет.'
    ),
    (
      RegExp(r'proxy/tun: connection was refused'),
      (_) => 'Программа на компьютере закрыла соединение раньше, чем оно установилось. '
          'Обычная строка — на работу VPN не влияет.'
    ),
    (
      RegExp(r'proxy/tun: operation timed out'),
      (_) => 'Соединение программы долго молчало и закрыто по времени. Разовые случаи — норма.'
    ),
    // Связь с VPN-сервером.
    (
      RegExp(r'observatory.*error ping .* with (\S+):'),
      (m) => 'Ядро само проверяет серверы провайдера, чтобы выбрать лучший: сервер «${m.group(1)}» не ответил '
          'на проверку. Сразу после подключения это обычное дело; если повторяется постоянно — сервер недоступен.'
    ),
    (
      RegExp(r'failed to find an available destination|all retry attempts failed|failed to dial'),
      (_) => 'Не удалось соединиться с VPN-сервером: он недоступен или заблокирован. Попробуйте другой сервер.'
    ),
    (
      RegExp(r'REALITY|reality.*(verify|handshake)|tls: |x509|certificate'),
      (_) => 'Ошибка защищённого соединения с сервером: не сошлись ключи или сертификат. '
          'Обновите подписку; если не поможет — напишите провайдеру.'
    ),
    (
      RegExp(r'no such host|failed to lookup|lookup .* (timeout|failed)|dns: .*fail'),
      (_) => 'Не удалось узнать адрес сайта (DNS не ответил).'
    ),

    // Windows сама проверяет, есть ли интернет по IPv6 (от этого зависит значок сети), а у этих её
    // адресов есть только IPv6. При выключенном IPv6 ядру некуда подключиться — это не сбой.
    (
      RegExp(r'ipv6\.(msftncsi|msftconnecttest)\.com'),
      (_) => 'Windows проверяет, есть ли интернет по IPv6. Пока IPv6 выключен в настройках, проверка '
          'не проходит — так и должно быть, на работу VPN не влияет.'
    ),

    // DNS ответил «такого имени нет» (код 3): программа стучится на адрес, которого не существует.
    (
      RegExp(r'failed to resolve ip.*domain (\S+) > rcode: 3'),
      (m) => 'Программа запросила адрес ${m.group(1)}, а такого имени не существует — так ответил DNS. '
          'Это не сбой VPN: без него она получила бы тот же отказ.'
    ),

    // Отдельные соединения — обычно не требуют действий.
    (
      RegExp(r'failed to read response from (\S+)'),
      (m) => 'Сайт ${m.group(1)} закрыл соединение, не ответив. Разовые случаи — норма, на VPN не влияют.'
    ),
    (RegExp(r'i/o timeout|deadline exceeded|timed? ?out'), (_) => 'Другая сторона не ответила вовремя.'),
    (
      RegExp(r'connection refused|actively refused'),
      (_) => 'Другая сторона отказала в соединении: порт закрыт или сервис не работает.'
    ),
    (
      RegExp(r'connection reset|forcibly closed|wsarecv|wsasend'),
      (_) => 'Соединение оборвано другой стороной или по пути. Если повторяется на всех сайтах — мешает блокировка или сервер.'
    ),
    (
      RegExp(r'context canceled|closed pipe|use of closed network connection|unexpected EOF|\bEOF\b'),
      (_) => 'Соединение закрыто раньше времени — чаще всего самой программой (закрыли вкладку, отменили загрузку).'
    ),
    (RegExp(r'rejected|blocked'), (_) => 'Соединение отклонено правилами.'),
  ];

  static final _problem = RegExp(r'\[(Warning|Error)\]|\b(WARN|ERROR|FATAL)\b|fail', caseSensitive: false);

  /// Пояснение к строке или null, если сказать нечего. Строки самой программы уже написаны по-русски.
  static String? of(String source, String text) {
    if (source != 'xray' && source != 'sing-box' && source != 'test') return null;
    for (final (pattern, explain) in [..._rules, if (_problem.hasMatch(text)) ..._problems]) {
      final m = pattern.firstMatch(text);
      if (m != null) return explain(m);
    }
    return null;
  }
}
