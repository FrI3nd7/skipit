# Разработка SkipIt

Этот файл — для разработчиков. Пользователям достаточно установщика из Releases.

Программа написана на Flutter (Windows), протоколы обрабатывает **Xray-core**, режим TUN и правила
по приложениям — **sing-box**. Ядра кладутся в установщик при сборке.

## Сборка из исходников

Нужны [Flutter](https://docs.flutter.dev/get-started/install/windows/desktop) (stable),
Visual Studio 2022 с нагрузкой «Разработка классических приложений на C++» и
[Inno Setup](https://jrsoftware.org/isdl.php).

```
powershell -ExecutionPolicy Bypass -File tools\setup.ps1                     # скачать ядра Xray и sing-box в core\
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Version 1.0.1a     # программа + установщик
```

Результат — `build\installer\SkipIt-Setup-1.0.1a.exe`.
Запуск для разработки: `flutter run -d windows`. Тесты: `flutter test`.
Иконка пересобирается скриптом `tools\make_icon.ps1`.

## Выпуск версии

Собирать вручную не нужно — это делает GitHub Actions (`.github/workflows/build.yml`).

1. **Releases → Draft a new release**, тег — номер версии: `1.0.1a`, `1.0.2b`, `1.0.3`
   (сначала сравниваются цифры, при равных — буква; версия без буквы новее версии с буквой).
2. Для тестовой версии отметьте **Set as a pre-release** — её получат только пользователи
   с каналом обновлений «Бета» (Настройки → О приложении).
3. **Publish release.** Через несколько минут к релизу прикрепится `SkipIt-Setup-<версия>.exe`,
   а установленные SkipIt предложат обновиться. Версия в программе берётся из тега.

## Где программа хранит данные

`%APPDATA%\SkipIt`: `state.json` (подписки и настройки), `app.log` (журнал), сгенерированные
конфиги ядер, geo-базы. Положение окна — в реестре `HKCU\Software\SkipIt`.

Флаги стран — [flagcdn.com](https://flagcdn.com) (общественное достояние).
