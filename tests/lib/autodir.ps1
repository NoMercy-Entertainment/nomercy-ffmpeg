# Auto-created output folders (#134), the same checks as autodir.sh: every
# local file opened for writing gets its missing parent folders, whoever opens
# it. Each check writes into its own missing nested folder and asserts the
# written files, never ffmpeg's log. Returns @{ Status = Pass|Fail|Skip }.

# Every check, in the order smoke.ps1 runs them.
function Get-AutoDirModes {
    return @('Mp4', 'Mov', 'Webm', 'Mkv', 'Audio', 'Segment', 'Tee', 'Hls', 'Image2',
        'SpriteVtt', 'ChaptersVtt', 'FilePrefix', 'Pipe', 'Input')
}

function Test-AutoDir {
    param (
        [string]$FFmpegExe,
        [ValidateSet('Mp4', 'Mov', 'Webm', 'Mkv', 'Audio', 'Segment', 'Tee', 'Hls', 'Image2',
            'SpriteVtt', 'ChaptersVtt', 'FilePrefix', 'Pipe', 'Input')][string]$Mode
    )
    $work = Join-Path ([IO.Path]::GetTempPath()) ('nm-autodir-' + [guid]::NewGuid().ToString('N'))
    $d = Join-Path $work 'nm-autodir'
    $video = @('-f', 'lavfi', '-i', 'testsrc=d=0.5:size=128x72:rate=10')
    $audio = @('-f', 'lavfi', '-i', 'sine=d=0.5')
    $script:autodirOutput = ''
    # Windows PowerShell 5.1 turns native stderr into ErrorRecords under Stop.
    $ErrorActionPreference = 'Continue'
    $pushed = $false

    function Has($kind, $name) {
        $list = & $FFmpegExe -hide_banner "-$kind" 2>$null | Out-String
        return $list -match "\s$([regex]::Escape($name))\s"
    }
    function Invoke-FF([string[]]$ffArgs) {
        $script:autodirOutput += (& $FFmpegExe -hide_banner -loglevel error -y @ffArgs 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg exited $LASTEXITCODE" }
    }
    function Expect([string[]]$files) {
        foreach ($f in $files) {
            if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or (Get-Item -LiteralPath $f).Length -eq 0) { throw "not written: $f" }
        }
    }
    function Skip($reason) { return @{ Status = 'Skip'; Reason = $reason; Output = "SKIP: $reason" } }
    function Pass($msg) { return @{ Status = 'Pass'; Reason = ''; Output = $msg } }

    try {
        New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
        Push-Location -LiteralPath $work
        $pushed = $true
        switch ($Mode) {
            { $_ -in 'Mp4', 'Mov' } {
                $ext = $Mode.ToLower()
                $vc = 'mpeg4'
                if (Has 'encoders' 'libx264') { $vc = 'libx264' }
                $out = Join-Path $d "$ext\a\b\o.$ext"
                Invoke-FF ($video + $audio + @('-c:v', $vc, '-c:a', 'aac', $out))
                Expect @($out)
                return (Pass "$ext ($vc + aac) written into a folder that did not exist")
            }
            'Webm' {
                $vp = $null
                if (Has 'encoders' 'libvpx') { $vp = 'libvpx' }
                if (Has 'encoders' 'libvpx-vp9') { $vp = 'libvpx-vp9' }
                if (-not $vp) { return (Skip 'no VP8/VP9 encoder (libvpx) in this build') }
                $a = @()
                if (Has 'encoders' 'libopus') { $a = $audio + @('-c:a', 'libopus') }
                $out = Join-Path $d 'webm\a\b\o.webm'
                Invoke-FF ($video + $a + @('-c:v', $vp, $out))
                Expect @($out)
                return (Pass "webm ($vp$(if ($a.Count) { ' + libopus' })) written into a folder that did not exist")
            }
            'Mkv' {
                $out = Join-Path $d 'mkv\a\b\o.mkv'
                Invoke-FF ($video + $audio + @('-c:v', 'ffv1', '-c:a', 'flac', $out))
                Expect @($out)
                return (Pass 'mkv (ffv1 + flac) written into a folder that did not exist')
            }
            'Audio' {
                # Two outputs of one command, each into its own missing folder.
                $flac = Join-Path $d 'flac\a\o.flac'
                $m4a = Join-Path $d 'm4a\a\o.m4a'
                Invoke-FF ($audio + @('-c:a', 'flac', $flac, '-c:a', 'aac', $m4a))
                Expect @($flac, $m4a)
                return (Pass 'flac and m4a written into folders that did not exist')
            }
            'Segment' {
                $list = Join-Path $d 'segment\list\l.csv'
                Invoke-FF ($video + @('-map', '0:v', '-c:v', 'ffv1', '-f', 'segment', '-segment_time', '0.2',
                        '-segment_format', 'matroska', '-segment_list', $list, (Join-Path $d 'segment\files\s_%03d.mkv')))
                Expect @((Join-Path $d 'segment\files\s_000.mkv'), $list)
                return (Pass 'segment files and segment list written into two folders that did not exist')
            }
            'Tee' {
                # Relative with forward slashes: tee unescapes backslashes in
                # its slave list. The current folder is the work folder.
                Invoke-FF ($video + @('-map', '0:v', '-c:v', 'ffv1', '-f', 'tee',
                        '[f=matroska]nm-autodir/tee/a/o.mkv|[f=matroska]nm-autodir/tee/b/o.mkv'))
                Expect @((Join-Path $d 'tee\a\o.mkv'), (Join-Path $d 'tee\b\o.mkv'))
                return (Pass 'tee wrote both outputs into two folders that did not exist')
            }
            'Hls' {
                $pl = Join-Path $d 'hls\pl\index.m3u8'
                Invoke-FF ($video + @('-c:v', 'mpeg4', '-g', '2', '-f', 'hls', '-hls_time', '0.2', '-hls_list_size', '0',
                        '-hls_segment_filename', (Join-Path $d 'hls\seg\s_%03d.ts'), $pl))
                Expect @($pl, (Join-Path $d 'hls\seg\s_000.ts'))
                return (Pass 'hls playlist and segments written into two folders that did not exist')
            }
            'Image2' {
                $dir = Join-Path $d 'img\x'
                Invoke-FF ($video + @('-frames:v', '2', (Join-Path $dir 'f_%02d.png')))
                Expect @((Join-Path $dir 'f_01.png'), (Join-Path $dir 'f_02.png'))
                return (Pass 'image2 frames written into a folder that did not exist')
            }
            'SpriteVtt' {
                if (-not (Has 'muxers' 'spritevtt')) { return (Skip 'no spritevtt muxer in this build') }
                $dir = Join-Path $d 'sprite\x'
                Invoke-FF ($video + @('-vf', 'fps=2,scale=32:18', '-f', 'spritevtt', (Join-Path $dir 'sheet.png')))
                Expect @((Join-Path $dir 'sheet.png'), (Join-Path $dir 'sheet.vtt'))
                return (Pass 'spritevtt sheet and its .vtt written into a folder that did not exist')
            }
            'ChaptersVtt' {
                if (-not (Has 'muxers' 'chapters_vtt')) { return (Skip 'no chapters_vtt muxer in this build') }
                $meta = Join-Path $work 'chapters.txt'
                [IO.File]::WriteAllText($meta, ";FFMETADATA1`n[CHAPTER]`nTIMEBASE=1/1000`nSTART=0`nEND=500`ntitle=One`n")
                $out = Join-Path $d 'chapters\x\chapters.vtt'
                Invoke-FF @('-i', $meta, '-f', 'chapters_vtt', $out)
                Expect @($out)
                return (Pass 'chapters_vtt written into a folder that did not exist')
            }
            'FilePrefix' {
                # Relative on purpose: the old helper turned "file:nm-autodir\..."
                # into a folder named after the prefix in the current folder.
                Invoke-FF ($video + @('-c:v', 'ffv1', 'file:nm-autodir\file\c\o.mkv'))
                Expect @((Join-Path $d 'file\c\o.mkv'))
                $stray = @(Get-ChildItem -LiteralPath $work -Force | Where-Object { $_.Name -like 'file*' })
                if ($stray.Count -gt 0) { throw "a folder named after the file: prefix was created: $($stray.Name -join ', ')" }
                return (Pass 'file: output written, no folder named file:* created')
            }
            'Pipe' {
                # Through cmd so the bytes reach the file untouched (PowerShell
                # 5.1 would re-encode native stdout as text).
                $cmd = "`"$FFmpegExe`" -hide_banner -loglevel error -f lavfi -i testsrc=d=0.5:size=128x72:rate=10 -c:v ffv1 -f matroska pipe:1 > pipe.out"
                $script:autodirOutput += (& cmd.exe /d /c $cmd 2>&1 | Out-String)
                if ($LASTEXITCODE -ne 0) { throw "ffmpeg exited $LASTEXITCODE" }
                Expect @((Join-Path $work 'pipe.out'))
                $left = @(Get-ChildItem -LiteralPath $work -Force | Where-Object { $_.Name -ne 'pipe.out' })
                if ($left.Count -gt 0) { throw "pipe:1 left something besides its own output: $($left.Name -join ', ')" }
                return (Pass 'pipe:1 output written to stdout, no folder created')
            }
            'Input' {
                $script:autodirOutput += (& $FFmpegExe -hide_banner -loglevel error -i (Join-Path $d 'in\x\missing.mkv') -f null - 2>&1 | Out-String)
                if ($LASTEXITCODE -eq 0) { throw 'reading a missing input succeeded' }
                if (Test-Path -LiteralPath $d) { throw "reading a missing input created $d" }
                return (Pass 'a missing input fails and creates no folder')
            }
        }
    }
    catch {
        return @{ Status = 'Fail'; Reason = $_.Exception.Message; Output = $script:autodirOutput }
    }
    finally {
        if ($pushed) { Pop-Location }
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}
