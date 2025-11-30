<#
.SYNOPSIS
    Splits video files into segments based on timestamped chapter files.

.DESCRIPTION
    Takes a video file and a text file containing chapter timestamps,
    then splits the video into separate files organized in folders.
    
    Can process a single video or batch process an entire folder.

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

.EXAMPLE
    .\split-video.ps1 -VideoFile "video.mp4" -ChapterFile "chapters.txt"

.EXAMPLE
    .\split-video.ps1 -InputDir ".\Courses" -OutputDir ".\output"
#>

param(
    [string]$VideoFile,
    
    [string]$ChapterFile,
    
    [string]$InputDir,
    
    [string]$OutputDir = ".\output",
    
    [switch]$Force
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
    .EXAMPLE
        Convert-TimestampToSeconds "1:23"    # Returns 83
        Convert-TimestampToSeconds "1:23:45" # Returns 5025
        Convert-TimestampToSeconds "45"      # Returns 45
    #>
    param([string]$Timestamp)
    
    $parts = $Timestamp -split ':'
    
    switch ($parts.Count) {
        1 { 
            # Just seconds: "45"
            return [int]$parts[0] 
        }
        2 { 
            # M:SS or MM:SS: "1:23"
            return ([int]$parts[0] * 60) + [int]$parts[1] 
        }
        3 { 
            # H:MM:SS: "1:23:45"
            return ([int]$parts[0] * 3600) + ([int]$parts[1] * 60) + [int]$parts[2] 
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
    
    # Match patterns: "0", "1:23", "01:23", "1:23:45", "01:23:45"
    return $Text -match '^\d{1,2}(:\d{2}){0,2}$'
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
    #>
    param([string]$Line)
    
    $Line = $Line.Trim()
    
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    
    # Regex to find timestamp (whitespace-agnostic)
    # Patterns with colon: "0:00", "1:23", "01:23", "1:23:45", "01:23:45"
    # Special case: "0" alone (whitespace-separated) means 0:00
    
    $timestamp = $null
    $title = $null
    
    # Match timestamp with colon(s): M:SS, MM:SS, H:MM:SS, HH:MM:SS
    if ($Line -match '(\d{1,2}:\d{2}(?::\d{2})?)') {
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
    
    # Remove the timestamp from the line to get the title
    $title = $Line -replace [regex]::Escape($timestamp), ''
    
    # Clean up separators and extra whitespace
    $title = $title -replace '^\s*[-–—]\s*', ''  # Leading dash
    $title = $title -replace '\s*[-–—]\s*$', ''  # Trailing dash
    $title = $title -replace '\t', ' '           # Tabs to spaces
    $title = $title -replace '\s+', ' '          # Multiple spaces to one
    $title = $title.Trim()
    
    if ([string]::IsNullOrWhiteSpace($title)) {
        return $null
    }
    
    return @{
        Title = $title
        Seconds = $seconds
    }
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
    $isFirstNonEmptyLine = $true
    
    foreach ($line in $lines) {
        $trimmedLine = $line.Trim()
        
        if ([string]::IsNullOrWhiteSpace($trimmedLine)) {
            continue
        }
        
        $parsed = Parse-ChapterLine $trimmedLine
        
        if ($null -eq $parsed) {
            # No timestamp found - could be a header
            if ($isFirstNonEmptyLine -or $null -eq $volumeName) {
                $volumeName = $trimmedLine
            }
            # Otherwise skip lines without timestamps
        } else {
            $chapters += $parsed
        }
        
        $isFirstNonEmptyLine = $false
    }
    
    # Sort chapters by timestamp
    $chapters = $chapters | Sort-Object { $_.Seconds }
    
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
    
    Write-Host ""
    Write-Host "=== Video Splitter Preview ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Source: " -NoNewline; Write-Host $videoName -ForegroundColor Yellow -NoNewline
    Write-Host " ($durationStr)"
    Write-Host "Chapters: " -NoNewline; Write-Host "$($Chapters.Count) segments" -ForegroundColor Yellow
    Write-Host "Output: " -NoNewline; Write-Host $OutputDir -ForegroundColor Yellow
    Write-Host ""
    
    # Build folder name from volume
    $volumeFolder = if ($VolumeName) { Get-SafeFilename $VolumeName } else { "chapters" }
    
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
        
        $isLast = ($i -eq $Chapters.Count - 1)
        $branch = if ($isLast) { $script:TreeLast } else { $script:TreeBranch }
        $cont = if ($isLast) { $script:TreeSpace } else { $script:TreePipe }
        
        Write-Host "  $script:TreeSpace$branch" -NoNewline -ForegroundColor DarkGray; Write-Host "$folderName/" -ForegroundColor Gray
        Write-Host "  $script:TreeSpace$cont$script:TreeLast" -NoNewline -ForegroundColor DarkGray
        Write-Host "$fileName  " -NoNewline -ForegroundColor DarkGray
        Write-Host "[$startStr - $endStr]" -ForegroundColor DarkCyan
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
        [string]$OutputDir
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
    Write-Host "Splitting video into $totalChapters segments..." -ForegroundColor Cyan
    Write-Host ""
    
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
        
        # Create chapter folder
        if (-not (Test-Path $chapterFolder)) {
            New-Item -ItemType Directory -Path $chapterFolder -Force | Out-Null
        }
        
        # Progress display
        $progress = $i + 1
        $startStr = Convert-SecondsToTimestamp $startTime
        $endStr = if ($endTime) { Convert-SecondsToTimestamp $endTime } else { "end" }
        
        Write-Host "[${progress}/${totalChapters}] " -NoNewline -ForegroundColor Cyan
        Write-Host "$($chapter.Title) " -NoNewline -ForegroundColor White
        Write-Host "[$startStr - $endStr]" -NoNewline -ForegroundColor DarkGray
        
        # Build FFmpeg command
        $ffmpegStart = Convert-SecondsToFFmpegTimestamp $startTime
        
        $ffmpegArgs = @(
            "-i", "`"$VideoFile`"",
            "-ss", $ffmpegStart,
            "-t", $duration,
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            "`"$outputFile`"",
            "-y"
        )
        
        # Execute FFmpeg
        try {
            $process = Start-Process -FilePath "ffmpeg" -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru -RedirectStandardError "NUL"
            
            if ($process.ExitCode -eq 0) {
                Write-Host " OK" -ForegroundColor Green
                $successCount++
            } else {
                Write-Host " FAILED (FFmpeg error)" -ForegroundColor Red
                $failCount++
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
            Title = "$trackNumber. $VolumeName - $($chapter.Title)"
            Duration = $duration
            RelativePath = Join-Path $volumeFolder (Join-Path $folderName $fileName)
        }
    }
    
    Write-Host ""
    Write-Host "=== Complete ===" -ForegroundColor Green
    Write-Host "Success: $successCount / $totalChapters" -ForegroundColor $(if ($successCount -eq $totalChapters) { "Green" } else { "Yellow" })
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
    
    foreach ($entry in $Entries) {
        $playlistLines += "#EXTINF:$($entry.Duration),$($entry.Title)"
        $playlistLines += $entry.RelativePath
    }
    
    $playlistLines | Out-File -FilePath $playlistPath -Encoding UTF8
    
    Write-Host "Playlist: $playlistPath" -ForegroundColor Cyan
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
            # No timestamp - this is a volume header
            # Save previous volume if exists
            if ($null -ne $currentVolume -and $currentChapters.Count -gt 0) {
                $volumes += @{
                    VolumeName = $currentVolume
                    Chapters = $currentChapters | Sort-Object { $_.Seconds }
                }
            }
            $currentVolume = $trimmedLine
            $currentChapters = @()
        } else {
            $currentChapters += $parsed
        }
    }
    
    # Don't forget the last volume
    if ($null -ne $currentVolume -and $currentChapters.Count -gt 0) {
        $volumes += @{
            VolumeName = $currentVolume
            Chapters = $currentChapters | Sort-Object { $_.Seconds }
        }
    }
    
    # If no volume headers found, treat entire file as one volume
    if ($volumes.Count -eq 0 -and $currentChapters.Count -gt 0) {
        $volumes += @{
            VolumeName = "chapters"
            Chapters = $currentChapters | Sort-Object { $_.Seconds }
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
            Write-Host "  $volCont" -NoNewline -ForegroundColor DarkGray
            Write-Host "($($volume.Chapters.Count) chapters)" -ForegroundColor DarkGray
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
                                -OutputDir $OutputDir
                
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
                                        -OutputDir $OutputDir
                        
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
                    -OutputDir $OutputDir
    
    # Write playlist
    if ($splitResult -and $splitResult.PlaylistEntries.Count -gt 0) {
        Write-M3UPlaylist -OutputPath $splitResult.ParentOutputPath -Entries $splitResult.PlaylistEntries
    }
}
