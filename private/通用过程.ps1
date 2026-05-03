function 断言_命令存在 {
    param([Parameter(Mandatory)] [string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "未找到命令：$Name。请先安装并确保 $Name 在 PATH 中。"
    }
}

function 测试_管理员权限 {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function 刷新_会话PATH {
    $m = [Environment]::GetEnvironmentVariable('Path','Machine')
    $u = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = @($m,$u | Where-Object { $_ }) -join ';'
}

function 添加_机器PATH {
    param([Parameter(Mandatory)][string]$Dir)
    $cur = [Environment]::GetEnvironmentVariable('Path','Machine')
    $parts = @()
    if ($cur) { $parts = $cur.Split(';') | Where-Object { $_ } }
    if ($parts -notcontains $Dir) {
        $new = (@($parts) + $Dir) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $new, 'Machine')
    }
    刷新_会话PATH
}

function 安装_ffmpeg_通过Winget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }
    Write-Host "正在通过 winget 为所有用户安装 ffmpeg (Gyan.FFmpeg)..." -ForegroundColor Cyan
    $wingetArgs = @(
        'install','--id','Gyan.FFmpeg','--source','winget',
        '--scope','machine','--silent',
        '--accept-package-agreements','--accept-source-agreements'
    )
    try {
        Start-Process -FilePath $winget.Source -ArgumentList $wingetArgs -Wait -NoNewWindow | Out-Null
        # winget 对“已安装/无更新”会返回非零；放宽判定：看命令可用性
    } catch {
        Write-Warning "winget 执行失败：$($_.Exception.Message)"
        return $false
    }
    刷新_会话PATH
    return [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
}

function 安装_ffmpeg_通过下载 {
    $installRoot = Join-Path $env:ProgramFiles 'ffmpeg'
    $binDir = Join-Path $installRoot 'bin'
    $tmpZip = Join-Path $env:TEMP 'ffmpeg-release-essentials.zip'
    $tmpExtract = Join-Path $env:TEMP ("ffmpeg-extract-" + [Guid]::NewGuid().ToString('N'))
    $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'

    Write-Host "正在从 gyan.dev 下载 ffmpeg 静态构建包到 $tmpZip ..." -ForegroundColor Cyan
    $oldPref = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
    } finally {
        $ProgressPreference = $oldPref
    }

    Write-Host "正在解压到 $installRoot ..." -ForegroundColor Cyan
    if (-not (Test-Path $tmpExtract)) { New-Item -ItemType Directory -Path $tmpExtract -Force | Out-Null }
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpExtract -Force

    $extracted = Get-ChildItem -Path $tmpExtract -Directory | Select-Object -First 1
    if (-not $extracted) { throw "ffmpeg 压缩包内容异常，未发现顶层目录。" }

    if (Test-Path $installRoot) {
        # 覆盖安装：先清理 bin/presets 等子目录，避免残留
        Get-ChildItem -Path $installRoot -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    }
    Get-ChildItem -Path $extracted.FullName -Force | Move-Item -Destination $installRoot -Force

    Remove-Item -Path $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path (Join-Path $binDir 'ffmpeg.exe'))) {
        throw "下载安装失败：未找到 $binDir\ffmpeg.exe。"
    }
    添加_机器PATH -Dir $binDir
    return $true
}

function 获取_提权安装脚本路径 {
    param([Parameter(Mandatory)] [string]$文件名)

    $脚本路径 = Join-Path -Path $script:视频工坊根目录 -ChildPath ("private\提权安装\{0}" -f $文件名)
    if (-not (Test-Path -LiteralPath $脚本路径)) {
        throw "提权安装脚本不存在：$脚本路径"
    }
    return $脚本路径
}

