# Pester tests for video-splitter.ps1
# Run with: Invoke-Pester -Path .\video-splitter.Tests.ps1
# Compatible with Pester 3.x (uses "Should Be" instead of "Should -Be")

# Import the functions from the main script without executing the main logic
$scriptPath = Join-Path $PSScriptRoot "video-splitter.ps1"
$scriptContent = Get-Content $scriptPath -Raw

# Extract everything from the first function definition up to "# --- Main Script ---"
if ($scriptContent -match '(?s)(# --- Tree Drawing Characters ---.*?)# --- Main Script ---') {
    $functionsOnly = $Matches[1]
    # Execute the functions in the current scope
    Invoke-Expression $functionsOnly
}

Describe "Convert-TimestampToSeconds" {
    Context "Simple M:SS format" {
        It "Converts 1:23 to 83 seconds" {
            Convert-TimestampToSeconds "1:23" | Should Be 83
        }
        
        It "Converts 0:00 to 0 seconds" {
            Convert-TimestampToSeconds "0:00" | Should Be 0
        }
        
        It "Converts 25:38 to 1538 seconds" {
            Convert-TimestampToSeconds "25:38" | Should Be 1538
        }
        
        It "Converts 59:59 to 3599 seconds" {
            Convert-TimestampToSeconds "59:59" | Should Be 3599
        }
    }
    
    Context "H:MM:SS format" {
        It "Converts 1:23:45 to 5025 seconds" {
            Convert-TimestampToSeconds "1:23:45" | Should Be 5025
        }
        
        It "Converts 2:00:00 to 7200 seconds" {
            Convert-TimestampToSeconds "2:00:00" | Should Be 7200
        }
    }
    
    Context "Dot separator format" {
        It "Converts 3.48 to 228 seconds (M.SS)" {
            Convert-TimestampToSeconds "3.48" | Should Be 228
        }
        
        It "Converts 3.48.00 to 228 seconds (ignores trailing .00)" {
            Convert-TimestampToSeconds "3.48.00" | Should Be 228
        }
        
        It "Converts 1.06.08.00 to 3968 seconds (H.MM.SS.noise)" {
            Convert-TimestampToSeconds "1.06.08.00" | Should Be 3968
        }
    }
    
    Context "M:SS:frames format (trailing noise)" {
        It "Converts 25:38:00 to 1538 seconds (M:SS with :00 noise)" {
            Convert-TimestampToSeconds "25:38:00" | Should Be 1538
        }
        
        It "Converts 37:58:12 to 2278 seconds (M > 23, ignore third part)" {
            Convert-TimestampToSeconds "37:58:12" | Should Be 2278
        }
    }
    
    Context "Single number format" {
        It "Converts 45 to 45 seconds" {
            Convert-TimestampToSeconds "45" | Should Be 45
        }
        
        It "Converts 0 to 0 seconds" {
            Convert-TimestampToSeconds "0" | Should Be 0
        }
    }
}

Describe "Convert-SecondsToTimestamp" {
    Context "Minutes and seconds only" {
        It "Converts 83 to 1:23" {
            Convert-SecondsToTimestamp 83 | Should Be "1:23"
        }
        
        It "Converts 0 to 0:00" {
            Convert-SecondsToTimestamp 0 | Should Be "0:00"
        }
        
        It "Converts 3599 to 59:59" {
            Convert-SecondsToTimestamp 3599 | Should Be "59:59"
        }
    }
    
    Context "Hours, minutes and seconds" {
        It "Converts 5025 to 1:23:45" {
            Convert-SecondsToTimestamp 5025 | Should Be "1:23:45"
        }
        
        It "Converts 3600 to 1:00:00" {
            Convert-SecondsToTimestamp 3600 | Should Be "1:00:00"
        }
        
        It "Converts 7200 to 2:00:00" {
            Convert-SecondsToTimestamp 7200 | Should Be "2:00:00"
        }
    }
}

Describe "Test-IsTimestamp" {
    Context "Valid timestamps" {
        It "Recognizes 0:00" { Test-IsTimestamp "0:00" | Should Be $true }
        It "Recognizes 1:23" { Test-IsTimestamp "1:23" | Should Be $true }
        It "Recognizes 12:34" { Test-IsTimestamp "12:34" | Should Be $true }
        It "Recognizes 1:23:45" { Test-IsTimestamp "1:23:45" | Should Be $true }
        It "Recognizes 0" { Test-IsTimestamp "0" | Should Be $true }
        It "Recognizes 45" { Test-IsTimestamp "45" | Should Be $true }
    }
    
    Context "Invalid timestamps" {
        It "Rejects text" { Test-IsTimestamp "intro" | Should Be $false }
        It "Rejects timestamps with dots" { Test-IsTimestamp "1.23" | Should Be $false }
        It "Rejects timestamps with extra parts" { Test-IsTimestamp "1:23:45:67" | Should Be $false }
    }
}

