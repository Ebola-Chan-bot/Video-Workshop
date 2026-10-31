function 反转视频 {
	<#
	.SYNOPSIS
		把视频文件的所有音视频轨按时间轴反转（倒放），其它轨道原样保留。

	.DESCRIPTION
		使用 ffmpeg 的 reverse（视频）和 areverse（音频）滤镜，把输入文件中每一条视频轨和
		音频轨整体倒放。输出视频的分辨率、帧率与原视频保持完全一致。

		反转必须重编码，因此采用与"压缩到指定大小"一致的二次编码方案：Pass 1 全片倒放预分析，
		Pass 2 按原视频实际码率正式编码，使输出体积与原文件接近。编码器选择参照"超级合并"策略：
		目标编码统一 HEVC，优先 GPU（h264/hevc 的 NVENC → QSV → AMF），无可用 GPU 时回退 CPU libx265。
		音频统一重编码为 AAC，每轨目标码率取自该轨原码率。

		注：NVENC/libx265 支持二次编码；QSV/AMF 仅支持单遍码率控制，会回退到单遍编码并提示。

		字幕、附件等其它类型轨道无法时间反转，命令会发出警告并将其原样复制进输出；
		这些轨道的时间轴不会随画面倒转，播放时可能与画面对不上。

		未指定输出路径时，在输入文件同目录生成"原文件名_反转+原扩展名"；若原扩展名容器装不下
		原样复制的字幕等轨道，会自动改用 .mkv 并提示。输出文件已存在时会被覆盖。

	.PARAMETER 输入文件
		要反转的视频文件路径，必须存在且至少包含一个视频轨。

	.PARAMETER 输出文件
		输出文件路径。省略时在输入文件同目录生成"原文件名_反转+原扩展名"。

	.EXAMPLE
		反转视频 -输入文件 'D:\片段.mp4'

		将 D:\片段.mp4 倒放为 D:\片段_反转.mp4，分辨率帧率不变，体积与原文件接近。

	.EXAMPLE
		反转视频 -输入文件 'D:\片段.mkv' -输出文件 'D:\倒放.mkv'

		倒放并指定输出路径。

	.NOTES
		依赖 ffmpeg 和 ffprobe；缺失时命令会尝试自动安装。
		reverse/areverse 会把整条轨道缓存在内存里倒排，且 NVENC/libx265 路径需要完整解码两遍
		（Pass 1/2），长视频内存占用和耗时都明显高于普通转码。
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0, HelpMessage = '要反转的视频文件路径')]
		[string]$输入文件,

		[Parameter(Position = 1)]
		[string]$输出文件
	)

	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'
	$script:输出外部进程信息 = $false

	$输入文件 = 规范化_用户路径参数 -Path $输入文件
	if ($输出文件) { $输出文件 = 规范化_用户路径参数 -Path $输出文件 }

	确保_ffmpeg_ffprobe_可用

	if (-not (Test-Path -LiteralPath $输入文件)) { throw "文件不存在: $输入文件" }
	$输入绝对路径 = (Resolve-Path -LiteralPath $输入文件).Path

	# ── 探测轨道 ─────────────────────────────────────────────────
	$探测结果 = 获取_媒体流探测数据 -Path $输入绝对路径
	$全部轨道 = @($探测结果.streams)
	if ($全部轨道.Count -eq 0) { throw "输入文件没有任何媒体轨: $输入文件" }

	$视频轨列表 = @($全部轨道 | Where-Object { $_.codec_type -eq 'video' })
	$音频轨列表 = @($全部轨道 | Where-Object { $_.codec_type -eq 'audio' })
	$其它轨列表 = @($全部轨道 | Where-Object { $_.codec_type -notin @('video', 'audio') })

	if ($视频轨列表.Count -eq 0) { throw "输入文件没有视频轨: $输入文件" }
	$视频序号列表 = @($视频轨列表 | ForEach-Object { [int]$_.index })
	$音频序号列表 = @($音频轨列表 | ForEach-Object { [int]$_.index })

	# 源视频帧率（分数形式，如 5820/241）：reverse 后容器重算平均帧率会漂移，
	# 用 fps=<原分数> 滤镜锁定，保证输出帧率与原视频严格一致。
	$源帧率表达式 = [string](取_对象属性值 -Obj $视频轨列表[0] -Name 'avg_frame_rate')
	if ([string]::IsNullOrWhiteSpace($源帧率表达式) -or $源帧率表达式 -eq '0/0') {
		$源帧率表达式 = [string](取_对象属性值 -Obj $视频轨列表[0] -Name 'r_frame_rate')
	}

	if ($视频轨列表.Count -gt 1) {
		Write-Warning ("检测到 {0} 条视频轨：二次编码的码率预算按第一条视频轨计算，所有视频轨共用该码率。" -f $视频轨列表.Count)
	}
	if ($其它轨列表.Count -gt 0) {
		$类型汇总 = ($其它轨列表 | Group-Object codec_type | ForEach-Object { "{0}×{1}" -f $_.Name, $_.Count }) -join '、'
		Write-Warning ("检测到 {0} 条非音视频轨道（{1}）无法时间反转，将原样复制进输出；其时间轴不会随画面倒转，可能与画面对不上。" -f $其它轨列表.Count, $类型汇总)
	}

	# ── 时长 ─────────────────────────────────────────────────────
	$时长秒 = [double](获取_媒体信息 -Path $输入绝对路径).Duration
	if ($时长秒 -le 0) { throw "无法从输入文件获取时长: $输入文件" }

	# ── 逐包统计各轨字节数，用于目标码率 ────────────────────────
	$所有序号 = @($全部轨道 | ForEach-Object { [int]$_.index })
	$包字节表 = @{}
	try {
		$包字节表 = 取_按流序号统计包字节数 -Path $输入绝对路径 -StreamIndices $所有序号
	} catch {
		$global:LASTEXITCODE = 0
	}

	# 单轨目标码率：优先“该轨实际字节数×8÷时长”，失败回退探测声明值，最后兜底并钳制范围
	$视频目标bps列表 = @()
	foreach ($轨 in $视频轨列表) {
		$idx = [int]$轨.index
		$bps = $null
		if ($包字节表.ContainsKey($idx) -and [int64]$包字节表[$idx] -gt 0) {
			$bps = [int64]([math]::Round([int64]$包字节表[$idx] * 8.0 / $时长秒))
		}
		if (-not $bps -or $bps -le 0) { $bps = 解析_整数或空 ([string](取_对象属性值 -Obj $轨 -Name 'bit_rate')) }
		if (-not $bps -or $bps -le 0) { $bps = [int64]2000000 }
		if ($bps -lt [int64]100000) { $bps = [int64]100000 }
		if ($bps -gt [int64]200000000) { $bps = [int64]200000000 }
		$视频目标bps列表 += $bps
	}

	# ── 逐轨目标音频编码：与超级合并一致，无损源保持无损，有损源转 AAC ──
	$目标音频编码列表 = @()
	foreach ($轨 in $音频轨列表) {
		$源音频编码 = ([string](取_对象属性值 -Obj $轨 -Name 'codec_name')).ToLowerInvariant()
		if (测试_音频编码是否无损 -Codec $源音频编码) {
			if ($源音频编码 -in @('flac', 'alac')) { $目标音频编码列表 += $源音频编码 }
			else { $目标音频编码列表 += 'flac' }
		} else {
			$目标音频编码列表 += 'aac'
		}
	}

	$音频目标bps列表 = @()
	foreach ($轨 in $音频轨列表) {
		$idx = [int]$轨.index
		$bps = $null
		if ($包字节表.ContainsKey($idx) -and [int64]$包字节表[$idx] -gt 0) {
			$bps = [int64]([math]::Round([int64]$包字节表[$idx] * 8.0 / $时长秒))
		}
		if (-not $bps -or $bps -le 0) { $bps = 解析_整数或空 ([string](取_对象属性值 -Obj $轨 -Name 'bit_rate')) }
		if (-not $bps -or $bps -le 0) { $bps = [int64]128000 }
		if ($bps -lt [int64]64000) { $bps = [int64]64000 }
		if ($bps -gt [int64]512000) { $bps = [int64]512000 }
		$音频目标bps列表 += $bps
	}
	$视频目标bps = [int64]$视频目标bps列表[0]
	$视频目标kbps = [int64]([math]::Floor($视频目标bps / 1000.0))

	# ── 选择编码器：与超级合并一致，目标编码一律 HEVC，GPU 优先回退 CPU ──
	$ffmpeg路径 = 解决_工具执行路径 -工具名 'ffmpeg'
	$源编码 = [string]$视频轨列表[0].codec_name
	$编码器 = [string](选择_视频编码器 -目标视频编码 'hevc').Encoder
	$支持二次编码 = ($编码器 -like '*_nvenc') -or ($编码器 -eq 'libx265')
	if (-not $支持二次编码) {
		Write-Warning ("编码器 {0} 不支持二次编码，将改用单遍码率控制；输出体积可能与原文件偏差稍大。" -f $编码器)
	}

	# ── 输出路径 ─────────────────────────────────────────────────
	if (-not $输出文件) {
		$目录   = [System.IO.Path]::GetDirectoryName($输入绝对路径)
		$基础名 = [System.IO.Path]::GetFileNameWithoutExtension($输入绝对路径)
		$扩展名 = [System.IO.Path]::GetExtension($输入绝对路径)
		if ([string]::IsNullOrWhiteSpace($扩展名)) { $扩展名 = '.mkv' }
		$输出文件 = Join-Path $目录 ("${基础名}_反转${扩展名}")
	}
	$输出绝对路径 = [System.IO.Path]::GetFullPath($输出文件)
	if ($输出绝对路径 -ieq $输入绝对路径) { throw '输出文件不能与输入文件相同，请换一个输出路径。' }

	# 原样复制的轨道（尤其字幕）与重编码的音频必须能被输出容器容纳，否则改用 MKV
	$输出扩展名 = [System.IO.Path]::GetExtension($输出绝对路径).ToLowerInvariant()
	if ($输出扩展名 -ne '.mkv') {
		$需要换容器 = $false
		foreach ($轨 in $其它轨列表) {
			if ([string]$轨.codec_type -eq 'subtitle') {
				if (-not (测试_容器是否支持_字幕编码 -容器扩展名 $输出扩展名 -字幕编码 ([string]$轨.codec_name))) { $需要换容器 = $true }
			}
		}
		foreach ($编 in ($目标音频编码列表 | Select-Object -Unique)) {
			if (-not (测试_容器是否支持_音频编码 -容器扩展名 $输出扩展名 -音频编码 $编)) { $需要换容器 = $true }
		}
		if ($需要换容器) {
			$输出绝对路径 = [System.IO.Path]::ChangeExtension($输出绝对路径, '.mkv')
			Write-Warning ("原样复制的轨道与容器 {0} 不兼容，输出容器已改为 .mkv：{1}" -f $输出扩展名, $输出绝对路径)
		}
	}

	# ── 组装滤镜链 ───────────────────────────────────────────────
	$视频翻转片段 = @()
	for ($i = 0; $i -lt $视频序号列表.Count; $i++) {
		$片段 = ("[0:{0}]reverse" -f $视频序号列表[$i])
		if ($源帧率表达式) { $片段 += ",fps=$源帧率表达式" }
		$视频翻转片段 += "$片段[v$i]"
	}
	$音频翻转片段 = @()
	for ($j = 0; $j -lt $音频序号列表.Count; $j++) {
		$音频翻转片段 += ("[0:{0}]areverse[a{1}]" -f $音频序号列表[$j], $j)
	}
	$pass1滤镜 = $视频翻转片段 -join ';'
	$pass2滤镜 = @($视频翻转片段 + $音频翻转片段) -join ';'

	# ── 二次编码统计日志临时目录（Pass 1/2 共用），结束后清理 ────
	$临时目录    = Join-Path ([System.IO.Path]::GetTempPath()) ("视频工坊反转_" + [Guid]::NewGuid().ToString('N'))
	$passlog前缀 = Join-Path $临时目录 'ffmpeg2pass'
	$x265统计文件 = Join-Path $临时目录 'x265_stats.log'
	New-Item -ItemType Directory -Path $临时目录 -Force | Out-Null

	# ── 打印摘要 ─────────────────────────────────────────────────
	Write-Host ''
	Write-Host '视频反转（二次编码 / 时间倒放）' -ForegroundColor Cyan
	Write-Host ("  输入         : {0}" -f $输入绝对路径)
	Write-Host ("  视频轨       : {0} 条，全部 reverse（目标码率 {1} kbps）" -f $视频轨列表.Count, ([math]::Round($视频目标bps / 1000.0, 1)))
	Write-Host ("  音频轨       : {0} 条，全部 areverse（{1}）" -f $音频轨列表.Count, (($目标音频编码列表 | Select-Object -Unique) -join '/'))
	if ($其它轨列表.Count -gt 0) { Write-Host ("  其它轨道     : {0} 条，原样复制（不参与反转）" -f $其它轨列表.Count) }
	Write-Host ("  源编码       : {0} → HEVC" -f $源编码)
	Write-Host ("  编码器       : {0}{1}" -f $编码器, $(if ($编码器 -like '*_nvenc') { '（NVIDIA GPU）' } elseif ($编码器 -like '*_qsv') { '（Intel QSV）' } elseif ($编码器 -like '*_amf') { '（AMD GPU）' } else { '（CPU）' }))
	Write-Host ("  时长         : {0}s" -f ([math]::Round($时长秒, 1)))
	Write-Host ("  输出         : {0}" -f $输出绝对路径)
	Write-Host ''

	# ── 组装视频编码参数（NVENC/libx265 两遍；QSV/AMF 仅单遍码率控制）──
	if ($编码器 -like '*_nvenc') {
		$视频公共参数 = @(
			'-c:v', $编码器,
			'-preset', 'p4',
			'-tune', 'hq',
			'-rc', 'vbr',
			'-b:v', "$视频目标bps",
			'-maxrate', "$视频目标bps",
			'-bufsize', "$($视频目标bps * 2)",
			'-passlogfile', $passlog前缀
		)
		$pass1视频参数 = $视频公共参数 + @('-pass', '1')
		$pass2视频参数 = $视频公共参数 + @('-pass', '2')
	} elseif ($编码器 -eq 'libx265') {
		$视频公共参数 = @(
			'-c:v', 'libx265',
			'-preset', 'medium',
			'-b:v', "$视频目标bps"
		)
		$pass1视频参数 = $视频公共参数 + @('-x265-params', ("pass=1:bitrate={0}:stats={1}" -f $视频目标kbps, $x265统计文件))
		$pass2视频参数 = $视频公共参数 + @('-x265-params', ("pass=2:bitrate={0}:stats={1}" -f $视频目标kbps, $x265统计文件))
	} else {
		# QSV/AMF：不支持二次编码，单遍码率约束（与超级合并一致：-b:v/-maxrate/-bufsize）
		$视频公共参数 = @()
		if ($编码器 -like '*_qsv') { $视频公共参数 += @('-c:v', $编码器, '-global_quality', '23') }
		elseif ($编码器 -like '*_amf') { $视频公共参数 += @('-c:v', $编码器, '-rc', 'cqp', '-qp_i', '23', '-qp_p', '23', '-qp_b', '23') }
		$视频公共参数 += @(
			'-b:v', "$视频目标bps",
			'-maxrate', "$视频目标bps",
			'-bufsize', "$($视频目标bps * 2)"
		)
		$pass1视频参数 = @()
		$pass2视频参数 = $视频公共参数
	}

	# Pass 1：只倒放视频预分析，音频字幕一律跳过（仅二次编码时需要）
	$pass1映射 = @()
	for ($i = 0; $i -lt $视频序号列表.Count; $i++) { $pass1映射 += @('-map', "[v$i]") }
	$pass1参数 = @('-hide_banner', '-nostdin', '-y', '-i', $输入绝对路径, '-filter_complex', $pass1滤镜) +
		$pass1映射 + $pass1视频参数 + @('-an', '-sn', '-dn', '-f', 'null', 'NUL')

	# Pass 2：倒放视频 + 倒放音频（AAC），其余轨道原样复制
	$pass2映射 = @()
	for ($i = 0; $i -lt $视频序号列表.Count; $i++) { $pass2映射 += @('-map', "[v$i]") }
	for ($j = 0; $j -lt $音频序号列表.Count; $j++) { $pass2映射 += @('-map', "[a$j]") }
	foreach ($轨 in $其它轨列表) { $pass2映射 += @('-map', ("0:{0}" -f ([int]$轨.index))) }

	$音频编码参数 = @()
	for ($j = 0; $j -lt $音频序号列表.Count; $j++) {
		$目标音频编码 = $目标音频编码列表[$j]
		$音频编码参数 += @("-c:a:$j", $目标音频编码)
		# FLAC/ALAC 为无损编码，码率参数无效，只给 AAC 轨设目标码率
		if ($目标音频编码 -eq 'aac') {
			$音频编码参数 += @("-b:a:$j", "$($音频目标bps列表[$j])")
		}
	}

	$pass2参数 = @('-hide_banner', '-nostdin', '-y', '-i', $输入绝对路径, '-filter_complex', $pass2滤镜) +
		$pass2映射 + $pass2视频参数 + $音频编码参数 +
		@('-c:s', 'copy', '-c:d', 'copy', $输出绝对路径)

	try {
		# Pass 1：预分析（reverse 滤镜会把整条视频轨缓冲到内存倒排；QSV/AMF 无此遍）
		$旧错误偏好 = $ErrorActionPreference
		if ($支持二次编码) {
			Write-Host 'Pass 1 / 2 倒放预分析中...' -ForegroundColor DarkYellow
			$ErrorActionPreference = 'SilentlyContinue'
			& $ffmpeg路径 @pass1参数
			$退出码 = $LASTEXITCODE
			$ErrorActionPreference = $旧错误偏好
			if ($退出码 -ne 0) { throw "反转失败：Pass 1 预分析出错（退出码 $退出码）" }
		}

		# Pass 2：正式编码输出（libx265 会在当前目录写临时分块文件，切换到临时目录避免污染）
		Write-Host $(if ($支持二次编码) { 'Pass 2 / 2 倒放编码中...' } else { '单遍倒放编码中...' }) -ForegroundColor DarkYellow
		if ($编码器 -eq 'libx265') {
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
		} else {
			$ErrorActionPreference = 'SilentlyContinue'
			& $ffmpeg路径 @pass2参数
			$退出码 = $LASTEXITCODE
			$ErrorActionPreference = $旧错误偏好
		}
		if ($退出码 -ne 0) { throw "反转失败：Pass 2 编码出错（退出码 $退出码）" }
	} finally {
		Remove-Item -LiteralPath $临时目录 -Recurse -Force -ErrorAction SilentlyContinue
	}

	# ── 完成，报告输出体积与原文件的接近程度 ────────────────────
	$原字节 = (Get-Item -LiteralPath $输入绝对路径).Length
	$实际字节 = (Get-Item -LiteralPath $输出绝对路径).Length
	$达成比例 = [math]::Round($实际字节 * 100.0 / $原字节, 1)

	Write-Host ''
	Write-Host '反转完成' -ForegroundColor Green
	Write-Host ("  输出文件 : {0}" -f $输出绝对路径)
	Write-Host ("  实际大小 : {0}（原文件 {1}，为原大小的 {2}%）" -f (格式化_字节到文本 $实际字节), (格式化_字节到文本 $原字节), $达成比例)
}
