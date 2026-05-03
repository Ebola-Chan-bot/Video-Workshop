function 取_EBML变长整数长度 {
    param([byte]$FirstByte)
    for ($len = 1; $len -le 8; $len++) {
        $mask = [byte](0x80 -shr ($len - 1))
        if (($FirstByte -band $mask) -ne 0) { return $len }
    }
    return $null
}

function 读_EBML_ID {
    param([byte[]]$Bytes, [int]$Offset)
    $len = 取_EBML变长整数长度 -FirstByte $Bytes[$Offset]
    if (-not $len) { return $null }
    $id = 0
    for ($i = 0; $i -lt $len; $i++) { $id = ($id -shl 8) -bor $Bytes[$Offset + $i] }
    return [pscustomobject]@{ Length = $len; Id = $id }
}

function 读_EBML_Size {
    param([byte[]]$Bytes, [int]$Offset)
    $len = 取_EBML变长整数长度 -FirstByte $Bytes[$Offset]
    if (-not $len) { return $null }
    $first = $Bytes[$Offset]
    $mask = [byte](0x80 -shr ($len - 1))
    $value = ($first -bxor $mask)
    for ($i = 1; $i -lt $len; $i++) { $value = ($value -shl 8) -bor $Bytes[$Offset + $i] }
    $maxVal = ([int64]1 -shl (7 * $len)) - 1
    $unknown = ([int64]$value -eq $maxVal)
    return [pscustomobject]@{ Length = $len; Size = [int64]$value; Unknown = $unknown }
}

function 读_EBML_UInt {
    param([byte[]]$Bytes, [int]$Offset, [int]$Length)
    $v = [int64]0
    for ($i = 0; $i -lt $Length; $i++) { $v = ($v -shl 8) -bor $Bytes[$Offset + $i] }
    return $v
}

function 写_EBML_UInt_原地 {
    param([byte[]]$Bytes, [int]$Offset, [int]$Length, [int64]$Value)
    for ($i = 0; $i -lt $Length; $i++) {
        $shift = 8 * ($Length - 1 - $i)
        $Bytes[$Offset + $i] = [byte](($Value -shr $shift) -band 0xFF)
    }
}

