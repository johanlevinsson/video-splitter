<#
.SYNOPSIS
    Splits video files into segments based on timestamped chapter files.

.DESCRIPTION
    Takes a video file and a text file containing chapter timestamps,
    then splits the video into separate files organized in folders.
    
    Can process a single video or batch process an entire folder.
    
    By default uses stream copy (fast) which cuts at keyframes.
    Use -Reencode for precise cuts or to fix broken segments.

.PARAMETER VideoFile
    Path to the source video file (single file mode).

.PARAMETER ChapterFile
    Path to the text file containing chapter timestamps (single file mode).

.PARAMETER InputDir
    Path to a folder containing subfolders with videos and timestamp files (batch mode).

.PARAMETER OutputDir
    Output directory for the split videos. Defaults to ./output

.PARAMETER Force
    Skip confirmation prompt.

.PARAMETER Reencode
    Re-encode video instead of stream copy. Slower but fixes broken segments.

.PARAMETER VideoCodec
    Video codec for re-encoding. Defaults to libx264.

.PARAMETER AudioCodec
    Audio codec for re-encoding. Defaults to aac.

.PARAMETER Quality
    CRF quality value for re-encoding (0-51, lower = better). Defaults to 23.

.EXAMPLE
    .\split-video.ps1 -VideoFile "video.mp4" -ChapterFile "chapters.txt"

.EXAMPLE
    .\split-video.ps1 -InputDir ".\Courses" -OutputDir ".\output"

.EXAMPLE
    .\split-video.ps1 -InputDir ".\Courses" -Reencode -Quality 20
#>

param(
    [string]$VideoFile,
    
    [string]$ChapterFile,
    
    [string]$InputDir,
    
    [string]$OutputDir = ".\output",
    
    [switch]$Force,
    
    [switch]$Reencode,
    
    [string]$VideoCodec = "libx264",
    
    [string]$AudioCodec = "aac",
    
    [int]$Quality = 27
)

# --- Tree Drawing Characters ---
# Using Unicode box-drawing characters for nice tree output
$script:TreeBranch = [char]0x251C + [char]0x2500 + [char]0x2500 + " "  # ├── 
$script:TreeLast   = [char]0x2514 + [char]0x2500 + [char]0x2500 + " "  # └── 
$script:TreePipe   = [char]0x2502 + "   "                               # │   
$script:TreeSpace  = "    "                                             #     

# --- Timestamp Parsing Functions ---

function Convert-TimestampToSeconds {
    <#
    .SYNOPSIS
        Converts a timestamp string to total seconds.
        Handles trailing noise like .00 or frame numbers.
    .PARAMETER Timestamp
        The timestamp string to convert.
    .PARAMETER ForceMinutesSeconds
        If true, interpret 3-part timestamps as MM:SS:frames instead of H:MM:SS.
        Useful when context indicates the video is short (not hours long).
    .EXAMPLE
        Convert-TimestampToSeconds "1:23"       # Returns 83 (1 min 23 sec)
        Convert-TimestampToSeconds "1:23:45"    # Returns 5025 (1 hr 23 min 45 sec)
        Convert-TimestampToSeconds "3.48.00"    # Returns 228 (3 min 48 sec, ignores .00)
        Convert-TimestampToSeconds "1.06.08.00" # Returns 3968 (1 hr 6 min 8 sec)
        Convert-TimestampToSeconds "25:38:00"   # Returns 1538 (25 min 38 sec, not 25 hours)
        Convert-TimestampToSeconds "45"         # Returns 45
        Convert-TimestampToSeconds "16.44.12" -ForceMinutesSeconds  # Returns 1004 (16 min 44 sec)
    #>
    param(
        [string]$Timestamp,
        [switch]$ForceMinutesSeconds
    )
    
    # Normalize . to : for splitting
    $normalized = $Timestamp -replace '\.', ':'
    $parts = $normalized -split ':'
    
    # Convert parts to integers
    $intParts = $parts | ForEach-Object { [int]$_ }
    
    switch ($parts.Count) {
        1 { 
            # Just seconds or minutes: "45"
            return $intParts[0]
        }
        2 { 
            # M:SS: "1:23", "25:38"
            return ($intParts[0] * 60) + $intParts[1]
        }
        3 { 
            # Could be H:MM:SS or M:SS:frames
            # If ForceMinutesSeconds is set, always treat as M:SS (ignore third part)
            if ($ForceMinutesSeconds) {
                return ($intParts[0] * 60) + $intParts[1]
            }
            # Heuristic: if first part is small (likely minutes) and we see patterns like
            # 37.58.12 (where .12 is frames), treat as M:SS
            # If first part looks like hours (small number) with valid MM:SS, treat as H:MM:SS
            # Key insight: in this dataset, H:MM:SS only appears when hours is small (1-2)
            # and timestamps like 37.58.12 are clearly M:SS with frame noise
            if ($intParts[0] -gt 23) {
                # First part > 23, definitely not hours - treat as M:SS (ignore third part)
                return ($intParts[0] * 60) + $intParts[1]
            } elseif ($intParts[2] -eq 0) {
                # Third part is 00 - likely noise, treat as M:SS
                return ($intParts[0] * 60) + $intParts[1]
            } else {
                # Treat as H:MM:SS (small hour value with non-zero seconds)
                return ($intParts[0] * 3600) + ($intParts[1] * 60) + $intParts[2]
            }
        }
        4 {
            # H:MM:SS:noise (like 1.06.08.00) - ignore the last part
            return ($intParts[0] * 3600) + ($intParts[1] * 60) + $intParts[2]
        }
        default { 
            throw "Invalid timestamp format: $Timestamp" 
        }
    }
}

function Convert-SecondsToTimestamp {
    <#
    .SYNOPSIS
        Converts seconds to a readable timestamp string.
    .EXAMPLE
        Convert-SecondsToTimestamp 83   # Returns "1:23"
        Convert-SecondsToTimestamp 5025 # Returns "1:23:45"
    #>
    param([int]$Seconds)
    
    $hours = [int][math]::Floor($Seconds / 3600)
    $minutes = [int][math]::Floor(($Seconds % 3600) / 60)
    $secs = [int]($Seconds % 60)
    
    if ($hours -gt 0) {
        return "{0}:{1:D2}:{2:D2}" -f $hours, $minutes, $secs
    } else {
        return "{0}:{1:D2}" -f $minutes, $secs
    }
}