function 调用_提权安装脚本 {
    param(
        [Parameter(Mandatory)] [string]$文件名,
        [Parameter(Mandatory)] [string]$提示,
        [Parameter(Mandatory)] [string]$失败消息
    )

    $脚本路径 = 获取_提权安装脚本路径 -文件名 $文件名
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = 'powershell.exe' }
    $procArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $脚本路径))

    Write-Host $提示 -ForegroundColor Yellow
    $进程 = Start-Process -FilePath $exe -ArgumentList $procArgs -Verb RunAs -Wait -PassThru
    if ($进程.ExitCode -ne 0) {
        throw ("{0}（ExitCode={1}）。" -f $失败消息, $进程.ExitCode)
    }
    刷新_会话PATH
}

function 以管理员执行_安装ffmpeg {
    调用_提权安装脚本 `
        -文件名 '安装ffmpeg.ps1' `
        -提示 '需要管理员权限以为所有用户安装 ffmpeg，将弹出 UAC 提示...' `
        -失败消息 '提权安装 ffmpeg 失败'
}

function 安装_mkvmerge_通过Winget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) { return $false }
    Write-Host "正在通过 winget 为所有用户安装 MKVToolNix (MoritzBunkus.MKVToolNix)..." -ForegroundColor Cyan
    $wingetArgs = @(
        'install','--id','MoritzBunkus.MKVToolNix','--source','winget',
        '--scope','machine','--silent',
        '--accept-package-agreements','--accept-source-agreements'
    )
    try {
        Start-Process -FilePath $winget.Source -ArgumentList $wingetArgs -Wait -NoNewWindow | Out-Null
    } catch {
        Write-Warning "winget 执行失败：$($_.Exception.Message)"
        return $false
    }
    刷新_会话PATH
    # MKVToolNix 默认安装到 %ProgramFiles%\MKVToolNix，未必会自动加到 PATH，主动补一把
    $defaultBin = Join-Path $env:ProgramFiles 'MKVToolNix'
    if (Test-Path (Join-Path $defaultBin 'mkvmerge.exe')) {
        添加_机器PATH -Dir $defaultBin
    }
    return [bool](Get-Command mkvmerge -ErrorAction SilentlyContinue)
}

function 以管理员执行_安装mkvmerge {
    调用_提权安装脚本 `
        -文件名 '安装mkvmerge.ps1' `
        -提示 '需要管理员权限以为所有用户安装 MKVToolNix，将弹出 UAC 提示...' `
        -失败消息 '提权安装 MKVToolNix 失败'
}

function 确保_mkvmerge_可用 {
    刷新_会话PATH
    if (Get-Command mkvmerge -ErrorAction SilentlyContinue) { return }
    Write-Host "检测到缺少 mkvmerge，将尝试自动安装 MKVToolNix（机器级，对所有 Windows 用户可用）。" -ForegroundColor Yellow
    if (测试_管理员权限) {
        [void](安装_mkvmerge_通过Winget)
    } else {
        以管理员执行_安装mkvmerge
    }
    刷新_会话PATH
    if (-not (Get-Command mkvmerge -ErrorAction SilentlyContinue)) {
        throw "自动安装完成但仍未找到 mkvmerge。请重启 PowerShell 会话后重试，或手动从 https://mkvtoolnix.download 安装。"
    }
    Write-Host "mkvmerge 已就绪。" -ForegroundColor Green
}

function 确保_ffmpeg_ffprobe_可用 {
    # 先从注册表刷新会话 PATH，吸收 Machine/User 级别的最新变更
    # （典型场景：父终端是在 ffmpeg 安装之前启动的，进程环境里的 PATH 已陈旧）
    刷新_会话PATH

    $need = @(@('ffmpeg','ffprobe') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($need.Count -eq 0) { return }

    Write-Host "检测到缺少命令：$($need -join ', ')，将尝试自动安装（机器级，对所有 Windows 用户可用）。" -ForegroundColor Yellow

    if (测试_管理员权限) {
        if (-not (安装_ffmpeg_通过Winget)) {
            [void](安装_ffmpeg_通过下载)
        }
    } else {
        以管理员执行_安装ffmpeg
    }

    刷新_会话PATH
    foreach ($n in @('ffmpeg','ffprobe')) {
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
            throw "自动安装完成但仍未找到 $n。请手动检查 PATH，或重启 PowerShell 会话后重试。"
        }
    }
    Write-Host "ffmpeg / ffprobe 已就绪。" -ForegroundColor Green
}

