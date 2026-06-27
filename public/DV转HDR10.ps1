function DV转HDR10 {
    <#
    .SYNOPSIS
        将 Dolby Vision HEVC 视频转为带 HDR10 元数据的 HEVC 文件。

    .DESCRIPTION
        使用支持 libplacebo 滤镜的 ffmpeg 处理 Dolby Vision 元数据和色彩空间，并输出 BT.2020、PQ（SMPTE ST 2084）、TV range 的 HDR10 HEVC 视频。

        命令只转换第一个视频轨，并复制输入文件中的所有音频轨；字幕、附件和其它非音频轨不会映射到输出文件。
        如果检测到 hevc_nvenc，则使用 GPU 编码（preset p4、VBR、CQ 等于 -质量）；否则回退到 libx265（medium，并把 -质量 写入 x265 CRF 参数）。

        未指定输出路径时，会在输入文件同目录生成“原文件名_HDR10.mkv”。启用 -测试秒数 时，输出名会变为“原文件名_HDR10_testNs.mkv”，并只转换开头 N 秒，便于快速验证色彩和编码参数。
        输出文件已存在时会被覆盖。

    .PARAMETER 输入文件
        输入 MKV/MP4 等媒体文件路径。文件必须存在。

    .PARAMETER 输出文件
        输出文件路径。省略时自动生成 MKV 输出文件名。

    .PARAMETER 质量
        视频编码质量值，范围 1 到 51。数值越小质量越高、文件通常越大。使用 hevc_nvenc 时作为 CQ；使用 libx265 时作为 CRF。
        默认值为 19。

    .PARAMETER 测试秒数
        只转换输入开头指定秒数。默认 0 表示转换完整文件。设置为正数时输出文件名会自动带 test 后缀。

    .EXAMPLE
        DV转HDR10 -输入文件 'D:\电影.DV.mkv'

        将完整影片转换为 D:\电影.DV_HDR10.mkv。

    .EXAMPLE
        DV转HDR10 -输入文件 'D:\电影.DV.mkv' -测试秒数 30 -质量 21

        只转换前 30 秒，用稍高 CRF/CQ 值快速测试输出效果。

    .EXAMPLE
        DV转HDR10 -输入文件 'D:\电影.DV.mkv' -输出文件 'D:\电影.HDR10.mkv' -质量 18

        使用指定输出路径和质量参数转换完整文件。

    .NOTES
        依赖支持 libplacebo 滤镜的 ffmpeg。命令会优先寻找 winget 安装的 Gyan.FFmpeg 或 PATH 中的 ffmpeg；找不到合适构建时会尝试安装。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, HelpMessage = '输入 MKV/MP4 文件路径')]
        [string]$输入文件,

        [string]$输出文件 = '',

        [ValidateRange(1, 51)]
        [int]$质量 = 19,

        [int]$测试秒数 = 0
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $script:输出外部进程信息 = $false

    $输入文件 = 规范化_用户路径参数 -Path $输入文件
    if ($输出文件) { $输出文件 = 规范化_用户路径参数 -Path $输出文件 }

    if (-not (Test-Path -LiteralPath $输入文件)) {
        throw "文件不存在: $输入文件"
    }

    if (-not $输出文件) {
        $绝对路径 = (Resolve-Path -LiteralPath $输入文件).Path
        $基础名 = [System.IO.Path]::GetFileNameWithoutExtension($绝对路径)
        $目录 = [System.IO.Path]::GetDirectoryName($绝对路径)
        $后缀 = if ($测试秒数 -gt 0) { "_HDR10_test${测试秒数}s" } else { '_HDR10' }
        $输出文件 = Join-Path $目录 "${基础名}${后缀}.mkv"
    }

    $ffmpeg = 确保_ffmpeg支持过滤器 -过滤器名称 'libplacebo'
    $版本信息 = (& $ffmpeg -version 2>&1 | Select-Object -First 1) -replace 'ffmpeg version ', ''
    Write-Host "ffmpeg  : $版本信息"
    Write-Host "路径    : $ffmpeg"

    $支持nvenc = 测试_ffmpeg视频编码器可用 -FfmpegPath $ffmpeg -编码器名称 'hevc_nvenc'
    $视频过滤器基础 = 'libplacebo=colorspace=bt2020nc:color_trc=smpte2084:color_primaries=bt2020:range=tv:apply_dolbyvision=true'

    if ($支持nvenc) {
        Write-Host '编码器  : hevc_nvenc（GPU）'
        $视频过滤器 = "$视频过滤器基础,format=p010le"
        $视频编码参数 = @(
            '-c:v', 'hevc_nvenc',
            '-preset', 'p4',
            '-rc', 'vbr',
            '-cq', "$质量"
        )
    } else {
        Write-Host '编码器  : libx265（CPU，NVENC 不可用）'
        $x265参数 = "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:crf=$质量"
        $视频过滤器 = "$视频过滤器基础,format=yuv420p10le"
        $视频编码参数 = @(
            '-c:v', 'libx265',
            '-preset', 'medium',
            '-x265-params', $x265参数
        )
    }

    $色彩元数据 = @(
        '-color_primaries', 'bt2020',
        '-color_trc', 'smpte2084',
        '-colorspace', 'bt2020nc',
        '-color_range', 'tv'
    )

    $时长参数 = if ($测试秒数 -gt 0) { @('-t', "$测试秒数") } else { @() }
    $参数列表 = @('-y') +
        $时长参数 +
        @('-i', $输入文件, '-vf', $视频过滤器) +
        $视频编码参数 +
        $色彩元数据 +
        @('-map', '0:v:0', '-map', '0:a', '-c:a', 'copy', $输出文件)

    Write-Host ''
    Write-Host "输入    : $输入文件"
    Write-Host "输出    : $输出文件"
    Write-Host "质量    : $质量"
    if ($测试秒数 -gt 0) { Write-Host "测试模式: 仅转换前 ${测试秒数} 秒" }
    Write-Host ''
    Write-Host '开始转换'

    $旧错误偏好 = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & $ffmpeg @参数列表
    $退出码 = $LASTEXITCODE
    $ErrorActionPreference = $旧错误偏好

    if ($退出码 -eq 0) {
        $大小MB = [math]::Round((Get-Item -LiteralPath $输出文件).Length / 1MB, 1)
        Write-Host ''
        Write-Host '转换完成'
        Write-Host "输出文件：$输出文件（${大小MB} MB）"
    } else {
        throw "转换失败（退出码：$退出码）"
    }
}


