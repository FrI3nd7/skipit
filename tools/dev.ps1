# Тестовая сборка разработчика: собирает программу и запускает её отдельной копией «SkipIt Dev».
#   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 [-NoRun]
#
# Копия лежит в build\dev и помечена файлом dev-build. По этой метке программа берёт всё своё:
# папку данных %APPDATA%\SkipIt Dev, автозапуск, положение окна, имя TUN-адаптера, порт единственного
# экземпляра. Поэтому её можно запускать рядом со SkipIt, установленным из релиза, — они не пересекаются.
# При первом запуске подписки и настройки один раз копируются из установленной программы.

param([switch]$NoRun)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    & (Join-Path $PSScriptRoot 'setup.ps1')

    flutter build windows --release --no-tree-shake-icons
    if ($LASTEXITCODE -ne 0) { throw 'flutter build завершился с ошибкой' }

    $dev = Join-Path $root 'build\dev'
    $exe = Join-Path $dev 'SkipIt.exe'
    # Запущенную тестовую копию просим выйти (она отключит VPN и вернёт прокси), иначе файлы заняты.
    if (Test-Path $exe) {
        & $exe --quit | Out-Null
        Start-Sleep -Seconds 3
    }

    robocopy 'build\windows\x64\runner\Release' $dev /MIR /XD core /XF dev-build /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Не удалось скопировать сборку в $dev (robocopy $LASTEXITCODE)" }
    New-Item -ItemType Directory -Force (Join-Path $dev 'core') | Out-Null
    Copy-Item 'core\skipit-*.exe', 'core\wintun.dll', 'core\LICENSE-*.txt' (Join-Path $dev 'core') -Force
    Set-Content (Join-Path $dev 'dev-build') 'Тестовая сборка SkipIt: данные и настройки отдельно от установленной программы.' -Encoding utf8

    Write-Host "Готово: $exe" -ForegroundColor Green
    if (-not $NoRun) { Start-Process $exe }
} finally {
    Pop-Location
}
