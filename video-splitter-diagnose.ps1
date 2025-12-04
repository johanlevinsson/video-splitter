<#
.SYNOPSIS
    Diagnoses potential issues in video-splitter output.

.DESCRIPTION
    Scans the output directory for common problems:
    - Playlist issues (missing files, invalid timestamps)
    - Video issues (corrupt, wrong duration, missing streams)
    - Structure issues (empty folders, missing chapters, duplicates)
    - File issues (zero bytes, very small files)

.PARAMETER OutputDir
    Path to the video-splitter output directory to diagnose.

.PARAMETER MinDuration
    Minimum expected clip duration in seconds. Default: 30

.PARAMETER MaxDuration
    Maximum expected clip duration in seconds. Default: 1200 (20 minutes)

.PARAMETER SkipFFprobe
    Skip video file validation with ffprobe (faster but less thorough).

.EXAMPLE
    .\video-splitter-diagnose.ps1 -OutputDir ".\output"

.EXAMPLE
    .\video-splitter-diagnose.ps1 -OutputDir ".\output" -MinDuration 20 -MaxDuration 1800
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    
    [int]$MinDuration = 30,
    
    [int]$MaxDuration = 1200,
    
    [switch]$SkipFFprobe
)

# --- Helper Functions ---

function Convert-SecondsToTimestamp {
    param([int]$Seconds)
    
    if ($Seconds -lt 0) {
        return "-" + (Convert-SecondsToTimestamp ([Math]::Abs($Seconds)))
    }
    
    $hours = [int][Math]::Floor($Seconds / 3600)
    $minutes = [int][Math]::Floor(($Seconds % 3600) / 60)
    $secs = [int]($Seconds % 60)
    
    if ($hours -gt 0) {
        return "{0}:{1:D2}:{2:D2}" -f $hours, $minutes, $secs
    } else {
        return "{0}:{1:D2}" -f $minutes, $secs
    }
}

function Get-VideoDuration {
    param([string]$FilePath)
    
    try {
        $result = & ffprobe -v quiet -show_entries format=duration -of csv=p=0 $FilePath 2>$null
        if ($result) {
            return [double]$result
        }
    } catch {
        return $null
    }
    return $null
}

function Test-VideoIntegrity {
    param([string]$FilePath)
    
    try {
        $result = & ffprobe -v error -show_entries stream=codec_type -of csv=p=0 $FilePath 2>&1
        $hasVideo = $result -match 'video'
        $hasAudio = $result -match 'audio'
        $errors = $result | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
        
        return @{
            HasVideo = $hasVideo
            HasAudio = $hasAudio
            Errors = $errors
            Success = ($null -eq $errors -or $errors.Count -eq 0)
        }
    } catch {
        return @{
            HasVideo = $false
            HasAudio = $false
            Errors = @($_.Exception.Message)
            Success = $false
        }
    }
}

# --- Issue Collection ---

$issues = @{
    Critical = @()
    Warning = @()
    Info = @()
}

# Per-course issues for log files
$courseIssues = @{}

function Add-Issue {
    param(
        [ValidateSet('Critical', 'Warning', 'Info')]
        [string]$Severity,
        [string]$Category,
        [string]$Message,
        [string]$Path,
        [string]$CourseName
    )
    
    $issue = @{
        Category = $Category
        Message = $Message
        Path = $Path
    }
    
    $issues[$Severity] += $issue
    
    # Also track per-course
    if ($CourseName) {
        if (-not $courseIssues.ContainsKey($CourseName)) {
            $courseIssues[$CourseName] = @{
                Critical = @()
                Warning = @()
                Info = @()
            }
        }
        $courseIssues[$CourseName][$Severity] += $issue
    }
}