Describe "Test-IsVolumeHeader" {
    Context "Valid volume headers" {
        It "Recognizes 'Volume 1'" { Test-IsVolumeHeader "Volume 1" | Should Be $true }
        It "Recognizes 'VOLUME 1'" { Test-IsVolumeHeader "VOLUME 1" | Should Be $true }
        It "Recognizes 'Vol. 1'" { Test-IsVolumeHeader "Vol. 1" | Should Be $true }
        It "Recognizes 'Vol 1'" { Test-IsVolumeHeader "Vol 1" | Should Be $true }
        It "Recognizes 'DISC 2'" { Test-IsVolumeHeader "DISC 2" | Should Be $true }
        It "Recognizes 'Part 3'" { Test-IsVolumeHeader "Part 3" | Should Be $true }
        It "Recognizes 'Section 4'" { Test-IsVolumeHeader "Section 4" | Should Be $true }
        It "Recognizes '01' (just a number)" { Test-IsVolumeHeader "01" | Should Be $true }
        It "Recognizes '1' (just a number)" { Test-IsVolumeHeader "1" | Should Be $true }
        It "Recognizes '12' (just a number)" { Test-IsVolumeHeader "12" | Should Be $true }
    }
    
    Context "Invalid volume headers" {
        It "Rejects 'Course Content'" { Test-IsVolumeHeader "Course Content" | Should Be $false }
        It "Rejects 'START TIME'" { Test-IsVolumeHeader "START TIME" | Should Be $false }
        It "Rejects 'Intro to Armbars'" { Test-IsVolumeHeader "Intro to Armbars" | Should Be $false }
    }
}

Describe "Get-SafeFilename" {
    It "Converts to lowercase" {
        Get-SafeFilename "Hello World" | Should Be "hello world"
    }
    
    It "Removes special characters" {
        Get-SafeFilename 'Test: File "Name"?' | Should Be "test file name"
    }
    
    It "Collapses multiple spaces" {
        Get-SafeFilename "Multiple   Spaces   Here" | Should Be "multiple spaces here"
    }
    
    It "Trims whitespace" {
        Get-SafeFilename "  Padded  " | Should Be "padded"
    }
    
    It "Handles complex BJJ chapter names" {
        Get-SafeFilename "Intro To Armbars" | Should Be "intro to armbars"
    }
}

Describe "Parse-ChapterLine" {
    Context "Tab-separated format (title first)" {
        It "Parses 'Intro To Armbars	0'" {
            $result = Parse-ChapterLine "Intro To Armbars	0"
            $result.Title | Should Be "Intro To Armbars"
            $result.Seconds | Should Be 0
        }
        
        It "Parses 'Top Juji	1:13'" {
            $result = Parse-ChapterLine "Top Juji	1:13"
            $result.Title | Should Be "Top Juji"
            $result.Seconds | Should Be 73
        }
    }
    
    Context "Timestamp first format" {
        It "Parses '1:23 Top Juji Vs Bottom Juji'" {
            $result = Parse-ChapterLine "1:23 Top Juji Vs Bottom Juji"
            $result.Title | Should Be "Top Juji Vs Bottom Juji"
            $result.Seconds | Should Be 83
        }
        
        It "Parses '2:45 - Central Problems'" {
            $result = Parse-ChapterLine "2:45 - Central Problems"
            $result.Title | Should Be "Central Problems"
            $result.Seconds | Should Be 165
        }
    }
    
    Context "Dual timestamp format" {
        It "Parses 'Overview 4:52 - 7:23' (uses first timestamp)" {
            $result = Parse-ChapterLine "Overview 4:52 - 7:23"
            $result.Title | Should Be "Overview"
            $result.Seconds | Should Be 292
        }
    }
    
    Context "Invalid lines" {
        It "Returns null for empty string" {
            Parse-ChapterLine "" | Should Be $null
        }
        
        It "Returns null for whitespace only" {
            Parse-ChapterLine "   " | Should Be $null
        }
        
        It "Returns null for line with no timestamp" {
            Parse-ChapterLine "Course Content" | Should Be $null
        }
    }
}

Describe "Convert-SecondsToFFmpegTimestamp" {
    It "Converts 0 to 00:00:00" {
        Convert-SecondsToFFmpegTimestamp 0 | Should Be "00:00:00"
    }
    
    It "Converts 83 to 00:01:23" {
        Convert-SecondsToFFmpegTimestamp 83 | Should Be "00:01:23"
    }
    
    It "Converts 3661 to 01:01:01" {
        Convert-SecondsToFFmpegTimestamp 3661 | Should Be "01:01:01"
    }
    
    It "Converts 5025 to 01:23:45" {
        Convert-SecondsToFFmpegTimestamp 5025 | Should Be "01:23:45"
    }
}
