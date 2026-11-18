# Same checks as rubberband.sh, on the same input (1 s of silence, then 3 s
# of a 440 Hz sine, 48 kHz): exact length round(192000 / tempo), the sine
# starting at 1/tempo s within 10 ms, and the spectral centroid within 10 %
# of 440 Hz x pitch. See rubberband.sh for the measured numbers.
$script:RubberbandSource = "aevalsrc='if(gte(t,1),sin(2*PI*440*t),0)':s=48000:d=4"

function Test-Rubberband {
    param (
        [string]$FFmpegExe,
        [ValidateSet('faster', 'finer')][string]$Engine,
        [double]$Tempo = 1,
        [double]$Pitch = 1
    )
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $option = 'tempo={0}:pitch={1}:engine={2}' -f $Tempo.ToString($inv), $Pitch.ToString($inv), $Engine
    $wantSamples = [math]::Floor(192000 / $Tempo + 0.5)
    $wantStart = 1 / $Tempo
    $wantHz = 440 * $Pitch
    $from = (1.75 / $Tempo).ToString('0.000', $inv)
    $to = (3.25 / $Tempo).ToString('0.000', $inv)
    $output = ''
    $ErrorActionPreference = 'Continue'
    try {
        $run = & $FFmpegExe -hide_banner -loglevel error -filter_complex `
            "$script:RubberbandSource,rubberband=$option,silencedetect=n=0.5:d=0.05,astats=metadata=1:reset=0,ametadata=mode=print:file=-" `
            -f null - 2>&1 | Out-String
        $output = $run
        if ($LASTEXITCODE -ne 0) { throw "rubberband $option failed" }
        $counts = [regex]::Matches($run, '(?m)^lavfi\.astats\.Overall\.Number_of_samples=([0-9]+(?:\.[0-9]+)?)\r?$')
        if ($counts.Count -eq 0) { throw "rubberband ${option}: no sample count measured" }
        $samples = [double]::Parse($counts[$counts.Count - 1].Groups[1].Value, $inv)
        if ($samples -ne $wantSamples) { throw "rubberband ${option}: $samples samples, expected exactly $wantSamples" }
        $starts = [regex]::Matches($run, '(?m)^lavfi\.silence_end=([0-9]+(?:\.[0-9]+)?)\r?$')
        if ($starts.Count -eq 0) { throw "rubberband ${option}: no start of the sine found" }
        $start = [double]::Parse($starts[0].Groups[1].Value, $inv)
        if ([math]::Abs($start - $wantStart) -gt 0.010) {
            throw "rubberband ${option}: the sine starts at $start s, expected $wantStart s (10 ms tolerance)"
        }

        $pitchRun = & $FFmpegExe -hide_banner -loglevel error -filter_complex `
            "$script:RubberbandSource,rubberband=$option,atrim=start=${from}:end=$to,aspectralstats,ametadata=mode=print:key=lavfi.aspectralstats.1.centroid:file=-" `
            -f null - 2>&1 | Out-String
        $output += $pitchRun
        if ($LASTEXITCODE -ne 0) { throw "rubberband $option spectral measurement failed" }
        Assert-CentroidWindows -Text $pitchRun -WantHz $wantHz -Label "rubberband $option"
        return @{ Status = 'Pass'; Reason = ''; Output = "rubberband ${option}: $wantSamples samples, starts at $start s (expected $wantStart), centroid at $wantHz Hz" }
    }
    catch {
        return @{ Status = 'Fail'; Reason = $_.Exception.Message; Output = $output }
    }
}

# Every window within 10 % of WantHz, at least twelve of them. The first and
# the last window are left out: atrim's hard cut and the half-filled last
# window smear the spectrum even on the plain sine.
function Assert-CentroidWindows {
    param ([string]$Text, [double]$WantHz, [string]$Label)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $values = [regex]::Matches($Text, '(?m)^lavfi\.aspectralstats\.1\.centroid=([^\r\n]*)\r?$')
    if ($values.Count -lt 12) { throw "${Label}: only $($values.Count) spectral windows measured" }
    for ($i = 1; $i -lt $values.Count - 1; $i++) {
        $text = $values[$i].Groups[1].Value
        if ($text -notmatch '^[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?$') { throw "${Label}: non-numeric centroid '$text'" }
        $value = [double]::Parse($text, [Globalization.NumberStyles]::Float, $inv)
        if ($value -lt $WantHz * 0.9 -or $value -gt $WantHz * 1.1) {
            throw "${Label}: spectral centroid $value Hz, expected $WantHz Hz"
        }
    }
}

# faster (R2) and finer (R3) must give different samples for the same input;
# a filter that ignored engine= would pass every other check.
function Test-RubberbandEnginesDiffer {
    param ([string]$FFmpegExe)
    $ErrorActionPreference = 'Continue'
    try {
        $faster = (& $FFmpegExe -hide_banner -loglevel error -filter_complex `
            "$script:RubberbandSource,rubberband=tempo=1.5:engine=faster" -f hash -hash md5 - 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "rubberband engine=faster failed: $faster" }
        $finer = (& $FFmpegExe -hide_banner -loglevel error -filter_complex `
            "$script:RubberbandSource,rubberband=tempo=1.5:engine=finer" -f hash -hash md5 - 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "rubberband engine=finer failed: $finer" }
        if ($faster -notmatch '^MD5=' -or $finer -notmatch '^MD5=') { throw "rubberband engines: no checksum ($faster / $finer)" }
        if ($faster -eq $finer) { throw "rubberband engines: faster and finer give identical output ($faster); engine= has no effect" }
        return @{ Status = 'Pass'; Reason = ''; Output = "rubberband engines: faster $($faster.Substring(4)), finer $($finer.Substring(4))" }
    }
    catch {
        return @{ Status = 'Fail'; Reason = $_.Exception.Message; Output = '' }
    }
}
