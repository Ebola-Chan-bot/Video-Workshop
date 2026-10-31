function 压缩到指定大小 {
	<#
	.SYNOPSIS
		将视频文件重编码到指定大小，视频轨统一转为 HEVC，其余轨道原样保留。

	.DESCRIPTION
		采用二次编码（two-pass）方法压缩视频：先全片预分析一遍（Pass 1），再按计算出的目标码率正式编码（Pass 2），使输出文件体积尽量贴近指定的目标大小。只重编码第一个视频轨；音频、字幕、附件等其它轨道全部以流复制方式原样搬进输出，不做任何改动。
		HEVC 编码器优先使用 NVIDIA 显卡的 hevc_nvenc；本机没有可用的 NVENC 时回退到 CPU libx265。输出容器固定为 MKV，保证任意轨道都能顺利复用。输出文件已存在时会被覆盖。
		码率预算 = (目标大小 - 容器预留富余 - 非视频轨字节数) × 8 ÷ 时长，其中非视频轨字节数通过 ffprobe 逐包统计，保证预算准确。

	.PARAMETER 输入文件
		要压缩的视频文件路径，必须存在且至少包含一个视频轨。

	.PARAMETER 输出文件
		输出文件路径。省略时在输入文件同目录生成"原文件名_压缩.mkv"。

	.PARAMETER 目标大小
		期望的输出文件大小，支持 700MB、1.5G、512000KB、104857600 等写法。输出会略小于该值。

	.EXAMPLE
		压缩到指定大小 -输入文件 'D:\电影.mkv' -目标大小 700MB

		将 D:\电影.mkv 压缩为 D:\电影_压缩.mkv，目标体积 700MB，视频轨转为 HEVC。

	.EXAMPLE
		压缩到指定大小 -输入文件 'D:\电影.mkv' -输出文件 'D:\out.mkv' -目标大小 2G

		压缩到 2GB 并指定输出路径。

	.NOTES
		依赖 ffmpeg 和 ffprobe。无 NVIDIA NVENC 时使用 libx265 CPU 编码，速度会明显变慢。
		视频轨已经是 HEVC 时也会重新编码，以便达到目标大小。
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0, HelpMessage = '要压缩的视频文件路径')]
		[string]$输入文件,

		[Parameter(Position = 1)]
		[string]$输出文件,

		[Parameter(Mandatory, Position = 2, HelpMessage = '目标文件大小，如 700MB、1.5G')]
		[string]$目标大小
	)

	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'
	$script:输出外部进程信息 = $false

	$输入文件 = 规范化_用户路径参数 -Path $输入文件
	if ($输出文件) { $输出文件 = 规范化_用户路径参数 -Path $输出文件 }
	$目标大小 = 规范化_用户路径参数 -Path $目标大小

	确保_ffmpeg_ffprobe_可用

	if (-not (Test-Path -LiteralPath $输入文件)) { throw "文件不存在: $输入文件" }
	$输入绝对路径 = (Resolve-Path -LiteralPath $输入文件).Path

	# ── 解析目标大小 ──────────────────────────────────────────────
	$目标字节 = 解析_大小文本到字节 -文本 $目标大小
	if ($目标字节 -lt 1MB) { throw '目标大小过小（最小限制 1MB），请重新指定。' }

	# ── 探测输入 ──────────────────────────────────────────────────
	$探测结果 = 获取_媒体流探测数据 -Path $输入绝对路径
	$全部轨道 = @($探测结果.streams)

	$视频轨列表 = @($全部轨道 | Where-Object { $_.codec_type -eq 'video' })
	if ($视频轨列表.Count -eq 0) { throw "输入文件没有视频轨: $输入文件" }

	$视频轨     = $视频轨列表[0]
	$视频序号   = [int]$视频轨.index
	$视频宽     = [int]$视频轨.width
	$视频高     = [int]$视频轨.height
	$源视频编码 = [string]$视频轨.codec_name

	# 时长：优先用视频轨自带 duration，其次用 format.duration
	$时长秒 = 0.0
	$轨时长属性 = 取_对象属性值 -Obj $视频轨 -Name 'duration'
	if ($轨时长属性) {
		try { $时长秒 = [double]$轨时长属性 } catch { $时长秒 = 0.0 }
	}
	if ($时长秒 -le 0) {
		$时长秒 = [double](获取_媒体信息 -Path $输入绝对路径).Duration
	}
	if ($时长秒 -le 0) { throw "无法从输入文件获取时长: $输入文件" }

	# 统计非视频轨（音频+字幕+附件等）的总字节数，用于码率预算
	$非视频轨序号 = @($全部轨道 | Where-Object { $_.codec_type -ne 'video' } | ForEach-Object { [int]$_.index })
	$非视频轨字节 = [int64]0
	if ($非视频轨序号.Count -gt 0) {
		$包统计 = 取_按流序号统计包字节数 -Path $输入绝对路径 -StreamIndices $非视频轨序号
		foreach ($序 in $非视频轨序号) {
			if ($包统计.ContainsKey($序)) { $非视频轨字节 += [int64]$包统计[$序] }
		}
	}

	# ── 选择 HEVC 编码器：NVIDIA hevc_nvenc 优先，无则 CPU libx265 ──
	$ffmpeg路径 = 解决_工具执行路径 -工具名 'ffmpeg'
	if (测试_ffmpeg视频编码器可用 -FfmpegPath $ffmpeg路径 -编码器名称 'hevc_nvenc') {
		$使用gpu  = $true
		$编码器名 = 'hevc_nvenc'
	} else {
		$使用gpu  = $false
		$编码器名 = 'libx265'
	}

	# ── 计算视频目标码率 ─────────────────────────────────────────
	$容器富余字节 = [int64]131072   # MKV 头/SeekHead/元数据等预留
	$可用视频字节 = $目标字节 - $非视频轨字节 - $容器富余字节
	if ($可用视频字节 -le 0) {
		throw ("目标大小 {0} 过小：仅非视频轨就占 {1}，装不下任何视频码率。" -f
			(格式化_字节到文本 $目标字节), (格式化_字节到文本 $非视频轨字节))
	}

	$视频目标bps = [int64]([math]::Floor(($可用视频字节 * 8.0) / $时长秒))
	if ($视频目标bps -lt [int64]32000) { $视频目标bps = [int64]32000 }   # 保底 32kbps
	$视频目标kbps = [int64]([math]::Floor($视频目标bps / 1000.0))

	# ── 默认输出路径 ─────────────────────────────────────────────
	if (-not $输出文件) {
		$目录   = [System.IO.Path]::GetDirectoryName($输入绝对路径)
		$基础名 = [System.IO.Path]::GetFileNameWithoutExtension($输入绝对路径)
		$输出文件 = Join-Path $目录 "${基础名}_压缩.mkv"
	}
	$输出绝对路径 = [System.IO.Path]::GetFullPath($输出文件)
	if ($输出绝对路径 -ieq $输入绝对路径) { throw '输出文件不能与输入文件相同，请换一个输出路径。' }

	# 二次编码统计日志统一放临时目录（Pass 1/2 共用），结束后清理
	$临时目录    = Join-Path ([System.IO.Path]::GetTempPath()) ("视频工坊压缩_" + [Guid]::NewGuid().ToString('N'))
	$passlog前缀 = Join-Path $临时目录 'ffmpeg2pass'
	New-Item -ItemType Directory -Path $临时目录 -Force | Out-Null

	# ── 打印摘要 ─────────────────────────────────────────────────
	Write-Host ''
	Write-Host '压缩到指定大小（二次编码 / HEVC）' -ForegroundColor Cyan
	Write-Host ("  输入         : {0}" -f $输入绝对路径)
	Write-Host ("  视频轨 #{0}  : {1}  {2}x{3}  时长 {4}s" -f $视频序号, $源视频编码, $视频宽, $视频高, ([math]::Round($时长秒, 1)))
	Write-Host ("  其它轨道     : {0} 条，全部原样复制（共 {1}）" -f $非视频轨序号.Count, (格式化_字节到文本 $非视频轨字节))
	if ($使用gpu) {
		Write-Host ("  编码器       : {0}（NVIDIA GPU）" -f $编码器名)
	} else {
		Write-Host ("  编码器       : {0}（CPU，未检测到 NVIDIA NVENC）" -f $编码器名)
	}
	Write-Host ("  视频目标码率 : {0} kbps" -f ([math]::Round($视频目标bps / 1000.0, 1)))
	Write-Host ("  目标大小     : {0}（{1}）" -f $目标大小, (格式化_字节到文本 $目标字节))
	Write-Host ("  输出         : {0}" -f $输出绝对路径)
	Write-Host ''

	# ── 组装两遍编码参数 ─────────────────────────────────────────
	if ($使用gpu) {
		$视频公共参数 = @(
			'-c:v', 'hevc_nvenc',
			'-preset', 'p4',
			'-tune', 'hq',
			'-b:v', "$视频目标bps",
			'-maxrate', "$视频目标bps",
			'-bufsize', "$($视频目标bps * 2)",
			'-passlogfile', $passlog前缀
		)
		$pass1参数 = @('-hide_banner', '-nostdin', '-y', '-i', $输入绝对路径) + $视频公共参数 +
			@('-pass', '1', '-map', '0:v:0', '-an', '-sn', '-dn', '-f', 'null', 'NUL')
		$pass2视频参数 = $视频公共参数 + @('-pass', '2')
	} else {
		$x265统计文件 = Join-Path $临时目录 'x265_stats.log'
		$视频公共参数 = @(
			'-c:v', 'libx265',
			'-preset', 'medium',
			'-b:v', "$视频目标bps"
		)
		$pass1参数 = @('-hide_banner', '-nostdin', '-y', '-i', $输入绝对路径) + $视频公共参数 +
			@('-x265-params', ("pass=1:bitrate={0}:stats={1}" -f $视频目标kbps, $x265统计文件),
			  '-map', '0:v:0', '-an', '-sn', '-dn', '-f', 'null', 'NUL')
		$pass2视频参数 = $视频公共参数 +
			@('-x265-params', ("pass=2:bitrate={0}:stats={1}" -f $视频目标kbps, $x265统计文件))
	}

	$pass2参数 = @('-hide_banner', '-nostdin', '-y', '-i', $输入绝对路径) + $pass2视频参数 +
		@('-map', '0', '-c:a', 'copy', '-c:s', 'copy', '-c:d', 'copy', $输出绝对路径)

	try {
		# Pass 1：预分析
		Write-Host 'Pass 1 / 2 预分析中...' -ForegroundColor DarkYellow
		$旧错误偏好 = $ErrorActionPreference
		$ErrorActionPreference = 'SilentlyContinue'
		& $ffmpeg路径 @pass1参数
		$退出码 = $LASTEXITCODE
		$ErrorActionPreference = $旧错误偏好
		if ($退出码 -ne 0) { throw "压缩失败：Pass 1 预分析出错（退出码 $退出码）" }

		# Pass 2：正式编码输出（libx265 会在当前目录写临时分块文件，切换到临时目录避免污染）
		Write-Host 'Pass 2 / 2 正式编码中...' -ForegroundColor DarkYellow
		if ($使用gpu) {
			$ErrorActionPreference = 'SilentlyContinue'
			& $ffmpeg路径 @pass2参数
			$退出码 = $LASTEXITCODE
			$ErrorActionPreference = $旧错误偏好
		} else {
			$旧目录 = (Get-Location).Path
			try {
				Set-Location -LiteralPath $临时目录
				$ErrorActionPreference = 'SilentlyContinue'
				& $ffmpeg路径 @pass2参数
				$退出码 = $LASTEXITCODE
				$ErrorActionPreference = $旧错误偏好
			} finally {
				Set-Location -LiteralPath $旧目录
			}
		}
		if ($退出码 -ne 0) { throw "压缩失败：Pass 2 正式编码出错（退出码 $退出码）" }
	} finally {
		Remove-Item -LiteralPath $临时目录 -Recurse -Force -ErrorAction SilentlyContinue
	}

	# ── 完成，校验输出大小 ────────────────────────────────────────
	$实际字节 = (Get-Item -LiteralPath $输出绝对路径).Length
	$达成比例 = [math]::Round($实际字节 * 100.0 / $目标字节, 1)

	Write-Host ''
	Write-Host '压缩完成' -ForegroundColor Green
	Write-Host ("  输出文件 : {0}" -f $输出绝对路径)
	Write-Host ("  实际大小 : {0}（目标 {1}，达成 {2}%）" -f (格式化_字节到文本 $实际字节), (格式化_字节到文本 $目标字节), $达成比例)

	if ($实际字节 -gt $目标字节) {
		Write-Warning ("输出超出目标大小约 {0}，可尝试再降低目标大小后重试。" -f
			(格式化_字节到文本 ($实际字节 - $目标字节)))
	}
}
