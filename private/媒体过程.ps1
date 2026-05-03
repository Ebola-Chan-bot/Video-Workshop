function 转义_ConCat路径 {
    param([Parameter(Mandatory)] [string]$Path)
    $p = $Path -replace '\\','/'
    $p = $p -replace "'", "'\\''"
    return $p
}

function 获取_视频包范围 {
    param([Parameter(Mandatory)] [string]$Path)
    $res = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @('-v','error','-select_streams','v:0','-show_entries','packet=pts_time','-of','csv=p=0', $Path) -CaptureOutput
    $pts = New-Object 'System.Collections.Generic.List[double]'
    foreach ($line in ($res.StdOut -split "`r?`n")) { $s = ([string]$line).Trim(); if ($s -match '^-?\d+(?:\.\d+)?') { $pts.Add([double]::Parse($Matches[0], [System.Globalization.CultureInfo]::InvariantCulture)) } }
    if ($pts.Count -lt 1) { return $null }
    $firstPts = [double]$pts[0]; $lastPts = [double]$pts[$pts.Count - 1]
    if ($pts.Count -ge 2) { $frameInterval = ($lastPts - $firstPts) / ($pts.Count - 1); if ([double]::IsNaN($frameInterval) -or [double]::IsInfinity($frameInterval) -or $frameInterval -le 0) { $frameInterval = 0.041709 }; $duration = [math]::Max(0.0, ($lastPts - $firstPts + $frameInterval)) } else { $frameInterval = 0.041709; $duration = $frameInterval }
    return [pscustomobject]@{ FirstPts = $firstPts; LastPts = $lastPts; PacketCount = $pts.Count; FrameInterval = $frameInterval; DurationSeconds = [double]$duration }
}

function 获取_媒体信息 {
    param([Parameter(Mandatory)] [string]$Path)

    $res = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @('-v','error','-print_format','json','-show_streams','-show_format', $Path) -CaptureOutput
    $json = $res.StdOut | ConvertFrom-Json

    $v = $json.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $a = $json.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
    $s = $json.streams | Where-Object { $_.codec_type -eq 'subtitle' } | Select-Object -First 1

    # 流签名：按流索引列出 "type:codec"。用于同构检测（是否来自同一原片的多段裁剪）。
    $signatureTokens = @()
    foreach ($st in @($json.streams)) {
        $t = [string](取_对象属性值 -Obj $st -Name 'codec_type')
        $c = [string](取_对象属性值 -Obj $st -Name 'codec_name')
        $signatureTokens += ("{0}:{1}" -f $t, $c)
    }

    $duration = $null
    if ($json.format -and $json.format.duration) {
        try { $duration = [double]$json.format.duration } catch { $duration = $null }
    }
    if ($null -eq $duration -and $v -and (取_对象属性值 -Obj $v -Name 'duration')) {
        try { $duration = [double](取_对象属性值 -Obj $v -Name 'duration') } catch { $duration = $null }
    }
    if ($null -eq $duration) { $duration = 0.0 }

    $fpsRaw = $null
    $fps = $null
    if ($v) {
        $fpsRaw = [string](取_对象属性值 -Obj $v -Name 'avg_frame_rate')
        if ([string]::IsNullOrWhiteSpace($fpsRaw)) { $fpsRaw = [string](取_对象属性值 -Obj $v -Name 'r_frame_rate') }
        $fps = 解析_有理数 $fpsRaw
    }

    return [pscustomobject]@{
        Path = $Path
        Duration = [double]$duration
        StreamSignature = ($signatureTokens -join '|')
        StreamCount = @($json.streams).Count
        Video = if ($v) {
            [pscustomobject]@{
                Codec = [string](取_对象属性值 -Obj $v -Name 'codec_name')
                Width = 解析_整数或空 ([string](取_对象属性值 -Obj $v -Name 'width'))
                Height = 解析_整数或空 ([string](取_对象属性值 -Obj $v -Name 'height'))
                PixFmt = [string](取_对象属性值 -Obj $v -Name 'pix_fmt')
                FpsRaw = [string]$fpsRaw
                Fps = $fps
                BitRate = 解析_整数或空 ([string](取_对象属性值 -Obj $v -Name 'bit_rate'))
            }
        } else { $null }
        Audio = if ($a) {
            [pscustomobject]@{
                Codec = [string](取_对象属性值 -Obj $a -Name 'codec_name')
                SampleRate = 解析_整数或空 ([string](取_对象属性值 -Obj $a -Name 'sample_rate'))
                Channels = 解析_整数或空 ([string](取_对象属性值 -Obj $a -Name 'channels'))
                BitRate = 解析_整数或空 ([string](取_对象属性值 -Obj $a -Name 'bit_rate'))
            }
        } else { $null }
        Subtitle = if ($s) {
            [pscustomobject]@{
                Codec = [string](取_对象属性值 -Obj $s -Name 'codec_name')
            }
        } else { $null }
    }
}