function 获取_ffmpeg_编码器集合 {
    $cached = Get-Variable -Name 'ffmpeg编码器集合' -Scope Script -ErrorAction SilentlyContinue
    if ($cached -and $null -ne $cached.Value) { return $script:ffmpeg编码器集合 }
    $res = 调用_外部命令 -Exe 'ffmpeg' -ArgumentList @('-hide_banner','-encoders') -CaptureOutput
    $set = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($line in ($res.StdOut -split "`r?`n")) {
        # 示例：" V..... h264_nvenc           NVIDIA NVENC H.264 encoder"
        if ($line -match '^\s*[A-Z\.]{6}\s+([0-9A-Za-z_]+)\s+') {
            [void]$set.Add($matches[1])
        }
    }

    $script:ffmpeg编码器集合 = $set
    return $set
}

function 选择_视频编码器 {
    param(
        [Parameter(Mandatory)] [string]$目标视频编码
    )

    $codec = $目标视频编码.ToLowerInvariant()
    $encSet = 获取_ffmpeg_编码器集合

    $gpuCandidates = @()
    $cpuFallback = $null

    switch ($codec) {
        'h264' {
            $gpuCandidates = @('h264_nvenc','h264_qsv','h264_amf')
            $cpuFallback = 'libx264'
        }
        'hevc' {
            $gpuCandidates = @('hevc_nvenc','hevc_qsv','hevc_amf')
            $cpuFallback = 'libx265'
        }
        default {
            # 其它编码：尽量保持 CPU 回退策略
            $cpuFallback = 'libx264'
        }
    }

    # 一律优先 GPU（NVENC/QSV/AMF）
    foreach ($cand in $gpuCandidates) {
        if ($encSet.Contains($cand)) { return [pscustomobject]@{ Encoder = $cand; IsGpu = $true } }
    }

    Write-Warning "未检测到可用 GPU 编码器（NVENC/QSV/AMF）。将回退到 CPU 编码：$cpuFallback"

    return [pscustomobject]@{ Encoder = $cpuFallback; IsGpu = $false }
}

