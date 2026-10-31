function 转GIF {
	<#
	.SYNOPSIS
		将视频的第一个视频轨转换为 GIF 动图。

	.DESCRIPTION
		使用 ffmpeg 的 palettegen/paletteuse 两遍调色板流程，把输入文件的第一个视频轨转成高质量 GIF：
		第一遍分析全片生成优化调色板（stats_mode=diff），第二遍用该调色板逐帧量化输出，
		画面色彩和过渡明显优于一遍直出的 GIF。

		尺寸控制三选一：可以指定 -宽度 和/或 -高度（只指定其一时另一边按原视频比例自动计算；
		同时指定时按给定宽高直接缩放，允许宽高比不同于原视频），或者指定 -缩放率（按原视频比例
		整体缩放，1 表示保持原分辨率，小于 1 缩小、大于 1 放大）。两种尺寸方式互斥：
		缩放率不能与宽度/高度同时使用。未指定任何尺寸参数时保持原始分辨率。

		未指定输出路径时，在输入文件同目录生成“原文件名.gif”。输出文件已存在时会被覆盖。

	.PARAMETER 输入文件
		要转换的视频文件路径，必须存在且至少包含一个视频轨。

	.PARAMETER 输出文件
		输出 GIF 路径。省略时为输入文件同目录下的“原文件名.gif”。

	.PARAMETER 宽度
		目标 GIF 宽度（像素）。可与 -高度 搭配使用；只指定宽度时，高度按原视频比例自动计算。
		与 -缩放率 互斥。

	.PARAMETER 高度
		目标 GIF 高度（像素）。可与 -宽度 搭配使用；只指定高度时，宽度按原视频比例自动计算。
		与 -缩放率 互斥。

	.PARAMETER 缩放率
		按原视频宽高比整体缩放的倍率，任意正数，默认 1（不缩放）；如 0.5 表示缩小为一半、
		2 表示放大为两倍。与 -宽度/-高度 互斥。

	.PARAMETER 帧率
		GIF 帧率（每秒帧数），浮点数。0 表示保持原始帧率（默认）；调低可显著减小体积，常用 10~15；
		指定高于原视频的帧率时会自动插帧补顺。分数写法请用括号表达式传入，如 -帧率 (23.57/5.8)，
		PowerShell 会先求值再传入。

	.EXAMPLE
		转GIF -输入文件 'D:\头像.mp4'

		按原始分辨率和帧率转换为 D:\头像.gif。

	.EXAMPLE
		转GIF -输入文件 'D:\头像.mp4' -宽度 320 -帧率 15

		宽度固定 320（高度按比例）并以 15fps 输出，是控制体积的常见用法。

	.EXAMPLE
		转GIF -输入文件 'D:\头像.mp4' -宽度 300 -高度 300

		缩放到 300x300；宽高比与原视频不同时画面会按目标尺寸拉伸。

	.EXAMPLE
		转GIF -输入文件 'D:\片段.mkv' -缩放率 0.5 -输出文件 'D:\表情.gif'

		按原视频比例缩小到一半，并指定输出路径。

	.EXAMPLE
		转GIF -输入文件 'D:\片段.mkv' -缩放率 2

		按原视频比例放大为两倍分辨率。

	.NOTES
		依赖 ffmpeg 和 ffprobe；缺失时命令会尝试自动安装。
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0, HelpMessage = '要转换的视频文件路径')]
		[string]$输入文件,

		[Parameter(Position = 1)]
		[string]$输出文件,

		[ValidateRange(0, 10000)]
		[int]$宽度 = 0,

		[ValidateRange(0, 10000)]
		[int]$高度 = 0,

		[ValidateScript({ if ($_ -gt 0) { $true } else { throw '-缩放率 必须是正数（1 不缩放，小于 1 缩小，大于 1 放大）' } })]
		[double]$缩放率 = 1,

		[ValidateRange(0.0, 1000.0)]
		[double]$帧率 = 0
	)

	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'
	$script:输出外部进程信息 = $false

	$输入文件 = 规范化_用户路径参数 -Path $输入文件
	if ($输出文件) { $输出文件 = 规范化_用户路径参数 -Path $输出文件 }

	确保_ffmpeg_ffprobe_可用

	if (-not (Test-Path -LiteralPath $输入文件)) { throw "文件不存在: $输入文件" }
	$输入绝对路径 = (Resolve-Path -LiteralPath $输入文件).Path

	# ── 探测输入 ─────────────────────────────────────────────────
	$媒体信息 = 获取_媒体信息 -Path $输入绝对路径
	if (-not $媒体信息.Video) { throw "输入文件没有视频轨: $输入文件" }

	$源宽   = $媒体信息.Video.Width
	$源高   = $媒体信息.Video.Height
	$源编码 = $媒体信息.Video.Codec
	$时长秒 = [double]$媒体信息.Duration
	if (-not $源宽 -or -not $源高 -or $源宽 -le 0 -or $源高 -le 0) { throw "无法获取输入视频的分辨率: $输入文件" }

	# ── 计算目标尺寸（宽度/高度 与 缩放率 互斥）────────────────
	$目标宽 = $源宽
	$目标高 = $源高

	$显式给了缩放率 = $PSBoundParameters.ContainsKey('缩放率')
	$显式给了宽高   = $PSBoundParameters.ContainsKey('宽度') -or $PSBoundParameters.ContainsKey('高度')
	if ($显式给了缩放率 -and $显式给了宽高) {
		throw '-缩放率 与 -宽度/-高度 不能同时指定：要么给出目标宽高（可只给一边，另一边按比例计算），要么给出缩放率。'
	}

	if ($显式给了缩放率) {
		if ($缩放率 -ne 1) {
			$目标宽 = [math]::Round($源宽 * $缩放率)
			$目标高 = [math]::Round($源高 * $缩放率)
		}
	} elseif ($宽度 -gt 0 -or $高度 -gt 0) {
		if ($宽度 -gt 0 -and $高度 -gt 0) {
			$目标宽 = $宽度
			$目标高 = $高度
		} elseif ($宽度 -gt 0) {
			$目标宽 = $宽度
			$目标高 = [math]::Round($源高 * ([double]$宽度 / $源宽))
		} else {
			$目标高 = $高度
			$目标宽 = [math]::Round($源宽 * ([double]$高度 / $源高))
		}
	}

	# ffmpeg scale 要求目标边长为偶数；取偶后误差不超过 1 像素
	$目标宽 = [math]::Max(2, [int]($目标宽 / 2) * 2)
	$目标高 = [math]::Max(2, [int]($目标高 / 2) * 2)

	# ── 默认输出路径 ─────────────────────────────────────────────
	if (-not $输出文件) {
		$目录   = [System.IO.Path]::GetDirectoryName($输入绝对路径)
		$基础名 = [System.IO.Path]::GetFileNameWithoutExtension($输入绝对路径)
		$输出文件 = Join-Path $目录 "${基础名}.gif"
	}
	$输出绝对路径 = [System.IO.Path]::GetFullPath($输出文件)
	if ($输出绝对路径 -ieq $输入绝对路径) { throw '输出文件不能与输入文件相同，请换一个输出路径。' }

	$ffmpeg路径 = 解决_工具执行路径 -工具名 'ffmpeg'

	# ── 组装滤镜链（两遍使用同一链，保证调色板与画面一致）────────
	# ffmpeg fps 滤镜要求小数点为英文句点；用 InvariantCulture 格式化，避免区域设置影响
	$帧率文本 = $帧率.ToString('0.######', [System.Globalization.CultureInfo]::InvariantCulture)

	$滤镜片段 = @()
	if ($帧率 -gt 0) { $滤镜片段 += "fps=$帧率文本" }
	if ($目标宽 -ne $源宽 -or $目标高 -ne $源高) { $滤镜片段 += ("scale={0}:{1}:flags=lanczos" -f $目标宽, $目标高) }
	$滤镜链 = $滤镜片段 -join ','

	$pass1滤镜 = if ($滤镜链) { "$滤镜链,palettegen=stats_mode=diff" } else { 'palettegen=stats_mode=diff' }
	$pass2滤镜 = if ($滤镜链) { ("[0:v]{0}[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=5" -f $滤镜链) } else { '[0:v][1:v]paletteuse=dither=bayer:bayer_scale=5' }

	# ── 打印摘要 ────────────────────────────────────────────────
	Write-Host ''
	Write-Host '视频转 GIF（两遍调色板流程）' -ForegroundColor Cyan
	Write-Host ("  输入     : {0}" -f $输入绝对路径)
	Write-Host ("  视频轨   : {0}  {1}x{2}  时长 {3}s" -f $源编码, $源宽, $源高, ([math]::Round($时长秒, 1)))
	if ($目标宽 -ne $源宽 -or $目标高 -ne $源高) { Write-Host ("  目标尺寸 : {0}x{1}" -f $目标宽, $目标高) }
	if ($帧率 -gt 0) { Write-Host ("  帧率     : {0} fps" -f $帧率文本) }
	Write-Host ("  输出     : {0}" -f $输出绝对路径)
	Write-Host ''

	# 调色板临时目录（Pass 1/2 共用），结束后清理
	$临时目录   = Join-Path ([System.IO.Path]::GetTempPath()) ("视频工坊GIF_" + [Guid]::NewGuid().ToString('N'))
	$调色板文件 = Join-Path $临时目录 'palette.png'
	New-Item -ItemType Directory -Path $临时目录 -Force | Out-Null

	try {
		# Pass 1：全片分析生成调色板
		Write-Host 'Pass 1 / 2 分析调色板...' -ForegroundColor DarkYellow
		$pass1参数 = @('-hide_banner', '-nostdin', '-y', '-i', $输入绝对路径, '-vf', $pass1滤镜, '-frames:v', '1', '-update', '1', $调色板文件)

		$旧错误偏好 = $ErrorActionPreference
		$ErrorActionPreference = 'SilentlyContinue'
		& $ffmpeg路径 @pass1参数
		$退出码 = $LASTEXITCODE
		$ErrorActionPreference = $旧错误偏好
		if ($退出码 -ne 0) { throw "转 GIF 失败：Pass 1 调色板分析出错（退出码 $退出码）" }
		if (-not (Test-Path -LiteralPath $调色板文件)) { throw '转 GIF 失败：Pass 1 未生成调色板文件。' }

		# Pass 2：用调色板量化输出 GIF
		Write-Host 'Pass 2 / 2 生成 GIF...' -ForegroundColor DarkYellow
		$pass2参数 = @('-hide_banner', '-nostdin', '-y', '-i', $输入绝对路径, '-i', $调色板文件, '-lavfi', $pass2滤镜, '-loop', '0', $输出绝对路径)

		$ErrorActionPreference = 'SilentlyContinue'
		& $ffmpeg路径 @pass2参数
		$退出码 = $LASTEXITCODE
		$ErrorActionPreference = $旧错误偏好
		if ($退出码 -ne 0) { throw "转 GIF 失败：Pass 2 生成出错（退出码 $退出码）" }
	} finally {
		Remove-Item -LiteralPath $临时目录 -Recurse -Force -ErrorAction SilentlyContinue
	}

	# ── 完成，报告输出 ──────────────────────────────────────────
	$实际字节 = (Get-Item -LiteralPath $输出绝对路径).Length
	Write-Host ''
	Write-Host '转换完成' -ForegroundColor Green
	Write-Host ("  输出文件 : {0}" -f $输出绝对路径)
	Write-Host ("  大小     : {0}" -f (格式化_字节到文本 $实际字节))
}