function 获取_媒体码率估算 {
    param([Parameter(Mandatory)] [string]$Path)

    # 尽量快速：优先使用 stream.bit_rate / format.bit_rate；其次用 size/duration 估算。
    $res = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @(
        '-v','error',
        '-print_format','json',
        '-show_entries','format=duration,size,bit_rate:stream=index,codec_type,bit_rate',
        $Path
    ) -CaptureOutput

    $j = $res.StdOut | ConvertFrom-Json

    $duration = 0.0
    if ($j.format -and $j.format.duration) {
        try { $duration = [double]$j.format.duration } catch { $duration = 0.0 }
    }

    $sizeBytes = $null
    if ($j.format -and $j.format.size) {
        try { $sizeBytes = [int64]$j.format.size } catch { $sizeBytes = $null }
    }

    $formatBps = $null
    if ($j.format -and $j.format.bit_rate) {
        $formatBps = 解析_整数或空 ([string]$j.format.bit_rate)
    }

    $v = $j.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $a = $j.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1

    $videoBps = $null
    $audioBps = $null

    if ($v) { $videoBps = 解析_整数或空 ([string](取_对象属性值 -Obj $v -Name 'bit_rate')) }
    if ($a) { $audioBps = 解析_整数或空 ([string](取_对象属性值 -Obj $a -Name 'bit_rate')) }

    if ((-not $videoBps -or $videoBps -le 0) -and $formatBps -and $formatBps -gt 0) {
        if ($audioBps -and $audioBps -gt 0) {
            $videoBps = [int64]([math]::Max(0.0, ($formatBps - $audioBps)))
        } else {
            $videoBps = $formatBps
        }
    }

    if ((-not $videoBps -or $videoBps -le 0) -and $duration -gt 0 -and $sizeBytes -and $sizeBytes -gt 0) {
        $totalBps = [int64]([math]::Round(($sizeBytes * 8.0) / $duration))
        if ($audioBps -and $audioBps -gt 0) {
            $videoBps = [int64]([math]::Max(0.0, ($totalBps - $audioBps)))
        } else {
            $videoBps = $totalBps
        }
    }

    if ((-not $audioBps -or $audioBps -le 0) -and $formatBps -and $formatBps -gt 0 -and $videoBps -and $videoBps -gt 0) {
        $audioBps = [int64]([math]::Max(0.0, ($formatBps - $videoBps)))
    }

    return [pscustomobject]@{
        DurationSeconds = $duration
        SizeBytes = $sizeBytes
        FormatBps = $formatBps
        VideoBps = $videoBps
        AudioBps = $audioBps
    }
}

