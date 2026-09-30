/// Версия программы. Берётся из тега релиза при сборке на GitHub
/// (`--dart-define=APP_VERSION=1.0.1` из тега `v1.0.1`), при локальной сборке — значение по умолчанию.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0a');

/// GitHub-репозиторий приложения в формате `owner/repo` — отсюда берутся обновления SkipIt
/// (последний релиз и установщик SkipIt-Setup-*.exe в нём).
const appRepo = 'FrI3nd7/skipit';
