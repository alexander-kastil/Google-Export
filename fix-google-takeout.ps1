# Requires -Version 7.0
using namespace System.Collections.Concurrent

[CmdletBinding()]
param (
    [ValidateSet('yes', 'no')]
    [string]$Extract = 'yes',
    
    [ValidateSet('yes', 'no')]
    [string]$InstallExif = 'no',

    [ValidateSet('yes', 'no')]
    [string]$FixMetadata = 'yes',
    
    [ValidateSet('yes', 'no')]
    [string]$GenerateAlbums = 'no',
    
    [ValidateSet('no', 'years', 'onefolder')]
    [string]$Sort = 'onefolder',
    
    [ValidateSet('yes', 'no')]
    [string]$ExportAlbum = 'no',

    [ValidateSet('yes')]
    [string]$Clean = 'no'
)

# Check PowerShell version
$requiredVersion = [Version]"7.0"
$currentVersion = $PSVersionTable.PSVersion
if ($currentVersion -lt $requiredVersion) {
    Write-Error "This script requires PowerShell $requiredVersion or later. Current version: $currentVersion`nPlease install PowerShell Core from: https://github.com/PowerShell/PowerShell#get-powershell"
    exit 1
}

# Enable information output
$InformationPreference = 'Continue'

# Set up output formatting - handle older PowerShell versions
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSStyle.Progress.View = 'Classic'
}
$ProgressPreference = 'Continue'

# Import required modules
Import-Module $PSScriptRoot\FileOperations.psm1
Import-Module $PSScriptRoot\MetadataOperations.psm1
Import-Module $PSScriptRoot\AlbumOperations.psm1
Import-Module $PSScriptRoot\SharedOperations.psm1

function Write-JsonError {
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [array]$ErrorItems
    )
    
    $json = ConvertTo-Json -InputObject $ErrorItems -Depth 10
    [System.IO.File]::WriteAllText($FilePath, $json, [System.Text.Encoding]::UTF8)
}

# Initialize script-level variables
$script:extractedPath = Join-Path -Path $PSScriptRoot -ChildPath "extracted"
$script:outputPath = Join-Path -Path $PSScriptRoot -ChildPath "output"
$script:logsPath = Join-Path -Path $PSScriptRoot -ChildPath "logs"
$script:albumsPath = Join-Path -Path $script:outputPath -ChildPath "albums"
$script:metadataErrorsPath = Join-Path -Path $script:logsPath -ChildPath "metadata.errors.json"
$script:sortingErrorsPath = Join-Path -Path $script:logsPath -ChildPath "sorting.errors.json"
$script:duplicateErrorsPath = Join-Path -Path $script:logsPath -ChildPath "duplicate.errors.json"

