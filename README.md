# Google Photos Takeout Metadata Fixer

A PowerShell tool to fix and organize photos exported from Google Photos using Google Takeout.

## Background

When you export your photos from Google Photos using Google Takeout, several issues occur:

1. File timestamps are lost during ZIP extraction, defaulting to the extraction time
2. Original metadata (including creation date) is stored in separate JSON files
3. Photos are organized by album rather than date, leading to duplicates
4. File extensions may be incorrect (e.g., uppercase vs lowercase)
5. EXIF data may be incomplete or missing

This tool addresses all these issues and provides flexible organization options.

## Prerequisites

- PowerShell 7.0 or later
- ExifTool (can be automatically installed using -InstallExif yes)
- Windows OS (for full functionality)
- Sufficient disk space for extraction (at least 2x the size of your ZIP files)

## Quick Start

Basic usage (recommended for most users):

- Copy the zip files from Google Takeout to the root of this project

```powershell
.\fix-google-takeout.ps1 -Extract yes -InstallExif yes -Sort onefolder
```

## Parameter Details

### Core Parameters

`-Extract yes|no` (Default: yes)

- Controls whether ZIP files are extracted
- Set to 'no' if you've already extracted files manually
- Creates the 'extracted/' folder and preserves folder structure
- Handles multiple Takeout ZIP files in parallel

`-InstallExif yes|no` (Default: no)

- Downloads and installs ExifTool if not found
- ExifTool is required for metadata operations
- Installs to './ExifTool' folder
- Adds ExifTool to the current session's PATH

`-FixMetadata yes|no` (Default: yes)

- Processes and corrects file metadata:
  - Reads creation dates from JSON metadata files
  - Updates EXIF timestamps
  - Corrects file extensions (e.g., .JPG → .jpg)
  - Handles various date formats and timezones
- Runs in parallel for better performance

`-Sort no|years|onefolder` (Default: onefolder)

- Controls how files are organized after processing:
  - 'no': Leaves files in place after metadata fix
  - 'years': Sorts into year-based folders (2023/, 2022/, etc.)
    - Each year folder contains pictures/ and movies/
  - 'onefolder': Places all files in pictures/ or movies/
- Handles duplicates by adding unique suffixes

### Album Management

`-GenerateAlbums yes|no` (Default: no)

- Creates JSON files tracking photo locations
- Requires albums.txt with one album name per line
- Maintains album structure even after sorting
- Creates album metadata in output/albums folder

`-ExportAlbum yes|no` (Default: no)

- Must be used alone without other parameters
- Exports photos from generated albums
- Creates separate pictures/ and movies/ in each album
- Places exported albums in output/albums/NAME

### Maintenance

`-Clean yes`

- Must be used alone
- Removes all processing folders:
  - extracted/
  - output/
  - logs/
  - albums/
  - exported-albums/
  - ExifTool/

## Output Structure

```
workspace/
├── extracted/               # Extracted Takeout contents
│   └── Takeout/
│       └── Google Photos/
├── output/                 # Organized photo collection
│   ├── pictures/          # All image files (.jpg, .heic, .png)
│   ├── movies/           # All video files (.mp4)
│   └── albums/          # Generated and exported album content
│       ├── vacation2023/
│       │   ├── album.json
│       │   ├── pictures/
│       │   └── movies/
│       └── family2023/
│           ├── album.json
│           ├── pictures/
│           └── movies/
└── logs/                  # Processing reports
    ├── metadata.errors.json   # Files with metadata issues
    ├── sorting.errors.json    # Files that failed to sort
    └── duplicate.errors.json  # Renamed duplicate files
```

## Error Handling

The script creates detailed logs in the `logs/` folder:

- `metadata.errors.json`: Lists files where metadata processing failed

  - Missing dates
  - Corrupt EXIF data
  - Unreadable JSON metadata

- `sorting.errors.json`: Records sorting operation failures

  - Permission issues
  - Disk space problems
  - Invalid file paths

- `duplicate.errors.json`: Tracks duplicate file handling
  - Original file path
  - New file name with unique suffix
  - Reason for duplication

## Examples

1. Process existing extracted files:

```powershell
.\fix-google-takeout.ps1 -Extract no -Sort onefolder
```

2. Extract and sort by year with album tracking:

```powershell
.\fix-google-takeout.ps1 -Extract yes -GenerateAlbums yes -Sort years
```

3. Fix metadata only (no sorting):

```powershell
.\fix-google-takeout.ps1 -Extract yes -Sort no
```

4. Export generated albums:

```powershell
.\fix-google-takeout.ps1 -ExportAlbum yes
```

5. Clean up all processing files:

```powershell
.\fix-google-takeout.ps1 -Clean yes
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Credits

This project was prompted by [Alexander Kastil](https://www.linkedin.com/in/alexander-kastil-3bb26511a/) and implemented using the Agentic Preview of GitHub Copilot Edits with Claude 3.5 Sonnet as the underlying AI model. It is dedicated to Giro, a beloved Galgo Espanol rescue, who passed away on 2024-08-05 at approximately 14 years of age.

![giro](/sample_export/giro.jpg)
