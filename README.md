# Google Photos Takeout Matadata Fixer

> This project was prompted by [Alexander Kastil](https://www.linkedin.com/in/alexander-kastil-3bb26511a/) and implemented using the Agentic Preview of GitHub Copilot Edits with Claude 3.5 Sonnet as the underlying AI model.

This PowerShell script helps fix common issues with Google Photos exports using Google Takeout. It addresses problems such as:

- Incorrect file creation dates after unzipping
- Missing EXIF metadata that needs to be applied from supplemental JSON files
- Disorganized folder structure
- Duplicate files
- Need to extract photos from specific albums

## Background

When you export your photos from Google Photos using Google Takeout, the exported ZIP files contain your photos along with supplemental metadata JSON files. However, several issues occur:

1. When unzipping, file creation dates are set to the extraction time instead of the original photo date
2. Original metadata is stored in separate `.json` files (see `/sample_export` for examples)
3. Photos are organized by album rather than date
4. Duplicate photos may exist across different albums

## Prerequisites

- PowerShell 7.0 or later
- ExifTool (can be automatically installed using the script)

## Main Script: fix-google-takeout-v2.ps1

The main script provides a comprehensive solution for processing Google Photos Takeout exports.

### Parameters

- `-ExtractZip` (yes/no, default: yes)

  - Extracts the Takeout ZIP files into the `extracted` folder
  - Use 'no' if you've already extracted the files

- `-InstallExif` (yes/no, default: no)

  - Downloads and installs ExifTool if not found
  - Required for metadata processing

- `-GenerateAlbums` (yes/no, default: yes)

  - Generates JSON files for each album in `photo-albums` folder
  - Requires `albums.txt` file with one album name per line

- `-ExportAlbum` (yes/pattern/no)
  - Must be used alone without other parameters
  - Exports all albums when used with 'yes'
  - Copies photos from the processed albums to an export folder

### What the Script Does

1. **ZIP Extraction**

   - Creates an `extracted` folder
   - Extracts all Takeout ZIP files while preserving folder structure

2. **Metadata Processing**

   - Reads original dates from supplemental JSON files
   - Updates EXIF data using ExifTool
   - Fixes file creation dates

3. **File Organization**

   - Sorts photos into year-based folders under `sorted`
   - Handles duplicate files by appending a unique suffix
   - Maintains a clean, date-based structure

4. **Album Management**
   - Creates JSON files for each album
   - Tracks photo locations after sorting
   - Enables easy album-based exports

### Output Structure

```
workspace/
├── extracted/               # Extracted Takeout contents
├── sorted/                  # Photos organized by year
│   ├── 2020/
│   ├── 2021/
│   └── 2022/
├── photo-albums/            # Album JSON files
├── logs/                    # Error logs
│   ├── metadata.errors.json
│   ├── sorting.errors.json
│   └── duplicate.errors.json
└── exported-albums/         # Album exports (when using -ExportAlbum)
```

## Testing

The project includes a test file `fix-google-takeout-v2.tests.ps1` that verifies:

- ZIP extraction functionality
- Album generation
- ExifTool installation and usage
- Metadata processing
- Album export features

Run the tests using Pester:

```powershell
Invoke-Pester .\fix-google-takeout-v2.tests.ps1 -Tag "Integration"
```

## Example Usage

1. Basic processing with metadata fix:

```powershell
.\fix-google-takeout-v2.ps1 -ExtractZip yes -InstallExif yes
```

2. Generate and export albums:

```powershell
# First, create albums.txt with album names
.\fix-google-takeout-v2.ps1 -ExtractZip yes -GenerateAlbums yes
# Then export the albums
.\fix-google-takeout-v2.ps1 -ExportAlbum yes
```

## Error Handling

The script creates detailed error logs in the `logs` folder:

- `metadata.errors.json`: Files with metadata processing issues
- `sorting.errors.json`: Files that couldn't be sorted
- `duplicate.errors.json`: List of duplicate files found

## Requirements

- Windows PowerShell 7.0+
- Sufficient disk space for extraction
- Admin rights if installing ExifTool

## License

This project is licensed under the MIT License - see the LICENSE file for details.