function 调用_外部命令 {
    param(
        [Parameter(Mandatory)] [string]$Exe,
        [Parameter(Mandatory)] [string[]]$ArgumentList,
        [switch]$CaptureOutput,
        [switch]$显示捕获输出,
        # 允许视为"成功"的额外退出码（除 0 外）。mkvmerge 约定 1=仅警告、2=错误，所以调用它时传 @(1)。
        [int[]]$AllowedExitCodes = @()
    )

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($script:输出外部进程信息 -and -not $CaptureOutput) {
            & $Exe @ArgumentList
            $exit = $LASTEXITCODE
            if ($exit -ne 0 -and ($AllowedExitCodes -notcontains $exit)) {
                throw "外部命令失败：$Exe $($ArgumentList -join ' ') (exit=$exit)"
            }
            return [pscustomobject]@{ StdOut = ''; StdErr = '' }
        }

        $all = & $Exe @ArgumentList 2>&1
        $exit = $LASTEXITCODE
        $text = ($all | Out-String)
        if ($script:输出外部进程信息 -and $CaptureOutput -and $显示捕获输出 -and -not [string]::IsNullOrWhiteSpace($text)) {
            Write-Host $text
        }
        if ($exit -ne 0 -and ($AllowedExitCodes -notcontains $exit)) {
            throw "外部命令失败：$Exe $($ArgumentList -join ' ') (exit=$exit)`n$text"
        }
        return [pscustomobject]@{ StdOut = $text; StdErr = '' }
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

function 取_对象属性值 {
    param(
        [Parameter(Mandatory)] $Obj,
        [Parameter(Mandatory)] [string]$Name
    )
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function 解析_整数或空 {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    try { return [int64]$s } catch { return $null }
}

function 解析_有理数 {
    param([string]$r)
    if ([string]::IsNullOrWhiteSpace($r)) { return $null }
    if ($r -match '^\s*(\d+)\s*/\s*(\d+)\s*$') {
        $n = [double]$matches[1]
        $d = [double]$matches[2]
        if ($d -eq 0) { return $null }
        return $n / $d
    }
    if ($r -match '^\s*\d+(\.\d+)?\s*$') {
        return [double]$r
    }
    return $null
}

function 格式化_值列表 {
    param([Parameter(Mandatory)] [object[]]$Values)
    $s = @($Values | ForEach-Object {
            if ($null -eq $_) { 'N/A' } else { [string]$_ }
        })
    return ($s -join ', ')
}

function 取_非空字符串去重 {
    param([object[]]$Values)
    $arr = @(
        $Values |
            ForEach-Object { if ($null -eq $_) { $null } else { ([string]$_).Trim() } } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    return ,$arr
}

function 取_按流序号统计包字节数 {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [int[]]$StreamIndices
    )

    # 性能优化：一次 show_packets 扫描同时统计视频/音频 packet.size（避免扫两遍）。
    $need = @($StreamIndices | Where-Object { $null -ne $_ } | Select-Object -Unique)
    if ($need.Count -eq 0) { return @{} }

    $res = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @(
        '-v','error',
        '-show_packets',
        '-show_entries','packet=stream_index,size',
        '-of','compact=p=0:nk=1',
        $Path
    ) -CaptureOutput

    $sums = @{}
    foreach ($i in $need) { $sums[[int]$i] = [int64]0 }

    foreach ($line in ($res.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $t = $line.Trim()

        # compact nk=1 通常输出："<stream_index>|<size>"
        $parts = $t -split '\|'
        if ($parts.Count -lt 2) { $parts = $t -split ',' }
        if ($parts.Count -lt 2) { continue }

        $si = 0
        $sz = [int64]0
        if (-not [int]::TryParse($parts[0].Trim(), [ref]$si)) { continue }
        if (-not [int64]::TryParse($parts[1].Trim(), [ref]$sz)) { continue }

        if ($sums.ContainsKey($si)) {
            $sums[$si] = [int64]($sums[$si] + $sz)
        }
    }

    return $sums
}

function 取_最小值或空 {
    param([object[]]$Values)
    $vals = @($Values | Where-Object { $null -ne $_ })
    if ($vals.Count -eq 0) { return $null }
    return ($vals | Measure-Object -Minimum).Minimum
}

function 取_极值或空 {
    param(
        [AllowNull()]
        [object[]]$Values,
        [Parameter(Mandatory)] [ValidateSet('Min','Max')] [string]$Mode
    )
    if ($null -eq $Values) { return $null }
    $vals = @($Values | Where-Object { $null -ne $_ })
    if ($vals.Count -eq 0) { return $null }
    if ($Mode -eq 'Max') {
        return ($vals | Measure-Object -Maximum).Maximum
    }
    return ($vals | Measure-Object -Minimum).Minimum
}

function 转换_码率到bps {
    param([Parameter(Mandatory)] [string]$Value)
    $v = $Value.Trim()
    if ($v -match '^\d+$') { return [int64]$v }
    if ($v -match '^(\d+(?:\.\d+)?)\s*([kKmMgG])$') {
        $num = [double]$matches[1]
        $unit = $matches[2].ToLowerInvariant()
        switch ($unit) {
            'k' { return [int64]([math]::Round($num * 1000)) }
            'm' { return [int64]([math]::Round($num * 1000 * 1000)) }
            'g' { return [int64]([math]::Round($num * 1000 * 1000 * 1000)) }
        }
    }
    return $null
}

function 转换_fps到DefaultDuration_ns {
    param([Parameter(Mandatory)] [string]$Fps)
    $s = $Fps.Trim()
    if ($s -match '^(\d+)\s*/\s*(\d+)$') {
        $num = [double]$matches[1]
        $den = [double]$matches[2]
        if ($num -le 0 -or $den -le 0) { return $null }
        return [int64]([math]::Round(($den * 1000000000.0) / $num))
    }
    if ($s -match '^(\d+(?:\.\d+)?)$') {
        $num = [double]$matches[1]
        if ($num -le 0) { return $null }
        return [int64]([math]::Round(1000000000.0 / $num))
    }
    return $null
}

function 获取_可执行命令路径 {
    param([Parameter(Mandatory)] [string]$名称)

    $命令 = Get-Command $名称 -ErrorAction SilentlyContinue
    if (-not $命令) { return $null }
    return $命令.Source
}

function 测试_ffmpeg过滤器可用 {
    param(
        [Parameter(Mandatory)] [string]$FfmpegPath,
        [Parameter(Mandatory)] [string]$过滤器名称
    )

    try {
        $结果 = 调用_外部命令 -Exe $FfmpegPath -ArgumentList @('-hide_banner', '-filters') -CaptureOutput
    } catch {
        return $false
    }

    return ($结果.StdOut -match ("(?m)^\s*\S+\s+{0}\s" -f [regex]::Escape($过滤器名称)))
}

function 查找_支持过滤器的ffmpeg {
    param([Parameter(Mandatory)] [string]$过滤器名称)

    $winget包路径 = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*" `
        -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    $候选列表 = @($winget包路径, (获取_可执行命令路径 -名称 'ffmpeg')) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique

    foreach ($路径 in $候选列表) {
        if (测试_ffmpeg过滤器可用 -FfmpegPath $路径 -过滤器名称 $过滤器名称) {
            return $路径
        }
    }

    return $null
}

function 确保_ffmpeg支持过滤器 {
    param([Parameter(Mandatory)] [string]$过滤器名称)

    $ffmpeg路径 = 查找_支持过滤器的ffmpeg -过滤器名称 $过滤器名称
    if ($ffmpeg路径) { return $ffmpeg路径 }

    Write-Host "未找到支持 $过滤器名称 的 ffmpeg，将尝试安装 Gyan.FFmpeg。" -ForegroundColor Yellow
    if (测试_管理员权限) {
        if (-not (安装_ffmpeg_通过Winget)) {
            [void](安装_ffmpeg_通过下载)
        }
    } else {
        以管理员执行_安装ffmpeg
    }

    刷新_会话PATH
    $ffmpeg路径 = 查找_支持过滤器的ffmpeg -过滤器名称 $过滤器名称
    if (-not $ffmpeg路径) {
        throw "安装后仍未找到支持 $过滤器名称 的 ffmpeg，请重新打开终端后再试。"
    }

    return $ffmpeg路径
}

function 测试_ffmpeg视频编码器可用 {
    param(
        [Parameter(Mandatory)] [string]$FfmpegPath,
        [Parameter(Mandatory)] [string]$编码器名称
    )

    try {
        $结果 = 调用_外部命令 -Exe $FfmpegPath -ArgumentList @('-hide_banner', '-encoders') -CaptureOutput
    } catch {
        return $false
    }

    return ($结果.StdOut -match ("(?m)^\s*[A-Z\.]{6}\s+{0}\s" -f [regex]::Escape($编码器名称)))
}

function 获取_媒体流探测数据 {
    param([Parameter(Mandatory)] [string]$Path)

    $结果 = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @(
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_streams',
        $Path
    ) -CaptureOutput

    return ($结果.StdOut | ConvertFrom-Json)
}
