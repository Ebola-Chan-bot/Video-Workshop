function 超级合并 {
    <#
    .SYNOPSIS
        按列表或剪贴板顺序合并多个视频片段，兼容时尽量无损 copy。

    .DESCRIPTION
        读取一组输入文件，按给定顺序生成一个连续输出文件。命令会先探测每段的第一个视频轨、音频轨和字幕轨，再决定走“同构快速路径”或“标准化路径”。

        如果没有显式传入 -列表文件，命令会从剪贴板读取文件列表；显式传入 -列表文件 时，会按 UTF-8 文本读取。列表支持一行一个路径、带引号路径，以及 ffmpeg concat 形式的 file '路径'；空行和以 # 开头的注释会被忽略。

        同构快速路径用于流数量相同且每个流索引位置的 codec_type/codec_name 都相同的输入。该路径会先用 mkvmerge 按真实视频包 PTS 精剪每段，再用 ffmpeg 修复 H.264 SPS/PPS 容器元数据并通过 concat demuxer 无损拼接，尽量保留所有轨道。此路径的判定依据是“轨道布局和编码名”，不会进一步比较分辨率、像素格式、帧率等参数；这些参数中途变化时能否稳定播放取决于解码器和播放器。

        标准化路径用于轨道布局不同或编码布局不一致的输入。视频、音频、字幕会分别判断：兼容则 copy，不兼容或缺失时只标准化对应部分。视频会比较编码、宽度、高度、像素格式和帧率；如果只有分辨率不同，且当前视频编码允许同一视频轨中途改变分辨率（当前按 H.264/HEVC/AV1/VP9 判断），会保留各段原分辨率并继续 copy。若视频仍需因为编码、像素格式、帧率等其它原因重编码，则按 -不兼容策略 选择统一宽高/帧率，必要时缩放并补边，编码器优先 GPU（NVENC/QSV/AMF），否则回退 CPU。音频会比较编码、采样率和声道数；不兼容或缺失时补静音并重编码，通常输出 AAC，Max 模式遇到无损音频时会优先保住无损目标。字幕会处理 ASS/SRT 互转、缺失字幕占位，以及位图字幕的限制。

        输出容器会根据用户指定扩展名、输入容器和字幕/音频兼容性选择；必要时会切换到 MKV。若用户明确指定了不匹配的扩展名，命令可能先写内部 MKV，再移动成用户指定文件名，并提示实际容器。合并完成后会尽量写入码率、时长、帧率等流标签，并修正 Matroska 的 FrameRate/DefaultDuration 元素。

    .PARAMETER 输出文件
        目标输出文件路径。默认值为 .\merged.mkv。若显式指定路径但不带扩展名，会按实际输出容器补扩展名；若显式指定了扩展名，最终文件名会尽量保持该扩展名，即使内部实际容器因兼容性改为 MKV。

    .PARAMETER 列表文件
        包含输入文件路径的 UTF-8 文本文件。显式传入时必须存在。未显式传入时，不使用参数默认值读取文件，而是从剪贴板读取路径列表。

    .PARAMETER 不兼容策略
        当无法避免重编码且宽度、高度、帧率、采样率或声道数不一致时，选择目标参数的策略。Min 选择较小值，Max 选择较大值。默认 Min。
        视频编码不一致时统一为 HEVC；像素格式不一致时统一为 yuv420p。音频不兼容时通常统一为 AAC；Max 模式且存在无损音频时，会优先选择 FLAC/ALAC 这类无损目标以避免无损源被转为有损。

    .PARAMETER 详细模式
        显示外部命令的详细输出，并保留临时工作目录，便于排查分段标准化、concat 列表和中间文件。默认会清理临时目录。

    .EXAMPLE
        超级合并 -输出文件 'D:\合集.mkv' -列表文件 'D:\要合并的文件列表.txt'

        按列表文件中的顺序合并所有片段。

    .EXAMPLE
        超级合并 'D:\合集.mkv'

        从剪贴板读取路径列表，并输出到 D:\合集.mkv。

    .EXAMPLE
        超级合并 -输出文件 'D:\合集.mkv' -列表文件 'D:\列表.txt' -不兼容策略 Max -详细模式

        在参数不一致时选择较大的目标规格，显示外部工具输出，并保留临时目录用于检查。

    .NOTES
        依赖 ffmpeg 和 ffprobe；同构快速路径还依赖 mkvmerge。命令会尝试自动检测或安装缺失依赖。输出成功不等同于所有播放器都能完美处理非常规码流，尤其是同一视频轨中途变更分辨率或参数集的文件。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$输出文件 = '.\merged.mkv',

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$列表文件 = '.\要合并的文件列表.txt',

        [Parameter(Mandatory = $false, Position = 2)]
        [ValidateSet('Min', 'Max')]
        [string]$不兼容策略 = 'Min',

        [switch]$详细模式
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:输出外部进程信息 = [bool]$详细模式
    $工作目录 = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("视频工坊_ffmpeg_concat_work_{0}" -f ([Guid]::NewGuid().ToString('N')))

    确保_ffmpeg_ffprobe_可用

    $列表文件是否显式指定 = $PSBoundParameters.ContainsKey('列表文件')

    if (-not $列表文件是否显式指定) {
        if (-not (Get-Command Get-Clipboard -ErrorAction SilentlyContinue)) {
            throw "未显式指定 -列表文件，且当前环境不支持 Get-Clipboard。请显式指定 -列表文件，或升级/启用剪贴板 cmdlet。"
        }

        $clip = Get-Clipboard -Raw
        if ([string]::IsNullOrWhiteSpace($clip)) {
            throw "未显式指定 -列表文件，但剪贴板为空（或无法读取）。请先在剪贴板中放入要合并的文件路径列表（每行一个），或显式指定 -列表文件。"
        }

        $输入文件列表 = 解析_输入文件列表_来自文本 -Text $clip
        $输入文件列表 = @($输入文件列表 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($输入文件列表.Count -lt 1) { throw "从剪贴板解析到的文件列表为空。请确保剪贴板中每行一个路径，或为 ffmpeg concat 的 'file \'...\'' 格式。" }
    } else {
        if (-not (Test-Path -LiteralPath $列表文件)) {
            throw "未找到列表文件：$列表文件"
        }

        $列表文本 = Get-Content -LiteralPath $列表文件 -Encoding UTF8 -Raw
        $输入文件列表 = 解析_输入文件列表_来自文本 -Text $列表文本
        $输入文件列表 = @($输入文件列表 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($输入文件列表.Count -lt 1) { throw "从列表文件解析到的输入文件为空：$列表文件" }
    }

    foreach ($f in $输入文件列表) { if (-not (Test-Path -LiteralPath $f)) { throw "输入文件不存在：$f" } }

    # 记录：用户是否显式传入了 -输出文件（含位置参数）。
    $用户明确指定输出文件 = $PSBoundParameters.ContainsKey('输出文件')
    $默认输出文件 = $输出文件
    $用户输出文件 = if ($用户明确指定输出文件) { $输出文件 } else { $null }

    Write-Host "探测媒体参数..." -ForegroundColor Cyan
    $媒体信息列表 = @($输入文件列表 | ForEach-Object { 获取_媒体信息 -Path $_ })

    if ((@($媒体信息列表 | Where-Object { $null -eq $_.Video })).Count -gt 0) {
        $bad = @($媒体信息列表 | Where-Object { $null -eq $_.Video } | Select-Object -ExpandProperty Path)
        throw "以下文件缺少视频轨，无法合并：`n$($bad -join "`n")"
    }

    # -------- 同构快速路径 --------
    # 如果所有输入的轨道布局完全一致（流数量相同、且每个索引位的 "codec_type:codec_name" 都相同），
    # 即看起来就是从同一原片裁出的多段，就直接 -map 0 -c copy 无损合并所有轨道，不做任何筛检/补齐/转码。
    $同构 = $false
    if ($媒体信息列表.Count -ge 1) {
        $首签名 = [string]$媒体信息列表[0].StreamSignature
        $同构 = $true
        for ($i = 1; $i -lt $媒体信息列表.Count; $i++) {
            if ([string]$媒体信息列表[$i].StreamSignature -ne $首签名) { $同构 = $false; break }
        }
    }

    if ($同构) {
        Write-Host ("检测到所有输入轨道布局相同（{0} 路流），启用同构快速路径：精剪后无损合并全部轨道。" -f $媒体信息列表[0].StreamCount) -ForegroundColor Green

        # mkvmerge 是专为 Matroska 多轨 append 设计的工具，对外部裁切工具 -ss copy 产生的 pts 异常段比 ffmpeg concat 更健壮。
        确保_mkvmerge_可用

        New-Item -ItemType Directory -Force -Path $工作目录 | Out-Null

        # mkvmerge 只能输出 MKV；若用户扩展名不是 .mkv 则先写临时 mkv，随后改名。
        $用户指定输出 = $输出文件
        $用户扩展名 = [System.IO.Path]::GetExtension($用户指定输出)
        $内部输出 = if ($用户扩展名 -and $用户扩展名.ToLowerInvariant() -eq '.mkv') {
            $用户指定输出
        } else {
            [System.IO.Path]::ChangeExtension($用户指定输出, '.mkv')
        }
        $实际输出扩展名 = '.mkv'

        # 构造 mkvmerge 参数：先用 --split parts:vStart-vEnd 对每段精确裁切出干净的临时 mkv，
        # 再用 "+" 追加合并。
        #
        # 为什么需要先裁切：外部裁切工具 -ss copy 生成的段常见问题是
        #   (a) 视频包 pts 不归零（例如起点 447s），容器 start_time/duration 与真实包范围不一致；
        #   (b) 音频 / 字幕轨可能包含超出视频范围的尾巴包；
        #   (c) 不同段之间时间戳冲突（重叠或跳跃），直接 mkvmerge --append 会触发丢包或错位。
        # mkvmerge 的 --split parts 会基于源 pts 做精确裁切，输出一个时间轴归零、容器元数据干净、
        # 各轨道对齐的新文件，然后再 append 就稳。所有信息都来自真实的视频包数据，不依赖文件名或
        # 容器元数据。
        #
        # 注意：修复容器 CodecPrivate（SPS/PPS）的步骤必须放在精剪之后执行。
        # 原因：外部裁切工具 -ss copy 产生的段里视频 pts 起点常常不为零且 B 帧 pts 乱序，
        # 若直接对原始段做 `ffmpeg -c copy -bsf:v extract_extradata` 远端复用器会因 DTS/PTS
        # 异常丢包；而经过 `mkvmerge --split parts` 精剪得到的 clip 时间轴已归零且单调，
        # 再跑 extract_extradata 就稳。
        Write-Host "探测每段视频首末包 pts（真实内容范围）..." -ForegroundColor Cyan
        $段范围 = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $媒体信息列表.Count; $i++) {
            $info = $媒体信息列表[$i]
            $pr = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @(
                '-v','error','-select_streams','v:0',
                '-show_entries','packet=pts_time',
                '-of','csv=p=0', $info.Path
            ) -CaptureOutput
            $rows = @(($pr.StdOut -split "`r?`n") | Where-Object { $_ -match '^[\d.]+' })
            if ($rows.Count -lt 1) {
                throw "第 $($i+1) 段未能读取视频包 pts：$($info.Path)"
            }
            $vStart = [double]$rows[0]
            $vEnd   = [double]$rows[-1]
            $段范围.Add([pscustomobject]@{
                Path   = $info.Path
                VStart = $vStart
                VEnd   = $vEnd
            })
            Write-Host ("  [{0}/{1}] v_pts {2:0.###}s → {3:0.###}s （内容 {4:0.###}s）" -f `
                ($i+1), $媒体信息列表.Count, $vStart, $vEnd, ($vEnd - $vStart))
        }

        # 用 mkvmerge --split parts 对每段精剪到 [vStart, vEnd+一帧]，输出到工作目录。
        # mkvmerge 的时间戳要求 HH:MM:SS.nnn 格式，纯秒数不被接受。
        $格式化时间戳 = {
            param([double]$秒)
            if ($秒 -lt 0) { $秒 = 0 }
            $h = [int][math]::Floor($秒 / 3600)
            $m = [int][math]::Floor(($秒 - $h*3600) / 60)
            $s = $秒 - $h*3600 - $m*60
            return ('{0:D2}:{1:D2}:{2:00.000}' -f $h, $m, $s)
        }
        $临时段列表 = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $段范围.Count; $i++) {
            $r = $段范围[$i]
            $tmpOut = Join-Path $工作目录 ("clip_{0:D3}.mkv" -f ($i+1))
            # 末尾加一小段余量以确保末帧被包含（mkvmerge --split parts 的 end 是开区间式截断）
            $endWithMargin = [double]$r.VEnd + 0.5
            $startStr = & $格式化时间戳 ([double]$r.VStart)
            $endStr   = & $格式化时间戳 $endWithMargin
            Write-Host ("精剪第 {0}/{1} 段: parts:{2}-{3}" -f ($i+1), $段范围.Count, $startStr, $endStr) -ForegroundColor Cyan
            # mkvmerge 约定：0=成功，1=成功但含警告（例如字幕编码不规范），2=失败。仅 2 才应视为错误。
            调用_外部命令 -Exe 'mkvmerge' -ArgumentList @(
                '-o', $tmpOut,
                '--split', ("parts:{0}-{1}" -f $startStr, $endStr),
                $r.Path
            ) -AllowedExitCodes @(1) | Out-Null
            # mkvmerge --split 以 parts 模式通常只产出一个输出（因为只有一段 parts），文件名就是我们指定的 $tmpOut。
            # 但为了稳健，若它产出了 "clip_XXX-001.mkv" 这种变体，也要纳入。
            if (-not (Test-Path -LiteralPath $tmpOut)) {
                $candidate = Get-ChildItem -LiteralPath $工作目录 -Filter ("{0}*" -f [System.IO.Path]::GetFileNameWithoutExtension($tmpOut)) -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $candidate) { throw "mkvmerge 精剪第 $($i+1) 段后未生成输出文件：$tmpOut" }
                $tmpOut = $candidate.FullName
            }
            $临时段列表.Add($tmpOut)
        }

        # 修复每个 clip 的 SPS/PPS 容器元数据（独立处理、纯 copy、不重编码）。
        # 外部裁切工具 -ss copy 产生的源段常见问题：容器 CodecPrivate（H.264 extradata）里没有有效 SPS/PPS
        # （ffprobe 解析不出 profile/pix_fmt 就是这种情形）。mkvmerge --split parts 会把源的
        # CodecPrivate 原样带到 clip 里，且 H.264 以 AVCC 格式（length-prefix）存储。
        # BSF 链：h264_mp4toannexb → 把 AVCC 转为 Annex-B（添加 0x000001 start code，使后续 BSF 可
        # 找到 SPS/PPS NALU）；extract_extradata → 从 Annex-B 码流中提取 SPS/PPS 写回容器 extradata。
        # matroska muxer 收到 Annex-B 数据时会自动转回 AVCC 写入文件。
        # 不主动归零时间戳：clip 的源 pts 可能非零（如 447s 起），但后续 concat demuxer 会基于每段
        # start_time/duration 重建连续时间戳，源 pts 偏移不影响结果。
        # 非致命：若某段 BSF 修复后仍无视频包（极少数情形），降级为直接使用原始 clip，
        # profile 可能仍为 unknown，但合并本身不中断。
        Write-Host "修复每段 clip 的 SPS/PPS 容器元数据（独立处理、纯 copy）..." -ForegroundColor Cyan
        $修复后列表 = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $临时段列表.Count; $i++) {
            $clip = $临时段列表[$i]
            $fixed = Join-Path $工作目录 ("fixed_{0:D3}.mkv" -f ($i+1))
            调用_外部命令 -Exe 'ffmpeg' -ArgumentList @(
                '-nostdin','-v','error','-y',
                '-i', $clip,
                '-map','0','-c','copy',
                '-bsf:v','h264_mp4toannexb,extract_extradata',
                $fixed
            ) | Out-Null
            # 校验：修复后的 clip 必须能读出视频包。
            $gotVideo = $false
            if (Test-Path -LiteralPath $fixed) {
                $vc = 调用_外部命令 -Exe 'ffprobe' -ArgumentList @(
                    '-v','error','-select_streams','v:0',
                    '-show_entries','packet=pts_time',
                    '-of','csv=p=0', $fixed
                ) -CaptureOutput
                $vcRows = @(($vc.StdOut -split "`r?`n") | Where-Object { $_ -match '^[\d.]+' })
                $gotVideo = ($vcRows.Count -ge 1)
            }
            if (-not $gotVideo) {
                # BSF 修复失败：降级为直接使用原始 clip（不修改 extradata）。
                Write-Warning ("第 {0} 段 extradata 修复失败，降级使用原始 clip（profile 可能为 unknown）" -f ($i+1))
                Remove-Item -LiteralPath $fixed -Force -ErrorAction SilentlyContinue
                $fixed = $clip
            }
            $修复后列表.Add($fixed)
        }

        # 最终拼接：用 ffmpeg concat demuxer 把所有已修复 extradata 的 clip 首尾相接。
        # 为什么不用 mkvmerge --append：实测 mkvmerge 在合并源 pts 非零归起的 clip 时，会残留源时间戳偏移导致输出里有空洞，播放器在空洞处卡住。改用 ffmpeg concat demuxer 把每个 clip 当独立段重建连续 pts，纯 copy。
        $concatList = Join-Path $工作目录 'concat_fixed.txt'
        $concatLines = New-Object System.Collections.Generic.List[string]
        $总视频时长 = [double]0
        for ($idx = 0; $idx -lt $修复后列表.Count; $idx++) {
            $clipPath = $修复后列表[$idx]
            $esc = ($clipPath -replace '\\','/') -replace "'","'\\''"
            $concatLines.Add("file '$esc'")
            $clipDur = $null
            try { $clipVideoRange = 获取_视频包范围 -Path $clipPath; if ($clipVideoRange) { $clipDur = [double]$clipVideoRange.DurationSeconds } } catch { $clipDur = $null; $global:LASTEXITCODE = 0 }
            if (-not $clipDur -or $clipDur -le 0) { $fallbackSpan = [double]$段范围[$idx].VEnd - [double]$段范围[$idx].VStart; $fallbackFrame = if ($媒体信息列表[$idx].Video -and $媒体信息列表[$idx].Video.Fps -and $媒体信息列表[$idx].Video.Fps -gt 0) { 1.0 / [double]$媒体信息列表[$idx].Video.Fps } else { 0.041709 }; $clipDur = [math]::Max(0.0, ($fallbackSpan + $fallbackFrame)) }
            if ($clipDur -and $clipDur -gt 0) { $durStr = $clipDur.ToString('0.000000', [System.Globalization.CultureInfo]::InvariantCulture); $concatLines.Add("duration $durStr"); $总视频时长 += $clipDur }
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($concatList, [string[]]$concatLines.ToArray(), $utf8NoBom)
        Write-Host ("开始 ffmpeg concat 合并 {0} 段精剪文件..." -f $修复后列表.Count) -ForegroundColor Cyan
        $finalConcatArgs = @('-nostdin','-v','error','-y','-f','concat','-safe','0','-i',$concatList,'-map','0','-c','copy','-map_metadata','-1','-map_metadata:s:v','-1','-map_metadata:s:a','-1','-map_metadata:s:s','-1','-map_chapters','-1','-avoid_negative_ts','make_zero')
        if ($总视频时长 -gt 0) { $总视频时长文本 = $总视频时长.ToString('0.000000', [System.Globalization.CultureInfo]::InvariantCulture); Write-Host ("按视频包累计时长裁齐全部轨道：{0}s" -f $总视频时长文本) -ForegroundColor Cyan; $finalConcatArgs += @('-t', $总视频时长文本) }
        $finalConcatArgs += @($内部输出)
        调用_外部命令 -Exe 'ffmpeg' -ArgumentList $finalConcatArgs | Out-Null
        Write-Host "完成：$内部输出" -ForegroundColor Green

        if ($内部输出 -ne $用户指定输出) {
            try {
                Move-Item -LiteralPath $内部输出 -Destination $用户指定输出 -Force
                Write-Host ("已将结果文件命名为：{0}（注意：容器实际为 {1}）" -f $用户指定输出, $实际输出扩展名) -ForegroundColor Yellow
            } catch {
                Write-Warning "移动结果文件失败：$($_.Exception.Message)"
            }
        }

        if (-not $详细模式) {
            try { Remove-Item -LiteralPath $工作目录 -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        } else {
            Write-Host "已保留临时目录：$工作目录" -ForegroundColor Yellow
        }

        $global:LASTEXITCODE = 0
        return
    }

    $存在字幕 = ((@($媒体信息列表 | Where-Object { $null -ne $_.Subtitle })).Count -gt 0)
    $全部有音轨 = ((@($媒体信息列表 | Where-Object { $null -eq $_.Audio })).Count -eq 0)

    # -------- 字幕目标格式选择（按优先级） --------
    # 位图字幕（PGS/DVD 等）无法与文本字幕互转，也无法用空字幕占位，只能要求所有段字幕一致并走 copy。
    # 1) 含位图字幕：要求所有段都有字幕且 codec 完全一致，否则抛错；目标=该位图 codec
    # 2) 任一输入包含 ass → 输出 ass
    # 3) 所有输入都是 subrip/srt → 输出 subrip
    # 4) 其它文本字幕混合 → 输出 ass
    # 5) 所有输入都不含字幕轨 → 输出也不含字幕轨
    $位图字幕编码集合 = @('hdmv_pgs_subtitle','pgssub','dvd_subtitle','dvdsub','dvb_subtitle','dvbsub','xsub')
    $目标字幕编码 = $null
    $目标字幕为位图 = $false
    if ($存在字幕) {
        $subCodecs = @($媒体信息列表 | Where-Object { $null -ne $_.Subtitle } | ForEach-Object { $_.Subtitle.Codec })
        $uniqSub = 取_非空字符串去重 -Values $subCodecs
        $含位图字幕 = @($uniqSub | Where-Object { $_ -in $位图字幕编码集合 }).Count -gt 0
        if ($含位图字幕) {
            $allHaveSub0 = ((@($媒体信息列表 | Where-Object { $null -eq $_.Subtitle })).Count -eq 0)
            if (-not $allHaveSub0) {
                throw "存在位图字幕（$($uniqSub -join ',')）但有片段缺少字幕轨，无法统一（位图字幕无法用空字幕占位）。请先为所有段准备同一种字幕，或先移除字幕轨。"
            }
            if ($uniqSub.Count -ne 1) {
                throw "字幕编码不一致：$($uniqSub -join ',')。位图字幕无法与其它编码互转，请先统一字幕格式。"
            }
            $目标字幕编码 = $uniqSub[0]
            $目标字幕为位图 = $true
        } elseif ($uniqSub -contains 'ass') {
            $目标字幕编码 = 'ass'
        } elseif ($uniqSub.Count -eq 1 -and $uniqSub[0] -in @('subrip','srt')) {
            # ffprobe 通常显示为 subrip
            $目标字幕编码 = 'subrip'
        } else {
            $目标字幕编码 = 'ass'
        }
    }

    # -------- 输出容器选择（按优先级） --------
    $用户输出扩展名 = $null
    if ($用户明确指定输出文件 -and $用户输出文件) {
        $tmpExt = [System.IO.Path]::GetExtension($用户输出文件)
        if (-not [string]::IsNullOrWhiteSpace($tmpExt)) { $用户输出扩展名 = $tmpExt.ToLowerInvariant() }
    }

    $实际输出扩展名 = 选择_输出容器扩展名 -输入文件列表 $输入文件列表 -存在字幕 $存在字幕 -目标字幕编码 $目标字幕编码 -用户明确指定输出文件 $用户明确指定输出文件 -用户输出扩展名 $用户输出扩展名

    # -------- 输出文件名规则 --------
    # 1) 用户明确指定输出文件路径：最终使用用户指定的扩展名（即便容器不同）
    # 2) 未明确指定输出路径：最终扩展名与实际输出容器一致

    $最终输出文件 = $null
    $内部输出文件 = $null

    if ($用户明确指定输出文件) {
        $finalDir = Split-Path -Parent $用户输出文件
        if ([string]::IsNullOrWhiteSpace($finalDir)) { $finalDir = (Get-Location).Path }
        $finalBase = [System.IO.Path]::GetFileNameWithoutExtension($用户输出文件)
        $finalExt = [System.IO.Path]::GetExtension($用户输出文件)
        if ([string]::IsNullOrWhiteSpace($finalExt)) {
            # 用户给了路径但没给扩展名：按实际容器补齐
            $最终输出文件 = Join-Path $finalDir ($finalBase + $实际输出扩展名)
        } else {
            $最终输出文件 = $用户输出文件
        }

        $内部输出文件 = Join-Path $finalDir ($finalBase + $实际输出扩展名)
    } else {
        $d = Split-Path -Parent $默认输出文件
        if ([string]::IsNullOrWhiteSpace($d)) { $d = (Get-Location).Path }
        $b = [System.IO.Path]::GetFileNameWithoutExtension($默认输出文件)
        $最终输出文件 = Join-Path $d ($b + $实际输出扩展名)
        $内部输出文件 = $最终输出文件
    }

    if ($内部输出文件 -ne $最终输出文件) {
        $reason = if ($存在字幕 -and -not (测试_容器是否支持_字幕编码 -容器扩展名 $用户输出扩展名 -字幕编码 $目标字幕编码)) {
            '字幕格式与用户指定容器不兼容'
        } elseif ($用户明确指定输出文件) {
            '用户扩展名推断容器（若无字幕不兼容）'
        } else {
            '输入容器不一致，优先兼容'
        }
        Write-Host ("输出容器将使用 {0}（原因：{1}）。内部输出：{2}；最终文件名：{3}" -f $实际输出扩展名, $reason, $内部输出文件, $最终输出文件) -ForegroundColor Yellow
    } else {
        Write-Host ("输出容器将使用 {0}（最终文件扩展名与容器一致）" -f $实际输出扩展名) -ForegroundColor DarkCyan
    }

    # 后续流程统一使用内部输出文件路径
    $输出文件 = $内部输出文件

    $视频编码集合 = @($媒体信息列表 | ForEach-Object { $_.Video.Codec } | Select-Object -Unique)
    $音频编码集合 = @($媒体信息列表 | ForEach-Object { if ($_.Audio) { $_.Audio.Codec } else { $null } } | Select-Object -Unique)

    # ---- 逐参数兼容性判定（兼容就保留；不兼容才选“最小值”作为输出标准化参数） ----

    $视频宽度值集合  = @($媒体信息列表 | ForEach-Object { $_.Video.Width })
    $视频高度值集合 = @($媒体信息列表 | ForEach-Object { $_.Video.Height })
    $视频分辨率值集合 = @($媒体信息列表 | ForEach-Object { if ($_.Video -and $null -ne $_.Video.Width -and $null -ne $_.Video.Height) { ("{0}x{1}" -f $_.Video.Width, $_.Video.Height) } else { 'N/A' } })
    $视频像素格式值集合 = @($媒体信息列表 | ForEach-Object { $_.Video.PixFmt })
    $视频帧率原始值集合 = @($媒体信息列表 | ForEach-Object { $_.Video.FpsRaw })
    $视频帧率数值集合 = @($媒体信息列表 | ForEach-Object { $_.Video.Fps })

    $音频采样率值集合 = @($媒体信息列表 | ForEach-Object { if ($_.Audio) { $_.Audio.SampleRate } else { $null } })
    $音频声道数值集合   = @($媒体信息列表 | ForEach-Object { if ($_.Audio) { $_.Audio.Channels } else { $null } })

    $唯一视频编码 = @($视频编码集合 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $唯一视频宽度   = @($视频宽度值集合  | Where-Object { $null -ne $_ } | Select-Object -Unique)
    $唯一视频高度  = @($视频高度值集合 | Where-Object { $null -ne $_ } | Select-Object -Unique)
    $唯一视频像素格式  = 取_非空字符串去重 -Values $视频像素格式值集合
    $唯一视频帧率原始  = 取_非空字符串去重 -Values $视频帧率原始值集合

    $视频编码兼容  = ($唯一视频编码.Count -eq 1)
    $视频宽度兼容  = ($唯一视频宽度.Count -eq 1)
    $视频高度兼容 = ($唯一视频高度.Count -eq 1)
    $视频像素格式兼容 = ($唯一视频像素格式.Count -eq 1)
    $视频帧率兼容    = ($唯一视频帧率原始.Count -eq 1)

    $视频分辨率兼容 = ($视频宽度兼容 -and $视频高度兼容)
    $视频分辨率可动态变更 = $false
    if ((-not $视频分辨率兼容) -and $视频编码兼容 -and $唯一视频编码.Count -eq 1) {
        $视频分辨率可动态变更 = 测试_视频编码是否支持动态分辨率 -Codec $唯一视频编码[0]
    }

    $视频可直接拷贝 = ($视频编码兼容 -and ($视频分辨率兼容 -or $视频分辨率可动态变更) -and $视频像素格式兼容 -and $视频帧率兼容)

    $audioCodecCompatible = $false
    $audioSrCompatible = $false
    $audioChCompatible = $false
    $canCopyAudio = $false

    if ($全部有音轨) {
        $uniqACodec = @($音频编码集合 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $uniqASr = @($音频采样率值集合 | Where-Object { $null -ne $_ } | Select-Object -Unique)
        $uniqACh = @($音频声道数值集合   | Where-Object { $null -ne $_ } | Select-Object -Unique)

        $audioCodecCompatible = ($uniqACodec.Count -eq 1)
        $audioSrCompatible    = ($uniqASr.Count -eq 1)
        $audioChCompatible    = ($uniqACh.Count -eq 1)
        $canCopyAudio         = ($audioCodecCompatible -and $audioSrCompatible -and $audioChCompatible)
    }

    # 目标输出参数：兼容→保留（取首个）；不兼容→统一为 hevc（无论 Min/Max）
    $目标视频编码 = if ($视频编码兼容) { $唯一视频编码[0] } else { 'hevc' }
    $目标视频宽度 = if ($视频宽度兼容) { [int64]$视频宽度值集合[0] } else { [int64](取_极值或空 -Values $视频宽度值集合 -Mode $不兼容策略) }
    $目标视频高度 = if ($视频高度兼容) { [int64]$视频高度值集合[0] } else { [int64](取_极值或空 -Values $视频高度值集合 -Mode $不兼容策略) }

    $目标视频帧率数值 = if ($视频帧率兼容) {
        [double]($视频帧率数值集合 | Where-Object { $null -ne $_ } | Select-Object -First 1)
    } else {
        [double](取_极值或空 -Values $视频帧率数值集合 -Mode $不兼容策略)
    }
    if (-not $目标视频帧率数值 -or $目标视频帧率数值 -le 0) { $目标视频帧率数值 = 24 }

    $目标视频像素格式 = if ($视频像素格式兼容) { $唯一视频像素格式[0] } else { 'yuv420p' }

    $目标音频采样率 = if ($audioSrCompatible) {
        [int64]($音频采样率值集合 | Where-Object { $null -ne $_ } | Select-Object -First 1)
    } else {
        [int64](取_极值或空 -Values $音频采样率值集合 -Mode $不兼容策略)
    }
    if (-not $目标音频采样率 -or $目标音频采样率 -le 0) { $目标音频采样率 = 48000 }

    $目标音频声道数 = if ($audioChCompatible) {
        [int64]($音频声道数值集合 | Where-Object { $null -ne $_ } | Select-Object -First 1)
    } else {
        [int64](取_极值或空 -Values $音频声道数值集合 -Mode $不兼容策略)
    }
    if (-not $目标音频声道数 -or $目标音频声道数 -le 0) { $目标音频声道数 = 2 }

    # 目标音频编码：若全体音频参数兼容则保留原编码；否则统一到 aac
    $存在无损输入音频 = $false
    if ($全部有音轨) {
        $allAudioCodecs = @($媒体信息列表 | ForEach-Object { if ($_.Audio) { $_.Audio.Codec } else { $null } })
        $allAudioNonEmpty = @($allAudioCodecs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($allAudioNonEmpty.Count -eq $媒体信息列表.Count) {
            $lossless = @($allAudioNonEmpty | Where-Object { 测试_音频编码是否无损 -Codec $_ })
            $存在无损输入音频 = ($lossless.Count -gt 0)
        }
    }

    $目标音频编码 = if ($全部有音轨 -and $audioCodecCompatible -and $audioSrCompatible -and $audioChCompatible) {
        $uniqACodec[0]
    } else {
        if ($不兼容策略 -eq 'Max' -and $存在无损输入音频) {
            # Max 模式：只要存在无损输入且需要重编码（参数不兼容），则确保无损输入片段不会被转为有损。
            # 由于 concat 要求所有分段音频编码一致，这里选择无损目标编码（会导致有损输入也被转为无损封装，但不会进一步损失）。
            # 若全体 codec 已一致且为 flac/alac，则沿用；否则优先 flac（通用、压缩比好）。
            $uniqLosslessCodec = @(
                @($媒体信息列表 | ForEach-Object { if ($_.Audio) { $_.Audio.Codec } else { $null } }) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { $_.ToLowerInvariant() } |
                    Select-Object -Unique
            )
            if ($uniqLosslessCodec.Count -eq 1 -and $uniqLosslessCodec[0] -in @('flac','alac')) {
                $uniqLosslessCodec[0]
            } else {
                'flac'
            }
        } else {
            'aac'
        }
    }

    # bitrate 不是 concat copy 的兼容性参数；转码时优先“每段沿用该段输入码率”，全局 Min/Max 仅作为兜底。
    $全局备用视频码率 = 取_极值或空 -Values ($媒体信息列表 | ForEach-Object { $_.Video.BitRate }) -Mode $不兼容策略
    $全局备用音频码率 = 取_极值或空 -Values ($媒体信息列表 | ForEach-Object { if ($_.Audio) { $_.Audio.BitRate } else { $null } }) -Mode $不兼容策略

    # 仅在“需要重新编码视频”时使用：一律优先选择可用 GPU 编码器（NVENC/QSV/AMF）
    $选定视频编码器 = 选择_视频编码器 -目标视频编码 $目标视频编码
    $转码视频编码器名 = [string]$选定视频编码器.Encoder

    $需要标准化视频 = -not $视频可直接拷贝
    $需要标准化音频 = -not $canCopyAudio

    # Max 模式无损音频输出可能与容器不兼容（例如 mp4 不支持 flac）。此处确保“实际容器”可承载目标音频/字幕。
    $容器需要修正 = $false
    if ($存在字幕 -and (-not (测试_容器是否支持_字幕编码 -容器扩展名 $实际输出扩展名 -字幕编码 $目标字幕编码))) { $容器需要修正 = $true }
    if (-not (测试_容器是否支持_音频编码 -容器扩展名 $实际输出扩展名 -音频编码 $目标音频编码)) { $容器需要修正 = $true }

    if ($容器需要修正 -and $实际输出扩展名 -ne '.mkv') {
        $oldExt = $实际输出扩展名
        $实际输出扩展名 = '.mkv'

        # 重新计算输出文件名（规则不变：用户指定扩展名时最终仍保持用户扩展名，仅内部容器改为 mkv）
        if ($用户明确指定输出文件) {
            $finalDir = Split-Path -Parent $用户输出文件
            if ([string]::IsNullOrWhiteSpace($finalDir)) { $finalDir = (Get-Location).Path }
            $finalBase = [System.IO.Path]::GetFileNameWithoutExtension($用户输出文件)
            $finalExt = [System.IO.Path]::GetExtension($用户输出文件)
            if ([string]::IsNullOrWhiteSpace($finalExt)) {
                $最终输出文件 = Join-Path $finalDir ($finalBase + $实际输出扩展名)
            } else {
                $最终输出文件 = $用户输出文件
            }
            $内部输出文件 = Join-Path $finalDir ($finalBase + $实际输出扩展名)
        } else {
            $d = Split-Path -Parent $默认输出文件
            if ([string]::IsNullOrWhiteSpace($d)) { $d = (Get-Location).Path }
            $b = [System.IO.Path]::GetFileNameWithoutExtension($默认输出文件)
            $最终输出文件 = Join-Path $d ($b + $实际输出扩展名)
            $内部输出文件 = $最终输出文件
        }

        $输出文件 = $内部输出文件

        Write-Host ("检测到目标音频/字幕与容器 {0} 不兼容，已将实际输出容器切换为 {1}（最终扩展名规则不变）" -f $oldExt, $实际输出扩展名) -ForegroundColor Yellow
    }

    # 字幕规则（按目标字幕编码）：
    $subtitleCopyPossible = $false
    if ($存在字幕) {
        if ($目标字幕为位图) {
            # 位图字幕在外部裁切工具已强制要求全部相同，必然可 copy
            $subtitleCopyPossible = $true
        } else {
            $allHaveSubtitle = ((@($媒体信息列表 | Where-Object { $null -eq $_.Subtitle })).Count -eq 0)
            if ($allHaveSubtitle) {
                $subCodecsAll = @($媒体信息列表 | ForEach-Object { if ($_.Subtitle) { $_.Subtitle.Codec } else { $null } })
                $uniqSubAll = 取_非空字符串去重 -Values $subCodecsAll
                if ($uniqSubAll.Count -eq 1) {
                    $c = $uniqSubAll[0]
                    if ($目标字幕编码 -eq 'ass' -and $c -eq 'ass') { $subtitleCopyPossible = $true }
                    if ($目标字幕编码 -eq 'subrip' -and ($c -in @('subrip','srt'))) { $subtitleCopyPossible = $true }
                }
            }
        }
    }
    $需要转码字幕 = ($存在字幕 -and (-not $subtitleCopyPossible))

    $选取词 = if ($不兼容策略 -eq 'Max') { '最大' } else { '最小' }

    Write-Host "兼容性判定：" -ForegroundColor Cyan
    $视频兼容性摘要 = if ($视频可直接拷贝) {
        if ($视频分辨率可动态变更 -and (-not $视频分辨率兼容)) { "兼容→保留各段原视频参数（copy，动态分辨率）" } else { "兼容→保留原编码/参数（copy）" }
    } else {
        "不兼容→仅标准化不兼容参数"
    }
    Write-Host ("- 视频：" + $视频兼容性摘要)
    Write-Host ("- 音频：" + $(if ($canCopyAudio) { "兼容→保留原编码/参数（copy）" } else { "不兼容/缺失→仅标准化不兼容参数" }))
    if ($存在字幕) {
        $subMsg = if ($目标字幕编码 -eq 'ass') { 'ASS' } elseif ($目标字幕编码 -eq 'subrip') { 'SRT' } else { $目标字幕编码 }
        Write-Host ("- 字幕：" + $(if ($subtitleCopyPossible) { "全部为 $subMsg→copy" } else { "统一转为 $subMsg（含补空字幕）" }))
    }

    if (-not $视频分辨率兼容) {
        $codecText = if ($视频编码兼容 -and $唯一视频编码.Count -eq 1) { $唯一视频编码[0] } else { '当前编码组合' }
        if ($视频分辨率可动态变更 -and $视频可直接拷贝) {
            Write-Host ("视频分辨率不一致：{0}；{1} 支持动态分辨率 -> 保留各段原分辨率（copy）" -f (格式化_值列表 -Values $视频分辨率值集合), $codecText) -ForegroundColor Yellow
        } elseif ($视频分辨率可动态变更) {
            Write-Host ("视频分辨率不一致：{0}；{1} 支持动态分辨率，但视频仍需因其它参数重编码 -> 选择{2}：{3}x{4}" -f (格式化_值列表 -Values $视频分辨率值集合), $codecText, $选取词, $目标视频宽度, $目标视频高度) -ForegroundColor Yellow
        } else {
            Write-Host ("视频分辨率不兼容：{0} -> 选择{1}：{2}x{3}" -f (格式化_值列表 -Values $视频分辨率值集合), $选取词, $目标视频宽度, $目标视频高度) -ForegroundColor Yellow
        }
    }
    if (-not $视频帧率兼容) {
        Write-Host ("视频帧率不兼容：" + (格式化_值列表 -Values $视频帧率原始值集合) + (" -> 选择{0}：{1:0.###}" -f $选取词, $目标视频帧率数值)) -ForegroundColor Yellow
    }
    if (-not $视频像素格式兼容) {
        Write-Host ("视频像素格式不兼容：" + (格式化_值列表 -Values $视频像素格式值集合) + " -> 选择：$目标视频像素格式") -ForegroundColor Yellow
    }
    if (-not $视频编码兼容) {
        Write-Host ("视频编码不兼容：" + (格式化_值列表 -Values ($媒体信息列表 | ForEach-Object { $_.Video.Codec })) + " -> 输出编码：$转码视频编码器名") -ForegroundColor Yellow
    }

    if (-not $全部有音轨) {
        Write-Host "存在缺失音轨：将补静音并按目标采样率/声道标准化" -ForegroundColor Yellow
    }
    if ($全部有音轨 -and (-not $audioCodecCompatible)) {
        Write-Host ("音频编码不兼容：" + (格式化_值列表 -Values ($媒体信息列表 | ForEach-Object { $_.Audio.Codec })) + " -> 输出编码：$目标音频编码") -ForegroundColor Yellow
    }
    if ($全部有音轨 -and (-not $audioSrCompatible)) {
        Write-Host ("音频采样率不兼容：" + (格式化_值列表 -Values $音频采样率值集合) + (" -> 选择{0}：{1}" -f $选取词, $目标音频采样率)) -ForegroundColor Yellow
    }
    if ($全部有音轨 -and (-not $audioChCompatible)) {
        Write-Host ("音频声道数不兼容：" + (格式化_值列表 -Values $音频声道数值集合) + (" -> 选择{0}：{1}" -f $选取词, $目标音频声道数)) -ForegroundColor Yellow
    }

    $targetVideoBps = $null
    $targetAudioBps = $null

    # 由于现在可能“每段目标码率不同”，这里用时长加权平均生成 BPS_TARGET（用于输出文件 tags）。
    $videoTargetSum = [double]0
    $videoTargetDur = [double]0
    $audioTargetSum = [double]0
    $audioTargetDur = [double]0

    New-Item -ItemType Directory -Force -Path $工作目录 | Out-Null
    $分段目录 = Join-Path $工作目录 'segments'
    $辅助目录 = Join-Path $工作目录 'aux'
    New-Item -ItemType Directory -Force -Path $分段目录 | Out-Null
    New-Item -ItemType Directory -Force -Path $辅助目录 | Out-Null

    Write-Host "标准化分段文件（用于兼容 concat）..." -ForegroundColor Cyan
    Write-Host ("策略：兼容就 copy；不兼容只标准化对应参数（视频/音频/字幕分别决策）")

    $segPaths = @()

    for ($i = 0; $i -lt $媒体信息列表.Count; $i++) {
        $info = $媒体信息列表[$i]
        $inPath = $info.Path
        $index = $i + 1
        $segOut = Join-Path $分段目录 ("seg_{0:0000}.mkv" -f $index)

        $segmentDuration = [double]$info.Duration

        $inputArgs = @('-nostdin','-stats','-i', $inPath)
        $outputArgs = @('-map','0:v:0')
        $nextInputIndex = 1

        if ($null -ne $info.Audio) {
            $outputArgs += @('-map','0:a:0')
        } else {
            $audioInputIndex = $nextInputIndex
            $inputArgs += @('-f','lavfi','-t', ([string]$segmentDuration), '-i', ("anullsrc=r={0}:cl=stereo" -f $目标音频采样率))
            $nextInputIndex++
            $outputArgs += @('-map', ("{0}:a:0" -f $audioInputIndex))
        }

        if ($存在字幕) {
            if ($null -ne $info.Subtitle) {
                $outputArgs += @('-map','0:s:0')
            } else {
                if ($目标字幕编码 -eq 'subrip') {
                    $blank = Join-Path $辅助目录 ("blank_{0:0000}.srt" -f $index)
                    写入_空白SRT -Path $blank -DurationSeconds $segmentDuration
                    $subInputIndex = $nextInputIndex
                    $inputArgs += @('-f','srt','-i', $blank)
                    $nextInputIndex++
                    $outputArgs += @('-map', ("{0}:s:0" -f $subInputIndex))
                } else {
                    $blank = Join-Path $辅助目录 ("blank_{0:0000}.ass" -f $index)
                    写入_空白ASS -Path $blank -DurationSeconds $segmentDuration
                    $subInputIndex = $nextInputIndex
                    $inputArgs += @('-f','ass','-i', $blank)
                    $nextInputIndex++
                    $outputArgs += @('-map', ("{0}:s:0" -f $subInputIndex))
                }
            }
        }

        # ---- 视频：能 copy 就 copy；否则仅为“本段不符合目标参数”的片段做标准化 ----
        $本段视频已符合目标 = $true
        if ($null -eq $info.Video) { $本段视频已符合目标 = $false }
        if ($本段视频已符合目标 -and (-not [string]::IsNullOrWhiteSpace($目标视频编码)) -and ($info.Video.Codec -ne $目标视频编码)) { $本段视频已符合目标 = $false }
        if ($本段视频已符合目标 -and ($info.Video.Width -ne $目标视频宽度)) { $本段视频已符合目标 = $false }
        if ($本段视频已符合目标 -and ($info.Video.Height -ne $目标视频高度)) { $本段视频已符合目标 = $false }
        if ($本段视频已符合目标 -and (-not [string]::IsNullOrWhiteSpace($目标视频像素格式)) -and ($info.Video.PixFmt -ne $目标视频像素格式)) { $本段视频已符合目标 = $false }
        if ($本段视频已符合目标) {
            $fpsNow = [double]$info.Video.Fps
            if (-not $fpsNow -or $fpsNow -le 0) { $本段视频已符合目标 = $false }
            elseif ([math]::Abs($fpsNow - [double]$目标视频帧率数值) -gt 0.0001) { $本段视频已符合目标 = $false }
        }

        $本段需要标准化视频 = ($需要标准化视频 -and (-not $本段视频已符合目标))

        if ($本段需要标准化视频) {
            $vfParts = @()
            if (-not ($视频宽度兼容 -and $视频高度兼容)) {
                $vfParts += ("scale=w={0}:h={1}:force_original_aspect_ratio=decrease,pad={0}:{1}:(ow-iw)/2:(oh-ih)/2" -f $目标视频宽度, $目标视频高度)
            }
            if (-not $视频帧率兼容) {
                $vfParts += ("fps={0:0.###}" -f [double]$目标视频帧率数值)
            }

            # 需要重新编码时：优先使用 GPU（若可用），否则回退 CPU
            $vEnc = $转码视频编码器名
            $outputArgs += @('-c:v', $vEnc)

            if ($vEnc -eq 'libx264') {
                $outputArgs += @('-preset','veryfast','-crf','23')
            } elseif ($vEnc -eq 'libx265') {
                # hevc 的 CRF 经验值通常更高一些
                $outputArgs += @('-preset','medium','-crf','28')
            } elseif ($vEnc -like '*_nvenc') {
                # NVENC：默认用 CQ（类 CRF）；若指定了目标码率则使用 VBR
                $outputArgs += @('-preset','p5')
            } elseif ($vEnc -like '*_qsv') {
                # QSV：默认用 global_quality；若指定码率则直接按码率控制
                # （不强加 preset 参数，避免不同版本 ffmpeg 行为差异）
            } elseif ($vEnc -like '*_amf') {
                # AMF：默认用 CQP；若指定码率则按码率控制
            }

            # 尽量保留兼容的像素格式；否则回退 yuv420p
            $pix = $目标视频像素格式
            $supportedPix = @('yuv420p','yuv420p10le')
            if ([string]::IsNullOrWhiteSpace($pix) -or ($supportedPix -notcontains $pix)) {
                $pix = 'yuv420p'
            }
            $outputArgs += @('-pix_fmt', $pix)

            if ($vfParts.Count -gt 0) { $outputArgs += @('-vf', ($vfParts -join ',')) }

            $本段视频目标码率 = $info.Video.BitRate
            if (-not $本段视频目标码率 -or $本段视频目标码率 -le 0) {
                try {
                    $est = 获取_媒体码率估算 -Path $inPath
                    if ($est -and $est.VideoBps -and $est.VideoBps -gt 0) { $本段视频目标码率 = [int64]$est.VideoBps }
                } catch {
                    $global:LASTEXITCODE = 0
                }
            }
            if (-not $本段视频目标码率 -or $本段视频目标码率 -le 0) {
                $本段视频目标码率 = $全局备用视频码率
            }

            # 简单合理性钳制，避免异常值影响编码器
            if ($本段视频目标码率 -and $本段视频目标码率 -gt 0) {
                $minV = [int64]100000
                $maxV = [int64]200000000
                if ($本段视频目标码率 -lt $minV) { $本段视频目标码率 = $minV }
                if ($本段视频目标码率 -gt $maxV) { $本段视频目标码率 = $maxV }
            }

            if ($null -ne $本段视频目标码率 -and $本段视频目标码率 -gt 0) {
                $maxrate = [int64]$本段视频目标码率
                $buf = [int64]($maxrate * 2)
                # 统一用 bitrate 约束（不同编码器都支持 -b:v/-maxrate/-bufsize）
                $outputArgs += @('-b:v', "$maxrate", '-maxrate', "$maxrate", '-bufsize', "$buf")
                if ($vEnc -like '*_nvenc') {
                    $outputArgs += @('-rc','vbr')
                }

                if ($segmentDuration -gt 0) {
                    $videoTargetSum += ([double]$maxrate * [double]$segmentDuration)
                    $videoTargetDur += [double]$segmentDuration
                }
            } else {
                # 未能从输入探测到码率：改用“质量模式”的默认参数
                if ($vEnc -like '*_nvenc') {
                    $outputArgs += @('-rc','vbr','-cq','23')
                } elseif ($vEnc -like '*_qsv') {
                    $outputArgs += @('-global_quality','23')
                } elseif ($vEnc -like '*_amf') {
                    $outputArgs += @('-rc','cqp','-qp_i','23','-qp_p','23','-qp_b','23')
                }
            }
        } else {
            $outputArgs += @('-c:v','copy')
        }

        # ---- 音频：能 copy 就 copy；否则仅为“本段不符合目标参数”的片段做标准化（含缺失补静音） ----
        $segmentHasAudio = ($null -ne $info.Audio)
        $本段音频已符合目标 = $segmentHasAudio
        if ($本段音频已符合目标 -and (-not [string]::IsNullOrWhiteSpace($目标音频编码)) -and ($info.Audio.Codec -ne $目标音频编码)) { $本段音频已符合目标 = $false }
        if ($本段音频已符合目标 -and ($info.Audio.SampleRate -ne $目标音频采样率)) { $本段音频已符合目标 = $false }
        if ($本段音频已符合目标 -and ($info.Audio.Channels -ne $目标音频声道数)) { $本段音频已符合目标 = $false }

        $本段需要标准化音频 = ((-not $segmentHasAudio) -or ($需要标准化音频 -and (-not $本段音频已符合目标)))

        if ($本段需要标准化音频) {
            $outputArgs += @('-c:a', $目标音频编码, '-ar', "$目标音频采样率", '-ac', "$目标音频声道数")
            if ($目标音频编码 -eq 'aac') {
                $本段音频目标码率 = if ($info.Audio) { $info.Audio.BitRate } else { $null }
                if (-not $本段音频目标码率 -or $本段音频目标码率 -le 0) {
                    try {
                        $est = 获取_媒体码率估算 -Path $inPath
                        if ($est -and $est.AudioBps -and $est.AudioBps -gt 0) { $本段音频目标码率 = [int64]$est.AudioBps }
                    } catch {
                        $global:LASTEXITCODE = 0
                    }
                }
                if (-not $本段音频目标码率 -or $本段音频目标码率 -le 0) {
                    $本段音频目标码率 = $全局备用音频码率
                }

                if ($本段音频目标码率 -and $本段音频目标码率 -gt 0) {
                    $minA = [int64]64000
                    $maxA = [int64]512000
                    if ($本段音频目标码率 -lt $minA) { $本段音频目标码率 = $minA }
                    if ($本段音频目标码率 -gt $maxA) { $本段音频目标码率 = $maxA }
                }

                if ($null -ne $本段音频目标码率 -and $本段音频目标码率 -gt 0) {
                    $abr = [int64]$本段音频目标码率
                    $outputArgs += @('-b:a', "$abr")
                    if ($segmentDuration -gt 0) {
                        $audioTargetSum += ([double]$abr * [double]$segmentDuration)
                        $audioTargetDur += [double]$segmentDuration
                    }
                } else {
                    $outputArgs += @('-b:a','128k')
                    if ($segmentDuration -gt 0) {
                        $audioTargetSum += (128000.0 * [double]$segmentDuration)
                        $audioTargetDur += [double]$segmentDuration
                    }
                }
            }
        } else {
            $outputArgs += @('-c:a','copy')
        }

        # ---- 字幕：全部 ass 且都有字幕 → copy；否则统一 ass（含补空字幕） ----
        if ($存在字幕) {
            if ($需要转码字幕) {
                if ($目标字幕编码 -eq 'subrip') {
                    $outputArgs += @('-c:s','subrip')
                } else {
                    $outputArgs += @('-c:s','ass')
                }
            } else {
                $outputArgs += @('-c:s','copy')
            }
        }

        # 强制每段 pts 归零：外部裁切工具裁切工具若未重置时间戳，段内包 pts 可能仍是原片绝对时间，
        # 会导致 concat demuxer 按末尾 pts 计算时长，把输出撑到原片级别时长。
        # +genpts 允许在缺失 pts 时重建；make_zero 把最小 pts 偏移到 0。
        $outputArgs += @('-fflags','+genpts','-avoid_negative_ts','make_zero')

        $outputArgs += @('-y', $segOut)

        Write-Host ("[{0}/{1}] {2}" -f $index, $媒体信息列表.Count, (Split-Path -Leaf $inPath))
        调用_外部命令 -Exe 'ffmpeg' -ArgumentList @($inputArgs + $outputArgs) | Out-Null

        $segPaths += ([System.IO.Path]::GetFullPath($segOut))
    }

    Write-Host "生成 concat 列表并合并..." -ForegroundColor Cyan
    $concatList = Join-Path $工作目录 'concat_list.txt'
    $lines = foreach ($p in $segPaths) { "file '$(转义_ConCat路径 -Path $p)'" }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($concatList, $lines, $utf8NoBom)


    $finalArgs = @('-nostdin','-stats','-f','concat','-safe','0','-i',$concatList,'-map','0:v:0','-map','0:a:0')
    if ($存在字幕) { $finalArgs += @('-map','0:s:0') }
    $finalArgs += @('-c','copy','-y',$输出文件)

    调用_外部命令 -Exe 'ffmpeg' -ArgumentList $finalArgs | Out-Null
    Write-Host "完成：$输出文件" -ForegroundColor Green

    if ($videoTargetDur -gt 0) { $targetVideoBps = [int64]([math]::Round($videoTargetSum / $videoTargetDur)) }
    if ($audioTargetDur -gt 0) { $targetAudioBps = [int64]([math]::Round($audioTargetSum / $audioTargetDur)) }

    try {
        $pd = 获取_输出探测数据_快速 -Path $输出文件
        $fpsStr = [string]$pd.VideoFps

        try {
            通过Remux写入_流标签 -InputPath $输出文件 -OutputPath $输出文件 `
                -VideoBps $pd.VideoBps -AudioBps $pd.AudioBps -VideoTargetBps $targetVideoBps -AudioTargetBps $targetAudioBps -DurationSeconds $pd.DurationSeconds -VideoFps $fpsStr -VideoBytes $pd.VideoBytes -AudioBytes $pd.AudioBytes `
                -AudioLanguage $pd.AudioLanguage -SubtitleLanguage $pd.SubtitleLanguage
        } catch {
            Write-Warning "写入 stream tags 失败（不影响合并结果）：$($_.Exception.Message)"
        }

        if (-not [string]::IsNullOrWhiteSpace($fpsStr)) {
            try { 尝试_修正Matroska_FrameRate元素 -Path $输出文件 -Fps $fpsStr | Out-Null } catch { Write-Warning "修正 Matroska FrameRate 失败：$($_.Exception.Message)" }
            try { 尝试_修正Matroska_DefaultDuration -Path $输出文件 -Fps $fpsStr | Out-Null } catch { Write-Warning "修正 Matroska DefaultDuration 失败：$($_.Exception.Message)" }
        }
    } catch {
        Write-Warning "写入输出文件元数据失败（不影响合并结果）：$($_.Exception.Message)"
    }

    # 若内部输出文件与用户指定输出文件不同：最终移动成用户指定的文件名（扩展名保持用户要求）。
    if ($输出文件 -ne $最终输出文件) {
        try {
            Move-Item -LiteralPath $输出文件 -Destination $最终输出文件 -Force
            $输出文件 = $最终输出文件
            Write-Host ("已将结果文件命名为：{0}（注意：容器实际为 {1}）" -f $输出文件, $实际输出扩展名) -ForegroundColor Yellow
        } catch {
            Write-Warning "移动结果文件失败：$($_.Exception.Message)"
        }
    }

    if (-not $详细模式) {
        try { Remove-Item -LiteralPath $工作目录 -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    } else {
        Write-Host "已保留临时目录：$工作目录" -ForegroundColor Yellow
    }

    # 防止中途某次外部命令失败被捕获后遗留 $LASTEXITCODE，导致 powershell.exe 进程退出码非 0。
    $global:LASTEXITCODE = 0
}
