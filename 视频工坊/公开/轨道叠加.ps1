function 轨道叠加 {
	<#
	.SYNOPSIS
		把所有输入文件的所有轨道叠加到同一个输出文件，轨道并行、不在时间轴上拼接、不做重编码。

	.DESCRIPTION
		读取一组输入文件，将每个输入的全部轨道（视频、音频、字幕、附件等）以流复制方式原样搬进同一个输出文件。与“超级合并”的按顺序首尾相接不同，轨道叠加是把各文件的轨道并列放在同一个容器里（多个视频轨/音频轨并存），时间轴互不影响，任何轨道都不重编码。

		输入可以是显式传入的一个或多个文件路径（-输入文件），也可以不传 -输入文件 而改从 -列表文件 或剪贴板读取路径列表（与 超级合并 相同规则）。列表支持一行一个路径、带引号路径和 ffmpeg concat 的 file '路径' 格式，空行和 # 注释会被忽略。

		命令会自动识别并还原 B站客户端缓存的混淆 m4s：这类文件在标准 MP4/M4S 头部填充了一段 ASCII '0'（0x30）字节，导致普通播放器无法识别。命令会定位真正的 ftyp box 并整体剥离前面的填充字节，生成干净的标准 MP4 副本后再参与叠加。

		输出容器固定使用 MKV（唯一能无差别容纳任意编码轨道的常见容器）。每个轨道会写入 title 元数据注明来源文件名，方便在播放器里区分同名类型（如两条音频轨）。若用户指定的输出扩展名不是 .mkv，命令会先写一个 .mkv 再改名为用户指定的文件名，并提示实际容器。

	.PARAMETER 输入文件
		一个或多个输入媒体文件路径。省略时使用 -列表文件（或剪贴板）。

	.PARAMETER 输出文件
		目标输出文件路径。默认值为 .\merged.mkv。不带扩展名时会补 .mkv。

	.PARAMETER 列表文件
		包含输入文件路径的 UTF-8 文本文件，仅在未显式传入 -输入文件 时生效。未显式传入且 -输入文件 为空时会从剪贴板读取路径列表。

	.PARAMETER 详细模式
		显示外部命令的详细输出，并保留临时工作目录以便排查混淆还原等中间文件。默认会清理临时目录。

	.EXAMPLE
		轨道叠加 'D:\视频.m4s' 'D:\音频.m4s' -输出文件 'D:\成片.mkv'

		把两个 m4s 的轨道叠加到同一个 mkv：一条视频轨和一条音频轨并行存在，均为流复制。

	.EXAMPLE
		轨道叠加 -输入文件 $files -输出文件 'D:\out.mkv' -详细模式

		显式传入文件数组叠加所有轨道，显示外部工具输出并保留临时目录。

	.EXAMPLE
		轨道叠加 -列表文件 'D:\列表.txt'

		按列表文件中的顺序读取所有输入，叠加到默认输出 .\merged.mkv。

	.NOTES
		依赖 ffmpeg 和 ffprobe；缺失时命令会尝试自动安装。
		多文件包含多条同类型轨道（如两条视频轨）时，播放器一般默认播放第一条；可在播放器中手动切换轨道。
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $false, Position = 0)]
		[string[]]$输入文件 = @(),

		[Parameter(Mandatory = $false, Position = 1)]
		[string]$输出文件 = '.\merged.mkv',

		[Parameter(Mandatory = $false)]
		[string]$列表文件 = '.\要合并的文件列表.txt',

		[switch]$详细模式
	)

	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'

	$script:输出外部进程信息 = [bool]$详细模式

	$工作目录 = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("视频工坊_stack_work_{0}" -f ([Guid]::NewGuid().ToString('N')))
	New-Item -ItemType Directory -Path $工作目录 -Force | Out-Null

	try {
		确保_ffmpeg_ffprobe_可用

		# -------- 收集输入列表 --------
		$输入文件列表 = @($输入文件 | ForEach-Object { 规范化_用户路径参数 -Path $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

		if ($输入文件列表.Count -eq 0) {
			# 与 超级合并 相同的回退规则：显式列表文件优先，否则读剪贴板
			$列表文件是否显式指定 = $PSBoundParameters.ContainsKey('列表文件')
			if ($列表文件是否显式指定) {
				if (-not (Test-Path -LiteralPath $列表文件)) { throw "未找到列表文件：$列表文件" }
				$列表文本 = Get-Content -LiteralPath $列表文件 -Encoding UTF8 -Raw
			} else {
				if (-not (Get-Command Get-Clipboard -ErrorAction SilentlyContinue)) {
					throw "未传入 -输入文件，且当前环境不支持 Get-Clipboard。请显式传入 -输入文件 或 -列表文件。"
				}
				$clip = Get-Clipboard -Raw
				if ([string]::IsNullOrWhiteSpace($clip)) {
					throw "未传入 -输入文件，但剪贴板为空（或无法读取）。请先在剪贴板中放入文件路径列表（每行一个），或显式传入 -输入文件。"
				}
				$列表文本 = $clip
			}

			$输入文件列表 = 解析_输入文件列表_来自文本 -Text $列表文本
			$输入文件列表 = @($输入文件列表 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
		}

		if ($输入文件列表.Count -lt 1) { throw "没有可用的输入文件。请通过 -输入文件、-列表文件 或剪贴板提供至少一个文件。" }
		foreach ($f in $输入文件列表) { if (-not (Test-Path -LiteralPath $f)) { throw "输入文件不存在：$f" } }

		# -------- 输出路径 --------
		$输出文件 = 规范化_用户路径参数 -Path $输出文件
		$用户输出文件 = $输出文件
		$用户输出扩展名 = [System.IO.Path]::GetExtension($用户输出文件)
		if ([string]::IsNullOrWhiteSpace($用户输出扩展名)) {
			$用户输出文件 = $用户输出文件 + '.mkv'
			$用户输出扩展名 = '.mkv'
		}
		$用户输出扩展名 = $用户输出扩展名.ToLowerInvariant()

		$outDir = Split-Path -Parent $用户输出文件
		if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = (Get-Location).Path }
		if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

		$内部输出文件 = if ($用户输出扩展名 -eq '.mkv') { $用户输出文件 } else { Join-Path $工作目录 'stack_output.mkv' }

		# -------- 探测与混淆还原 --------
		Write-Host ("探测 {0} 个输入文件..." -f $输入文件列表.Count) -ForegroundColor Cyan
		$有效输入列表 = New-Object System.Collections.Generic.List[object]
		for ($i = 0; $i -lt $输入文件列表.Count; $i++) {
			$raw = $输入文件列表[$i]
			$有效路径 = 还原_B站混淆媒体文件 -Path $raw -WorkDir $工作目录 -Index ($i + 1)
			$信息 = 获取_媒体信息 -Path $有效路径
			if ([int]$信息.StreamCount -lt 1) { throw "文件不包含任何媒体轨道：$raw" }
			$有效输入列表.Add([pscustomobject]@{
				原始路径  = $raw
				有效路径  = $有效路径
				信息      = $信息
				是否还原  = ($有效路径 -ne $raw)
			})
		}

		# -------- 叠加：每个输入的所有轨道原样搬进同一容器 --------
		$ffmpegArgs = New-Object System.Collections.Generic.List[string]
		$ffmpegArgs.Add('-nostdin'); $ffmpegArgs.Add('-hide_banner'); $ffmpegArgs.Add('-y'); $ffmpegArgs.Add('-v'); $ffmpegArgs.Add('error')
		foreach ($item in $有效输入列表) {
			$ffmpegArgs.Add('-i'); $ffmpegArgs.Add($item.有效路径)
		}
		for ($i = 0; $i -lt $有效输入列表.Count; $i++) { $ffmpegArgs.Add('-map'); $ffmpegArgs.Add([string]$i) }
		$ffmpegArgs.Add('-c'); $ffmpegArgs.Add('copy')
		$ffmpegArgs.Add('-map_metadata'); $ffmpegArgs.Add('-1')
		$ffmpegArgs.Add('-map_chapters'); $ffmpegArgs.Add('-1')

		# 给每个轨道写入 title 元数据，注明来源文件名，便于播放器里区分同类型轨道。
		$全局流序号 = 0
		foreach ($item in $有效输入列表) {
			$来源名 = [System.IO.Path]::GetFileName([string]$item.原始路径)
			for ($s = 0; $s -lt [int]$item.信息.StreamCount; $s++) {
				$ffmpegArgs.Add(('-metadata:s:{0}' -f $全局流序号)); $ffmpegArgs.Add(('title={0}' -f $来源名))
				$全局流序号++
			}
		}

		$ffmpegArgs.Add($内部输出文件)

		Write-Host ("开始叠加：{0} 个输入文件共 {1} 条轨道 → {2}（纯流复制，不重编码）" -f $有效输入列表.Count, $全局流序号, $内部输出文件) -ForegroundColor Cyan
		调用_外部命令 -Exe 'ffmpeg' -ArgumentList ([string[]]$ffmpegArgs.ToArray()) | Out-Null

		# -------- 校验输出 --------
		$输出信息 = 获取_媒体信息 -Path $内部输出文件
		if ([int]$输出信息.StreamCount -ne $全局流序号) {
			throw ("输出轨道数量异常：期望 {0} 条，实际 {1} 条。输出文件：{2}" -f $全局流序号, $输出信息.StreamCount, $内部输出文件)
		}

		# -------- 交付 --------
		if ($内部输出文件 -ne $用户输出文件) {
			Move-Item -LiteralPath $内部输出文件 -Destination $用户输出文件 -Force
			Write-Host ("已将结果文件命名为：{0}（注意：容器实际为 MKV）" -f $用户输出文件) -ForegroundColor Yellow
		}

		Write-Host ("完成：{0}" -f $用户输出文件) -ForegroundColor Green
		Write-Host ("共叠加 {0} 条轨道（时长 {1:F3}s）。同名类型轨道可在播放器内手动切换。" -f $全局流序号, $输出信息.Duration) -ForegroundColor DarkCyan

		if ($详细模式) {
			Write-Host "已保留临时目录：$工作目录" -ForegroundColor Yellow
		}
	} finally {
		if (-not $详细模式) {
			try { if (Test-Path -LiteralPath $工作目录) { Remove-Item -LiteralPath $工作目录 -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
		}
	}

	$global:LASTEXITCODE = 0
}
