# Same generated RGBA fixture and byte comparison as jpegxl.sh.
function Test-JpegXL {
    param (
        [string]$FFmpegExe,
        [switch]$Animated,
        [switch]$DefaultSettings
    )
    $codec = 'libjxl'
    $frames = 1
    if ($Animated) { $codec = 'libjxl_anim'; $frames = 3 }
    $qualityArgs = @('-distance', '0')
    if ($DefaultSettings) { $qualityArgs = @() }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('nm-jpegxl-' + [guid]::NewGuid().ToString('N'))
    $output = ''
    # Windows PowerShell 5.1 turns native stderr into ErrorRecords under Stop.
    $ErrorActionPreference = 'Continue'
    try {
        New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
        $sourcePath = Join-Path $work 'source.rgba'
        $imagePath = Join-Path $work 'image.jxl'
        $decodedPath = Join-Path $work 'decoded.rgba'
        $source = "testsrc=size=64x48:rate=5,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*X/W'"
        $output += (& $FFmpegExe -hide_banner -loglevel error -y -f lavfi -i $source `
            -frames:v $frames -pix_fmt rgba -f rawvideo $sourcePath 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'fixture generation failed' }
        $output += (& $FFmpegExe -hide_banner -loglevel error -y -f rawvideo -pixel_format rgba `
            -video_size 64x48 -framerate 5 -i $sourcePath -frames:v $frames `
            -c:v $codec @qualityArgs -pix_fmt rgba -f image2pipe $imagePath 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "$codec encoding failed" }
        $output += (& $FFmpegExe -hide_banner -loglevel error -y -c:v $codec -i $imagePath `
            -pix_fmt rgba -fps_mode passthrough -f rawvideo $decodedPath 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "$codec decoding failed" }
        if ((Get-Item -LiteralPath $sourcePath -ErrorAction Stop).Length -ne (64 * 48 * 4 * $frames) -or
            (Get-Item -LiteralPath $decodedPath -ErrorAction Stop).Length -ne (64 * 48 * 4 * $frames)) {
            throw "$codec round-trip changed the frame size or count"
        }
        if (-not $DefaultSettings -and
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256 -ErrorAction Stop).Hash -ne
            (Get-FileHash -LiteralPath $decodedPath -Algorithm SHA256 -ErrorAction Stop).Hash) {
            throw "$codec lossless round-trip changed pixels, alpha or frame count"
        }
        if ($DefaultSettings) {
            return @{ Status = 'Pass'; Reason = ''; Output = "${codec}: default encoding settings encode and decode successfully" }
        }
        return @{ Status = 'Pass'; Reason = ''; Output = "${codec}: $frames frame(s), RGBA bytes identical" }
    }
    catch {
        return @{ Status = 'Fail'; Reason = $_.Exception.Message; Output = $output }
    }
    finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}