function 获取_输出探测数据_快速 {
    param([Parameter(Mandatory)] [string]$Path)

    $probe = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @('-v','error','-print_format','json','-show_streams','-show_format', $Path) -CaptureOutput
    $j = $probe.StdOut | ConvertFrom-Json

    $v = $j.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $a = $j.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
    $s = $j.streams | Where-Object { $_.codec_type -eq 'subtitle' } | Select-Object -First 1

    $duration = 0.0
    if ($j.format -and $j.format.duration) {
        try { $duration = [double]$j.format.duration } catch { $duration = 0.0 }
    }

    $sizeBytes = 0
    if ($j.format -and $j.format.size) {
        try { $sizeBytes = [int64]$j.format.size } catch { $sizeBytes = 0 }
    }

    $fps = $null
    if ($v) {
        $fps = [string](取_对象属性值 -Obj $v -Name 'avg_frame_rate')
        if ([string]::IsNullOrWhiteSpace($fps)) { $fps = [string](取_对象属性值 -Obj $v -Name 'r_frame_rate') }
    }

    $videoBpsDeclared = $null
    $audioBpsDeclared = $null
    if ($v) {
        $vt = 取_对象属性值 -Obj $v -Name 'tags'
        $bpsTag = if ($vt) { 取_对象属性值 -Obj $vt -Name 'BPS' } else { $null }
        if ($bpsTag) { $videoBpsDeclared = 转换_码率到bps -Value ([string]$bpsTag) }
        if (-not $videoBpsDeclared) { $videoBpsDeclared = 解析_整数或空 ([string](取_对象属性值 -Obj $v -Name 'bit_rate')) }
    }
    if ($a) {
        $at = 取_对象属性值 -Obj $a -Name 'tags'
        $bpsTag = if ($at) { 取_对象属性值 -Obj $at -Name 'BPS' } else { $null }
        if ($bpsTag) { $audioBpsDeclared = 转换_码率到bps -Value ([string]$bpsTag) }
        if (-not $audioBpsDeclared) { $audioBpsDeclared = 解析_整数或空 ([string](取_对象属性值 -Obj $a -Name 'bit_rate')) }
    }

    $aBytes = $null
    $vBytes = $null
    if ($duration -gt 0 -and $v) {
        $vIndex = 解析_整数或空 ([string](取_对象属性值 -Obj $v -Name 'index'))
        $aIndex = if ($a) { 解析_整数或空 ([string](取_对象属性值 -Obj $a -Name 'index')) } else { $null }
        try {
            $sums = 取_按流序号统计包字节数 -Path $Path -StreamIndices @($vIndex, $aIndex)
            if ($null -ne $vIndex -and $sums.ContainsKey([int]$vIndex)) { $vBytes = $sums[[int]$vIndex] }
            if ($null -ne $aIndex -and $sums.ContainsKey([int]$aIndex)) { $aBytes = $sums[[int]$aIndex] }
        } catch {
            $aBytes = $null
            $vBytes = $null
            # 这里允许 ffprobe 扫包失败（不影响合并结果），但要清理 $LASTEXITCODE，避免脚本最终返回非 0。
            $global:LASTEXITCODE = 0
        }
    }

    $videoBpsEff = $null
    $audioBpsUsed = $null

    if ($duration -gt 0) {
        if ($vBytes -and $vBytes -gt 0) { $videoBpsEff = [int64]([math]::Round(($vBytes * 8.0) / $duration)) }
        if ($aBytes -and $aBytes -gt 0) { $audioBpsUsed = [int64]([math]::Round(($aBytes * 8.0) / $duration)) }
    }

    if (-not $videoBpsEff) { $videoBpsEff = $videoBpsDeclared }
    if (-not $audioBpsUsed) { $audioBpsUsed = $audioBpsDeclared }

    if ($duration -gt 0 -and $sizeBytes -gt 0 -and (-not $vBytes -or $vBytes -le 0)) {
        if ($audioBpsUsed -and $audioBpsUsed -gt 0) {
            $aBytes = [int64]([math]::Round($audioBpsUsed * $duration / 8.0))
            $vBytes = [int64]([math]::Max(0.0, ($sizeBytes - $aBytes)))
        } else {
            $vBytes = $sizeBytes
        }
        if (-not $videoBpsEff -and $vBytes -and $vBytes -gt 0) {
            $videoBpsEff = [int64]([math]::Round(($vBytes * 8.0) / $duration))
        }
    }

    $audioLang = $null
    if ($a) {
        $at = 取_对象属性值 -Obj $a -Name 'tags'
        if ($at) { $audioLang = [string](取_对象属性值 -Obj $at -Name 'language') }
    }
    $subLang = $null
    if ($s) {
        $st = 取_对象属性值 -Obj $s -Name 'tags'
        if ($st) { $subLang = [string](取_对象属性值 -Obj $st -Name 'language') }
    }

    return [pscustomobject]@{
        DurationSeconds = $duration
        SizeBytes = $sizeBytes
        VideoFps = $fps
        VideoBps = $videoBpsEff
        AudioBps = $audioBpsUsed
        VideoBytes = $vBytes
        AudioBytes = $aBytes
        SourceVideoBps = $videoBpsDeclared
        SourceAudioBps = $audioBpsDeclared
        AudioLanguage = $audioLang
        SubtitleLanguage = $subLang
    }
}

