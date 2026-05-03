#requires -Version 5.1
. (Join-Path -Path $PSScriptRoot -ChildPath '安装辅助.ps1')

try {
    $安装成功 = $false
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host '通过 winget 安装 Gyan.FFmpeg (machine scope)...'
        & $winget.Source install --id Gyan.FFmpeg --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements | Out-Host
        刷新_当前PATH
        $安装成功 = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue) -and [bool](Get-Command ffprobe -ErrorAction SilentlyContinue)
    }

    if (-not $安装成功) {
        Write-Host '回退：直接下载静态构建包...'
        $安装根目录 = Join-Path $env:ProgramFiles 'ffmpeg'
        $二进制目录 = Join-Path $安装根目录 'bin'
        $临时压缩包 = Join-Path $env:TEMP 'ffmpeg-release-essentials.zip'
        $临时解压目录 = Join-Path $env:TEMP ("ffmpeg-extract-{0}" -f ([Guid]::NewGuid().ToString('N')))

        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $临时压缩包 -UseBasicParsing
        if (-not (Test-Path -LiteralPath $临时解压目录)) {
            New-Item -ItemType Directory -Path $临时解压目录 -Force | Out-Null
        }
        Expand-Archive -LiteralPath $临时压缩包 -DestinationPath $临时解压目录 -Force

        $解压目录 = Get-ChildItem -Path $临时解压目录 -Directory | Select-Object -First 1
        if (-not $解压目录) { throw 'ffmpeg 压缩包内容异常。' }

        if (Test-Path -LiteralPath $安装根目录) {
            Get-ChildItem -LiteralPath $安装根目录 -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -ItemType Directory -Path $安装根目录 -Force | Out-Null
        }

        Get-ChildItem -LiteralPath $解压目录.FullName -Force | Move-Item -Destination $安装根目录 -Force
        Remove-Item -LiteralPath $临时压缩包 -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $临时解压目录 -Recurse -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path -LiteralPath (Join-Path $二进制目录 'ffmpeg.exe'))) {
            throw "下载安装失败：未找到 $二进制目录\ffmpeg.exe"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $二进制目录 'ffprobe.exe'))) {
            throw "下载安装失败：未找到 $二进制目录\ffprobe.exe"
        }
        添加_机器PATH -目录 $二进制目录
    }

    exit 0
} catch {
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
