@{
    RootModule = '视频工坊.psm1'
    ModuleVersion = '1.0.0'
    GUID = '00279415-4bd7-49fe-aaf4-721625314781'
    Author = '埃博拉酱'
    CompanyName = '一致行动党'
    Copyright = '(c) 2026 埃博拉酱. MIT License.'
    Description = '面向本地视频处理的 PowerShell 工具模块，集成硬字幕烧录、Dolby Vision 转 HDR10、视频片段标准化合并。'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @('烧录字幕', 'DV转HDR10', '超级合并')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    FileList = @(
        '视频工坊.psd1',
        '视频工坊.psm1',
        'private\通用过程.ps1',
        'private\Matroska过程.ps1',
        'private\字幕过程.ps1',
        'private\媒体过程.ps1',
        'private\提权安装\安装辅助.ps1',
        'private\提权安装\安装ffmpeg.ps1',
        'private\提权安装\安装mkvmerge.ps1',
        'public\烧录字幕.ps1',
        'public\DV转HDR10.ps1',
        'public\超级合并.ps1',
        '图标.png',
        'README.md'
    )

    PrivateData = @{
        PSData = @{
            Tags = @('ffmpeg', 'ffprobe', 'mkvmerge', 'video', 'subtitle', 'hardsub', 'DolbyVision', 'HDR10', 'HEVC', '中文', '视频')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ProjectUri = 'https://github.com/Ebola-Chan-bot/Video-Workshop'
            IconUri = 'https://raw.githubusercontent.com/Ebola-Chan-bot/Video-Workshop/main/%E5%9B%BE%E6%A0%87.png'
            ReleaseNotes = '1.0.0 - 将三个视频处理命令整合为模块原生命令，并提取共享媒体处理过程。'
        }
    }
}


