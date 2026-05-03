Set-StrictMode -Version Latest

$script:输出外部进程信息 = $false
$script:视频工坊根目录 = $PSScriptRoot

$privateRoot = Join-Path -Path $PSScriptRoot -ChildPath 'private'
$publicRoot = Join-Path -Path $PSScriptRoot -ChildPath 'public'

Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { . $_.FullName }

Get-ChildItem -LiteralPath $publicRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { . $_.FullName }

Export-ModuleMember -Function '烧录字幕', 'DV转HDR10', '超级合并'