function 通过Remux写入_流标签 {
    param(
        [Parameter(Mandatory)] [string]$InputPath,
        [Parameter(Mandatory)] [string]$OutputPath,
        [int64]$VideoBps,
        [int64]$AudioBps,
        [int64]$VideoTargetBps,
        [int64]$AudioTargetBps,
        [double]$DurationSeconds,
        [string]$VideoFps,
        [int64]$VideoBytes,
        [int64]$AudioBytes,
        [string]$AudioLanguage,
        [string]$SubtitleLanguage
    )

    $outDir = Split-Path -Parent $OutputPath
    if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = (Get-Location).Path }
    $outBase = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
    $outExt = [System.IO.Path]::GetExtension($OutputPath)
    if ([string]::IsNullOrWhiteSpace($outExt)) { $outExt = '.mkv' }
    $tmp = Join-Path $outDir ("{0}.tagged.tmp{1}" -f $outBase, $outExt)

    $ffArgs = @(
        '-nostdin','-y',
        '-i', $InputPath,
        '-map_metadata','-1',
        '-map_metadata:s:v','-1',
        '-map_metadata:s:a','-1',
        '-map_metadata:s:s','-1',
        '-map','0',
        '-c','copy'
    )

    if ($VideoBps -and $VideoBps -gt 0) {
        $ffArgs += @('-metadata:s:v:0', "BPS=$VideoBps")
        $ffArgs += @('-metadata:s:v:0', "BPS-eng=$VideoBps")
    }
    if ($VideoTargetBps -and $VideoTargetBps -gt 0 -and $VideoTargetBps -ne $VideoBps) {
        $ffArgs += @('-metadata:s:v:0', "BPS_TARGET=$VideoTargetBps")
        $ffArgs += @('-metadata:s:v:0', "BPS_TARGET-eng=$VideoTargetBps")
    }
    if (-not [string]::IsNullOrWhiteSpace($VideoFps)) {
        $ffArgs += @('-metadata:s:v:0', "FPS=$VideoFps")
        $ffArgs += @('-metadata:s:v:0', "FPS-eng=$VideoFps")
    }
    if ($VideoBytes -and $VideoBytes -gt 0) {
        $ffArgs += @('-metadata:s:v:0', "NUMBER_OF_BYTES=$VideoBytes")
        $ffArgs += @('-metadata:s:v:0', "NUMBER_OF_BYTES-eng=$VideoBytes")
    }
    if ($DurationSeconds -and $DurationSeconds -gt 0) {
        $ffArgs += @('-metadata:s:v:0', ("DURATION={0:0.###}" -f [double]$DurationSeconds))
    }

    if ($AudioBps -and $AudioBps -gt 0) {
        $ffArgs += @('-metadata:s:a:0', "BPS=$AudioBps")
        $ffArgs += @('-metadata:s:a:0', "BPS-eng=$AudioBps")
    }
    if (-not [string]::IsNullOrWhiteSpace($AudioLanguage)) {
        $ffArgs += @('-metadata:s:a:0', "language=$AudioLanguage")
    }
    if ($AudioTargetBps -and $AudioTargetBps -gt 0 -and $AudioTargetBps -ne $AudioBps) {
        $ffArgs += @('-metadata:s:a:0', "BPS_TARGET=$AudioTargetBps")
        $ffArgs += @('-metadata:s:a:0', "BPS_TARGET-eng=$AudioTargetBps")
    }
    if ($AudioBytes -and $AudioBytes -gt 0) {
        $ffArgs += @('-metadata:s:a:0', "NUMBER_OF_BYTES=$AudioBytes")
        $ffArgs += @('-metadata:s:a:0', "NUMBER_OF_BYTES-eng=$AudioBytes")
    }
    if ($DurationSeconds -and $DurationSeconds -gt 0) {
        $ffArgs += @('-metadata:s:a:0', ("DURATION={0:0.###}" -f [double]$DurationSeconds))
    }

    if (-not [string]::IsNullOrWhiteSpace($SubtitleLanguage)) {
        $ffArgs += @('-metadata:s:s:0', "language=$SubtitleLanguage")
    }

    调用_外部命令 -Exe 'ffmpeg' -ArgumentList ($ffArgs + @($tmp)) | Out-Null
    Move-Item -LiteralPath $tmp -Destination $OutputPath -Force
}