function 打开_内存映射访问器_可写 {
    param([Parameter(Mandatory)] [string]$Path)

    $len = [int64](Get-Item -LiteralPath $Path).Length
    if ($len -le 0) {
        throw "文件长度无效：$Path"
    }

    # .NET Framework 下 mapName 不能为 $null/空字符串；这里用一个临时唯一名称。
    $mapName = ("mkvfix_{0}" -f ([Guid]::NewGuid().ToString('N')))
    $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile(
        $Path,
        [System.IO.FileMode]::Open,
        $mapName,
        $len,
        [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite
    )
    $acc = $mmf.CreateViewAccessor(0, $len, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)

    return [pscustomobject]@{ Mmf = $mmf; Acc = $acc; Length = $len }
}

function 读_EBML_ID_映射 {
    param(
        [Parameter(Mandatory)] [System.IO.MemoryMappedFiles.MemoryMappedViewAccessor]$Acc,
        [Parameter(Mandatory)] [int64]$Offset,
        [Parameter(Mandatory)] [int64]$TotalLength
    )
    if ($Offset -lt 0 -or $Offset -ge $TotalLength) { return $null }
    $first = $Acc.ReadByte($Offset)
    $len = 取_EBML变长整数长度 -FirstByte $first
    if (-not $len) { return $null }
    if (($Offset + $len) -gt $TotalLength) { return $null }

    $buf = New-Object byte[] $len
    [void]$Acc.ReadArray($Offset, $buf, 0, $len)
    $id = 0
    for ($i = 0; $i -lt $len; $i++) { $id = ($id -shl 8) -bor $buf[$i] }
    return [pscustomobject]@{ Length = $len; Id = $id }
}

function 读_EBML_Size_映射 {
    param(
        [Parameter(Mandatory)] [System.IO.MemoryMappedFiles.MemoryMappedViewAccessor]$Acc,
        [Parameter(Mandatory)] [int64]$Offset,
        [Parameter(Mandatory)] [int64]$TotalLength
    )
    if ($Offset -lt 0 -or $Offset -ge $TotalLength) { return $null }
    $first = $Acc.ReadByte($Offset)
    $len = 取_EBML变长整数长度 -FirstByte $first
    if (-not $len) { return $null }
    if (($Offset + $len) -gt $TotalLength) { return $null }

    $buf = New-Object byte[] $len
    [void]$Acc.ReadArray($Offset, $buf, 0, $len)

    $mask = [byte](0x80 -shr ($len - 1))
    $value = [int64]($buf[0] -bxor $mask)
    for ($i = 1; $i -lt $len; $i++) { $value = ($value -shl 8) -bor $buf[$i] }

    $maxVal = ([int64]1 -shl (7 * $len)) - 1
    $unknown = ([int64]$value -eq $maxVal)
    return [pscustomobject]@{ Length = $len; Size = [int64]$value; Unknown = $unknown }
}

function 读_EBML_UInt_映射 {
    param(
        [Parameter(Mandatory)] [System.IO.MemoryMappedFiles.MemoryMappedViewAccessor]$Acc,
        [Parameter(Mandatory)] [int64]$Offset,
        [Parameter(Mandatory)] [int]$Length,
        [Parameter(Mandatory)] [int64]$TotalLength
    )
    if ($Length -le 0) { return [int64]0 }
    if (($Offset + $Length) -gt $TotalLength) { return $null }
    $buf = New-Object byte[] $Length
    [void]$Acc.ReadArray($Offset, $buf, 0, $Length)
    $v = [int64]0
    for ($i = 0; $i -lt $Length; $i++) { $v = ($v -shl 8) -bor $buf[$i] }
    return $v
}

function 写_EBML_UInt_原地_映射 {
    param(
        [Parameter(Mandatory)] [System.IO.MemoryMappedFiles.MemoryMappedViewAccessor]$Acc,
        [Parameter(Mandatory)] [int64]$Offset,
        [Parameter(Mandatory)] [int]$Length,
        [Parameter(Mandatory)] [int64]$Value,
        [Parameter(Mandatory)] [int64]$TotalLength
    )
    if ($Length -le 0) { return }
    if (($Offset + $Length) -gt $TotalLength) { return }
    $buf = New-Object byte[] $Length
    for ($i = 0; $i -lt $Length; $i++) {
        $shift = 8 * ($Length - 1 - $i)
        $buf[$i] = [byte](($Value -shr $shift) -band 0xFF)
    }
    [void]$Acc.WriteArray($Offset, $buf, 0, $Length)
}

function 尝试_修正Matroska_DefaultDuration {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Fps)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.mkv') { return $false }

    $targetNs = 转换_fps到DefaultDuration_ns -Fps $Fps
    if (-not $targetNs -or $targetNs -le 0) { return $false }

    $map = $null
    try {
        $map = 打开_内存映射访问器_可写 -Path $Path
        $acc = $map.Acc
        $lenTotal = $map.Length

    $SEGMENT_ID = 0x18538067
    $TRACKS_ID = 0x1654AE6B
    $TRACKENTRY_ID = 0xAE
    $TRACKTYPE_ID = 0x83
    $DEFAULTDURATION_ID = 0x23E383

    $pos = [int64]0
    $segmentStart = $null
    $segmentEnd = $lenTotal

    while ($pos -lt $lenTotal - 12) {
        $id = 读_EBML_ID_映射 -Acc $acc -Offset $pos -TotalLength $lenTotal
        if (-not $id) { break }
        $size = 读_EBML_Size_映射 -Acc $acc -Offset ($pos + $id.Length) -TotalLength $lenTotal
        if (-not $size) { break }
        $dataStart = $pos + $id.Length + $size.Length

        if ($id.Id -eq $SEGMENT_ID) {
            $segmentStart = $dataStart
            if ($size.Unknown) { $segmentEnd = $lenTotal } else { $segmentEnd = [math]::Min($lenTotal, $dataStart + [int64]$size.Size) }
            break
        }

        if ($size.Unknown) { break }
        $pos = $dataStart + [int64]$size.Size
    }

    if ($null -eq $segmentStart) { return $false }

    $pos = [int64]$segmentStart
    $tracksStart = $null
    $tracksEnd = $null
    while ($pos -lt $segmentEnd - 12) {
        $id = 读_EBML_ID_映射 -Acc $acc -Offset $pos -TotalLength $lenTotal
        if (-not $id) { break }
        $size = 读_EBML_Size_映射 -Acc $acc -Offset ($pos + $id.Length) -TotalLength $lenTotal
        if (-not $size) { break }
        $dataStart = $pos + $id.Length + $size.Length
        $dataEnd = if ($size.Unknown) { $segmentEnd } else { [math]::Min($segmentEnd, $dataStart + [int64]$size.Size) }

        if ($id.Id -eq $TRACKS_ID) {
            $tracksStart = $dataStart
            $tracksEnd = $dataEnd
            break
        }
        $pos = $dataEnd
    }

    if ($null -eq $tracksStart) { return $false }

    $pos = [int64]$tracksStart
    while ($pos -lt $tracksEnd - 8) {
        $id = 读_EBML_ID_映射 -Acc $acc -Offset $pos -TotalLength $lenTotal
        if (-not $id) { break }
        $size = 读_EBML_Size_映射 -Acc $acc -Offset ($pos + $id.Length) -TotalLength $lenTotal
        if (-not $size) { break }
        $dataStart = $pos + $id.Length + $size.Length
        $dataEnd = [math]::Min($tracksEnd, $dataStart + [int64]$size.Size)

        if ($id.Id -eq $TRACKENTRY_ID) {
            $trackType = $null
            $defaultDurOffset = $null
            $defaultDurLen = $null

            $p2 = [int64]$dataStart
            while ($p2 -lt $dataEnd - 4) {
                $cid = 读_EBML_ID_映射 -Acc $acc -Offset $p2 -TotalLength $lenTotal
                if (-not $cid) { break }
                $csz = 读_EBML_Size_映射 -Acc $acc -Offset ($p2 + $cid.Length) -TotalLength $lenTotal
                if (-not $csz) { break }
                $cDataStart = $p2 + $cid.Length + $csz.Length
                $cDataEnd = [math]::Min($dataEnd, $cDataStart + [int64]$csz.Size)

                if ($cid.Id -eq $TRACKTYPE_ID -and $csz.Size -ge 1 -and $csz.Size -le 8) {
                    $trackType = 读_EBML_UInt_映射 -Acc $acc -Offset $cDataStart -Length ([int]$csz.Size) -TotalLength $lenTotal
                }
                if ($cid.Id -eq $DEFAULTDURATION_ID -and $csz.Size -ge 1 -and $csz.Size -le 8) {
                    $defaultDurOffset = $cDataStart
                    $defaultDurLen = [int]$csz.Size
                }

                $p2 = $cDataEnd
            }

            if ($trackType -eq 1 -and $null -ne $defaultDurOffset -and $null -ne $defaultDurLen) {
                $old = 读_EBML_UInt_映射 -Acc $acc -Offset $defaultDurOffset -Length $defaultDurLen -TotalLength $lenTotal
                if ([math]::Abs([double]$old - [double]$targetNs) -gt 1000) {
                    $max = ([int64]1 -shl (8 * $defaultDurLen)) - 1
                    if ($targetNs -le $max) {
                        写_EBML_UInt_原地_映射 -Acc $acc -Offset $defaultDurOffset -Length $defaultDurLen -Value $targetNs -TotalLength $lenTotal
                        $acc.Flush()
                        Write-Host ("已修正 Matroska DefaultDuration: {0} -> {1} (ns)" -f $old, $targetNs) -ForegroundColor Yellow
                        return $true
                    }
                }
                return $false
            }
        }

        $pos = $dataEnd
    }

    return $false

    } finally {
        if ($map -and $map.Acc) { $map.Acc.Dispose() }
        if ($map -and $map.Mmf) { $map.Mmf.Dispose() }
    }
}