function Write-CourseLog {
    param(
        [string]$CoursePath,
        [string]$CourseName
    )
    
    $logPath = Join-Path $CoursePath "diagnostics.log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logContent = @()
    $logContent += "Video Splitter Diagnostics - $timestamp"
    $logContent += "=" * 50
    $logContent += ""
    
    if (-not $courseIssues.ContainsKey($CourseName)) {
        $logContent += "Status: OK"
        $logContent += ""
        $logContent += "No issues found."
    } else {
        $ci = $courseIssues[$CourseName]
        $criticalCount = $ci.Critical.Count
        $warningCount = $ci.Warning.Count
        
        if ($criticalCount -gt 0) {
            $logContent += "Status: ERRORS FOUND"
        } else {
            $logContent += "Status: WARNINGS"
        }
        $logContent += ""
        
        if ($criticalCount -gt 0) {
            $logContent += "CRITICAL ISSUES ($criticalCount):"
            $logContent += "-" * 30
            foreach ($issue in $ci.Critical) {
                $logContent += "  [$($issue.Category)] $($issue.Message)"
                $logContent += "    Path: $($issue.Path)"
            }
            $logContent += ""
        }
        
        if ($warningCount -gt 0) {
            $logContent += "WARNINGS ($warningCount):"
            $logContent += "-" * 30
            foreach ($issue in $ci.Warning) {
                $logContent += "  [$($issue.Category)] $($issue.Message)"
                $logContent += "    Path: $($issue.Path)"
            }
            $logContent += ""
        }
    }
    
    $logContent | Out-File -FilePath $logPath -Encoding UTF8
}

# --- Main Diagnostics ---

Write-Host ""
Write-Host "=== Video Splitter Diagnostics ===" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $OutputDir)) {
    Write-Host "ERROR: Output directory not found: $OutputDir" -ForegroundColor Red
    exit 1
}

$OutputDir = (Resolve-Path $OutputDir).Path
Write-Host "Scanning: " -NoNewline; Write-Host $OutputDir -ForegroundColor Yellow
Write-Host ""

# Find all course folders (folders containing playlist.m3u)
$courseFolders = Get-ChildItem -Path $OutputDir -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName "playlist.m3u")
}

if ($courseFolders.Count -eq 0) {
    Write-Host "No course folders found (folders with playlist.m3u)" -ForegroundColor Yellow
    exit 0
}

Write-Host "Found $($courseFolders.Count) course folder(s)" -ForegroundColor Green
Write-Host ""

$totalVideos = 0
$checkedVideos = 0