function 测试_容器是否支持_字幕编码 {
    param(
        [Parameter(Mandatory)] [string]$容器扩展名,
        [AllowNull()] [string]$字幕编码
    )
    if ([string]::IsNullOrWhiteSpace($字幕编码)) { return $true }

    $ext = $容器扩展名.ToLowerInvariant()
    $codec = $字幕编码.ToLowerInvariant()
    $movFamily = @('.mp4','.m4v','.mov')

    if ($ext -in $movFamily) {
        # mp4/mov 体系：ffmpeg 仅支持 mov_text 等少数字幕；ass/subrip 都不支持内嵌。
        return ($codec -eq 'mov_text')
    }

    if ($ext -eq '.mkv') {
        # Matroska：能很好支持 ass/subrip
        return ($codec -in @('ass','subrip'))
    }

    if ($ext -eq '.webm') {
        # WebM：常见为 WebVTT；这里不尝试支持其它字幕
        return ($codec -in @('webvtt'))
    }

    return $false
}

function 测试_容器是否支持_音频编码 {
    param(
        [Parameter(Mandatory)] [string]$容器扩展名,
        [AllowNull()] [string]$音频编码
    )
    if ([string]::IsNullOrWhiteSpace($音频编码)) { return $true }

    $ext = $容器扩展名.ToLowerInvariant()
    $codec = $音频编码.ToLowerInvariant()

    $movFamily = @('.mp4','.m4v','.mov')
    if ($ext -in $movFamily) {
        # mov/mp4：常见支持 aac/alac/mp3（此处保守列举）
        return ($codec -in @('aac','alac','mp3'))
    }

    if ($ext -eq '.mkv') {
        # mkv：对音频轨支持很广；这里按本脚本可能输出的编码做白名单
        if ($codec -like 'pcm_*') { return $true }
        return ($codec -in @('aac','flac','alac','opus','vorbis','mp3'))
    }

    if ($ext -eq '.webm') {
        return ($codec -in @('opus','vorbis'))
    }

    return $false
}

function 测试_音频编码是否无损 {
    param([AllowNull()] [string]$Codec)
    if ([string]::IsNullOrWhiteSpace($Codec)) { return $false }
    $c = $Codec.ToLowerInvariant()
    if ($c -like 'pcm_*') { return $true }
    return ($c -in @('flac','alac','wavpack','truehd','mlp','tta','ape'))
}

function 测试_视频编码是否支持动态分辨率 {
    param([AllowNull()] [string]$Codec)
    if ([string]::IsNullOrWhiteSpace($Codec)) { return $false }
    $c = $Codec.ToLowerInvariant()
    return ($c -in @('h264','avc1','hevc','h265','av1','vp9'))
}

