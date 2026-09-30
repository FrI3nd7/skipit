# SkipIt

VPN-клиент для Windows на ядрах **Xray-core** и **sing-box**. Подписки, JSON-конфиги провайдеров
с их правилами маршрутизации, режимы TUN / смешанный / системный прокси, раздельное туннелирование
по приложениям, трей, светлая и тёмная тема, автообновление из GitHub Releases.

## Установка

Скачайте `SkipIt-Setup-<версия>.exe` со страницы [Releases](https://github.com/FrI3nd7/skipit/releases)
и запустите. Установщик ставит программу в Program Files, создаёт ярлыки и добавляет удаление
в «Приложения» Windows. Скопируйте ссылку на подписку и нажмите **Ctrl+V** в окне SkipIt.

## Возможности

- **Протоколы:** VLESS (Reality, XTLS Vision, XHTTP, WS, gRPC, HTTPUpgrade, mKCP), VMess, Trojan,
  Shadowsocks (вкл. 2022), SOCKS, Hysteria2.
- **Подписки:** base64, ссылки, полный Xray JSON-конфиг (правила провайдера, балансировщики, DNS
  используются целиком). Для Remnawave-панелей JSON запрашивается автоматически (`/json`).
  Трафик, срок, объявления, поддержка, автообновление, HWID.
- **Режимы:** «Смешанный» (браузеры через прокси, остальное через TUN), TUN, системный прокси,
  только локальные порты.
- **Маршрутизация:** правила провайдера из JSON или свои профили (совместимы со ссылками `happ://routing`),
  geoip/geosite; правила по приложениям (все через VPN кроме списка / только выбранные).
- **Прочее:** реальная задержка, выбор быстрейшего сервера, скорость и трафик, логи, трей,
  автозапуск, ссылки `skipit://`, запоминание положения окна, обновление ядер и программы.

## Сборка

Нужны [Flutter](https://docs.flutter.dev/get-started/install/windows/desktop) (stable),
Visual Studio 2022 с нагрузкой «Разработка классических приложений на C++» и
[Inno Setup](https://jrsoftware.org/isdl.php).

```
powershell -ExecutionPolicy Bypass -File tools\setup.ps1          # скачать ядра Xray и sing-box в core\
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Version 1.0.1a
```

Результат — `build\installer\SkipIt-Setup-1.0.1a.exe`. Для разработки: `flutter run -d windows`.
Тесты: `flutter test`. Иконка пересобирается скриптом `tools\make_icon.ps1`.

## Выпуск версии

1. **Releases → Draft a new release**, тег — номер версии: `1.0.1a`, `1.0.2b`, `1.0.3`
   (сначала сравниваются цифры, при равных — буква; версия без буквы новее версии с буквой).
2. Для тестовой версии отметьте **Set as a pre-release** — её получат только пользователи
   с каналом обновлений «Бета» (Настройки → О приложении).
3. **Publish release.** GitHub Actions соберёт программу этой версии и прикрепит к релизу
   `SkipIt-Setup-<версия>.exe`. Версия в программе и установщике берётся из тега.

## Данные

`%APPDATA%\SkipIt`: `state.json` (подписки и настройки), `app.log` (журнал), сгенерированные
конфиги ядер, geo-базы. Положение окна — в реестре `HKCU\Software\SkipIt`.

Флаги стран — [flagcdn.com](https://flagcdn.com) (общественное достояние).
