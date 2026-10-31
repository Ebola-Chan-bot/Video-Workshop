function 读取_LLC项目 {
	param([Parameter(Mandatory)] [string]$Path)

	$项目路径 = (Resolve-Path -LiteralPath $Path).Path
	$文本 = [System.IO.File]::ReadAllText($项目路径, [System.Text.Encoding]::UTF8)
	# 仅删除字符串外的尾随逗号，保留 LLC 的字段顺序和字符串内容。
	$结果文本 = New-Object System.Text.StringBuilder
	$在字符串内 = $false
	$已转义 = $false
	for ($i = 0; $i -lt $文本.Length; $i++) {
		$字符 = $文本[$i]
		if ($在字符串内) {
			[void]$结果文本.Append($字符)
			if ($已转义) { $已转义 = $false }
			elseif ($字符 -eq '\') { $已转义 = $true }
			elseif ($字符 -eq '"') { $在字符串内 = $false }
		} elseif ($字符 -eq '"') {
			$在字符串内 = $true
			[void]$结果文本.Append($字符)
		} elseif ($字符 -eq ',' -and $文本.Substring($i + 1) -match '^\s*[}\]]') {
			continue
		} else {
			[void]$结果文本.Append($字符)
		}
	}
	$项目 = $结果文本.ToString() | ConvertFrom-Json
	if ([int]$项目.version -ne 2) { throw "仅支持 version 2 的 LLC 项目：$项目路径" }
	$媒体文件名 = [string]$项目.mediaFileName
	if ([string]::IsNullOrWhiteSpace($媒体文件名)) { throw 'LLC 项目缺少 mediaFileName。' }
	$媒体路径 = if ([System.IO.Path]::IsPathRooted($媒体文件名)) { $媒体文件名 } else { Join-Path (Split-Path -Parent $项目路径) $媒体文件名 }
	if (-not (Test-Path -LiteralPath $媒体路径 -PathType Leaf)) { throw "LLC 项目引用的媒体文件不存在：$媒体路径" }

	$片段列表 = New-Object 'System.Collections.Generic.List[object]'
	$序号 = 0
	foreach ($片段 in $项目.cutSegments) {
		$序号++
		if ($null -ne $片段.PSObject.Properties['selected'] -and -not [bool]$片段.selected) { continue }
		$开始 = [double]$片段.start
		$结束 = [double]$片段.end
		if ([double]::IsNaN($开始) -or [double]::IsInfinity($开始) -or [double]::IsNaN($结束) -or [double]::IsInfinity($结束) -or $开始 -lt 0 -or $结束 -le $开始) { throw "第 $序号 个片段的起止时间无效。" }
		$片段列表.Add([pscustomobject]@{ 序号 = $序号; 开始 = $开始; 结束 = $结束; 名称 = [string]$片段.name })
	}
	if ($片段列表.Count -eq 0) { throw 'LLC 项目中没有 selected 为 true 的有效剪切片段。' }
	return [pscustomobject]@{ 项目路径 = $项目路径; 媒体路径 = (Resolve-Path -LiteralPath $媒体路径).Path; 片段列表 = $片段列表.ToArray() }
}

function 查找_RealMedia编辑器路径 {
	$命令 = Get-Command 'rmeditor.exe' -ErrorAction SilentlyContinue
	if ($命令) { return $命令.Source }

	$候选路径 = @(
		(Join-Path ${env:ProgramFiles(x86)} 'Real\RealProducer Basic\rmeditor.exe'),
		(Join-Path $env:ProgramFiles 'Real\RealProducer Basic\rmeditor.exe'),
		(Join-Path $env:TEMP 'losslesscut-realmedia-tools\producer-files\Default_File_Group\rmeditor.exe')
	)
	foreach ($路径 in $候选路径) {
		if (Test-Path -LiteralPath $路径 -PathType Leaf) { return $路径 }
	}
	return $null
}

function 解决_RealMedia编辑器路径 {
	$编辑器路径 = 查找_RealMedia编辑器路径
	if ($编辑器路径) { return $编辑器路径 }

	Write-Host '未找到 RealMedia Editor，正在自动安装 RealProducer Basic 11……' -ForegroundColor Yellow
	调用_提权安装脚本 -文件名 '安装RealMedia工具.ps1' -提示 '需要管理员权限以安装 RealMedia Editor，将弹出 UAC 提示……' -失败消息 '提权安装 RealMedia Editor 失败'
	刷新_会话PATH
	$编辑器路径 = 查找_RealMedia编辑器路径
	if (-not $编辑器路径) { throw 'RealProducer 安装完成，但仍未找到 rmeditor.exe。' }
	return $编辑器路径
}

function 格式化_RealMedia时间 {
	param([Parameter(Mandatory)] [double]$秒)

	$总毫秒 = [int64][Math]::Round($秒 * 1000, [MidpointRounding]::AwayFromZero)
	$时间 = [TimeSpan]::FromMilliseconds($总毫秒)
	return '{0}:{1:00}:{2:00}:{3:00}.{4:000}' -f [Math]::Floor($时间.TotalDays), $时间.Hours, $时间.Minutes, $时间.Seconds, $时间.Milliseconds
}

function 剪切_RealMedia片段 {
	param(
		[Parameter(Mandatory)] [string]$编辑器路径,
		[Parameter(Mandatory)] [string]$源路径,
		[Parameter(Mandatory)] [string]$输出路径,
		[Parameter(Mandatory)] [double]$开始,
		[Parameter(Mandatory)] [double]$结束
	)

	$工作目录 = Join-Path ([System.IO.Path]::GetTempPath()) ('llc-rm-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $工作目录 -Force | Out-Null
	try {
		$临时源路径 = Join-Path $工作目录 ('source' + [System.IO.Path]::GetExtension($源路径))
		$临时输出路径 = Join-Path $工作目录 ('segment' + [System.IO.Path]::GetExtension($源路径))
		Copy-Item -LiteralPath $源路径 -Destination $临时源路径
		$参数 = @(
			'-i', $临时源路径, '-o', $临时输出路径,
			'-s', (格式化_RealMedia时间 -秒 $开始),
			'-e', (格式化_RealMedia时间 -秒 $结束)
		)
		Write-Host "> $编辑器路径 $($参数 -join ' ')" -ForegroundColor DarkGray
		[void](调用_外部命令 -Exe $编辑器路径 -ArgumentList $参数 -CaptureOutput)
		if (-not (Test-Path -LiteralPath $临时输出路径 -PathType Leaf) -or (Get-Item -LiteralPath $临时输出路径).Length -le 0) {
			throw "rmeditor 未生成有效片段：$输出路径"
		}
		Move-Item -LiteralPath $临时输出路径 -Destination $输出路径 -Force
	} finally {
		Remove-Item -LiteralPath $工作目录 -Recurse -Force -ErrorAction SilentlyContinue
	}
}

function 合并_RealMedia片段 {
	param(
		[Parameter(Mandatory)] [string[]]$输入文件列表,
		[Parameter(Mandatory)] [string]$输出文件
	)

	$编辑器路径 = 解决_RealMedia编辑器路径
	$输出目录 = Split-Path -Parent ([System.IO.Path]::GetFullPath($输出文件))
	if ($输出目录 -and -not (Test-Path -LiteralPath $输出目录 -PathType Container)) { New-Item -ItemType Directory -Path $输出目录 -Force | Out-Null }
	$工作目录 = Join-Path ([System.IO.Path]::GetTempPath()) ('merge-rm-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $工作目录 -Force | Out-Null
	try {
		$临时输出 = Join-Path $工作目录 'merged.rmvb'
		$参数 = New-Object 'System.Collections.Generic.List[string]'
		foreach ($输入文件 in $输入文件列表) {
			$临时输入 = Join-Path $工作目录 ('input-{0:D3}.rmvb' -f $参数.Count)
			Copy-Item -LiteralPath $输入文件 -Destination $临时输入
			$参数.Add('-i')
			$参数.Add($临时输入)
		}
		$参数.Add('-o')
		$参数.Add($临时输出)
		Write-Host "> $编辑器路径 $($参数 -join ' ')" -ForegroundColor DarkGray
		[void](调用_外部命令 -Exe $编辑器路径 -ArgumentList $参数.ToArray() -CaptureOutput)
		if (-not (Test-Path -LiteralPath $临时输出 -PathType Leaf) -or (Get-Item -LiteralPath $临时输出).Length -le 0) { throw 'rmeditor 未生成有效合并文件。' }
		Move-Item -LiteralPath $临时输出 -Destination $输出文件 -Force
	} finally {
		Remove-Item -LiteralPath $工作目录 -Recurse -Force -ErrorAction SilentlyContinue
	}
}

function 获取_视频关键帧 {
	param([Parameter(Mandatory)] [string]$Path)

	$结果 = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @(
		'-v', 'error', '-select_streams', 'v:0',
		'-show_entries', 'packet=pts_time,flags', '-of', 'csv=p=0', $Path
	) -CaptureOutput
	$视频包列表 = New-Object 'System.Collections.Generic.List[object]'
	foreach ($行 in ($结果.StdOut -split "`r?`n")) {
		if ([string]$行 -notmatch '^\s*(-?\d+(?:\.\d+)?),([A-Z_]+)') { continue }
		$视频包列表.Add([pscustomobject]@{
			时间 = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
			是关键帧 = $Matches[2].StartsWith('K')
		})
	}

	$关键帧列表 = New-Object 'System.Collections.Generic.List[object]'
	$前一显示时间 = $null
	foreach ($包 in ($视频包列表.ToArray() | Sort-Object -Property 时间)) {
		if ($包.是关键帧) {
			# rmeditor 按帧序号选择起点，提前半个显示帧以避免漏掉目标首关键帧。
			$编辑器起点 = if ($null -eq $前一显示时间) { $包.时间 } else { ($前一显示时间 + $包.时间) / 2 }
			$关键帧列表.Add([pscustomobject]@{ 时间 = $包.时间; 编辑器起点 = $编辑器起点 })
		}
		if ($null -eq $前一显示时间 -or $包.时间 -gt $前一显示时间) { $前一显示时间 = $包.时间 }
	}
	if ($关键帧列表.Count -eq 0) { throw "未能读取视频关键帧时间：$Path" }
	return $关键帧列表.ToArray()
}

function 取_最近关键帧 {
	param(
		[Parameter(Mandatory)] [object[]]$关键帧列表,
		[Parameter(Mandatory)] [double]$目标时间
	)

	$下界 = 0
	$上界 = $关键帧列表.Count - 1
	while ($下界 -le $上界) {
		$中点 = [int](($下界 + $上界) / 2)
		if ($关键帧列表[$中点].时间 -eq $目标时间) { return $关键帧列表[$中点] }
		if ($关键帧列表[$中点].时间 -lt $目标时间) { $下界 = $中点 + 1 } else { $上界 = $中点 - 1 }
	}
	if ($下界 -eq 0) { return $关键帧列表[0] }
	if ($下界 -eq $关键帧列表.Count) { return $关键帧列表[$关键帧列表.Count - 1] }
	$前一帧 = $关键帧列表[$下界 - 1]
	$后一帧 = $关键帧列表[$下界]
	if ($目标时间 - $前一帧.时间 -le $后一帧.时间 - $目标时间) { return $前一帧 }
	return $后一帧
}

function 格式化_LLC时间戳 {
	param([Parameter(Mandatory)] [double]$秒)
	return [TimeSpan]::FromSeconds($秒).ToString('hh\.mm\.ss\.fff', [Globalization.CultureInfo]::InvariantCulture)
}