function 选择_输出容器扩展名 {
    param(
        [Parameter(Mandatory)] [string[]]$输入文件列表,
        [Parameter(Mandatory)] [bool]$存在字幕,
        [AllowNull()] [string]$目标字幕编码,
        [Parameter(Mandatory)] [bool]$用户明确指定输出文件,
        [AllowNull()] [string]$用户输出扩展名
    )

    # 容器决定优先级（高->低）：
    # 1) 若字幕编码与候选容器不兼容，则使用兼容容器
    # 2) 若用户明确指定输出文件路径，则根据扩展名推断容器
    # 3) 尽量让输出容器和所有输入一致（混合则优先 mkv）

    $known = @('.mkv','.mp4','.m4v','.mov','.webm')
    $movFamily = @('.mp4','.m4v','.mov')

    $candidate = $null

    if ($用户明确指定输出文件 -and -not [string]::IsNullOrWhiteSpace($用户输出扩展名)) {
        $uExt = $用户输出扩展名.ToLowerInvariant()
        if ($uExt -in $known) { $candidate = $uExt }
    }

    if (-not $candidate) {
        $exts = @(
            $输入文件列表 |
                ForEach-Object { [System.IO.Path]::GetExtension($_) } |
                ForEach-Object { if ([string]::IsNullOrWhiteSpace($_)) { '' } else { $_.ToLowerInvariant() } }
        )
        $knownExts = @($exts | Where-Object { $_ -in $known })
        $uniqKnown = @($knownExts | Select-Object -Unique)

        if ($knownExts.Count -eq $exts.Count -and $uniqKnown.Count -eq 1) {
            $candidate = $uniqKnown[0]
        } else {
            $allInMovFamily = ($knownExts.Count -eq $exts.Count -and (@($knownExts | Where-Object { $_ -notin $movFamily }).Count -eq 0))
            if ($allInMovFamily) {
                # 都是 mp4/m4v/mov：选出现次数最多的扩展名
                $grouped = $knownExts | Group-Object | Sort-Object Count -Descending
                $candidate = $grouped[0].Name
            } else {
                $candidate = '.mkv'
            }
        }
    }

    if ($存在字幕) {
        if (-not (测试_容器是否支持_字幕编码 -容器扩展名 $candidate -字幕编码 $目标字幕编码)) {
            return '.mkv'
        }
    }

    return $candidate
}

function 解析_输入文件列表_来自文本 {
    param([Parameter(Mandatory)] [string]$Text)

    $lines = @($Text -split "`r?`n")
    $out = New-Object System.Collections.Generic.List[string]

    foreach ($raw in $lines) {
        if ($null -eq $raw) { continue }
        $line = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*#') { continue }

        # 兼容 ffmpeg concat 列表格式：file 'path' / file "path"
        # 注意：PowerShell 里反斜杠不转义引号，所以这里用单引号字符串。
        if ($line -match '^\s*file\s+([''"])(.*)\1\s*$') {
            $p = $matches[2]
            # 兼容本脚本生成的转义形式：'\''
            $p = $p.Replace("'\''", "'")
            $p = $p.Trim()
            if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$out.Add($p) }
            continue
        }

        if ($line -match '^\s*file\s+(.+)$') {
            $p = $matches[1].Trim()
            if (($p.StartsWith('"') -and $p.EndsWith('"')) -or ($p.StartsWith("'") -and $p.EndsWith("'"))) {
                if ($p.Length -ge 2) { $p = $p.Substring(1, $p.Length - 2) }
            }
            $p = $p.Trim()
            if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$out.Add($p) }
            continue
        }

        $p2 = $line
        if (($p2.StartsWith('"') -and $p2.EndsWith('"')) -or ($p2.StartsWith("'") -and $p2.EndsWith("'"))) {
            if ($p2.Length -ge 2) { $p2 = $p2.Substring(1, $p2.Length - 2) }
        }
        $p2 = $p2.Trim()
        if (-not [string]::IsNullOrWhiteSpace($p2)) { [void]$out.Add($p2) }
    }

    return ,@($out.ToArray())
}
