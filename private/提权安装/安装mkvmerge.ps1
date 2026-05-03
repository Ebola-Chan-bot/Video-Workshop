#requires -Version 5.1
. (Join-Path -Path $PSScriptRoot -ChildPath '安装辅助.ps1')

try {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw '未找到 winget，无法自动安装 MKVToolNix。请手动从 https://mkvtoolnix.download 下载安装。'
    }

    Write-Host '通过 winget 安装 MoritzBunkus.MKVToolNix (machine scope)...'
    & $winget.Source install --id MoritzBunkus.MKVToolNix --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements | Out-Host
    刷新_当前PATH

    $默认目录 = Join-Path $env:ProgramFiles 'MKVToolNix'
    if (Test-Path -LiteralPath (Join-Path $默认目录 'mkvmerge.exe')) {
        添加_机器PATH -目录 $默认目录
    }
    if (-not (Get-Command mkvmerge -ErrorAction SilentlyContinue)) {
        throw '安装似乎完成但未找到 mkvmerge.exe。'
    }

    exit 0
} catch {
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
