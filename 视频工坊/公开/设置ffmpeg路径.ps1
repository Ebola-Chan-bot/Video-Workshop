function 设置ffmpeg路径 {
	<#
	.SYNOPSIS
		设置模块内部使用的 ffmpeg/ffprobe 所在目录。

	.DESCRIPTION
		指定 ffmpeg.exe 和 ffprobe.exe 所在的目录后，视频工坊的所有命令（烧录字幕、DV转HDR10、超级合并）都会优先调用该目录下的 ffmpeg/ffprobe。
		设置会永久保存到 %LOCALAPPDATA%\视频工坊\ffmpeg路径.txt，以后新开的PowerShell 会话导入视频工坊时也会自动使用该路径；优先级高于 PATH 中的同名命令。如果指定目录下没有找到 ffmpeg.exe/ffprobe.exe，命令会自动清除该自定义目录设置（含已保存的设置文件），回退到 PATH，并在 PATH 中也缺失时按原有流程自动下载安装，不会因此失败。
		传入 ffmpeg.exe 自身的完整路径也可以，函数会自动取其所在目录。
		传入 $null 或空字符串可取消自定义设置，恢复默认查找行为（同时删除已保存的设置文件）。

	.PARAMETER 路径
		ffmpeg.exe 所在目录，或 ffmpeg.exe 的完整路径。目录必须已存在。
		传入 $null 或空字符串表示取消自定义设置。

	.EXAMPLE
		设置ffmpeg路径 'D:\Tools\ffmpeg\bin'

		之后所有命令都优先使用 D:\Tools\ffmpeg\bin 下的 ffmpeg/ffprobe。

	.EXAMPLE
		设置ffmpeg路径 'D:\Tools\ffmpeg\bin\ffmpeg.exe'

		与传目录等价，函数自动使用其所在目录。

	.EXAMPLE
		设置ffmpeg路径 $null

		取消自定义设置，恢复使用 PATH 查找。

	.NOTES
		设置保存在 %LOCALAPPDATA%\视频工坊\ffmpeg路径.txt，跨会话永久生效。
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0)]
		[AllowNull()]
		[AllowEmptyString()]
		[string]$路径
	)

	if ([string]::IsNullOrWhiteSpace($路径)) {
		$script:自定义ffmpeg目录 = $null
		$script:自定义ffmpeg缺失已警告 = $false
		$script:ffmpeg编码器集合 = $null
		写入_自定义ffmpeg路径设置 -目录 $null
		Write-Host "已取消自定义 ffmpeg 路径，恢复默认查找行为。" -ForegroundColor Green
		return
	}

	$路径 = 规范化_用户路径参数 -Path $路径

	# 如果传入的是 ffmpeg.exe 文件本身，取其所在目录
	if ([string]::Equals([System.IO.Path]::GetFileName($路径), 'ffmpeg.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
		$目录 = [System.IO.Path]::GetDirectoryName($路径)
		if ([string]::IsNullOrWhiteSpace($目录)) { $目录 = $路径 }
		$路径 = $目录
	}

	if (-not (Test-Path -LiteralPath $路径 -PathType Container)) {
		throw "目录不存在：$路径"
	}

	$script:自定义ffmpeg目录 = (Resolve-Path -LiteralPath $路径).Path
	$script:自定义ffmpeg缺失已警告 = $false
	$script:ffmpeg编码器集合 = $null

	写入_自定义ffmpeg路径设置 -目录 $script:自定义ffmpeg目录

	Write-Host "ffmpeg 目录已设置为：$($script:自定义ffmpeg目录)（已永久保存，新会话自动生效）" -ForegroundColor Green

	$缺少的工具 = @(@('ffmpeg','ffprobe') | Where-Object { -not (解决_自定义工具路径 -工具名 $_) })
	if ($缺少的工具.Count -gt 0) {
		Write-Warning ("该目录下未找到：$($缺少的工具 -join ', ')。已自动清除该目录设置，改用 PATH 查找；若 PATH 中也缺失，仍会自动下载安装。")
		$script:自定义ffmpeg目录 = $null
		$script:ffmpeg编码器集合 = $null
		写入_自定义ffmpeg路径设置 -目录 $null
	}
}
