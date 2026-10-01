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

    // Связь с VPN-сервером.
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

  /// Пояснение к строке или null, если сказать нечего. Строки самой программы уже написаны по-русски.
  static String? of(String source, String text) {
    if (source != 'xray' && source != 'sing-box' && source != 'test') return null;
    for (final (pattern, explain) in _rules) {
      final m = pattern.firstMatch(text);
      if (m != null) return explain(m);
    }
    return null;
  }
}
