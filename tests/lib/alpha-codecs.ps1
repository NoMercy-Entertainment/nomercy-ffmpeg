# Same three-frame gradient and per-frame bounds as alpha-codecs.sh.
function Test-AlphaCodec {
    param (
        [string]$FFmpegExe,
        [ValidateSet('hap', 'liboapv')][string]$Codec
    )
    $decoder = 'hap'
    $container = 'mov'
    $scale = 1
    $codecArgs = @('-format', 'hap_alpha')
    if ($Codec -eq 'liboapv') {
        $decoder = 'apv'; $container = 'mkv'; $scale = 4
        $codecArgs = @('-pix_fmt', 'yuva444p10le')
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('nm-alpha-' + [guid]::NewGuid().ToString('N'))
    $output = ''
    $ErrorActionPreference = 'Continue'
    try {
        New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
        $videoPath = Join-Path $work "video.$container"
        $source = "testsrc2=size=128x64:rate=5,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*X/W'"
        $output = & $FFmpegExe -hide_banner -loglevel error -y -f lavfi -i $source `
            -frames:v 3 -c:v $Codec @codecArgs $videoPath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "$Codec encoding failed" }
        $metadata = & $FFmpegExe -hide_banner -loglevel error -c:v $decoder -i $videoPath `
            -vf 'alphaextract,signalstats,metadata=mode=print:file=-' -frames:v 3 -f null - 2>&1 | Out-String
        $output += $metadata
        if ($LASTEXITCODE -ne 0) { throw "$Codec native decoding or alpha extraction failed" }
        foreach ($key in @('YMIN', 'YMAX', 'YAVG')) {
            $values = [regex]::Matches($metadata, "(?m)^lavfi\.signalstats\.$key=([^\r\n]*)\r?$")
            if ($values.Count -ne 3) { throw "$Codec missing $key metadata for three frames" }
            foreach ($match in $values) {
                if ($match.Groups[1].Value -notmatch '^[0-9]+(?:\.[0-9]+)?$') { throw "$Codec non-numeric $key metadata" }
                $value = [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
                if (($key -eq 'YMIN' -and $value -ge (40 * $scale)) -or
                    ($key -eq 'YMAX' -and $value -le (210 * $scale)) -or
                    ($key -eq 'YAVG' -and ($value -lt (100 * $scale) -or $value -gt (150 * $scale)))) {
                    throw "$Codec alpha gradient missing, opaque or flat ($key=$value)"
                }
            }
        }
        return @{ Status = 'Pass'; Reason = ''; Output = "${Codec}: alpha gradient retained in all 3 frames (${scale}x 8-bit scale)" }
    }
    catch {
        return @{ Status = 'Fail'; Reason = $_.Exception.Message; Output = $output }
    }
    finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}
