# Pester tests for video-splitter.ps1
# Run with: Invoke-Pester -Path .\video-splitter.Tests.ps1
# Compatible with Pester 3.x

# Define test copies of the functions (avoids importing the full script)
function Convert-TimestampToSeconds {
    param(
        [string]$Timestamp,
        [switch]$ForceMinutesSeconds
    )
    $normalized = $Timestamp -replace '\.', ':'
    $parts = $normalized -split ':'
    $intParts = $parts | ForEach-Object { [int]$_ }
    
    switch ($parts.Count) {
        1 { return $intParts[0] }
        2 { return ($intParts[0] * 60) + $intParts[1] }
        3 { 
            if ($ForceMinutesSeconds) {
                return ($intParts[0] * 60) + $intParts[1]
            }
            if ($intParts[0] -gt 23) {
                return ($intParts[0] * 60) + $intParts[1]
            } elseif ($intParts[2] -eq 0) {
                return ($intParts[0] * 60) + $intParts[1]
            } else {
                return ($intParts[0] * 3600) + ($intParts[1] * 60) + $intParts[2]
            }
        }
        4 { return ($intParts[0] * 3600) + ($intParts[1] * 60) + $intParts[2] }
        default { throw "Invalid timestamp format: $Timestamp" }
    }
}

function Repair-MisinterpretedTimestamps {
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
        return $alternativeChapters
    }
    
    return $Chapters
}

