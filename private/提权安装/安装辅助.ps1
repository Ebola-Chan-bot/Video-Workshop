Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function 刷新_当前PATH {
    $机器路径 = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $用户路径 = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($机器路径, $用户路径 | Where-Object { $_ }) -join ';'
}

function 添加_机器PATH {
    param([Parameter(Mandatory)] [string]$目录)

    $当前路径 = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $路径片段 = @()
    if ($当前路径) { $路径片段 = $当前路径.Split(';') | Where-Object { $_ } }
    if ($路径片段 -notcontains $目录) {
        [Environment]::SetEnvironmentVariable('Path', ((@($路径片段) + $目录) -join ';'), 'Machine')
    }
    刷新_当前PATH
}