# Show help text function
function Show-HelpAndExit {
    param([string]$ErrorMessage)
    if ($ErrorMessage) {
        Write-Error $ErrorMessage
        Write-Host "`nShowing help for correct usage:`n" -ForegroundColor Yellow
    }
    $helpText = @"
Google Photos Takeout Fixer
--------------------------
This tool processes Google Photos Takeout archives by fixing metadata timestamps, organizing photos, and managing albums.

Parameter Rules:
--------------
1. The -ExportAlbum parameter MUST be used alone without any other parameters
2. The -Clean parameter MUST be used alone and ONLY with value 'yes'
3. Other parameters (-Extract, -InstallExif, -FixMetadata, -GenerateAlbums, -Sort) can be combined
4. ExifTool is required for metadata operations. Use -InstallExif yes to install it automatically

Parameters:
----------
-Extract yes|no        : Extract ZIP files from Google Takeout (default: yes)
                        Extracts all .zip files found in the script directory

-InstallExif yes|no   : Download and install ExifTool if not found (default: no)
                        Required for metadata operations
                        Installs to ./ExifTool folder

-FixMetadata yes|no   : Fix metadata timestamps in media files (default: yes)
                        Corrects file extensions and timestamps
                        Processes EXIF data and Google's metadata JSON

-GenerateAlbums yes|no : Generate album JSON files (default: no)
                        Requires albums.txt file with one album name per line
                        Creates album structure in output/albums folder

-Sort no|years|onefolder : Control how files are organized (default: onefolder)
                        'no': Leave files in place after metadata fix
                        'years': Sort into year folders (2023/, 2022/, etc.)
                                Each year folder has pictures/ and movies/
                        'onefolder': Sort all files into pictures/ and movies/

-ExportAlbum yes|no   : Export photos from albums (default: no)
                        Exports albums to output/albums/NAME
                        Each album gets its own pictures/ and movies/ folders

-Clean yes            : Clean up ALL processing folders (must be used alone)
                        Removes: extracted/, output/, logs/, ExifTool/

Output Folders:
-------------
./extracted          : Contains extracted Google Takeout files
./output/           : Contains organized photo collection
  ├── pictures/     : All image files (.jpg, .heic, .png)
  ├── movies/       : All video files (.mp4)
  └── albums/       : Generated and exported album content
./logs/             : Contains error logs and processing reports
./ExifTool/         : Contains ExifTool installation (if installed)

Error Logs:
----------
./logs/metadata.errors.json : Files with metadata processing issues
./logs/sorting.errors.json  : Files that failed during sorting
./logs/duplicate.errors.json: Files renamed due to duplicates

Examples:
--------
Basic usage (recommended for most users):
  .\fix-google-takeout.ps1 -Extract yes -InstallExif yes -Sort onefolder

Process existing extracted files:
  .\fix-google-takeout.ps1 -Extract no -Sort onefolder

Extract and sort by year with album tracking:
  .\fix-google-takeout.ps1 -Extract yes -GenerateAlbums yes -Sort years

Fix metadata only (no sorting):
  .\fix-google-takeout.ps1 -Extract yes -Sort no

Export generated albums:
  .\fix-google-takeout.ps1 -ExportAlbum yes

Clean up all processing files:
  .\fix-google-takeout.ps1 -Clean yes
"@
    Write-Host $helpText
    exit 1
}

function Initialize-Folders {
    # Create required folders
    $foldersToCreate = @(
        $script:extractedPath,
        $script:logsPath,
        (Join-Path $script:outputPath "pictures"),
        (Join-Path $script:outputPath "movies"),
        $script:albumsPath
    )

    foreach ($folder in $foldersToCreate) {
        if (-not (Test-Path $folder)) {
            $null = New-Item -ItemType Directory -Path $folder -Force
        }
    }

    # Initialize error logging files
    $errorFiles = @(
        $script:metadataErrorsPath,
        $script:sortingErrorsPath,
        $script:duplicateErrorsPath
    )

    foreach ($errorFile in $errorFiles) {
        $errorDir = Split-Path -Path $errorFile -Parent
        if (-not (Test-Path $errorDir)) {
            $null = New-Item -ItemType Directory -Path $errorDir -Force
        }
        if (-not (Test-Path $errorFile)) {
            "[]" | Set-Content -Path $errorFile -Encoding UTF8 -Force
        }
    }
}

function Remove-TempFiles {
    Write-Information "Cleaning up all processing folders and files..."
    
    $foldersToClean = @(
        $script:extractedPath,
        $script:outputPath,
        $script:logsPath,
        (Join-Path $PSScriptRoot "ExifTool")
    )

    $filesToClean = @(
        (Join-Path $PSScriptRoot "exiftool.zip")
    )

    foreach ($folder in $foldersToClean) {
        if (Test-Path $folder) {
            try {
                Remove-Item -Path $folder -Recurse -Force
                Write-Information "Removed folder: $folder"
            }
            catch {
                Write-Warning "Failed to remove folder $folder : $_"
            }
        }
    }

    foreach ($file in $filesToClean) {
        if (Test-Path $file) {
            try {
                Remove-Item -Path $file -Force
                Write-Information "Removed file: $file"
            }
            catch {
                Write-Warning "Failed to remove file $file : $_"
            }
        }
    }
}

