# Same check as soxr.sh: a 4 s, 440 Hz sine from 48 kHz to 44.1 kHz with
# resampler=soxr must be 176400 samples and stay at 440 Hz. Without libsoxr
# aresample stops with "Requested resampling engine is unavailable".
# Needs Assert-CentroidWindows from rubberband.ps1.
function Test-Soxr {
    param ([string]$FFmpegExe)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $source = "aevalsrc='sin(2*PI*440*t)':s=48000:d=4,aresample=44100:resampler=soxr"
    $output = ''
    $ErrorActionPreference = 'Continue'
    try {
        $length = & $FFmpegExe -hide_banner -loglevel error -filter_complex `
            "$source,astats=metadata=1:reset=0,ametadata=mode=print:key=lavfi.astats.Overall.Number_of_samples:file=-" `
            -f null - 2>&1 | Out-String
        $output = $length
        if ($LASTEXITCODE -ne 0) { throw 'soxr resampling failed' }
        $counts = [regex]::Matches($length, '(?m)^lavfi\.astats\.Overall\.Number_of_samples=([0-9]+(?:\.[0-9]+)?)\r?$')
        if ($counts.Count -eq 0) { throw 'soxr: no sample count measured' }
        $samples = [double]::Parse($counts[$counts.Count - 1].Groups[1].Value, $inv)
        if ($samples -ne 176400) { throw "soxr: $samples samples at 44.1 kHz, expected 176400" }

        $pitch = & $FFmpegExe -hide_banner -loglevel error -filter_complex `
            "$source,atrim=start=1:end=3,aspectralstats,ametadata=mode=print:key=lavfi.aspectralstats.1.centroid:file=-" `
            -f null - 2>&1 | Out-String
        $output += $pitch
        if ($LASTEXITCODE -ne 0) { throw 'soxr spectral measurement failed' }
        Assert-CentroidWindows -Text $pitch -WantHz 440 -Label 'soxr'
        return @{ Status = 'Pass'; Reason = ''; Output = 'soxr: 48 kHz to 44.1 kHz, 176400 samples, centroid at 440 Hz' }
    }
    catch {
        return @{ Status = 'Fail'; Reason = $_.Exception.Message; Output = $output }
    }
}
