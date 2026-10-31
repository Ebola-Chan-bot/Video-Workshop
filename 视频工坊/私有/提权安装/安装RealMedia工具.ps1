#requires -Version 5.1
. (Join-Path -Path $PSScriptRoot -ChildPath '安装辅助.ps1')

try {
	$临时目录 = Join-Path $env:TEMP ('视频工坊-RealProducer-' + [Guid]::NewGuid().ToString('N'))
	$安装包 = Join-Path $临时目录 'realproducer_basic_11_win.exe'
	New-Item -ItemType Directory -Path $临时目录 -Force | Out-Null

	Write-Host '正在下载 RealProducer Basic 11……'
	$ProgressPreference = 'SilentlyContinue'
	Invoke-WebRequest -Uri 'https://ftp.vector.co.jp/42/99/3281/realproducer_basic_11_win.exe' -OutFile $安装包 -UseBasicParsing
	$哈希 = (Get-FileHash -LiteralPath $安装包 -Algorithm SHA256).Hash
	if ($哈希 -ne '6A9F3D974D96CD8CDE99ACB1B796D6ECD7114E8061E51C2D0697BEAABF319D37') {
		throw "RealProducer 安装包校验失败，SHA256 为 $哈希。"
	}

	Write-Host '正在静默安装 RealProducer Basic 11……'
	$进程 = Start-Process -FilePath $安装包 -ArgumentList '/s' -Wait -PassThru
	if ($进程.ExitCode -ne 0) { throw "RealProducer 安装程序退出码为 $($进程.ExitCode)。" }

	$候选路径 = @(
		(Join-Path ${env:ProgramFiles(x86)} 'Real\RealProducer Basic\rmeditor.exe'),
		(Join-Path $env:ProgramFiles 'Real\RealProducer Basic\rmeditor.exe')
	)
	$编辑器路径 = $候选路径 | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
	if (-not $编辑器路径) { throw 'RealProducer 安装结束，但未在默认安装目录找到 rmeditor.exe。' }
	添加_机器PATH -目录 (Split-Path -Parent $编辑器路径)
	exit 0
} catch {
	Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
	exit 1
} finally {
	if ($临时目录) { Remove-Item -LiteralPath $临时目录 -Recurse -Force -ErrorAction SilentlyContinue }
}
