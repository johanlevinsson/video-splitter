# Video Splitter

Split video files into chapters based on a timestamp file.

## Requirements

- PowerShell 5.1+
- FFmpeg (install via `winget install Gyan.FFmpeg`)

## Usage

### Single Video

```powershell
.\video-splitter.ps1 -VideoFile "video.mp4" -ChapterFile "chapters.txt"
```

### Batch Mode

Process all videos in subfolders:

```powershell
.\video-splitter.ps1 -InputDir ".\Courses"
```

### Parameters

| Parameter      | Required | Description                                      |
| -------------- | -------- | ------------------------------------------------ |
| `-VideoFile`   | \*       | Path to the video file (single mode)             |
| `-ChapterFile` | \*       | Path to the timestamp file (single mode)         |
| `-InputDir`    | \*       | Path to folder with subfolders (batch mode)      |
| `-OutputDir`   | No       | Output directory (default: `.\output`)           |
| `-Force`       | No       | Skip confirmation prompt                         |
| `-Reencode`    | No       | Re-encode video instead of stream copy (recommended) |
| `-VideoCodec`  | No       | Video codec for re-encoding (default: `libx264`) |
| `-AudioCodec`  | No       | Audio codec for re-encoding (default: `aac`)     |
| `-Quality`     | No       | CRF quality value 0-51, lower=better (default: 27) |

\* Use either `-VideoFile`/`-ChapterFile` OR `-InputDir`

### Re-encoding (Recommended)

By default, the script uses stream copy (fast) which cuts at keyframes. This can result in:
- Clips starting a few seconds early
- Black frames or glitches at the start of clips

**Recommendation:** Use `-Reencode` for precise cuts and clean clips:

```powershell
.\video-splitter.ps1 -InputDir ".\Courses" -Reencode
```

For higher quality output (larger files):

```powershell
.\video-splitter.ps1 -InputDir ".\Courses" -Reencode -Quality 20
```

## Timestamp File Format

Timestamps must include a colon (e.g., `0:00`, `1:23`, `1:23:45`), or `0` alone for the start.

**Title first:**

```
VOLUME 1
Intro	0:00
Chapter Two	1:23
Chapter Three	5:45
```

**Timestamp first:**

```
VOLUME 1
0:00 Intro
1:23 - Chapter Two
5:45 Chapter Three
```

**Multi-volume files:** In batch mode, videos are matched to VOLUME sections by number in filename (e.g., `video1.mp4` → VOLUME 1).

## Output Structure

```
output/
└── Parent Folder Name/
    ├── playlist.m3u
    ├── volume 1/
    │   ├── 01. intro/
    │   │   └── intro.mp4
    │   ├── 02. chapter two/
    │   │   └── chapter two.mp4
    │   └── ...
    └── volume 2/
        └── ...
```

A VLC-compatible `playlist.m3u` is generated at the parent folder level, containing all chapters from all volumes.

## Features

- **Automatic Intro chapter**: If the first timestamp doesn't start at 0:00, an "Intro" chapter is automatically added
- **Duration warnings**: Preview displays a warning if any clips are shorter than 20 seconds or longer than 20 minutes, prompting you to check input timestamps
- **Skip existing**: Already-processed clips are automatically skipped
- **Resume support**: Re-run the same command to continue where you left off

## Examples

**Single video:**

```powershell
.\video-splitter.ps1 `
    -VideoFile ".\videos\Course\lesson1.mp4" `
    -ChapterFile ".\videos\Course\chapters.txt"
```

**Batch processing:**

```powershell
.\video-splitter.ps1 -InputDir ".\Courses" -OutputDir ".\output" -Force
```

## Installation (Add to PATH)

To run `video-splitter.ps1` from anywhere, add the script folder to your PATH:

```powershell
$scriptDir = "H:\kod\video-splitter"  # Change to your path
$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$currentPath;$scriptDir", "User")
```

Restart your terminal, then run from anywhere:

```powershell
video-splitter.ps1 -InputDir "D:\Videos\MyCourse" -OutputDir "D:\Output"
```