# Validate parameters
if ($Clean -eq 'yes') {
    if ($PSBoundParameters.Count -gt 1) {
        Show-HelpAndExit "Error: -Clean yes must be used alone without other parameters"
    }
    Remove-TempFiles
    Write-Information "Cleanup completed successfully!"
    exit 0
}

if ($PSBoundParameters.ContainsKey('ExportAlbum')) {
    if ($PSBoundParameters.Count -gt 1) {
        Show-HelpAndExit "Error: -ExportAlbum must be used alone without other parameters"
    }
    if ($ExportAlbum -ne 'yes') {
        Show-HelpAndExit "Error: -ExportAlbum must be used with value 'yes'"
    }
}

try {
    # Initialize folders
    Initialize-Folders
    
    Write-Host "`nStarting Google Takeout processing..." -ForegroundColor Cyan

    # Handle ExifTool installation if needed
    if ($InstallExif -eq 'yes') {
        $exifToolCommand = Get-Command exiftool -ErrorAction SilentlyContinue
        $localExifTool = Join-Path $PSScriptRoot "ExifTool\exiftool.exe"
        
        if (-not $exifToolCommand -and -not (Test-Path $localExifTool)) {
            Write-Host "ExifTool not found, installing..." -ForegroundColor Yellow
            if (-not (Install-ExifTool)) {
                throw "Failed to install ExifTool"
            }
        }
    }

    # Handle zip extraction
    if ($Extract -eq 'yes') {
        Write-Host "`nExtracting archives..." -ForegroundColor Cyan
        Expand-ZipFiles -ExtractedPath $script:extractedPath
    }

    # Import albums if needed
    $albums = $null
    if ($GenerateAlbums -eq 'yes') {
        Write-Host "`nInitializing albums..." -ForegroundColor Cyan
        $albums = Import-Albums -AlbumsPath $script:albumsPath
        if ($null -eq $albums) {
            throw "Failed to initialize albums"
        }
    }

    # Process files for metadata
    if ($FixMetadata -eq 'yes') {
        Write-Host "`nProcessing metadata for files..." -ForegroundColor Cyan
        
        # Create and initialize the synchronized hashtable with thread-safe collections
        $script:syncHash = [hashtable]::Synchronized(@{
            MetadataErrors = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
            ProcessedFiles = [ref]0
        })
        
        $files = @(Get-ChildItem -Path $script:extractedPath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4")
        $totalFiles = $files.Count
        
        # Create runspace pool for parallel processing
        $InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $InitialSessionState.Variables.Add(
            [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
                'syncHash', $script:syncHash, 'Synchronized hashtable for cross-thread communication'
            )
        )
        
        $RunspacePool = [runspacefactory]::CreateRunspacePool(1, 8, $InitialSessionState, $Host)
        $RunspacePool.Open()
        
        $Jobs = @()
        
        foreach ($file in $files) {
            $PowerShell = [powershell]::Create().AddScript({
                param($FilePath, $ScriptRoot, $Total)
                
                try {
                    # Import required modules
                    Import-Module (Join-Path $ScriptRoot "MetadataOperations.psm1")
                    Import-Module (Join-Path $ScriptRoot "SharedOperations.psm1")
                    
                    # Update counter and show progress
                    $current = [System.Threading.Interlocked]::Increment($syncHash.ProcessedFiles)
                    $fileName = [System.IO.Path]::GetFileName($FilePath)
                    Write-ProgressStatus -Current $current -Total $Total -Operation "Processing" -ItemName $fileName
                    
                    if (-not (Update-FileMetadata -FilePath $FilePath)) {
                        $errorInfo = [PSCustomObject]@{
                            Path = $FilePath
                            Message = "Failed to update metadata"
                        }
                        $syncHash.MetadataErrors.Add($errorInfo)
                    }
                }
                catch {
                    $errorInfo = [PSCustomObject]@{
                        Path = $FilePath
                        Message = "Error: $_"
                    }
                    $syncHash.MetadataErrors.Add($errorInfo)
                    Write-Host ""  # New line after error
                }
            }).AddArgument($file.FullName).AddArgument($PSScriptRoot).AddArgument($totalFiles)
            
            $PowerShell.RunspacePool = $RunspacePool
            
            $Jobs += @{
                PowerShell = $PowerShell
                Handle = $PowerShell.BeginInvoke()
            }
        }
        
        # Wait for all jobs to complete
        Write-Host "`nWaiting for all files to be processed..." -ForegroundColor DarkGray
        do {
            $JobsRemaining = $Jobs.Handle | Where-Object { $_.IsCompleted -eq $false }
            
            if ($JobsRemaining) {
                Start-Sleep -Milliseconds 100
            }
        } while ($JobsRemaining)
        
        # Clean up
        foreach ($job in $Jobs) {
            $job.PowerShell.EndInvoke($job.Handle)
            $job.PowerShell.Dispose()
        }
        $RunspacePool.Close()
        $RunspacePool.Dispose()
        
        Write-Host "`nFile processing completed" -ForegroundColor Green

        # Write metadata errors
        if ($syncHash.MetadataErrors.Count -gt 0) {
            Write-Host "`nFound $($syncHash.MetadataErrors.Count) metadata errors" -ForegroundColor Yellow
            Write-JsonError -FilePath $script:metadataErrorsPath -ErrorItems @($syncHash.MetadataErrors.ToArray())
        }
    }

    # Sort files if enabled
    if ($Sort -ne 'no') {
        Write-Host "`nSorting files (mode: $Sort)..." -ForegroundColor Cyan
        $sortingResult = if ($Sort -eq 'years') {
            Move-ToYearFolders -SourcePath $script:extractedPath -DestinationRoot $script:outputPath `
                             -TrackAlbums ($GenerateAlbums -eq 'yes') -Albums $albums -AlbumsPath $script:outputPath
        } else {
            Move-ToOneFolder -SourcePath $script:extractedPath -DestinationRoot $script:outputPath `
                           -TrackAlbums ($GenerateAlbums -eq 'yes') -Albums $albums -AlbumsPath $script:outputPath
        }

        # Write sorting errors and duplicates
        if ($sortingResult.Errors.Count -gt 0) {
            Write-Host "`nFound $($sortingResult.Errors.Count) sorting errors" -ForegroundColor Yellow
            Write-JsonError -FilePath $script:sortingErrorsPath -ErrorItems $sortingResult.Errors
        }
        if ($sortingResult.Duplicates.Count -gt 0) {
            Write-Host "Found $($sortingResult.Duplicates.Count) duplicate files" -ForegroundColor Yellow
            Write-JsonError -FilePath $script:duplicateErrorsPath -ErrorItems $sortingResult.Duplicates
        }
        if ($sortingResult.AlbumUpdates.Count -gt 0) {
            Write-Host "Updating album data..." -ForegroundColor Cyan
            Update-AlbumFiles -AlbumUpdates $sortingResult.AlbumUpdates -AlbumsPath $script:albumsPath
        }
    }

    # Handle album export if requested
    if ($ExportAlbum -eq 'yes') {
        Write-Host "`nExporting albums..." -ForegroundColor Cyan
        if (-not (Export-Album -AlbumsPath $script:albumsPath -OutputPath $script:outputPath)) {
            throw "Failed to export albums"
        }
    }

    Write-Host "`nAll operations completed successfully!" -ForegroundColor Green
    Write-Host "`nCheck the following files for any issues:" -ForegroundColor Cyan
    Write-Host "Metadata Errors: $script:metadataErrorsPath"
    Write-Host "Sorting Errors: $script:sortingErrorsPath"
    Write-Host "Duplicate Files: $script:duplicateErrorsPath"
    if ($GenerateAlbums -eq 'yes') {
        Write-Host "Photo albums were generated in: $script:albumsPath"
    }
}
catch {
    Write-Error "Script failed: $_"
    exit 1
}