function Test-IsTimestamp {
    <#
    .SYNOPSIS
        Tests if a string looks like a timestamp.
    #>
    param([string]$Text)
    
    # Match patterns: "0", "1:23", "01:23", "1:23:45", "01:23:45", "1:16:0"
    return $Text -match '^\d{1,2}(:\d{1,2}){0,2}$'
}

function Test-IsVolumeHeader {
    <#
    .SYNOPSIS
        Tests if a line is a valid volume/disc header.
        Can be just a number (e.g., "01", "1") or a keyword with number.
    .EXAMPLE
        Test-IsVolumeHeader "01"            # True (just a number)
        Test-IsVolumeHeader "Volume 1"      # True
        Test-IsVolumeHeader "DISC 2"        # True
        Test-IsVolumeHeader "Part 3"        # True
        Test-IsVolumeHeader "Course Content" # False
        Test-IsVolumeHeader "START TIME"    # False
    #>
    param([string]$Text)
    
    # Match just a number (e.g., "01", "1", "12")
    if ($Text -match '^\d+$') {
        return $true
    }
    
    # Match patterns like "Volume 1", "DISC 2", "Part 3", "Vol. 1", "Vol 1"
    return $Text -match '\b(volume|vol\.?|disc|part|section|chapter)\s*\d+\b'
}

function Parse-ChapterLine {
    <#
    .SYNOPSIS
        Parses a single line from the chapter file.
        Returns hashtable with Title and Seconds, or $null if no timestamp found.
    .EXAMPLE
        Parse-ChapterLine "Intro To Armbars	0"
        Parse-ChapterLine "1:23 Top Juji Vs Bottom Juji"
        Parse-ChapterLine "2:45 - Central Problems"
        Parse-ChapterLine "Overview 4:52 - 7:23"  # Dual timestamps - uses first
    #>
    param([string]$Line)
    
    $Line = $Line.Trim()
    
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    
    # Regex to find timestamp (whitespace-agnostic)
    # Patterns with colon or dot: "0:00", "1:23", "25:38:00", "3.48.00", "1.06.08.00"
    # Supports 2-4 parts to handle trailing noise like .00 or frame numbers
    # Special case: "0" alone (whitespace-separated) means 0:00
    
    $timestamp = $null
    $title = $null
    
    # Match timestamp with colon(s) or dot(s): supports 2-4 parts
    # Use first match only (for dual timestamps like "4:52 - 7:23")
    if ($Line -match '(\d{1,2}[:\.](\d{1,2})(?:[:\.](\d{1,2}))?(?:[:\.](\d{1,2}))?)') {
        $timestamp = $Matches[1]
    }
    # Special case: bare "0" at end or start (whitespace-separated) means 0:00
    elseif ($Line -match '[\t\s]0$' -or $Line -match '^0[\t\s]') {
        $timestamp = "0"
    }
    
    if ($null -eq $timestamp) {
        return $null
    }
    
    $seconds = Convert-TimestampToSeconds $timestamp
    
    # Remove ALL timestamps from the line to get the title (handles dual timestamps)
    # Supports both : and . as separators, and 2-4 part timestamps
    $title = $Line -replace '\d{1,2}[:\.]\d{1,2}(?:[:\.]\d{1,2})?(?:[:\.]\d{1,2})?', ''
    
    # Also remove bare "0" if it was the timestamp (at start or end, whitespace-separated)
    $title = $title -replace '[\t\s]0$', ''
    $title = $title -replace '^0[\t\s]', ''
    
    # Clean up separators and extra whitespace
    $title = $title -replace '^\s*[-–—]\s*', ''  # Leading dash
    $title = $title -replace '\s*[-–—]\s*$', ''  # Trailing dash
    $title = $title -replace '\s+[-–—]\s+', ' '  # Middle dashes (from dual timestamps)
    $title = $title -replace '\t', ' '           # Tabs to spaces
    $title = $title -replace '\s+', ' '          # Multiple spaces to one
    $title = $title.Trim()
    
    if ([string]::IsNullOrWhiteSpace($title)) {
        return $null
    }
    
    return @{
        Title = $title
        Seconds = $seconds
        Timestamp = $timestamp  # Preserve original for potential re-parsing
    }
}

function Repair-MisinterpretedTimestamps {
    <#
    .SYNOPSIS
        Detects and fixes timestamps that were misinterpreted as H:MM:SS when they
        should have been MM:SS:FF (minutes:seconds:frames).
    .DESCRIPTION
        Timestamps in the input file are ALWAYS in chronological order within each volume.
        If after parsing, a timestamp results in a value that's LESS than the previous one,
        it means some earlier timestamps were misinterpreted.
        
        Example: If we have [0s, 336s, 60252s, 84816s, 2005s], the jump from 84816 back to 2005
        indicates that 60252 and 84816 were wrongly parsed (they should be ~1000s and ~1400s).
        
        Strategy: Build the alternative sequence (all timestamps re-parsed with ForceMinutesSeconds).
        If the original sequence has backwards jumps but the alternative is monotonic, use the alternative.
    .PARAMETER Chapters
        Array of chapter hashtables with Title, Seconds, and Timestamp properties.
    .OUTPUTS
        Corrected array of chapters.
    #>
    param([array]$Chapters)
    
    if ($Chapters.Count -lt 2) {
        return $Chapters
    }
    
    # Check if original sequence has backwards jumps
    $originalHasBackwardsJump = $false
    for ($i = 1; $i -lt $Chapters.Count; $i++) {
        if ($Chapters[$i].Seconds -lt $Chapters[$i - 1].Seconds) {
            $originalHasBackwardsJump = $true
            break
        }
    }
    
    if (-not $originalHasBackwardsJump) {
        # All timestamps are in ascending order - nothing to fix
        return $Chapters
    }
    
    # Build alternative sequence using ForceMinutesSeconds
    $alternativeChapters = @()
    foreach ($chapter in $Chapters) {
        $altSeconds = $chapter.Seconds
        if ($null -ne $chapter.Timestamp) {
            $altSeconds = Convert-TimestampToSeconds $chapter.Timestamp -ForceMinutesSeconds
        }
        $alternativeChapters += @{
            Title = $chapter.Title
            Seconds = $altSeconds
            Timestamp = $chapter.Timestamp
        }
    }
    
    # Check if alternative sequence is monotonically increasing
    $alternativeIsMonotonic = $true
    for ($i = 1; $i -lt $alternativeChapters.Count; $i++) {
        if ($alternativeChapters[$i].Seconds -lt $alternativeChapters[$i - 1].Seconds) {
            $alternativeIsMonotonic = $false
            break
        }
    }
    
    if ($alternativeIsMonotonic) {
        # Alternative interpretation is correct - use it
        return $alternativeChapters
    }
    
    # Neither interpretation works cleanly - return original (data quality issue)
    return $Chapters
}