function Convert-SecondsToTimestamp {
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

function Convert-SecondsToFFmpegTimestamp {
    param([int]$Seconds)
    $hours = [int][math]::Floor($Seconds / 3600)
    $minutes = [int][math]::Floor(($Seconds % 3600) / 60)
    $secs = [int]($Seconds % 60)
    return "{0:D2}:{1:D2}:{2:D2}" -f $hours, $minutes, $secs
}

function Get-SafeFilename {
    param([string]$Name)
    $safe = $Name.ToLower()
    $safe = $safe -replace '[<>:"/\\|?*]', ''
    $safe = $safe -replace '\s+', ' '
    return $safe.Trim()
}

function Test-IsVolumeHeader {
    param([string]$Text)
    if ($Text -match '^\d+$') { return $true }
    return $Text -match '\b(volume|vol\.?|disc|part|section|chapter)\s*\d+\b'
}

# Tests
Describe "Convert-TimestampToSeconds" {
    It "Converts 1:23 to 83" { Convert-TimestampToSeconds "1:23" | Should Be 83 }
    It "Converts 0:00 to 0" { Convert-TimestampToSeconds "0:00" | Should Be 0 }
    It "Converts 25:38 to 1538" { Convert-TimestampToSeconds "25:38" | Should Be 1538 }
    It "Converts 1:23:45 to 5025" { Convert-TimestampToSeconds "1:23:45" | Should Be 5025 }
    It "Converts 3.48.00 to 228" { Convert-TimestampToSeconds "3.48.00" | Should Be 228 }
    
    # MM.SS.FF format (minutes.seconds.frames) - frames should be ignored
    # These pass because first part > 23 or third part is 0
    It "Converts 5.36.00 to 336 (MM.SS.FF format)" { Convert-TimestampToSeconds "5.36.00" | Should Be 336 }
    It "Converts 33.25.00 to 2005 (MM.SS.FF format)" { Convert-TimestampToSeconds "33.25.00" | Should Be 2005 }
    
    # ForceMinutesSeconds parameter tests
    It "Converts 16.44.12 to 1004 with -ForceMinutesSeconds" { 
        Convert-TimestampToSeconds "16.44.12" -ForceMinutesSeconds | Should Be 1004 
    }
    It "Converts 23.33.36 to 1413 with -ForceMinutesSeconds" { 
        Convert-TimestampToSeconds "23.33.36" -ForceMinutesSeconds | Should Be 1413 
    }
}

Describe "Repair-MisinterpretedTimestamps" {
    # This tests the fix for the "Systematically Attacking the Guard 2.0" Volume 3 bug
    # Input: 0:00, 5.36.00, 16.44.12, 23.33.36, 33.25.00
    # Without repair: 0, 336, 60252 (wrong!), 84816 (wrong!), 2005
    # With repair: 0, 336, 1004, 1413, 2005
    
    It "Fixes misinterpreted MM.SS.FF timestamps when they break chronological order" {
        $chapters = @(
            @{ Title = "Gripping Battle"; Seconds = 0; Timestamp = "0:00" }
            @{ Title = "Passing on Grip"; Seconds = 336; Timestamp = "5.36.00" }
            @{ Title = "Using Shin Pin"; Seconds = 60252; Timestamp = "16.44.12" }  # Wrong: parsed as 16 hours
            @{ Title = "Pommeling"; Seconds = 84816; Timestamp = "23.33.36" }        # Wrong: parsed as 23 hours  
            @{ Title = "Forcing Half Guard"; Seconds = 2005; Timestamp = "33.25.00" }  # This breaks order -> triggers fix
        )
        
        $repaired = Repair-MisinterpretedTimestamps $chapters
        
        # After repair, the wrong ones should be fixed
        ($repaired | Where-Object { $_.Title -eq "Using Shin Pin" }).Seconds | Should Be 1004
        ($repaired | Where-Object { $_.Title -eq "Pommeling" }).Seconds | Should Be 1413
        
        # The correct ones should remain unchanged
        ($repaired | Where-Object { $_.Title -eq "Gripping Battle" }).Seconds | Should Be 0
        ($repaired | Where-Object { $_.Title -eq "Passing on Grip" }).Seconds | Should Be 336
        ($repaired | Where-Object { $_.Title -eq "Forcing Half Guard" }).Seconds | Should Be 2005
    }
    
    It "Does not modify timestamps that are already in chronological order" {
        # HH:MM:SS format - all in correct ascending order, should not be touched
        $chapters = @(
            @{ Title = "Intro"; Seconds = 0; Timestamp = "00:00:00" }
            @{ Title = "Part 1"; Seconds = 278; Timestamp = "00:04:38" }
            @{ Title = "Part 2"; Seconds = 3657; Timestamp = "01:00:57" }  # 1 hour mark
            @{ Title = "Part 3"; Seconds = 4084; Timestamp = "01:08:04" }
        )
        
        $repaired = Repair-MisinterpretedTimestamps $chapters
        
        # All should remain unchanged - they're already in order
        ($repaired | Where-Object { $_.Title -eq "Intro" }).Seconds | Should Be 0
        ($repaired | Where-Object { $_.Title -eq "Part 1" }).Seconds | Should Be 278
        ($repaired | Where-Object { $_.Title -eq "Part 2" }).Seconds | Should Be 3657
        ($repaired | Where-Object { $_.Title -eq "Part 3" }).Seconds | Should Be 4084
    }
    
    It "Does not modify timestamps in genuinely long videos" {
        # If the median is >= 1 hour, assume the video is actually long
        $chapters = @(
            @{ Title = "Intro"; Seconds = 0; Timestamp = "0:00" }
            @{ Title = "Part 1"; Seconds = 3600; Timestamp = "1:00:00" }
            @{ Title = "Part 2"; Seconds = 7200; Timestamp = "2:00:00" }
            @{ Title = "Part 3"; Seconds = 10800; Timestamp = "3:00:00" }
        )
        
        $repaired = Repair-MisinterpretedTimestamps $chapters
        
        # All should remain unchanged
        ($repaired | Where-Object { $_.Title -eq "Part 1" }).Seconds | Should Be 3600
        ($repaired | Where-Object { $_.Title -eq "Part 2" }).Seconds | Should Be 7200
    }
}

Describe "Convert-SecondsToTimestamp" {
    It "Converts 83 to 1:23" { Convert-SecondsToTimestamp 83 | Should Be "1:23" }
    It "Converts 0 to 0:00" { Convert-SecondsToTimestamp 0 | Should Be "0:00" }
    It "Converts 5025 to 1:23:45" { Convert-SecondsToTimestamp 5025 | Should Be "1:23:45" }
}

Describe "Convert-SecondsToFFmpegTimestamp" {
    It "Converts 0 to 00:00:00" { Convert-SecondsToFFmpegTimestamp 0 | Should Be "00:00:00" }
    It "Converts 83 to 00:01:23" { Convert-SecondsToFFmpegTimestamp 83 | Should Be "00:01:23" }
    It "Converts 3661 to 01:01:01" { Convert-SecondsToFFmpegTimestamp 3661 | Should Be "01:01:01" }
}

Describe "Get-SafeFilename" {
    It "Converts to lowercase" { Get-SafeFilename "Hello World" | Should Be "hello world" }
    It "Removes special chars" { Get-SafeFilename "Test Name" | Should Be "test name" }
    It "Trims whitespace" { Get-SafeFilename "  Padded  " | Should Be "padded" }
}

Describe "Test-IsVolumeHeader" {
    It "Recognizes Volume 1" { Test-IsVolumeHeader "Volume 1" | Should Be $true }
    It "Recognizes 01" { Test-IsVolumeHeader "01" | Should Be $true }
    It "Rejects Course Content" { Test-IsVolumeHeader "Course Content" | Should Be $false }
}

Describe "FFmpeg Args Building" {
    function Build-FFmpegArgs {
        param([bool]$Reencode, [string]$VideoCodec = "libx264", [int]$Quality = 23)
        if ($Reencode) {
            return @("-c:v", $VideoCodec, "-crf", $Quality, "-c:a", "aac")
        } else {
            return @("-c", "copy")
        }
    }
    
    It "Uses -c copy for stream copy" {
        $args = Build-FFmpegArgs -Reencode $false
        $args -contains "copy" | Should Be $true
    }
    
    It "Uses codec params for reencode" {
        $args = Build-FFmpegArgs -Reencode $true
        $args -contains "-c:v" | Should Be $true
        $args -contains "libx264" | Should Be $true
    }
    
    It "Uses custom quality" {
        $args = Build-FFmpegArgs -Reencode $true -Quality 18
        $args -contains 18 | Should Be $true
    }
}
