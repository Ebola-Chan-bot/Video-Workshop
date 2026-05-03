function 格式化_SRT时间 {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    $h = [int][math]::Floor($ts.TotalHours)
    return ('{0:00}:{1:00}:{2:00},{3:000}' -f $h, $ts.Minutes, $ts.Seconds, $ts.Milliseconds)
}

function 格式化_ASS时间 {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }

    # ASS 时间格式：H:MM:SS.cc（cc=百分之一秒）
    $totalCs = [int64][math]::Floor(($Seconds * 100.0) + 0.5)
    $h = [int64]($totalCs / 360000)
    $rem = [int64]($totalCs % 360000)
    $m = [int64]($rem / 6000)
    $rem = [int64]($rem % 6000)
    $s = [int64]($rem / 100)
    $cs = [int64]($rem % 100)
    return ("{0}:{1:00}:{2:00}.{3:00}" -f $h, $m, $s, $cs)
}

function 写入_空白ASS {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [double]$DurationSeconds)

    $end = 格式化_ASS时间 -Seconds ([math]::Max(0.01, $DurationSeconds))

    $content = @(
        '[Script Info]',
        'ScriptType: v4.00+',
        'WrapStyle: 0',
        'ScaledBorderAndShadow: yes',
        'PlayResX: 384',
        'PlayResY: 288',
        '',
        '[V4+ Styles]',
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
        'Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,-1,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1',
        '',
        '[Events]',
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
        # 用 Comment 事件占位：不会被渲染显示（避免播放器把空字幕渲染成“/”等可见字符）
        ("Comment: 0,0:00:00.00,{0},Default,,0,0,0,," -f $end),
        ''
    ) -join "`r`n"

    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function 写入_空白SRT {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [double]$DurationSeconds)
    $end = 格式化_SRT时间 -Seconds ([math]::Max(0.001, $DurationSeconds))
    $content = @(
        '1',
        '00:00:00,000 --> ' + $end,
        ' ',
        ''
    ) -join "`r`n"
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}
