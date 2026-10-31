function 按LLC剪切 {
	<#
	.SYNOPSIS
		按 LosslessCut 的 LLC 项目文件，将视频剪成多个片段文件。

	.DESCRIPTION
		读取 version 2 的 .llc 项目，使用 mediaFileName 定位同目录的源媒体，只处理 cutSegments 中 selected 为 true 的片段。start和 end 的单位为秒。两个端点分别对齐到距离最近的关键帧，而不是精确切在指定时间；对齐后若起点不早于终点，则报错并停止。所有轨道均不转码，只做流复制剪切。普通视频由 ffmpeg 处理，RM/RMVB 由 RealMedia Editor 原生处理，均保留源扩展名。片段默认使用源文件名、对齐后的时间戳和片段序号命名，源文件保持不变。

	.PARAMETER 项目文件
		要读取的 .llc 项目文件路径。支持带尾随逗号的 LLC JSONC 格式。

	.PARAMETER 输出目录
		存放所有片段的目录。省略时输出到源媒体所在目录；不存在时自动创建。

	.EXAMPLE
		按LLC剪切 -项目文件 'D:\视频-proj.llc'

		将项目中的所有已选片段分别保存为独立视频文件，文件名带实际使用的关键帧时间戳。

	.EXAMPLE
		按LLC剪切 -项目文件 'D:\视频-proj.llc' -输出目录 'D:\片段'

		把片段统一输出到指定目录。

	.NOTES
		依赖 ffmpeg 和 ffprobe；RM/RMVB 还依赖 RealProducer 自带的 rmeditor.exe，缺少时会自动安装。流复制片段以关键帧为边界，不保证恰好等于 LLC 中填写的毫秒时间。
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0, HelpMessage = 'LosslessCut 的 .llc 项目文件路径')]
		[string]$项目文件,

		[Parameter(Position = 1)]
		[string]$输出目录
	)

	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'
	$script:输出外部进程信息 = $false

	$项目文件 = 规范化_用户路径参数 -Path $项目文件
	if ($输出目录) { $输出目录 = 规范化_用户路径参数 -Path $输出目录 }
	if (-not (Test-Path -LiteralPath $项目文件 -PathType Leaf)) { throw "LLC 项目文件不存在：$项目文件" }
	确保_ffmpeg_ffprobe_可用

	$项目 = 读取_LLC项目 -Path $项目文件
	$源路径 = $项目.媒体路径
	$源扩展名 = [System.IO.Path]::GetExtension($源路径).ToLowerInvariant()
	$是RealMedia = $源扩展名 -in @('.rm', '.rmvb')
	$输出扩展名 = $源扩展名
	$RealMedia编辑器 = if ($是RealMedia) { 解决_RealMedia编辑器路径 } else { $null }
	if (-not $输出目录) { $输出目录 = Split-Path -Parent $源路径 }
	$输出目录 = [System.IO.Path]::GetFullPath($输出目录)
	if (-not (Test-Path -LiteralPath $输出目录 -PathType Container)) { New-Item -ItemType Directory -Path $输出目录 -Force | Out-Null }
	$基础名 = [System.IO.Path]::GetFileNameWithoutExtension($源路径)

	Write-Host "源文件：$源路径" -ForegroundColor Cyan
	Write-Host '正在读取关键帧并对齐剪切端点……' -ForegroundColor Cyan
	$关键帧列表 = @(获取_视频关键帧 -Path $源路径)
	if ($是RealMedia) { Write-Host 'RealMedia 使用 rmeditor 原生剪切：保留 RM/RMVB 容器，所有轨道均不转码。' -ForegroundColor Yellow }

	$结果列表 = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
	foreach ($片段 in $项目.片段列表) {
		$开始关键帧 = 取_最近关键帧 -关键帧列表 $关键帧列表 -目标时间 $片段.开始
		$结束关键帧 = 取_最近关键帧 -关键帧列表 $关键帧列表 -目标时间 $片段.结束
		$开始 = $开始关键帧.时间
		$结束 = $结束关键帧.时间
		if ($结束 -le $开始) { throw "第 $($片段.序号) 个片段在关键帧对齐后区间无效：$开始 至 $结束 秒。" }
		$名称后缀 = if ([string]::IsNullOrWhiteSpace($片段.名称)) { '' } else { '-' + ($片段.名称 -replace '[<>:"/\\|?*\x00-\x1f]', '_') }
		$文件名 = '{0}-{1}-{2}-seg{3}{4}{5}' -f $基础名, (格式化_LLC时间戳 -秒 $开始), (格式化_LLC时间戳 -秒 $结束), $片段.序号, $名称后缀, $输出扩展名
		$片段路径 = Join-Path $输出目录 $文件名
		if ([System.IO.Path]::GetFullPath($片段路径) -ieq $源路径) { throw "输出文件不能覆盖源文件：$片段路径" }

		Write-Host ("片段 {0}：{1:F3} → {2:F3} 秒（原请求 {3:F3} → {4:F3} 秒）" -f $片段.序号, $开始, $结束, $片段.开始, $片段.结束) -ForegroundColor Cyan
		if ($是RealMedia) {
			剪切_RealMedia片段 -编辑器路径 $RealMedia编辑器 -源路径 $源路径 -输出路径 $片段路径 -开始 $开始关键帧.编辑器起点 -结束 $结束
		} else {
			$参数 = @('-hide_banner', '-nostdin', '-y', '-i', $源路径,
				'-ss', $开始.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture),
				'-to', $结束.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture),
				'-map', '0', '-c', 'copy', '-avoid_negative_ts', 'make_zero', $片段路径)
			$ffmpeg路径 = 解决_工具执行路径 -工具名 'ffmpeg'
			Write-Host "> $ffmpeg路径 $($参数 -join ' ')" -ForegroundColor DarkGray
			[void](调用_外部命令 -Exe $ffmpeg路径 -ArgumentList $参数 -CaptureOutput)
		}
		$输出文件 = Get-Item -LiteralPath $片段路径
		if ($输出文件.Length -le 0) { throw "未生成有效片段：$片段路径" }
		$结果列表.Add($输出文件)
		Write-Host "完成：$片段路径" -ForegroundColor Green
	}
	return $结果列表.ToArray()
}