function Parse-ChapterFile {
    <#
    .SYNOPSIS
        Parses a chapter file and returns structured data.
    .OUTPUTS
        Hashtable with:
        - VolumeName: string (or $null if no header)
        - Chapters: array of @{Title, Seconds}
    #>
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        throw "Chapter file not found: $FilePath"
    }
    
    $lines = Get-Content $FilePath -Encoding UTF8
    $volumeName = $null
    $chapters = @()
    
    foreach ($line in $lines) {
        $trimmedLine = $line.Trim()
        
        if ([string]::IsNullOrWhiteSpace($trimmedLine)) {
            continue
        }
        
        $parsed = Parse-ChapterLine $trimmedLine
        
        if ($null -eq $parsed) {
            # No timestamp found - check if it's a valid volume header
            if (Test-IsVolumeHeader $trimmedLine) {
                $volumeName = $trimmedLine
            }
            # Otherwise skip lines without timestamps (e.g., "Course Content", "START TIME")
        } else {
            $chapters += $parsed
        }
    }
    
    # Validate and fix misinterpreted timestamps
    # If we detect timestamps that were likely MM:SS:FF interpreted as H:MM:SS,
    # re-parse them with ForceMinutesSeconds
    $chapters = Repair-MisinterpretedTimestamps $chapters
    
    # Sort chapters by timestamp
    $chapters = $chapters | Sort-Object { $_.Seconds }
    
    # If first chapter doesn't start at 0:00, add an Intro chapter
    if ($chapters.Count -gt 0 -and $chapters[0].Seconds -gt 0) {
        $introChapter = @{
            Title = "Intro"
            Seconds = 0
        }
        $chapters = @($introChapter) + $chapters
    }
    
    return @{
        VolumeName = $volumeName
        Chapters = $chapters
    }
}

# --- Video Functions ---

function Get-VideoDuration {
    <#
    .SYNOPSIS
        Gets the duration of a video file in seconds using FFprobe.
    #>
    param([string]$VideoPath)
    
    try {
        $output = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $VideoPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "FFprobe failed"
        }
        return [math]::Floor([double]$output)
    }
    catch {
        Write-Warning "Could not get video duration. Is FFmpeg/FFprobe installed and in PATH?"
        return $null
    }
}

