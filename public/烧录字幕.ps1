function 烧录字幕 {
    <#
    .SYNOPSIS
        将输入文件的第一个字幕轨硬烧到第一个视频轨。

    .DESCRIPTION
        使用 ffmpeg 读取输入媒体流，选取第一个视频轨和第一个字幕轨生成硬字幕视频。

        文本字幕会通过 subtitles 滤镜渲染；位图字幕（DVD/PGS/DVB/XSub）会先缩放到视频尺寸，再通过 overlay 叠加。
        输出中的视频轨一定会重新编码为 HEVC：优先使用 hevc_nvenc（CQ 23），不可用时回退到 libx265（CRF 23、medium）。

        除原第一个视频轨和被烧录的第一个字幕轨外，其它轨道会按原顺序复制到输出文件，例如音频轨、其它字幕轨等。
        如果未指定输出路径，会在输入文件同目录生成“原文件名_烧录字幕 + 原扩展名”。输出文件已存在时会被覆盖。

        输入文件必须至少包含一个视频轨和一个字幕轨；缺少任一轨道时命令会报错。

    .PARAMETER 输入文件
        要处理的媒体文件路径。命令会通过 ffprobe 探测轨道，并要求该文件存在且包含视频轨和字幕轨。

    .PARAMETER 输出文件
        输出文件路径。省略时使用输入文件所在目录，并将文件名追加“_烧录字幕”。扩展名沿用输入文件扩展名。

    .EXAMPLE
        烧录字幕 -输入文件 'D:\电影.mkv'

        将 D:\电影.mkv 的第一个字幕轨烧录进第一个视频轨，输出 D:\电影_烧录字幕.mkv。

    .EXAMPLE
        烧录字幕 -输入文件 'D:\电影.mkv' -输出文件 'D:\电影.hardsub.mkv'

        使用指定路径保存硬字幕版本。

    .NOTES
        依赖 ffmpeg 和 ffprobe。命令会尝试自动检测或安装依赖；实际字幕渲染效果取决于 ffmpeg 构建、字体环境和字幕格式。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
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

    if (-not (Test-Path -LiteralPath $输入文件)) {
        throw "文件不存在: $输入文件"
    }

    if (-not $输出文件) {
        $目录 = [IO.Path]::GetDirectoryName($输入文件)
        $文件名 = [IO.Path]::GetFileNameWithoutExtension($输入文件)
        $扩展名 = [IO.Path]::GetExtension($输入文件)
        $输出文件 = [IO.Path]::Combine($目录, "${文件名}_烧录字幕${扩展名}")
    }

    $探测结果 = 获取_媒体流探测数据 -Path $输入文件
    $全部轨道 = @($探测结果.streams)

    $视频轨列表 = @($全部轨道 | Where-Object codec_type -eq 'video')
    $字幕轨列表 = @($全部轨道 | Where-Object codec_type -eq 'subtitle')

    if ($视频轨列表.Count -eq 0) { throw '输入文件没有视频轨' }
    if ($字幕轨列表.Count -eq 0) { throw '输入文件没有字幕轨' }

    $视频轨 = $视频轨列表[0]
    $字幕轨 = $字幕轨列表[0]
    $视频序号 = [int]$视频轨.index
    $字幕序号 = [int]$字幕轨.index
    $字幕编码 = [string]$字幕轨.codec_name
    $视频宽 = [int]$视频轨.width
    $视频高 = [int]$视频轨.height

    Write-Host "视频轨 #$视频序号 : $($视频轨.codec_name) ${视频宽}x${视频高}" -ForegroundColor Cyan
    Write-Host "字幕轨 #$字幕序号 : $字幕编码" -ForegroundColor Cyan
    Write-Host "输出  : $输出文件" -ForegroundColor Green

    if (测试_ffmpeg视频编码器可用 -FfmpegPath 'ffmpeg' -编码器名称 'hevc_nvenc') {
        $编码参数 = @('-c:v', 'hevc_nvenc', '-cq', '23', '-b:v', '0')
        Write-Host '编码器: hevc_nvenc (GPU)' -ForegroundColor Cyan
    } else {
        $编码参数 = @('-c:v', 'libx265', '-crf', '23', '-preset', 'medium')
        Write-Host '编码器: libx265 (CPU 回退，NVENC 不可用)' -ForegroundColor Yellow
    }

    $图形字幕编码 = 'dvd_subtitle', 'hdmv_pgs_subtitle', 'dvb_subtitle', 'xsub'

    if ($字幕编码 -in $图形字幕编码) {
        $滤镜 = "[0:$字幕序号]scale=${视频宽}:${视频高}[sub];[0:$视频序号][sub]overlay=eof_action=pass[vout]"
    } else {
        $转义路径 = ($输入文件 -replace '\\', '/') -replace "([\[\]:;,'])", '\$1'
        $滤镜 = "[0:$视频序号]subtitles='${转义路径}':si=0[vout]"
    }

    $映射参数 = [Collections.Generic.List[string]]::new()
    $映射参数.Add('-map')
    $映射参数.Add('[vout]')

    foreach ($轨 in $全部轨道) {
        $序号 = [int]$轨.index
        if ($序号 -eq $视频序号 -or $序号 -eq $字幕序号) { continue }
        $映射参数.Add('-map')
        $映射参数.Add("0:$序号")
    }

    $ff参数 = @('-i', $输入文件, '-filter_complex', $滤镜) +
        $映射参数.ToArray() +
        $编码参数 +
        @('-c:a', 'copy', '-c:s', 'copy', '-y', $输出文件)

    Write-Host "`n> ffmpeg $($ff参数 -join ' ')`n" -ForegroundColor DarkGray

    $旧错误偏好 = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & ffmpeg @ff参数
    $退出码 = $LASTEXITCODE
    $ErrorActionPreference = $旧错误偏好

    if ($退出码 -eq 0) {
        Write-Host "`n完成: $输出文件" -ForegroundColor Green
    } else {
        throw "ffmpeg 失败，退出码 $退出码"
    }
}


