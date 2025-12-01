# Video Splitter Project Plan

## Overview

A PowerShell-based CLI tool that splits video files into segments based on timestamped chapter files.

## Input Format

### Video File

- Any video format supported by FFmpeg (mp4, mkv, avi, etc.)

### Timestamp File (.txt)

Supports flexible/fuzzy formats - timestamp can come before or after the title.

**Example formats supported:**

```
VOLUME 1
Intro To Armbars	0
Top Juji Vs Bottom Juji	1:13
Central Problems	2:45
```

```
VOLUME 1
0:00 Intro To Armbars
1:13 Top Juji Vs Bottom Juji
2:45 Central Problems
```

```
VOLUME 1
0:00 - Intro To Armbars
1:13 - Top Juji Vs Bottom Juji
2:45 - Central Problems
```

**Format rules:**

- First line (optional): Volume/section header (e.g., "VOLUME 1") - detected if no timestamp present
- Each subsequent line: timestamp and title in either order
- Separators: TAB, spaces, or `-` between timestamp and title
- Timestamps: `SS`, `M:SS`, `MM:SS`, or `H:MM:SS` (with or without leading zeros)

## Output Structure

**Important:** Input files are NEVER modified. All output goes to a separate output folder.

The parent folder name of the source video is preserved in the output structure:

```
output/
└── Gordon Ryan - Systematically Attacking The Arm Bar/
    └── volume 1/
        ├── 01. intro to armbars/
        │   └── intro to armbars.mp4
        ├── 02. top juji vs bottom juji/
        │   └── top juji vs bottom juji.mp4
        └── ...
```

## Tech Stack

- **PowerShell** - Main scripting language
- **FFmpeg** - Video splitting/encoding

## Project Structure

```
video-splitter/
├── plan.md                 # This file
├── split-video.ps1         # Main script
├── README.md               # Usage documentation
└── examples/
    └── sample-chapters.txt # Example timestamp file
```

## Implementation Phases

### Phase 1: Core Parser ✅

**Goal:** Parse chapter files reliably

- [x] Create `split-video.ps1` with parameter handling
- [x] Implement timestamp regex detection (requires colons: `0:00`, `1:23`, `01:23:45`, or `0` alone)
- [x] Parse lines with timestamp before or after title
- [x] Detect header lines (no timestamp = volume name)
- [x] Convert timestamps to seconds
- [x] Unit test with sample chapter files

### Phase 2: Preview & Validation ✅

**Goal:** Show user what will happen before doing it

- [x] Get video duration using FFprobe
- [x] Calculate segment durations
- [x] Generate preview output (folder tree with time ranges)
- [x] Implement Y/n confirmation prompt
- [x] Validate inputs (files exist, FFmpeg available)

### Phase 3: Video Splitting ✅

**Goal:** Actually split the video

- [x] Create folder structure (parent folder / volume / chapter)
- [x] Sanitize filenames (lowercase, remove invalid chars)
- [x] Execute FFmpeg for each segment
- [x] Display progress (segment X of Y)
- [x] Handle errors gracefully

### Phase 4: Polish ✅

**Goal:** Make it robust and user-friendly

- [x] Colored console output
- [x] Better error messages
- [x] Handle edge cases (empty lines, duplicate names)
- [x] Add `-Force` flag to skip confirmation
- [x] Write README with usage examples

### Phase 5: Batch Processing ✅

**Goal:** Process multiple videos from a parent folder

- [x] Add `-InputDir` parameter to target a parent folder
- [x] Scan for subfolders containing both video files and timestamp files
- [x] Auto-match videos to timestamp files (by naming convention or single txt per folder)
- [x] Process each video/timestamp pair sequentially
- [x] Show summary of all folders to be processed before starting
- [x] Report overall progress (folder X of Y)

### Phase 6: Skip Existing Files ✅

**Goal:** Allow incremental re-processing

