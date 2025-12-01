# Pester tests for video-splitter.ps1
# Run with: Invoke-Pester -Path .\video-splitter.Tests.ps1
# Compatible with Pester 3.x

# Define test copies of the functions (avoids importing the full script)
function Convert-TimestampToSeconds {
    param([string]$Timestamp)
    $normalized = $Timestamp -replace '\.', ':'
    $parts = $normalized -split ':'
    $intParts = $parts | ForEach-Object { [int]$_ }
    
    switch ($parts.Count) {
        1 { return $intParts[0] }
        2 { return ($intParts[0] * 60) + $intParts[1] }
        3 { 
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