foreach ($course in $courseFolders) {
    Write-Host "Checking: $($course.Name)" -ForegroundColor White
    
    $currentCourseName = $course.Name
    $playlistPath = Join-Path $course.FullName "playlist.m3u"
    
    # --- Check Playlist ---
    Write-Host "  Checking playlist..." -ForegroundColor Gray
    
    $playlistContent = Get-Content $playlistPath -ErrorAction SilentlyContinue
    if (-not $playlistContent) {
        Add-Issue -Severity 'Warning' -Category 'Playlist' -Message "Empty playlist file" -Path $playlistPath -CourseName $currentCourseName
    } else {
        $lastDuration = $null
        $lastTitle = $null
        $lineNum = 0
        
        foreach ($line in $playlistContent) {
            $lineNum++
            
            if ($line -match '^#EXTINF:(-?\d+),(.*)') {
                $lastDuration = [int]$Matches[1]
                $lastTitle = $Matches[2].Trim()
            }
            elseif ($line -notmatch '^#' -and $line.Trim()) {
                # This is a file path - check the previous EXTINF entry
                $filePath = Join-Path $course.FullName $line
                $clipName = if ($lastTitle) { $lastTitle } else { $line }
                
                if (-not (Test-Path $filePath)) {
                    Add-Issue -Severity 'Critical' -Category 'Playlist' -Message "Missing file referenced in playlist: $line" -Path $playlistPath -CourseName $currentCourseName
                }
                
                if ($null -ne $lastDuration) {
                    # Check for negative duration
                    if ($lastDuration -lt 0) {
                        Add-Issue -Severity 'Critical' -Category 'Playlist' -Message "Negative duration ($(Convert-SecondsToTimestamp $lastDuration)): $clipName" -Path $playlistPath -CourseName $currentCourseName
                    }
                    # Check for very short duration
                    elseif ($lastDuration -lt $MinDuration -and $lastDuration -gt 0) {
                        Add-Issue -Severity 'Warning' -Category 'Playlist' -Message "Very short clip ($(Convert-SecondsToTimestamp $lastDuration)): $clipName" -Path $playlistPath -CourseName $currentCourseName
                    }
                    # Check for very long duration
                    elseif ($lastDuration -gt $MaxDuration) {
                        Add-Issue -Severity 'Warning' -Category 'Playlist' -Message "Very long clip ($(Convert-SecondsToTimestamp $lastDuration)): $clipName" -Path $playlistPath -CourseName $currentCourseName
                    }
                }
                
                $lastDuration = $null
                $lastTitle = $null
            }
        }
    }
    
    # --- Check Volume Folders ---
    $volumeFolders = Get-ChildItem -Path $course.FullName -Directory | Where-Object { $_.Name -match 'volume' }
    
    foreach ($volume in $volumeFolders) {
        Write-Host "  Checking $($volume.Name)..." -ForegroundColor Gray
        
        # Get chapter folders
        $chapterFolders = Get-ChildItem -Path $volume.FullName -Directory | Sort-Object Name
        
        if ($chapterFolders.Count -eq 0) {
            Add-Issue -Severity 'Warning' -Category 'Structure' -Message "Empty volume folder" -Path $volume.FullName -CourseName $currentCourseName
            continue
        }
        
        # Check for gaps and duplicates in numbering
        $expectedNum = 1
        $seenNumbers = @{}
        
        foreach ($chapter in $chapterFolders) {
            if ($chapter.Name -match '^(\d+)\.') {
                $num = [int]$Matches[1]
                
                # Check for duplicate chapter numbers
                if ($seenNumbers.ContainsKey($num)) {
                    Add-Issue -Severity 'Critical' -Category 'Structure' -Message "Duplicate chapter number: $num" -Path $volume.FullName -CourseName $currentCourseName
                }
                $seenNumbers[$num] = $true
                
                # Check for gaps
                if ($num -ne $expectedNum) {
                    Add-Issue -Severity 'Critical' -Category 'Structure' -Message "Gap in chapter numbering: expected $expectedNum, found $num" -Path $volume.FullName -CourseName $currentCourseName
                }
                $expectedNum = $num + 1
            }
            
            # Check chapter folder contents
            $videoFiles = Get-ChildItem -Path $chapter.FullName -File | Where-Object { 
                $_.Extension -match '\.(mp4|mkv|avi|mov|webm)$' 
            }
            
            if ($videoFiles.Count -eq 0) {
                Add-Issue -Severity 'Critical' -Category 'Structure' -Message "Empty chapter folder (no video)" -Path $chapter.FullName -CourseName $currentCourseName
                continue
            }
            
            foreach ($video in $videoFiles) {
                $totalVideos++
                
                # Check file size
                if ($video.Length -eq 0) {
                    Add-Issue -Severity 'Critical' -Category 'File' -Message "Zero-byte video file" -Path $video.FullName -CourseName $currentCourseName
                    continue
                }
                elseif ($video.Length -lt 10KB) {
                    Add-Issue -Severity 'Critical' -Category 'File' -Message "Very small video file ($([Math]::Round($video.Length / 1KB, 1)) KB)" -Path $video.FullName -CourseName $currentCourseName
                    continue
                }
                
                # Check video with ffprobe (if not skipped)
                if (-not $SkipFFprobe) {
                    $checkedVideos++
                    Write-Progress -Activity "Checking videos" -Status $video.Name -PercentComplete (($checkedVideos / $totalVideos) * 100)
                    
                    # Check duration
                    $duration = Get-VideoDuration $video.FullName
                    if ($null -eq $duration) {
                        Add-Issue -Severity 'Critical' -Category 'Video' -Message "Cannot read video duration (possibly corrupt)" -Path $video.FullName -CourseName $currentCourseName
                    }
                    elseif ($duration -lt $MinDuration) {
                        Add-Issue -Severity 'Warning' -Category 'Video' -Message "Very short video ($(Convert-SecondsToTimestamp ([int]$duration)))" -Path $video.FullName -CourseName $currentCourseName
                    }
                    elseif ($duration -gt $MaxDuration) {
                        Add-Issue -Severity 'Warning' -Category 'Video' -Message "Very long video ($(Convert-SecondsToTimestamp ([int]$duration)))" -Path $video.FullName -CourseName $currentCourseName
                    }
                    
                    # Check integrity
                    $integrity = Test-VideoIntegrity $video.FullName
                    if (-not $integrity.Success) {
                        Add-Issue -Severity 'Critical' -Category 'Video' -Message "Video has errors: $($integrity.Errors -join '; ')" -Path $video.FullName -CourseName $currentCourseName
                    }
                    elseif (-not $integrity.HasVideo) {
                        Add-Issue -Severity 'Critical' -Category 'Video' -Message "No video stream found" -Path $video.FullName -CourseName $currentCourseName
                    }
                    elseif (-not $integrity.HasAudio) {
                        Add-Issue -Severity 'Warning' -Category 'Video' -Message "No audio stream found" -Path $video.FullName -CourseName $currentCourseName
                    }
                }
            }
        }
    }
    
    # Check for long paths
    $allFiles = Get-ChildItem -Path $course.FullName -Recurse -File
    foreach ($file in $allFiles) {
        if ($file.FullName.Length -gt 260) {
            Add-Issue -Severity 'Critical' -Category 'File' -Message "Path exceeds 260 characters" -Path $file.FullName -CourseName $currentCourseName
        }
    }
    
    # Write log file for this course
    Write-CourseLog -CoursePath $course.FullName -CourseName $currentCourseName
}

