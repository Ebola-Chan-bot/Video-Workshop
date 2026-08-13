Set-StrictMode -Version Latest

$script:输出外部进程信息 = $false
$script:视频工坊根目录 = $PSScriptRoot
$script:自定义ffmpeg目录 = $null
$script:自定义ffmpeg缺失已警告 = $false

$privateRoot = Join-Path -Path $PSScriptRoot -ChildPath 'private'
$publicRoot = Join-Path -Path $PSScriptRoot -ChildPath 'public'

Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
	Sort-Object Name |
	ForEach-Object { . $_.FullName }

Get-ChildItem -LiteralPath $publicRoot -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
	Sort-Object Name |
	ForEach-Object { . $_.FullName }

# 加载持久化的自定义 ffmpeg 路径设置（跨会话生效，保存在 %LOCALAPPDATA%\视频工坊\ffmpeg路径.txt）
$持久ffmpeg目录 = 读取_自定义ffmpeg路径设置
if ($持久ffmpeg目录) {
	$script:自定义ffmpeg目录 = $持久ffmpeg目录
}

Export-ModuleMember -Function '烧录字幕', 'DV转HDR10', '超级合并', '轨道叠加', '设置ffmpeg路径', '压缩到指定大小', '转GIF', '反转视频'