function Test-FFmpegAvailable {
    <#
    .SYNOPSIS
        Checks if FFmpeg is available in PATH.
    #>
    try {
        $null = & ffmpeg -version 2>&1
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

# --- Filename Functions ---

function Get-SafeFilename {
    <#
    .SYNOPSIS
        Converts a string to a safe filename (lowercase, no special chars).
    #>
    param([string]$Name)
    
    # Convert to lowercase
    $safe = $Name.ToLower()
    
    # Replace special characters with spaces
    $safe = $safe -replace '[<>:"/\\|?*]', ''
    
    # Replace multiple spaces with single space
    $safe = $safe -replace '\s+', ' '
    
    # Trim
    $safe = $safe.Trim()
    
    return $safe
}

# --- Preview Functions ---

function Show-Preview {
    <#
    .SYNOPSIS
        Displays a preview of what will be created.
        Shows SKIP for segments where output file already exists.
    #>
    param(
        [string]$VideoFile,
        [int]$VideoDuration,
        [string]$VolumeName,
        [array]$Chapters,
        [string]$OutputDir
    )
    
    $videoName = Split-Path $VideoFile -Leaf
    $videoExt = [System.IO.Path]::GetExtension($VideoFile)
    $durationStr = if ($VideoDuration) { Convert-SecondsToTimestamp $VideoDuration } else { "unknown" }
    
    # Get parent folder name from video file path
    $parentFolder = Split-Path (Split-Path $VideoFile -Parent) -Leaf
    
    # Build paths for checking existing files
    $volumeFolder = if ($VolumeName) { Get-SafeFilename $VolumeName } else { "chapters" }
    $parentOutputPath = Join-Path $OutputDir $parentFolder
    $baseOutputPath = Join-Path $parentOutputPath $volumeFolder
    
    # Count existing and new segments
    $existingCount = 0
    $newCount = 0
    
    for ($i = 0; $i -lt $Chapters.Count; $i++) {
        $chapter = $Chapters[$i]
        $safeTitle = Get-SafeFilename $chapter.Title
        $folderName = "{0:D2}. {1}" -f ($i + 1), $safeTitle
        $fileName = "$safeTitle$videoExt"
        $chapterFolder = Join-Path $baseOutputPath $folderName
        $outputFile = Join-Path $chapterFolder $fileName
        
        if (Test-Path $outputFile) {
            $existingCount++
        } else {
            $newCount++
        }
    }
    
    Write-Host ""
    Write-Host "=== Video Splitter Preview ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Source: " -NoNewline; Write-Host $videoName -ForegroundColor Yellow -NoNewline
    Write-Host " ($durationStr)"
    Write-Host "Chapters: " -NoNewline; Write-Host "$($Chapters.Count) segments" -ForegroundColor Yellow -NoNewline
    if ($existingCount -gt 0) {
        Write-Host " (" -NoNewline
        Write-Host "$newCount new" -ForegroundColor Green -NoNewline
        Write-Host ", " -NoNewline
        Write-Host "$existingCount skip" -ForegroundColor DarkYellow -NoNewline
        Write-Host ")"
    } else {
        Write-Host ""
    }
    Write-Host "Output: " -NoNewline; Write-Host $OutputDir -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Structure to be created:" -ForegroundColor Green
    Write-Host "  $parentFolder/" -ForegroundColor White
    Write-Host "  $script:TreeBranch" -NoNewline -ForegroundColor DarkGray; Write-Host "playlist.m3u" -ForegroundColor DarkCyan
    Write-Host "  $script:TreeLast" -NoNewline -ForegroundColor DarkGray; Write-Host "$volumeFolder/" -ForegroundColor White
    
    for ($i = 0; $i -lt $Chapters.Count; $i++) {
        $chapter = $Chapters[$i]
        $nextChapter = if ($i -lt $Chapters.Count - 1) { $Chapters[$i + 1] } else { $null }
        
        $startTime = $chapter.Seconds
        $endTime = if ($nextChapter) { $nextChapter.Seconds } else { $VideoDuration }
        
        $startStr = Convert-SecondsToTimestamp $startTime
        $endStr = if ($endTime) { Convert-SecondsToTimestamp $endTime } else { "end" }
        
        $safeTitle = Get-SafeFilename $chapter.Title
        $folderName = "{0:D2}. {1}" -f ($i + 1), $safeTitle
        $fileName = "$safeTitle$videoExt"
        
        # Check if output file already exists
        $chapterFolder = Join-Path $baseOutputPath $folderName
        $outputFile = Join-Path $chapterFolder $fileName
        $fileExists = Test-Path $outputFile
        
        $isLast = ($i -eq $Chapters.Count - 1)
        $branch = if ($isLast) { $script:TreeLast } else { $script:TreeBranch }
        $cont = if ($isLast) { $script:TreeSpace } else { $script:TreePipe }
        
        Write-Host "  $script:TreeSpace$branch" -NoNewline -ForegroundColor DarkGray; Write-Host "$folderName/" -ForegroundColor Gray
        Write-Host "  $script:TreeSpace$cont$script:TreeLast" -NoNewline -ForegroundColor DarkGray
        Write-Host "$fileName  " -NoNewline -ForegroundColor DarkGray
        Write-Host "[$startStr - $endStr]" -NoNewline -ForegroundColor DarkCyan
        
        if ($fileExists) {
            Write-Host " [SKIP]" -ForegroundColor DarkYellow
        } else {
            Write-Host ""
        }
    }
    
    Write-Host ""
}

function Get-Confirmation {
    <#
    .SYNOPSIS
        Prompts user for Y/n confirmation.
    #>
    Write-Host "Proceed? [Y/n]: " -ForegroundColor Cyan -NoNewline
    $response = Read-Host
    
    if ([string]::IsNullOrWhiteSpace($response) -or $response -match '^[Yy]') {
        return $true
    }
    return $false
}

# --- Video Splitting Functions ---

function Convert-SecondsToFFmpegTimestamp {
    <#
    .SYNOPSIS
        Converts seconds to FFmpeg timestamp format (HH:MM:SS).
    #>
    param([int]$Seconds)
    
    $hours = [int][math]::Floor($Seconds / 3600)
    $minutes = [int][math]::Floor(($Seconds % 3600) / 60)
    $secs = [int]($Seconds % 60)
    
    return "{0:D2}:{1:D2}:{2:D2}" -f $hours, $minutes, $secs
}

function Split-VideoFile {
    <#
    .SYNOPSIS
        Splits a video file into segments based on chapters.
    .OUTPUTS
        Hashtable with ParentOutputPath and PlaylistEntries for playlist generation.
    #>
    param(
        [string]$VideoFile,
        [int]$VideoDuration,
        [string]$VolumeName,
        [int]$VolumeIndex = 1,
        [array]$Chapters,
        [string]$OutputDir,
        [bool]$Reencode = $false,
        [string]$VideoCodec = "libx264",
        [string]$AudioCodec = "aac",
        [int]$Quality = 23
    )
    
    $videoExt = [System.IO.Path]::GetExtension($VideoFile)
    
    # Get parent folder name from video file path
    $parentFolder = Split-Path (Split-Path $VideoFile -Parent) -Leaf
    
    $volumeFolder = if ($VolumeName) { Get-SafeFilename $VolumeName } else { "chapters" }
    $parentOutputPath = Join-Path $OutputDir $parentFolder
    $baseOutputPath = Join-Path $parentOutputPath $volumeFolder
    
    # Create base output directory
    if (-not (Test-Path $baseOutputPath)) {
        New-Item -ItemType Directory -Path $baseOutputPath -Force | Out-Null
    }
    
    $totalChapters = $Chapters.Count
    $successCount = 0
    $failCount = 0
    $playlistEntries = @()
    
    Write-Host ""
    if ($Reencode) {
        Write-Host "Splitting video into $totalChapters segments (re-encoding with $VideoCodec, CRF $Quality)..." -ForegroundColor Cyan
    } else {
        Write-Host "Splitting video into $totalChapters segments (stream copy)..." -ForegroundColor Cyan
    }
    Write-Host ""
    
    $skipCount = 0
    
    for ($i = 0; $i -lt $Chapters.Count; $i++) {
        $chapter = $Chapters[$i]
        $nextChapter = if ($i -lt $Chapters.Count - 1) { $Chapters[$i + 1] } else { $null }
        
        $startTime = $chapter.Seconds
        $endTime = if ($nextChapter) { $nextChapter.Seconds } else { $VideoDuration }
        $duration = $endTime - $startTime
        
        $safeTitle = Get-SafeFilename $chapter.Title
        $folderName = "{0:D2}. {1}" -f ($i + 1), $safeTitle
        $fileName = "$safeTitle$videoExt"
        
        $chapterFolder = Join-Path $baseOutputPath $folderName
        $outputFile = Join-Path $chapterFolder $fileName
        
        # Progress display
        $progress = $i + 1
        $startStr = Convert-SecondsToTimestamp $startTime
        $endStr = if ($endTime) { Convert-SecondsToTimestamp $endTime } else { "end" }
        
        Write-Host "[${progress}/${totalChapters}] " -NoNewline -ForegroundColor Cyan
        Write-Host "$($chapter.Title) " -NoNewline -ForegroundColor White
        Write-Host "[$startStr - $endStr]" -NoNewline -ForegroundColor DarkGray
        
        # Check if output file already exists - skip if it does
        if (Test-Path $outputFile) {
            Write-Host " SKIP (exists)" -ForegroundColor DarkYellow
            $skipCount++
            
            # Still add entry for playlist (relative to parent folder)
            $chapterIndex = $i + 1
            $trackNumber = "{0:D2}-{1:D2}" -f $VolumeIndex, $chapterIndex
            $playlistEntries += @{
                Title = "$VolumeName - $trackNumber. $($chapter.Title)"
                Duration = $duration
                RelativePath = Join-Path $volumeFolder (Join-Path $folderName $fileName)
            }
            continue
        }
        
        # Create chapter folder
        if (-not (Test-Path $chapterFolder)) {
            New-Item -ItemType Directory -Path $chapterFolder -Force | Out-Null
        }
        
        # Build FFmpeg command
        $ffmpegStart = Convert-SecondsToFFmpegTimestamp $startTime
        
        if ($Reencode) {
            # Re-encoding mode: slower but precise cuts, fixes broken segments
            $ffmpegArgs = @(
                "-i", "`"$VideoFile`"",
                "-ss", $ffmpegStart,
                "-t", $duration,
                "-c:v", $VideoCodec,
                "-crf", $Quality,
                "-c:a", $AudioCodec,
                "-avoid_negative_ts", "make_zero",
                "-progress", "pipe:1",
                "-stats_period", "0.5",
                "`"$outputFile`"",
                "-y"
            )
        } else {
            # Stream copy mode: fast but cuts at keyframes
            $ffmpegArgs = @(
                "-i", "`"$VideoFile`"",
                "-ss", $ffmpegStart,
                "-t", $duration,
                "-c", "copy",
                "-avoid_negative_ts", "make_zero",
                "`"$outputFile`"",
                "-y"
            )
        }
        
        # Execute FFmpeg
        try {
            if ($Reencode) {
                # For re-encoding, show progress percentage
                Write-Host ""
                
                # Use a simpler approach - run FFmpeg and show a spinner
                # The -progress pipe:1 approach has issues with blocking reads
                $ffmpegArgsSimple = @(
                    "-i", "`"$VideoFile`"",
                    "-ss", $ffmpegStart,
                    "-t", $duration,
                    "-c:v", $VideoCodec,
                    "-crf", $Quality,
                    "-c:a", $AudioCodec,
                    "-avoid_negative_ts", "make_zero",
                    "-stats",
                    "`"$outputFile`"",
                    "-y"
                )
                
                Write-Host "    Encoding... " -NoNewline -ForegroundColor DarkGray
                
                $process = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgsSimple -NoNewWindow -Wait -PassThru -RedirectStandardError "NUL"
                
                if ($process.ExitCode -eq 0) {
                    Write-Host "OK" -ForegroundColor Green
                    $successCount++
                } else {
                    Write-Host "FAILED" -ForegroundColor Red
                    $failCount++
                }
            } else {
                # Stream copy - fast, no progress needed
                $process = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru -RedirectStandardError "NUL"
                
                if ($process.ExitCode -eq 0) {
                    Write-Host " OK" -ForegroundColor Green
                    $successCount++
                } else {
                    Write-Host " FAILED (FFmpeg error)" -ForegroundColor Red
                    $failCount++
                }
            }
        }
        catch {
            Write-Host " FAILED (Error: $_)" -ForegroundColor Red
            $failCount++
        }
        
        # Add entry for playlist (relative to parent folder)
        $chapterIndex = $i + 1
        $trackNumber = "{0:D2}-{1:D2}" -f $VolumeIndex, $chapterIndex
        $playlistEntries += @{
            Title = "$VolumeName - $trackNumber. $($chapter.Title)"
            Duration = $duration
            RelativePath = Join-Path $volumeFolder (Join-Path $folderName $fileName)
        }
    }
    
    Write-Host ""
    Write-Host "=== Complete ===" -ForegroundColor Green
    Write-Host "Success: $successCount / $totalChapters" -ForegroundColor $(if ($successCount -eq $totalChapters) { "Green" } else { "Yellow" })
    if ($skipCount -gt 0) {
        Write-Host "Skipped: $skipCount (already exist)" -ForegroundColor DarkYellow
    }
    if ($failCount -gt 0) {
        Write-Host "Failed: $failCount" -ForegroundColor Red
    }
    Write-Host "Output: $baseOutputPath" -ForegroundColor Cyan
    
    # Return playlist entries and parent output path for caller to generate playlist
    return @{
        ParentOutputPath = $parentOutputPath
        PlaylistEntries = $playlistEntries
    }
}

function Write-M3UPlaylist {
    <#
    .SYNOPSIS
        Writes an M3U playlist file from collected entries.
    #>
    param(
        [string]$OutputPath,
        [array]$Entries
    )
    
    $playlistPath = Join-Path $OutputPath "playlist.m3u"
    $playlistLines = @("#EXTM3U")
    $negativeDurations = @()
    
    foreach ($entry in $Entries) {
        $playlistLines += "#EXTINF:$($entry.Duration),$($entry.Title)"
        $playlistLines += $entry.RelativePath
        
        # Track negative durations
        if ($entry.Duration -lt 0) {
            $negativeDurations += $entry
        }
    }
    
    $playlistLines | Out-File -FilePath $playlistPath -Encoding UTF8
    
    Write-Host "Playlist: $playlistPath" -ForegroundColor Cyan
    
    # Warn about negative durations
    if ($negativeDurations.Count -gt 0) {
        Write-Host ""
        Write-Host "!!! WARNING: NEGATIVE DURATIONS DETECTED !!!" -ForegroundColor Red -BackgroundColor Black
        Write-Host "The following chapters have timestamps beyond the video duration:" -ForegroundColor Red
        Write-Host "This usually means the timestamp file doesn't match the video file," -ForegroundColor Red
        Write-Host "or the video file is corrupted/truncated." -ForegroundColor Red
        Write-Host ""
        foreach ($entry in $negativeDurations) {
            Write-Host "  - $($entry.Title): $($entry.Duration) seconds" -ForegroundColor Yellow
        }
        Write-Host ""
    }
}

# --- Batch Processing Functions ---

function Find-VideoTimestampPairs {
    <#
    .SYNOPSIS
        Scans a directory (and optionally its subfolders) for videos and timestamp files.
        First checks the InputDir itself, then checks subfolders.
    #>
    param([string]$InputDir)
    
    $results = @()
    $videoExtensions = @('.mp4', '.mkv', '.avi', '.mov', '.wmv')
    
    # Helper function to check a folder for videos and timestamps
    function Check-Folder {
        param([string]$FolderPath, [string]$FolderName)
        
        $videos = Get-ChildItem -Path $FolderPath -File | Where-Object {
            $videoExtensions -contains $_.Extension.ToLower()
        } | Sort-Object Name
        
        $txtFiles = Get-ChildItem -Path $FolderPath -Filter "*.txt" -File
        
        if ($videos.Count -gt 0 -and $txtFiles.Count -gt 0) {
            $timestampFile = $txtFiles | Select-Object -First 1
            
            return @{
                FolderName = $FolderName
                FolderPath = $FolderPath
                Videos = $videos
                TimestampFile = $timestampFile
            }
        }
        return $null
    }
    
    # First, check the InputDir itself
    $inputDirName = Split-Path $InputDir -Leaf
    $directMatch = Check-Folder -FolderPath $InputDir -FolderName $inputDirName
    if ($null -ne $directMatch) {
        $results += $directMatch
    }
    
    # Then check subfolders
    $subfolders = Get-ChildItem -Path $InputDir -Directory -ErrorAction SilentlyContinue
    
    foreach ($folder in $subfolders) {
        $match = Check-Folder -FolderPath $folder.FullName -FolderName $folder.Name
        if ($null -ne $match) {
            $results += $match
        }
    }
    
    return $results
}

function Parse-MultiVolumeChapterFile {
    <#
    .SYNOPSIS
        Parses a chapter file that may contain multiple VOLUME sections.
    .OUTPUTS
        Array of hashtables, each with VolumeName and Chapters.
    #>
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        throw "Chapter file not found: $FilePath"
    }
    
    $lines = Get-Content $FilePath -Encoding UTF8
    $volumes = @()
    $currentVolume = $null
    $currentChapters = @()
    
    foreach ($line in $lines) {
        $trimmedLine = $line.Trim()
        
        if ([string]::IsNullOrWhiteSpace($trimmedLine)) {
            continue
        }
        
        $parsed = Parse-ChapterLine $trimmedLine
        
        if ($null -eq $parsed) {
            # No timestamp - check if it's a valid volume header
            if (Test-IsVolumeHeader $trimmedLine) {
                # Save previous volume if exists
                if ($null -ne $currentVolume -and $currentChapters.Count -gt 0) {
                    # Repair any misinterpreted timestamps before sorting
                    $repairedChapters = Repair-MisinterpretedTimestamps $currentChapters
                    $sortedChapters = $repairedChapters | Sort-Object { $_.Seconds }
                    # Add Intro chapter if first doesn't start at 0:00
                    if ($sortedChapters[0].Seconds -gt 0) {
                        $sortedChapters = @(@{ Title = "Intro"; Seconds = 0 }) + $sortedChapters
                    }
                    $volumes += @{
                        VolumeName = $currentVolume
                        Chapters = $sortedChapters
                    }
                }
                $currentVolume = $trimmedLine
                $currentChapters = @()
            }
            # Otherwise skip lines without timestamps (e.g., "Course Content", "START TIME")
        } else {
            $currentChapters += $parsed
        }
    }
    
    # Don't forget the last volume
    if ($null -ne $currentVolume -and $currentChapters.Count -gt 0) {
        # Repair any misinterpreted timestamps before sorting
        $repairedChapters = Repair-MisinterpretedTimestamps $currentChapters
        $sortedChapters = $repairedChapters | Sort-Object { $_.Seconds }
        # Add Intro chapter if first doesn't start at 0:00
        if ($sortedChapters[0].Seconds -gt 0) {
            $sortedChapters = @(@{ Title = "Intro"; Seconds = 0 }) + $sortedChapters
        }
        $volumes += @{
            VolumeName = $currentVolume
            Chapters = $sortedChapters
        }
    }
    
    # If no volume headers found, treat entire file as one volume
    if ($volumes.Count -eq 0 -and $currentChapters.Count -gt 0) {
        # Repair any misinterpreted timestamps before sorting
        $repairedChapters = Repair-MisinterpretedTimestamps $currentChapters
        $sortedChapters = $repairedChapters | Sort-Object { $_.Seconds }
        # Add Intro chapter if first doesn't start at 0:00
        if ($sortedChapters[0].Seconds -gt 0) {
            $sortedChapters = @(@{ Title = "Intro"; Seconds = 0 }) + $sortedChapters
        }
        $volumes += @{
            VolumeName = "chapters"
            Chapters = $sortedChapters
        }
    }
    
    return $volumes
}

function Show-BatchPreview {
    <#
    .SYNOPSIS
        Shows a full tree preview of all folders and chapters to be created.
    #>
    param(
        [array]$Pairs,
        [string]$OutputDir
    )
    
    Write-Host ""
    Write-Host "=== Batch Processing Preview ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Output: " -NoNewline; Write-Host $OutputDir -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Structure to be created:" -ForegroundColor Green
    Write-Host ""
    
    foreach ($pair in $Pairs) {
        Write-Host "  $($pair.FolderName)/" -ForegroundColor White
        
        # Parse the chapter file to show volumes and chapters
        $volumes = Parse-MultiVolumeChapterFile $pair.TimestampFile.FullName
        $videos = $pair.Videos
        
        # Always show playlist first
        Write-Host "  $script:TreeBranch" -NoNewline -ForegroundColor DarkGray; Write-Host "playlist.m3u" -ForegroundColor DarkCyan
        
        # Build list of matched volumes to display
        $matchedVolumes = @()
        
        if ($videos.Count -eq $volumes.Count) {
            # 1:1 matching by order
            for ($v = 0; $v -lt $videos.Count; $v++) {
                $matchedVolumes += @{
                    Video = $videos[$v]
                    Volume = $volumes[$v]
                }
            }
        } else {
            # Match by number in filename
            foreach ($video in $videos) {
                if ($video.BaseName -match '(\d+)\s*$') {
                    $videoNum = [int]$Matches[1]
                    $matchedVolume = $volumes | Where-Object { $_.VolumeName -match "\b$videoNum\b" } | Select-Object -First 1
                    if ($matchedVolume) {
                        $matchedVolumes += @{
                            Video = $video
                            Volume = $matchedVolume
                        }
                    }
                }
            }
        }
        
        # Display matched volumes with tree structure
        for ($v = 0; $v -lt $matchedVolumes.Count; $v++) {
            $match = $matchedVolumes[$v]
            $video = $match.Video
            $volume = $match.Volume
            $videoExt = [System.IO.Path]::GetExtension($video.Name)
            $volumeFolder = Get-SafeFilename $volume.VolumeName
            
            $isLastVolume = ($v -eq $matchedVolumes.Count - 1)
            $volBranch = if ($isLastVolume) { $script:TreeLast } else { $script:TreeBranch }
            $volCont = if ($isLastVolume) { $script:TreeSpace } else { $script:TreePipe }
            
            Write-Host "  $volBranch" -NoNewline -ForegroundColor DarkGray; Write-Host "$volumeFolder/" -ForegroundColor White
            
            # Count existing files for this volume
            $parentOutputPath = Join-Path $OutputDir $pair.FolderName
            $baseOutputPath = Join-Path $parentOutputPath $volumeFolder
            $existingCount = 0
            $newCount = 0
            
            for ($c = 0; $c -lt $volume.Chapters.Count; $c++) {
                $chapter = $volume.Chapters[$c]
                $safeTitle = Get-SafeFilename $chapter.Title
                $folderName = "{0:D2}. {1}" -f ($c + 1), $safeTitle
                $fileName = "$safeTitle$videoExt"
                $chapterFolder = Join-Path $baseOutputPath $folderName
                $outputFile = Join-Path $chapterFolder $fileName
                
                if (Test-Path $outputFile) {
                    $existingCount++
                } else {
                    $newCount++
                }
            }
            
            Write-Host "  $volCont" -NoNewline -ForegroundColor DarkGray
            if ($existingCount -gt 0) {
                Write-Host "($($volume.Chapters.Count) chapters: " -NoNewline -ForegroundColor DarkGray
                Write-Host "$newCount new" -NoNewline -ForegroundColor Green
                Write-Host ", " -NoNewline -ForegroundColor DarkGray
                Write-Host "$existingCount skip" -NoNewline -ForegroundColor DarkYellow
                Write-Host ")" -ForegroundColor DarkGray
            } else {
                Write-Host "($($volume.Chapters.Count) chapters)" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }
}

function Invoke-BatchProcess {
    <#
    .SYNOPSIS
        Processes all video/timestamp pairs in batch mode.
    #>
    param(
        [array]$Pairs,
        [string]$OutputDir
    )
    
    $totalFolders = $Pairs.Count
    $folderIndex = 0
    
    foreach ($pair in $Pairs) {
        $folderIndex++
        $allPlaylistEntries = @()
        $parentOutputPath = $null
        
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Processing folder $folderIndex of $totalFolders`: $($pair.FolderName)" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        # Parse the multi-volume chapter file
        $volumes = Parse-MultiVolumeChapterFile $pair.TimestampFile.FullName
        
        if ($volumes.Count -eq 0) {
            Write-Warning "No chapters found in $($pair.TimestampFile.Name), skipping."
            continue
        }
        
        # Match videos to volumes
        # If same count, match by order. Otherwise try to match by number in filename.
        $videos = $pair.Videos
        
        if ($videos.Count -eq $volumes.Count) {
            # Direct 1:1 matching by order
            for ($v = 0; $v -lt $videos.Count; $v++) {
                $video = $videos[$v]
                $volume = $volumes[$v]
                
                Write-Host ""
                Write-Host "--- Video $($v + 1) of $($videos.Count): $($video.Name) ---" -ForegroundColor Yellow
                Write-Host "    Volume: $($volume.VolumeName)" -ForegroundColor Gray
                Write-Host "    Chapters: $($volume.Chapters.Count)" -ForegroundColor Gray
                
                $videoDuration = Get-VideoDuration $video.FullName
                
                $result = Split-VideoFile -VideoFile $video.FullName `
                                -VideoDuration $videoDuration `
                                -VolumeName $volume.VolumeName `
                                -VolumeIndex ($v + 1) `
                                -Chapters $volume.Chapters `
                                -OutputDir $OutputDir `
                                -Reencode $Reencode `
                                -VideoCodec $VideoCodec `
                                -AudioCodec $AudioCodec `
                                -Quality $Quality
                
                if ($result) {
                    $parentOutputPath = $result.ParentOutputPath
                    $allPlaylistEntries += $result.PlaylistEntries
                }
            }
        } else {
            # Try to match by number in filename
            Write-Host "Videos: $($videos.Count), Volumes: $($volumes.Count) - matching by filename number" -ForegroundColor Yellow
            
            foreach ($video in $videos) {
                # Extract number from filename (e.g., "Armbar 1.mp4" -> 1)
                if ($video.BaseName -match '(\d+)\s*$') {
                    $videoNum = [int]$Matches[1]
                    
                    # Find matching volume (VOLUME 1, VOLUME 2, etc.)
                    $matchedVolume = $volumes | Where-Object {
                        $_.VolumeName -match "\b$videoNum\b"
                    } | Select-Object -First 1
                    
                    if ($matchedVolume) {
                        Write-Host ""
                        Write-Host "--- $($video.Name) -> $($matchedVolume.VolumeName) ---" -ForegroundColor Yellow
                        
                        $videoDuration = Get-VideoDuration $video.FullName
                        
                        $result = Split-VideoFile -VideoFile $video.FullName `
                                        -VideoDuration $videoDuration `
                                        -VolumeName $matchedVolume.VolumeName `
                                        -VolumeIndex $videoNum `
                                        -Chapters $matchedVolume.Chapters `
                                        -OutputDir $OutputDir `
                                        -Reencode $Reencode `
                                        -VideoCodec $VideoCodec `
                                        -AudioCodec $AudioCodec `
                                        -Quality $Quality
                        
                        if ($result) {
                            $parentOutputPath = $result.ParentOutputPath
                            $allPlaylistEntries += $result.PlaylistEntries
                        }
                    } else {
                        Write-Warning "Could not match $($video.Name) to any volume"
                    }
                } else {
                    Write-Warning "Could not extract number from $($video.Name)"
                }
            }
        }
        
        # Write playlist for this folder (all volumes combined)
        if ($parentOutputPath -and $allPlaylistEntries.Count -gt 0) {
            Write-M3UPlaylist -OutputPath $parentOutputPath -Entries $allPlaylistEntries
        }
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Batch processing complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
}

# --- Main Script ---

# Check FFmpeg availability
$ffmpegAvailable = Test-FFmpegAvailable
if (-not $ffmpegAvailable) {
    Write-Error "FFmpeg is not installed or not in PATH. Please install FFmpeg first."
    Write-Host "Download from: https://ffmpeg.org/download.html" -ForegroundColor Yellow
    exit 1
}

# Determine mode: Batch or Single
$batchMode = -not [string]::IsNullOrWhiteSpace($InputDir)
$singleMode = -not [string]::IsNullOrWhiteSpace($VideoFile)

if (-not $batchMode -and -not $singleMode) {
    Write-Error "Please specify either -InputDir for batch mode or -VideoFile and -ChapterFile for single file mode."
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Cyan
    Write-Host "  Single file: .\split-video.ps1 -VideoFile 'video.mp4' -ChapterFile 'chapters.txt'"
    Write-Host "  Batch mode:  .\split-video.ps1 -InputDir '.\Courses'"
    exit 1
}

if ($batchMode) {
    # --- Batch Mode ---
    
    if (-not (Test-Path $InputDir)) {
        Write-Error "Input directory not found: $InputDir"
        exit 1
    }
    
    $InputDir = Resolve-Path $InputDir
    
    Write-Host "Scanning for videos and timestamp files..." -ForegroundColor Cyan
    $pairs = Find-VideoTimestampPairs $InputDir
    
    if ($pairs.Count -eq 0) {
        Write-Error "No folders found with both video and timestamp files."
        Write-Host "Make sure subfolders contain .mp4/.mkv files and a .txt timestamp file." -ForegroundColor Yellow
        exit 1
    }
    
    # Show preview
    Show-BatchPreview -Pairs $pairs -OutputDir $OutputDir
    
    # Get confirmation (unless -Force)
    if (-not $Force) {
        if (-not (Get-Confirmation)) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            exit 0
        }
    }
    
    # Process all pairs
    Invoke-BatchProcess -Pairs $pairs -OutputDir $OutputDir
    
} else {
    # --- Single File Mode ---
    
    if ([string]::IsNullOrWhiteSpace($ChapterFile)) {
        Write-Error "Please specify -ChapterFile when using -VideoFile."
        exit 1
    }
    
    # Validate inputs
    if (-not (Test-Path $VideoFile)) {
        Write-Error "Video file not found: $VideoFile"
        exit 1
    }

    if (-not (Test-Path $ChapterFile)) {
        Write-Error "Chapter file not found: $ChapterFile"
        exit 1
    }

    # Get absolute paths
    $VideoFile = Resolve-Path $VideoFile
    $ChapterFile = Resolve-Path $ChapterFile

    # Parse the chapter file
    Write-Host "Parsing chapter file..." -ForegroundColor Cyan
    $result = Parse-ChapterFile $ChapterFile

    if ($result.Chapters.Count -eq 0) {
        Write-Error "No chapters found in file. Make sure timestamps use colons (e.g., 0:00 or 1:23)"
        exit 1
    }

    # Get video duration
    Write-Host "Getting video duration..." -ForegroundColor Cyan
    $videoDuration = Get-VideoDuration $VideoFile

    # Show preview
    Show-Preview -VideoFile $VideoFile `
                 -VideoDuration $videoDuration `
                 -VolumeName $result.VolumeName `
                 -Chapters $result.Chapters `
                 -OutputDir $OutputDir

    # Get confirmation (unless -Force)
    if (-not $Force) {
        if (-not (Get-Confirmation)) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            exit 0
        }
    }

    # Split the video
    $splitResult = Split-VideoFile -VideoFile $VideoFile `
                    -VideoDuration $videoDuration `
                    -VolumeName $result.VolumeName `
                    -VolumeIndex 1 `
                    -Chapters $result.Chapters `
                    -OutputDir $OutputDir `
                    -Reencode $Reencode `
                    -VideoCodec $VideoCodec `
                    -AudioCodec $AudioCodec `
                    -Quality $Quality
    
    # Write playlist
    if ($splitResult -and $splitResult.PlaylistEntries.Count -gt 0) {
        Write-M3UPlaylist -OutputPath $splitResult.ParentOutputPath -Entries $splitResult.PlaylistEntries
    }
}
