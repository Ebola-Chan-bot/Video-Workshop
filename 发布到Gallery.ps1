#requires -Version 5.1
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$密钥
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$项目根目录 = Split-Path -Parent $PSCommandPath
$清单文件名 = '视频工坊.psd1'
$清单路径 = Join-Path -Path $项目根目录 -ChildPath $清单文件名
$发布脚本文件名 = Split-Path -Leaf $PSCommandPath

if (-not (Test-Path -LiteralPath $清单路径)) {
    throw "未找到模块清单：$清单路径"
}

$清单 = Import-PowerShellDataFile -LiteralPath $清单路径
$包文件列表 = @($清单.FileList)
if ($包文件列表.Count -lt 1) {
    throw '模块清单 FileList 为空，无法构造发布包。'
}

if ($包文件列表 -contains $发布脚本文件名) {
    throw "发布脚本 $发布脚本文件名 不应包含在模块清单 FileList 中。"
}

foreach ($相对路径 in $包文件列表) {
    $源路径 = Join-Path -Path $项目根目录 -ChildPath $相对路径
    if (-not (Test-Path -LiteralPath $源路径)) {
        throw "FileList 中的文件不存在：$相对路径"
    }
}

$临时发布目录 = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("视频工坊_publish_{0}" -f ([Guid]::NewGuid().ToString('N')))

try {
    New-Item -ItemType Directory -Force -Path $临时发布目录 | Out-Null

    foreach ($相对路径 in $包文件列表) {
        $源路径 = Join-Path -Path $项目根目录 -ChildPath $相对路径
        $目标路径 = Join-Path -Path $临时发布目录 -ChildPath $相对路径
        $目标目录 = Split-Path -Parent $目标路径
        if (-not [string]::IsNullOrWhiteSpace($目标目录)) {
            New-Item -ItemType Directory -Force -Path $目标目录 | Out-Null
        }
        Copy-Item -LiteralPath $源路径 -Destination $目标路径 -Force
    }

    $临时清单路径 = Join-Path -Path $临时发布目录 -ChildPath $清单文件名
    $模块信息 = Test-ModuleManifest -Path $临时清单路径
    Write-Host ("准备发布 {0} {1} 到 PowerShell Gallery。" -f $模块信息.Name, $模块信息.Version) -ForegroundColor Cyan
    Write-Host "发布目录：$临时发布目录" -ForegroundColor DarkGray

    $psResource发布命令 = Get-Command Publish-PSResource -ErrorAction SilentlyContinue
    if ($psResource发布命令) {
        Publish-PSResource -Path $临时发布目录 -Repository PSGallery -ApiKey $密钥 -Confirm:$false
    } else {
        $publishModule命令 = Get-Command Publish-Module -ErrorAction SilentlyContinue
        if (-not $publishModule命令) {
            throw '未找到 Publish-PSResource 或 Publish-Module。请先安装 Microsoft.PowerShell.PSResourceGet 或 PowerShellGet。'
        }
        Publish-Module -Path $临时发布目录 -Repository PSGallery -NuGetApiKey $密钥 -Force
    }

    Write-Host '发布完成。' -ForegroundColor Green
} finally {
    $密钥 = $null
    if (Test-Path -LiteralPath $临时发布目录) {
        Remove-Item -LiteralPath $临时发布目录 -Recurse -Force -ErrorAction SilentlyContinue
    }
}