- [x] Check if output file already exists before processing
- [x] Show `[SKIP]` indicator in preview for existing files
- [x] Skip existing files during processing (don't overwrite)
- [x] Show skip count in summary
- [x] Delete specific output files and re-run to regenerate only those

### Phase 7: Re-encoding Support 🔲

**Goal:** Allow re-encoding problematic segments

Sometimes stream copy (`-c copy`) produces broken files due to keyframe issues. This phase adds the ability to re-encode specific segments.

- [ ] Add `-Reencode` switch parameter
- [ ] When enabled, use full re-encoding instead of stream copy
- [ ] Add `-VideoCodec` parameter (default: `libx264`)
- [ ] Add `-AudioCodec` parameter (default: `aac`)
- [ ] Add `-Quality` parameter for CRF value (default: `23`)
- [ ] Show `[REENCODE]` indicator in preview when flag is set
- [ ] Combine with skip feature: delete broken files, re-run with `-Reencode`

**Usage workflow for fixing broken segments:**

1. Run initial split (fast, stream copy)
2. Find broken segments in output
3. Delete those specific segment folders
4. Re-run with `-Reencode` flag to regenerate only the deleted segments

**FFmpeg command for re-encoding:**

```powershell
ffmpeg -i input.mp4 -ss 00:01:13 -t 00:01:32 -c:v libx264 -crf 23 -c:a aac output.mp4
```

**Parameters:**

```powershell
.\split-video.ps1
    -InputDir ".\InputFolder"
    -Reencode                    # Use re-encoding instead of stream copy
    -VideoCodec "libx264"        # Optional, video codec (default: libx264)
    -AudioCodec "aac"            # Optional, audio codec (default: aac)
    -Quality 23                  # Optional, CRF quality 0-51 (default: 23, lower = better)
```

**Example:**

```
InputFolder/
├── Course Part 1/
│   ├── video1.mp4
│   ├── video2.mp4
│   └── Timing.txt       # Contains VOLUME 1, VOLUME 2 sections
├── Course Part 2/
│   ├── lesson.mp4
│   └── chapters.txt
└── ...
```

```powershell
.\split-video.ps1 -InputDir ".\InputFolder" -OutputDir ".\output"
```

---

## Core Features

### Phase 1: Basic Functionality ✅

- [x] Parse timestamp file (tab-delimited)
- [x] Extract volume/section name from header
- [x] Convert timestamps to seconds
- [x] Calculate segment durations (start time to next start time)
- [x] Split video using FFmpeg with `-ss` and `-t` flags
- [x] Create folder structure with proper naming
- [x] Handle last segment (to end of video)

### Phase 2: Enhancements ✅

- [x] Support multiple timestamp formats
- [x] Sanitize filenames (remove invalid characters)
- [x] Progress indicator
- [x] Error handling and validation
- [x] Dry-run mode (show what would be created)
- [x] Use stream copy (`-c copy`) for fast splitting

## Script Parameters

```powershell
.\split-video.ps1
    -VideoFile "path\to\video.mp4"
    -ChapterFile "path\to\chapters.txt"
    -OutputDir "path\to\output"      # Optional, defaults to ./output
    -Force                            # Optional, skip confirmation prompt
    -Reencode                         # Optional, re-encode instead of stream copy
    -VideoCodec "libx264"             # Optional, video codec (default: libx264)
    -AudioCodec "aac"                 # Optional, audio codec (default: aac)
    -Quality 23                       # Optional, CRF quality 0-51 (default: 23)
```

**Note:** By default uses stream copy (`-c copy`) for fast splitting. Use `-Reencode` when segments are broken.

## Interactive Preview

Before processing, the script displays a preview and prompts for confirmation:

```
=== Video Splitter Preview ===

Source: my-video.mp4 (1:23:45)
Chapters: 9 segments
Output: ./output/

Structure to be created:
  volume 1/
    01. intro to armbars/
        intro to armbars.mp4  [0:00 - 1:13]
    02. top juji vs bottom juji/
        top juji vs bottom juji.mp4  [1:13 - 2:45]
    03. central problems/
        central problems.mp4  [2:45 - 5:05]
    ...

Proceed? [Y/n]: _
```

User can review the parsed structure and confirm before any files are created.

## FFmpeg Commands

### Stream copy (fast, no re-encoding) - Default:

```powershell
ffmpeg -i input.mp4 -ss 00:01:13 -t 00:01:32 -c copy output.mp4
```

**Note:** Cuts at nearest keyframe. May be off by ~0.5-2 seconds, which is acceptable for chapter splits. Sometimes produces broken files.

### Re-encoding (slower, precise cuts) - With `-Reencode` flag:

```powershell
ffmpeg -i input.mp4 -ss 00:01:13 -t 00:01:32 -c:v libx264 -crf 23 -c:a aac output.mp4
```

**Note:** Frame-accurate cuts, fixes broken segments. Takes significantly longer (minutes vs seconds).

## Implementation Steps

1. **Create `split-video.ps1`**

   - Parameter handling
   - Input validation (check files exist, FFmpeg available)

2. **Parse chapter file**

   - Read lines, detect header (line without timestamp)
   - Use regex to find timestamp pattern anywhere in line
   - Extract title as remaining text (before or after timestamp)
   - Strip separators (tabs, `-`, extra spaces)
   - Convert all timestamps to seconds

3. **Calculate segments**

   - For each chapter, determine start and duration
   - Last segment goes to end of video (use FFmpeg to get duration)

4. **Show preview & confirm**

   - Display parsed structure with timestamps
   - Show segment durations
   - Prompt for Y/n confirmation
   - Exit if user declines

5. **Create output structure**

   - Sanitize names (lowercase, remove special chars)
   - Create numbered folders

6. **Execute FFmpeg**
   - Loop through segments
   - Display progress
   - Handle errors gracefully

## Edge Cases to Handle

- Missing/empty chapter file
- Invalid timestamp format
- Lines with no detectable timestamp (skip or warn)
- Mixed formats within same file
- Special characters in chapter names
- Chapters with same name
- Single chapter file
- No volume header in file

## Dependencies

- PowerShell 5.1+
- FFmpeg (must be in PATH or specify location)

## Future Ideas

- [x] VLC-compatible playlist (.m3u) with all output clips
- GUI wrapper (optional)
- Support for SRT/VTT chapter formats
- Thumbnail extraction for each segment
