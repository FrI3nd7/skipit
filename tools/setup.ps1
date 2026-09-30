# Скачивает ядра Xray-core и sing-box (последние релизы с GitHub) в папку core\
# и, если нужно, создаёт Windows-обвязку Flutter-проекта.
#   powershell -ExecutionPolicy Bypass -File tools\setup.ps1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'core'
$tmp = Join-Path $env:TEMP 'skipit-setup'
New-Item -ItemType Directory -Force $core, $tmp | Out-Null

function Get-LatestAsset($repo, $pattern) {
    $headers = @{ 'User-Agent' = 'skipit-setup' }
    # В GitHub Actions токен снимает лимит 60 запросов/час на API.
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers $headers
    $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "Не найден файл $pattern в релизе $repo $($rel.tag_name)" }
    Write-Host "  $repo $($rel.tag_name): $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) МБ)"
    return $asset.browser_download_url
}

Write-Host 'Xray-core...'
$url = Get-LatestAsset 'XTLS/Xray-core' '^Xray-windows-64\.zip$'
$zip = Join-Path $tmp 'xray.zip'
Invoke-WebRequest $url -OutFile $zip
Expand-Archive $zip -DestinationPath (Join-Path $tmp 'xray') -Force
Copy-Item (Join-Path $tmp 'xray\xray.exe') $core -Force

Write-Host 'sing-box...'
$url = Get-LatestAsset 'SagerNet/sing-box' '^sing-box-[\d.]+-windows-amd64\.zip$'
$zip = Join-Path $tmp 'sing-box.zip'
Invoke-WebRequest $url -OutFile $zip
Expand-Archive $zip -DestinationPath (Join-Path $tmp 'sing-box') -Force
Get-ChildItem (Join-Path $tmp 'sing-box') -Recurse -Filter 'sing-box.exe' | Select-Object -First 1 |
    Copy-Item -Destination $core -Force

Remove-Item $tmp -Recurse -Force
Write-Host "Ядра лежат в $core" -ForegroundColor Green

if (-not (Test-Path (Join-Path $root 'windows'))) {
    if (Get-Command flutter -ErrorAction SilentlyContinue) {
        Write-Host 'Создаю Windows-обвязку Flutter...'
        Push-Location $root
        flutter create --platforms=windows --project-name skipit --org app.skipit .
        Pop-Location
        # Заголовок окна «SkipIt» вместо имени пакета.
        $mainCpp = Join-Path $root 'windows\runner\main.cpp'
        (Get-Content $mainCpp -Raw) -replace 'L"skipit"', 'L"SkipIt"' | Set-Content $mainCpp -NoNewline
    } else {
        Write-Host 'Flutter не найден в PATH — установите его и выполните: flutter create --platforms=windows --project-name skipit .' -ForegroundColor Yellow
    }
}