Write-Progress -Activity "Checking videos" -Completed

# --- Report Results ---

Write-Host ""
Write-Host "=== Diagnostics Report ===" -ForegroundColor Cyan
Write-Host ""

$totalIssues = $issues.Critical.Count + $issues.Warning.Count + $issues.Info.Count

if ($totalIssues -eq 0) {
    Write-Host "No issues found! " -ForegroundColor Green -NoNewline
    Write-Host ([char]0x2714) -ForegroundColor Green
    Write-Host ""
    Write-Host "Checked $totalVideos video(s)" -ForegroundColor Gray
    exit 0
}

# Critical issues
if ($issues.Critical.Count -gt 0) {
    Write-Host "!!! CRITICAL ISSUES ($($issues.Critical.Count)) !!!" -ForegroundColor Red
    Write-Host ""
    foreach ($issue in $issues.Critical) {
        Write-Host "  [$($issue.Category)] " -NoNewline -ForegroundColor Red
        Write-Host $issue.Message -ForegroundColor White
        Write-Host "    $($issue.Path)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# Warnings
if ($issues.Warning.Count -gt 0) {
    Write-Host "WARNINGS ($($issues.Warning.Count))" -ForegroundColor Yellow
    Write-Host ""
    foreach ($issue in $issues.Warning) {
        Write-Host "  [$($issue.Category)] " -NoNewline -ForegroundColor Yellow
        Write-Host $issue.Message -ForegroundColor White
        Write-Host "    $($issue.Path)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# Info
if ($issues.Info.Count -gt 0) {
    Write-Host "INFO ($($issues.Info.Count))" -ForegroundColor Cyan
    Write-Host ""
    foreach ($issue in $issues.Info) {
        Write-Host "  [$($issue.Category)] " -NoNewline -ForegroundColor Cyan
        Write-Host $issue.Message -ForegroundColor White
        Write-Host "    $($issue.Path)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# Summary
Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host "Summary: " -NoNewline
if ($issues.Critical.Count -gt 0) {
    Write-Host "$($issues.Critical.Count) critical" -NoNewline -ForegroundColor Red
    Write-Host ", " -NoNewline
}
if ($issues.Warning.Count -gt 0) {
    Write-Host "$($issues.Warning.Count) warnings" -NoNewline -ForegroundColor Yellow
}
if ($issues.Info.Count -gt 0) {
    if ($issues.Warning.Count -gt 0) { Write-Host ", " -NoNewline }
    Write-Host "$($issues.Info.Count) info" -NoNewline -ForegroundColor Cyan
}
Write-Host ""
Write-Host "Checked $totalVideos video(s)" -ForegroundColor Gray
Write-Host ""

# Exit with error code if critical issues found
if ($issues.Critical.Count -gt 0) {
    exit 1
}
exit 0