function 尝试_修正Matroska_FrameRate元素 {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Fps)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.mkv') { return $false }

    $fpsValue = 解析_有理数 $Fps
    if (-not $fpsValue -or $fpsValue -le 0) { return $false }

    $map = $null
    try {
        $map = 打开_内存映射访问器_可写 -Path $Path
        $acc = $map.Acc
        $lenTotal = $map.Length

        $pat0 = [byte]0x23
        $pat1 = [byte]0x83
        $pat2 = [byte]0xE3

        # FrameRate 元素通常在头部 Tracks 附近；只扫描前 64MiB 以提升速度
        $scanLen = [int64]([math]::Min($lenTotal, 64MB))
        $chunkSize = 4MB
        $overlap = 2
        $offset = [int64]0
        $changed = $false

        while ($offset -lt $scanLen) {
            $remain = [int64]($scanLen - $offset)
            $readLen = [int]([math]::Min([int64]$chunkSize, $remain))
            if ($readLen -le 0) { break }

            $buf = New-Object byte[] $readLen
            [void]$acc.ReadArray($offset, $buf, 0, $readLen)

            for ($i = 0; $i -lt ($readLen - 16); $i++) {
                if ($buf[$i] -ne $pat0 -or $buf[$i+1] -ne $pat1 -or $buf[$i+2] -ne $pat2) { continue }

                $abs = $offset + $i
                $sizeOff = $abs + 3
                if ($sizeOff -ge $lenTotal) { continue }
                $first = $acc.ReadByte($sizeOff)
                $len = 取_EBML变长整数长度 -FirstByte $first
                if (-not $len) { continue }
                if (($sizeOff + $len) -gt $lenTotal) { continue }

                $szBuf = New-Object byte[] $len
                [void]$acc.ReadArray($sizeOff, $szBuf, 0, $len)
                $mask = [byte](0x80 -shr ($len - 1))
                $sz = [int64]($szBuf[0] -bxor $mask)
                for ($k = 1; $k -lt $len; $k++) { $sz = ($sz -shl 8) -bor $szBuf[$k] }

                $dataOff = $sizeOff + $len
                if (($dataOff + $sz) -gt $lenTotal) { continue }

                if ($sz -eq 4) {
                    $val = New-Object byte[] 4
                    [void]$acc.ReadArray($dataOff, $val, 0, 4)
                    $cur = [BitConverter]::ToSingle([byte[]]($val[3],$val[2],$val[1],$val[0]), 0)
                    if ($cur -gt 100 -or $cur -lt 1) {
                        $target = [single]$fpsValue
                        $le = [BitConverter]::GetBytes($target)
                        $be = [byte[]]@($le[3],$le[2],$le[1],$le[0])
                        [void]$acc.WriteArray($dataOff, $be, 0, 4)
                        $changed = $true
                    }
                } elseif ($sz -eq 8) {
                    $val = New-Object byte[] 8
                    [void]$acc.ReadArray($dataOff, $val, 0, 8)
                    $cur = [BitConverter]::ToDouble([byte[]]($val[7],$val[6],$val[5],$val[4],$val[3],$val[2],$val[1],$val[0]), 0)
                    if ($cur -gt 100 -or $cur -lt 1) {
                        $target = [double]$fpsValue
                        $le = [BitConverter]::GetBytes($target)
                        $be = New-Object byte[] 8
                        for ($k = 0; $k -lt 8; $k++) { $be[$k] = $le[7-$k] }
                        [void]$acc.WriteArray($dataOff, $be, 0, 8)
                        $changed = $true
                    }
                }
            }

            if ($offset -eq 0) {
                $offset += ([int64]$chunkSize - $overlap)
            } else {
                $offset += ([int64]$chunkSize - $overlap)
            }
        }

        if ($changed) {
            $acc.Flush()
            Write-Host "已修正 Matroska Video->FrameRate 字段（用于 MediaInfo 显示）" -ForegroundColor Yellow
        }
        return $changed
    } finally {
        if ($map -and $map.Acc) { $map.Acc.Dispose() }
        if ($map -and $map.Mmf) { $map.Mmf.Dispose() }
    }
}
