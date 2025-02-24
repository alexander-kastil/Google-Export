# Requires -Version 7.0
using namespace System.Collections.Concurrent

[CmdletBinding()]
param (
    [ValidateSet('yes', 'no')]
    [string]$ExtractZip = 'yes',
    
    [ValidateSet('yes', 'no')]
    [string]$InstallExif = 'no',
    
    [ValidateSet('yes', 'no')]
    [string]$GenerateAlbums = 'no',
    
    [ValidateSet('no', 'years', 'onefolder')]
    [string]$Sorting = 'onefolder',
    
    [ValidatePattern('^(yes|no|\S.+)$')]
    [string]$ExportAlbum = $null
)

# Version check
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7.0 or later. Current version: $($PSVersionTable.PSVersion)"
    Write-Host "Please install PowerShell 7+ from: https://github.com/PowerShell/PowerShell/releases"
    exit 1
}

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

# Validate export-album is used alone
if ($ExportAlbum -and ($ExtractZip -eq 'yes' -or $InstallExif -eq 'yes' -or $GenerateAlbums -eq 'yes')) {
    Show-HelpAndExit "Error: -ExportAlbum must be used alone without other parameters"
}

# Initialize script-level variables
$script:extractZipValue = $ExtractZip
$script:installExifValue = $InstallExif
$script:generateAlbumsValue = $GenerateAlbums

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
This tool processes Google Photos Takeout archives by fixing metadata timestamps and organizing photos into folders.

Parameter Rules:
--------------
1. The -ExportAlbum parameter MUST be used alone without any other parameters
2. Other parameters (-ExtractZip, -InstallExif, -GenerateAlbums, -Sorting) can be combined
3. ExifTool is NOT installed by default, use -InstallExif yes to install it

Parameters:
----------
-ExtractZip yes|no     : Extract ZIP files from Google Takeout (default: yes)
-InstallExif yes|no    : Download and install ExifTool if not found (default: no)
-GenerateAlbums yes|no : Generate album JSON files (default: no)
                        Requires albums.txt file with one album name per line
-Sorting no|years|onefolder : Control how files are organized (default: onefolder)
                        'no': Leave files in place after metadata fix
                        'years': Sort into year-based folders (2023, 2022, etc.)
                        'onefolder': Sort into pictures/ and movies/ folders
-ExportAlbum yes       : Export photos from albums
                        When used with yes, exports all albums 
                        Must be used alone without other parameters

Examples:
--------
Basic usage - extract and organize into pictures/movies folders:
  .\fix-google-takeout-v2.ps1 -ExtractZip yes -Sorting onefolder

Extract files and sort by year:
  .\fix-google-takeout-v2.ps1 -ExtractZip yes -Sorting years

Generate albums during sorting:
  .\fix-google-takeout-v2.ps1 -ExtractZip yes -GenerateAlbums yes -Sorting years

First time setup with ExifTool installation:
  .\fix-google-takeout-v2.ps1 -ExtractZip yes -InstallExif yes -Sorting onefolder

Export all albums (must be used alone):
  .\fix-google-takeout-v2.ps1 -ExportAlbum yes
"@
    Write-Host $helpText
    exit 1
}

function Test-ParamValue {
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    # For all parameters, only 'yes' or 'no' is allowed
    if ($Value -eq 'yes' -or $Value -eq 'no') {
        return $Value
    }
    else {
        Show-HelpAndExit "Error: Value for -$($Name) must be 'yes' or 'no'"
    }
}

# Validate parameters and set script variables
if ($PSBoundParameters.ContainsKey('ExportAlbum')) {
    if ($PSBoundParameters.Count -gt 1) {
        Show-HelpAndExit "Error: -ExportAlbum must be used alone without other parameters"
    }
    $ExportAlbum = Test-ParamValue -Name 'ExportAlbum' -Value $ExportAlbum
} else {
    # Only validate other parameters if ExportAlbum is not used
    $ExtractZip = Test-ParamValue -Name 'ExtractZip' -Value $ExtractZip
    $InstallExif = Test-ParamValue -Name 'InstallExif' -Value $InstallExif
    $GenerateAlbums = Test-ParamValue -Name 'GenerateAlbums' -Value $GenerateAlbums
}

# Initialize script-level variables
$script:extractZipValue = $ExtractZip
$script:installExifValue = $InstallExif
$script:generateAlbumsValue = $GenerateAlbums

function Initialize-Folders {
    # Create required folders first
    $foldersToCreate = @(
        $script:extractedPath,
        $script:sortedPath,
        $script:logsPath,
        $script:albumsPath,
        (Join-Path $script:outputPath "pictures"),
        (Join-Path $script:outputPath "movies")
    )

    foreach ($folder in $foldersToCreate) {
        if (-not (Test-Path $folder)) {
            $null = New-Item -ItemType Directory -Path $folder -Force
        }
    }

    # Initialize error logging files with empty arrays
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

    # Initialize albums if needed
    if ($script:generateAlbumbsValue -eq 'yes') {
        Import-Albums
    }
}

function Import-Albums {
    $albumsFile = Join-Path $PSScriptRoot "albums.txt"
    if (-not (Test-Path $albumsFile)) {
        Write-Error "albums.txt not found. This file is required when using -GenerateAlbums yes. Please create albums.txt with one album name per line."
        exit 1
    }

    if ((Get-Content $albumsFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Measure-Object).Count -eq 0) {
        Write-Error "albums.txt is empty. Please add at least one album name when using -GenerateAlbums yes."
        exit 1
    }

    # Create albums directory if it doesn't exist
    if (-not (Test-Path $script:albumsPath)) {
        $null = New-Item -ItemType Directory -Path $script:albumsPath -Force
    }

    # Read and process album names
    Get-Content $albumsFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $albumName = $_.Trim().ToLower()
        $script:albums[$albumName] = @{
            name = $albumName
            items = [ConcurrentBag[PSCustomObject]]::new()
        }
        
        # Initialize album JSON file
        $albumPath = Join-Path $script:albumsPath "$albumName.json"
        "[]" | Set-Content -Path $albumPath -Encoding UTF8
        Write-Information "Initialized album: $albumName"
    }
}

function Install-ExifTool {
    param (
        [string]$ExifToolUrl = "https://exiftool.org/exiftool-12.70.zip",
        [string]$InstallPath = (Join-Path $PSScriptRoot "ExifTool")
    )

    Write-ScriptInformation "Installing ExifTool..."
    $downloadPath = Join-Path $PSScriptRoot "exiftool.zip"

    try {
        # Download ExifTool using newer HTTP client
        $webClient = [System.Net.Http.HttpClient]::new()
        $response = $webClient.GetByteArrayAsync($ExifToolUrl).GetAwaiter().GetResult()
        [System.IO.File]::WriteAllBytes($downloadPath, $response)
        Write-ScriptInformation "ExifTool downloaded successfully"

        # Create ExifTool directory and extract
        $null = New-Item -ItemType Directory -Path $InstallPath -Force
        Expand-Archive -Path $downloadPath -DestinationPath $InstallPath -Force
        Write-ScriptInformation "ExifTool archive extracted"

        # Rename the executable
        $oldExePath = Join-Path $InstallPath "exiftool(-k).exe"
        if (Test-Path $oldExePath) {
            $null = Rename-Item -Path $oldExePath -NewName "exiftool.exe" -Force
        }

        # Clean up zip file
        $null = Remove-Item $downloadPath -Force

        # Add to temporary path for current session
        $env:Path = "$InstallPath;$env:Path"
        Write-ScriptInformation "ExifTool installed successfully"
        return $true
    }
    catch {
        Write-Error "Failed to install ExifTool: $_"
        return $false
    }
    finally {
        if ($webClient) { $webClient.Dispose() }
    }
}

function Update-FileMetadata {
    param (
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$MetadataErrorsPath
    )

    # Show current folder being processed
    $currentFolder = Split-Path (Split-Path $FilePath -Parent) -Leaf
    Write-Information "Processing folder: $currentFolder"

    $ErrorActionPreference = 'Stop'
    $fileTypeTask = $null
    $exifDataTask = $null
    
    try {
        # Run exiftool commands in parallel where possible
        $fileTypeTask = Start-ThreadJob -ScriptBlock { 
            param($path)
            exiftool -FileType "$path" -S 
        } -ArgumentList $FilePath

        $exifDataTask = Start-ThreadJob -ScriptBlock { 
            param($path)
            exiftool -json "$path" | ConvertFrom-Json 
        } -ArgumentList $FilePath

        $fileTypeInfo = Receive-Job -Job $fileTypeTask -Wait -ErrorAction Stop
        $exifData = Receive-Job -Job $exifDataTask -Wait -ErrorAction Stop

        # Check actual file type using exiftool
        if ($fileTypeInfo -match "^FileType: (.+)$") {
            $actualType = $matches[1]
            $currentExtension = [System.IO.Path]::GetExtension($FilePath)
            
            # Map of actual types to correct extensions
            $extensionMap = @{
                'JPEG' = '.jpg'
                'HEIC' = '.heic'
                'PNG' = '.png'
                'MP4' = '.mp4'
            }

            # Correct extension if needed
            if ($extensionMap.ContainsKey($actualType)) {
                $correctExtension = $extensionMap[$actualType]
                if ($currentExtension -ne $correctExtension) {
                    $newPath = [System.IO.Path]::ChangeExtension($FilePath, $correctExtension.TrimStart('.'))
                    Write-Host "Correcting extension: $([System.IO.Path]::GetFileName($FilePath)) -> $([System.IO.Path]::GetFileName($newPath))"
                    Move-Item -Path $FilePath -Destination $newPath -Force
                    $FilePath = $newPath
                }
            }
        }

        # Process dates in parallel
        $takenTime = $null
        $metadataFile = "$FilePath.supplemental-metadata.json"

        if (Test-Path $metadataFile) {
            $metadata = Get-Content $metadataFile -Raw | ConvertFrom-Json
            if ($metadata.photoTakenTime.formatted) {
                try {
                    $formatted = $metadata.photoTakenTime.formatted -replace " UTC$"
                    if ($formatted -match "^\d{2}\.\d{2}\.\d{4}, \d{2}:\d{2}:\d{2}$") {
                        $takenTime = [DateTime]::ParseExact(
                            $formatted,
                            "dd.MM.yyyy, HH:mm:ss",
                            [System.Globalization.CultureInfo]::InvariantCulture
                        )
                    } else {
                        $takenTime = [DateTime]::Parse($formatted)
                    }
                }
                catch {
                    Write-Warning "Failed to parse date: $formatted"
                }
            }
        }

        if ($null -eq $takenTime) {
            $takenTime = if ($exifData.DateTimeOriginal) {
                try {
                    [DateTime]::ParseExact(
                        $exifData.DateTimeOriginal,
                        "yyyy:MM:dd HH:mm:ss",
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                } catch {
                    [DateTime]::Parse($exifData.DateTimeOriginal)
                }
            }
            elseif ($exifData.CreateDate) {
                try {
                    [DateTime]::ParseExact(
                        $exifData.CreateDate,
                        "yyyy:MM:dd HH:mm:ss",
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                } catch {
                    [DateTime]::Parse($exifData.CreateDate)
                }
            }
            elseif ($exifData.FileModifyDate) {
                try {
                    [DateTime]::ParseExact(
                        $exifData.FileModifyDate,
                        "yyyy:MM:dd HH:mm:ss",
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                } catch {
                    [DateTime]::Parse($exifData.FileModifyDate)
                }
            }
        }

        if ($null -eq $takenTime) {
            $errorItem = [PSCustomObject]@{
                Path = $FilePath
                Message = "No date found in metadata or EXIF"
            }
            $currentErrors = @()
            if (Test-Path $MetadataErrorsPath) {
                $content = Get-Content -Path $MetadataErrorsPath -Raw
                if ($content) {
                    $currentErrors = @(ConvertFrom-Json -InputObject $content)
                }
            }
            $currentErrors = @($currentErrors) + @($errorItem)
            ConvertTo-Json -InputObject $currentErrors | Set-Content -Path $MetadataErrorsPath -Encoding UTF8
            return
        }

        # Use exiftool to set creation and modification dates
        $dateStr = $takenTime.ToString("yyyy:MM:dd HH:mm:ss")
        $result = exiftool "-AllDates=$dateStr" "-overwrite_original" "$FilePath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "ExifTool failed: $result"
        }
    }
    catch {
        $errorItem = [PSCustomObject]@{
            Path = $FilePath
            Message = "Error processing file: $_"
        }
        $currentErrors = @()
        if (Test-Path $MetadataErrorsPath) {
            $content = Get-Content -Path $MetadataErrorsPath -Raw
            if ($content) {
                $currentErrors = @(ConvertFrom-Json -InputObject $content)
            }
        }
        $currentErrors = @($currentErrors) + @($errorItem)
        ConvertTo-Json -InputObject $currentErrors | Set-Content -Path $MetadataErrorsPath -Encoding UTF8
    }
    finally {
        if ($fileTypeTask) { Remove-Job -Job $fileTypeTask -Force -ErrorAction SilentlyContinue }
        if ($exifDataTask) { Remove-Job -Job $exifDataTask -Force -ErrorAction SilentlyContinue }
        $ErrorActionPreference = 'Continue'
    }
}

function Move-ToYearFolders {
    param (
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$DestinationRoot,
        
        [bool]$TrackAlbums = $false,
        [hashtable]$Albums = $null,
        [string]$AlbumsPath = '',
        [int]$ThrottleLimit = 8
    )

    $sortingErrorsPath = $script:sortingErrorsPath
    $duplicateErrorsPath = $script:duplicateErrorsPath
    $errors = [ConcurrentBag[PSCustomObject]]::new()
    $duplicates = [ConcurrentBag[PSCustomObject]]::new()
    $albumUpdates = [ConcurrentBag[PSCustomObject]]::new()
    $scriptRoot = $PSScriptRoot

    try {
        # Process files in parallel
        @(Get-ChildItem -Path $SourcePath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4") | 
        ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $destRoot = $using:DestinationRoot
            $trackAlbums = $using:TrackAlbums
            $albums = $using:Albums
            $scriptRoot = $using:scriptRoot
            $errors = $using:errors
            $duplicates = $using:duplicates
            $albumUpdates = $using:albumUpdates
            
            try {
                $currentFolder = Split-Path (Split-Path $_.FullName -Parent) -Leaf
                Write-Information "Moving files from folder: $currentFolder"

                $exifData = exiftool -json $_.FullName | ConvertFrom-Json
                if ($exifData.CreateDate) {
                    $dateTime = [DateTime]::ParseExact(
                        $exifData.CreateDate,
                        "yyyy:MM:dd HH:mm:ss",
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                    $yearValue = $dateTime.Year.ToString()

                    $yearPath = Join-Path $destRoot $yearValue
                    $null = New-Item -ItemType Directory -Path $yearPath -Force

                    $destFileName = $_.Name
                    $destPath = Join-Path $yearPath $destFileName

                    # Handle duplicates with atomic operations
                    while (Test-Path $destPath) {
                        $fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                        $extension = [System.IO.Path]::GetExtension($_.Name)
                        $random = Get-Random -Maximum 99999
                        $newFileName = "${fileNameWithoutExt}_duplicate_${random}${extension}"
                        $destPath = Join-Path $yearPath $newFileName
                        
                        if (-not (Test-Path $destPath)) {
                            $duplicates.Add([PSCustomObject]@{
                                Path = $_.FullName
                                Message = "Duplicate file renamed to: $newFileName"
                            })
                            break
                        }
                    }

                    # Move the file with atomic operation
                    $null = Move-Item -Path $_.FullName -Destination $destPath -Force

                    # Track album if enabled
                    if ($trackAlbums) {
                        $folderNameLower = $currentFolder.ToLower()
                        if ($albums.ContainsKey($folderNameLower)) {
                            $relativePath = $yearPath.Replace($scriptRoot, '').TrimStart('\')
                            $fileName = [System.IO.Path]::GetFileName($destPath)
                            
                            $albumUpdates.Add([PSCustomObject]@{
                                Album = $folderNameLower
                                Item = [PSCustomObject]@{
                                    name = $fileName
                                    relativePath = $relativePath
                                    fullPath = Join-Path $relativePath $fileName
                                }
                            })
                        }
                    }
                } else {
                    $errors.Add([PSCustomObject]@{
                        Path = $_.FullName
                        Message = "No date found in EXIF data"
                    })
                }
            }
            catch {
                $errors.Add([PSCustomObject]@{
                    Path = $_.FullName
                    Message = "Error sorting file: $_"
                })
            }
        }

        # Process album updates after parallel execution
        if ($TrackAlbums) {
            $retryStrategy = @{
                MaxRetries = 5
                RetryDelay = 100  # milliseconds
                BackoffMultiplier = 2  # Exponential backoff
            }
            
            $albumUpdates.ToArray() | Group-Object -Property Album | ForEach-Object {
                $albumName = $_.Name
                $albumPath = Join-Path $AlbumsPath "$albumName.json"
                $lockFile = Join-Path $AlbumsPath "$albumName.lock"
                $success = $false
                $retryCount = 0
                $currentDelay = $retryStrategy.RetryDelay
                
                while (-not $success -and $retryCount -lt $retryStrategy.MaxRetries) {
                    $lockStream = $null
                    try {
                        $lockStream = [System.IO.File]::Open(
                            $lockFile, 
                            [System.IO.FileMode]::CreateNew,
                            [System.IO.FileAccess]::Write,
                            [System.IO.FileShare]::None
                        )
                        
                        $currentItems = @()
                        if (Test-Path $albumPath) {
                            $content = Get-Content -Path $albumPath -Raw -ErrorAction Stop
                            if ($content) {
                                $currentItems = @(ConvertFrom-Json -InputObject $content -ErrorAction Stop)
                            }
                        }
                        
                        # Ensure we don't add duplicates
                        $newItems = @($_.Group.Item)
                        $existingPaths = @($currentItems | Select-Object -ExpandProperty fullPath)
                        $uniqueNewItems = $newItems | Where-Object { $existingPaths -notcontains $_.fullPath }
                        
                        if ($uniqueNewItems) {
                            $updatedItems = @($currentItems) + @($uniqueNewItems)
                            $json = ConvertTo-Json -InputObject $updatedItems -Depth 10
                            [System.IO.File]::WriteAllText($albumPath, $json, [System.Text.Encoding]::UTF8)
                        }
                        
                        $success = $true
                    }
                    catch [System.IO.IOException] {
                        $retryCount++
                        if ($retryCount -lt $retryStrategy.MaxRetries) {
                            Start-Sleep -Milliseconds $currentDelay
                            $currentDelay *= $retryStrategy.BackoffMultiplier
                        }
                    }
                    catch {
                        Write-Error "Failed to update album $albumName : $_"
                        break
                    }
                    finally {
                        if ($lockStream) {
                            $lockStream.Dispose()
                            $null = Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                
                if (-not $success) {
                    Write-Error "Failed to update album $albumName after $($retryStrategy.MaxRetries) retries"
                }
            }
        }

        # Write all errors and duplicates to files after processing
        if ($errors.Count -gt 0) {
            Write-JsonError -FilePath $sortingErrorsPath -ErrorItems @($errors.ToArray())
        }
        if ($duplicates.Count -gt 0) {
            Write-JsonError -FilePath $duplicateErrorsPath -ErrorItems @($duplicates.ToArray())
        }
    }
    catch {
        Write-Error "Failed to process files: $_"
        throw
    }
}

function Move-ToOneFolder {
    param (
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$DestinationRoot,
        
        [bool]$TrackAlbums = $false,
        [hashtable]$Albums = $null,
        [string]$AlbumsPath = '',
        [int]$ThrottleLimit = 8
    )

    $sortingErrorsPath = $script:sortingErrorsPath
    $duplicateErrorsPath = $script:duplicateErrorsPath
    $errors = [ConcurrentBag[PSCustomObject]]::new()
    $duplicates = [ConcurrentBag[PSCustomObject]]::new()
    $albumUpdates = [ConcurrentBag[PSCustomObject]]::new()
    $scriptRoot = $PSScriptRoot

    try {
        # Create output folders if they don't exist
        $picturesPath = Join-Path $DestinationRoot "pictures"
        $moviesPath = Join-Path $DestinationRoot "movies"
        $null = New-Item -ItemType Directory -Path $picturesPath -Force
        $null = New-Item -ItemType Directory -Path $moviesPath -Force

        # Process files in parallel
        @(Get-ChildItem -Path $SourcePath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4") | 
        ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $destRoot = $using:DestinationRoot
            $trackAlbums = $using:TrackAlbums
            $albums = $using:Albums
            $errors = $using:errors
            $duplicates = $using:duplicates
            $albumUpdates = $using:albumUpdates
            
            try {
                $currentFolder = Split-Path (Split-Path $_.FullName -Parent) -Leaf
                Write-Information "Moving file from folder: $currentFolder"

                # Determine destination subfolder based on file extension
                $ext = $_.Extension.ToLower()
                $subFolder = if ($ext -eq '.mp4') { "movies" } else { "pictures" }
                $destFolder = Join-Path $destRoot $subFolder

                $destFileName = $_.Name
                $destPath = Join-Path $destFolder $destFileName

                # Handle duplicates
                while (Test-Path $destPath) {
                    $fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                    $extension = [System.IO.Path]::GetExtension($_.Name)
                    $random = Get-Random -Maximum 99999
                    $newFileName = "${fileNameWithoutExt}_duplicate_${random}${extension}"
                    $destPath = Join-Path $destFolder $newFileName
                    
                    if (-not (Test-Path $destPath)) {
                        $duplicates.Add([PSCustomObject]@{
                            Path = $_.FullName
                            Message = "Duplicate file renamed to: $newFileName"
                        })
                        break
                    }
                }

                # Move the file
                $null = Move-Item -Path $_.FullName -Destination $destPath -Force

                # Track album if enabled
                if ($trackAlbums) {
                    $folderNameLower = $currentFolder.ToLower()
                    if ($albums.ContainsKey($folderNameLower)) {
                        $relativePath = $subFolder
                        $fileName = [System.IO.Path]::GetFileName($destPath)
                        
                        $albumUpdates.Add([PSCustomObject]@{
                            Album = $folderNameLower
                            Item = [PSCustomObject]@{
                                name = $fileName
                                relativePath = $relativePath
                                fullPath = Join-Path $relativePath $fileName
                            }
                        })
                    }
                }
            }
            catch {
                $errors.Add([PSCustomObject]@{
                    Path = $_.FullName
                    Message = "Error moving file: $_"
                })
            }
        }

        # Process album updates
        if ($TrackAlbums) {
            $retryStrategy = @{
                MaxRetries = 5
                RetryDelay = 100
                BackoffMultiplier = 2
            }
            
            $albumUpdates.ToArray() | Group-Object -Property Album | ForEach-Object {
                $albumName = $_.Name
                $albumPath = Join-Path $AlbumsPath "$albumName.json"
                $lockFile = Join-Path $AlbumsPath "$albumName.lock"
                $success = $false
                $retryCount = 0
                $currentDelay = $retryStrategy.RetryDelay
                
                while (-not $success -and $retryCount -lt $retryStrategy.MaxRetries) {
                    $lockStream = $null
                    try {
                        $lockStream = [System.IO.File]::Open(
                            $lockFile, 
                            [System.IO.FileMode]::CreateNew,
                            [System.IO.FileAccess]::Write,
                            [System.IO.FileShare]::None
                        )
                        
                        $currentItems = @()
                        if (Test-Path $albumPath) {
                            $content = Get-Content -Path $albumPath -Raw -ErrorAction Stop
                            if ($content) {
                                $currentItems = @(ConvertFrom-Json -InputObject $content -ErrorAction Stop)
                            }
                        }
                        
                        # Add new items avoiding duplicates
                        $newItems = @($_.Group.Item)
                        $existingPaths = @($currentItems | Select-Object -ExpandProperty fullPath)
                        $uniqueNewItems = $newItems | Where-Object { $existingPaths -notcontains $_.fullPath }
                        
                        if ($uniqueNewItems) {
                            $updatedItems = @($currentItems) + @($uniqueNewItems)
                            $json = ConvertTo-Json -InputObject $updatedItems -Depth 10
                            [System.IO.File]::WriteAllText($albumPath, $json, [System.Text.Encoding]::UTF8)
                        }
                        
                        $success = $true
                    }
                    catch [System.IO.IOException] {
                        $retryCount++
                        if ($retryCount -lt $retryStrategy.MaxRetries) {
                            Start-Sleep -Milliseconds $currentDelay
                            $currentDelay *= $retryStrategy.BackoffMultiplier
                        }
                    }
                    catch {
                        Write-Error "Failed to update album $albumName : $_"
                        break
                    }
                    finally {
                        if ($lockStream) {
                            $lockStream.Dispose()
                            $null = Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                
                if (-not $success) {
                    Write-Error "Failed to update album $albumName after $($retryStrategy.MaxRetries) retries"
                }
            }
        }

        # Write errors and duplicates to files
        if ($errors.Count -gt 0) {
            Write-JsonError -FilePath $sortingErrorsPath -ErrorItems @($errors.ToArray())
        }
        if ($duplicates.Count -gt 0) {
            Write-JsonError -FilePath $duplicateErrorsPath -ErrorItems @($duplicates.ToArray())
        }
    }
    catch {
        Write-Error "Failed to process files: $_"
        throw
    }
}

# Check and install ExifTool if needed
$exifToolCommand = Get-Command exiftool -ErrorAction SilentlyContinue
$localExifTool = Join-Path $PSScriptRoot "ExifTool\exiftool.exe"

# Main execution
$InformationPreference = 'Continue'
$script:infoStream = [System.Collections.ArrayList]::new()

function Write-ScriptInformation {
    param([string]$Message)
    Write-Information $Message
    [void]$script:infoStream.Add($Message)
}

function Expand-ZipFiles {
    $extractErrors = [ConcurrentBag[string]]::new()
    Write-ScriptInformation "Starting ZIP extraction..."
    
    Get-ChildItem -Path $PSScriptRoot -Filter "*.zip" | 
    ForEach-Object -ThrottleLimit 4 -Parallel {
        try {
            Write-Information "Extracting $($_.Name)..."
            $null = Expand-Archive -Path $_.FullName -DestinationPath $using:script:extractedPath -Force
        }
        catch {
            $(using:extractErrors).Add("Failed to extract $($_.Name): $_")
        }
    }
    
    if ($extractErrors.Count -gt 0) {
        Write-Warning "Some archives failed to extract:"
        $extractErrors | ForEach-Object { Write-Warning $_ }
    }
    Write-ScriptInformation "ZIP extraction completed"
}

# Initialize script-level variables at the start
$script:extractedPath = Join-Path -Path $PSScriptRoot -ChildPath "extracted"
$script:sortedPath = Join-Path -Path $PSScriptRoot -ChildPath "sorted"
$script:outputPath = Join-Path -Path $PSScriptRoot -ChildPath "output"
$script:lastProcessedFolder = [ConcurrentDictionary[string,bool]]::new()
$script:lastSortedFolder = [ConcurrentDictionary[string,bool]]::new()
$script:logsPath = Join-Path -Path $PSScriptRoot -ChildPath "logs"
$script:albumsPath = Join-Path -Path $PSScriptRoot -ChildPath "photo-albums"
$script:exportPath = Join-Path -Path $PSScriptRoot -ChildPath "exported-albums"
$script:metadataErrorsPath = Join-Path -Path $script:logsPath -ChildPath "metadata.errors.json"
$script:sortingErrorsPath = Join-Path -Path $script:logsPath -ChildPath "sorting.errors.json"
$script:duplicateErrorsPath = Join-Path -Path $script:logsPath -ChildPath "duplicate.errors.json"
$script:albums = @{}
$script:generateAlbums = 'no'

# Initialize required folders and files
Initialize-Folders

# Handle ExifTool installation based on parameter or user input
if (-not $exifToolCommand -and -not (Test-Path $localExifTool)) {
    if ($InstallExif -eq 'yes') {
        Write-ScriptInformation "ExifTool not found, installing..."
        if (-not (Install-ExifTool)) {
            Show-HelpAndExit "Error: Failed to install ExifTool. Please install it manually from https://exiftool.org/"
        }
    } else {
        Show-HelpAndExit "Error: ExifTool is required but not installed. Run script with --install-exif yes to install it, or install manually from https://exiftool.org/"
    }
} else {
    Write-ScriptInformation "ExifTool already installed"
}

# Handle zip extraction
if ($ExtractZip -eq 'yes') {
    Write-ScriptInformation "Starting archive extraction..."
    Expand-ZipFiles
}

# Handle album generation
if ($GenerateAlbums -eq 'yes') {
    Write-ScriptInformation "Starting album generation..."
    Import-Albums
    Write-ScriptInformation "Album generation completed"
}

# Handle album export if requested
if ($ExportAlbum) {
    Write-ScriptInformation "Starting album export..."
    Export-Album -AlbumName $ExportAlbum -AlbumsPath $script:albumsPath -ExportPath $script:exportPath
}

# Process all media files in parallel
$updateFileMetadataStr = ${function:Update-FileMetadata}.ToString()
Get-ChildItem -Path $script:extractedPath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4" | 
ForEach-Object -ThrottleLimit 8 -Parallel {
    ${function:Update-FileMetadata} = $using:updateFileMetadataStr
    $metadataErrorsPath = $using:script:metadataErrorsPath
    Update-FileMetadata -FilePath $_.FullName -MetadataErrorsPath $metadataErrorsPath
}

# Sort files based on sorting parameter
if ($Sorting -ne 'no') {
    Write-ScriptInformation "Starting file sorting with mode: $Sorting"
    if ($script:generateAlbums -eq 'yes') {
        if ($Sorting -eq 'years') {
            Move-ToYearFolders -SourcePath $script:extractedPath -DestinationRoot $script:sortedPath -TrackAlbums $true -Albums $script:albums -AlbumsPath $script:albumsPath
        } else {
            Move-ToOneFolder -SourcePath $script:extractedPath -DestinationRoot $script:outputPath -TrackAlbums $true -Albums $script:albums -AlbumsPath $script:albumsPath
        }
    } else {
        if ($Sorting -eq 'years') {
            Move-ToYearFolders -SourcePath $script:extractedPath -DestinationRoot $script:sortedPath -TrackAlbums $false
        } else {
            Move-ToOneFolder -SourcePath $script:extractedPath -DestinationRoot $script:outputPath -TrackAlbums $false
        }
    }
    Write-ScriptInformation "File sorting completed"
} else {
    Write-ScriptInformation "Skipping file sorting (mode: no)"
}

function Export-Album {
    param (
        [Parameter(Mandatory)]
        [ValidateSet('yes')]  # Only accept 'yes' value
        [string]$AlbumName,
        [Parameter(Mandatory)]
        [string]$AlbumsPath,
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    # Validate required folders exist from previous runs
    if (-not (Test-Path $script:extractedPath)) {
        Show-HelpAndExit "Error: 'extracted' folder not found. Please run -ExtractZip yes first"
    }
    if (-not (Test-Path $script:albumsPath)) {
        Show-HelpAndExit "Error: 'photo-albums' folder not found. Please run -GenerateAlbums yes first"
    }
    if (-not (Test-Path $script:sortedPath)) {
        Show-HelpAndExit "Error: 'sorted' folder not found. Please run the script with both -ExtractZip yes and -GenerateAlbums yes first"
    }

    # Create export directory
    $null = New-Item -ItemType Directory -Path $ExportPath -Force

    # Get list of all albums to process
    $albumsToProcess = Get-ChildItem -Path $AlbumsPath -Filter "*.json" | ForEach-Object { 
        [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
    }
    if ($albumsToProcess.Count -eq 0) {
        Show-HelpAndExit "Error: No albums found in 'photo-albums' folder"
    }

    # Process each album
    foreach ($album in $albumsToProcess) {
        Write-Information "Processing album: $album"
        
        $albumFile = Join-Path $AlbumsPath "$album.json"
        $albumContent = Get-Content -Path $albumFile -Raw | ConvertFrom-Json
        
        if ($albumContent.Count -eq 0) {
            Write-Warning "Album '$album' is empty, skipping..."
            continue
        }

        $albumExportPath = Join-Path $ExportPath $album
        $null = New-Item -ItemType Directory -Path $albumExportPath -Force

        $albumContent | ForEach-Object {
            $sourcePath = Join-Path $PSScriptRoot $_.fullPath
            if (Test-Path $sourcePath) {
                $destPath = Join-Path $albumExportPath $_.name
                Copy-Item -Path $sourcePath -Destination $destPath -Force
                Write-Information "Exported: $($_.name)"
            } else {
                Write-Warning "File not found: $($_.fullPath)"
            }
        }
    }

    Write-Information "Album export complete!"
    Write-Information "All albums have been exported to: $ExportPath"
}

# Handle album export if requested
if ($ExportAlbum -eq 'yes') {
    Write-ScriptInformation "Starting album export..."
    Export-Album -AlbumName 'yes' -AlbumsPath $script:albumsPath -ExportPath $script:exportPath
    exit 0
} elseif ($ExportAlbum) {
    Show-HelpAndExit "Error: -ExportAlbum must be used with value 'yes'"
}

# Output summary
Write-Information "Processing complete!"
Write-Information "Check the following files for any issues:"
Write-Information "Metadata Errors: $script:metadataErrorsPath"
Write-Information "Sorting Errors: $script:sortingErrorsPath"
Write-Information "Duplicate Files: $script:duplicateErrorsPath"
if ($script:generateAlbums -eq 'yes') {
    Write-Information "Photo albums were generated in: $script:albumsPath"
}

try {
    # Initialize required folders
    Initialize-Folders

    # Handle ExifTool installation if needed
    if ($InstallExif -eq 'yes') {
        $exifToolCommand = Get-Command exiftool -ErrorAction SilentlyContinue
        $localExifTool = Join-Path $PSScriptRoot "ExifTool\exiftool.exe"
        
        if (-not $exifToolCommand -and -not (Test-Path $localExifTool)) {
            Write-ScriptInformation "ExifTool not found, installing..."
            if (-not (Install-ExifTool)) {
                throw "Failed to install ExifTool"
            }
        } else {
            Write-ScriptInformation "ExifTool already installed"
        }
    }

    # Handle zip extraction
    if ($ExtractZip -eq 'yes') {
        Write-ScriptInformation "Starting archive extraction..."
        Expand-ZipFiles
    }

    # Process all media files in parallel for metadata update
    $updateFileMetadataStr = ${function:Update-FileMetadata}.ToString()
    Get-ChildItem -Path $script:extractedPath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4" | 
    ForEach-Object -ThrottleLimit 8 -Parallel {
        ${function:Update-FileMetadata} = $using:updateFileMetadataStr
        $metadataErrorsPath = $using:script:metadataErrorsPath
        Update-FileMetadata -FilePath $_.FullName -MetadataErrorsPath $metadataErrorsPath
    }

    # Sort files if sorting is enabled
    if ($Sorting -ne 'no') {
        Write-ScriptInformation "Starting file sorting with mode: $Sorting"
        if ($Sorting -eq 'years') {
            Move-ToYearFolders -SourcePath $script:extractedPath -DestinationRoot $script:sortedPath -TrackAlbums $false
        } else {
            Move-ToOneFolder -SourcePath $script:extractedPath -DestinationRoot $script:outputPath -TrackAlbums $false
        }
        Write-ScriptInformation "File sorting completed"
    } else {
        Write-ScriptInformation "Skipping file sorting (mode: no)"
    }

    # Handle album generation independently
    if ($GenerateAlbums -eq 'yes') {
        Write-ScriptInformation "Starting album generation..."
        Import-Albums
        
        # Process files for albums based on current sorting mode
        $sourcePath = if ($Sorting -eq 'years') { $script:sortedPath } 
                     elseif ($Sorting -eq 'onefolder') { $script:outputPath }
                     else { $script:extractedPath }

        if ($Sorting -eq 'years') {
            Move-ToYearFolders -SourcePath $sourcePath -DestinationRoot $script:sortedPath -TrackAlbums $true -Albums $script:albums -AlbumsPath $script:albumsPath
        } elseif ($Sorting -eq 'onefolder') {
            Move-ToOneFolder -SourcePath $sourcePath -DestinationRoot $script:outputPath -TrackAlbums $true -Albums $script:albums -AlbumsPath $script:albumsPath
        } else {
            # If no sorting is selected, process files in place for albums
            Process-AlbumsInPlace -SourcePath $sourcePath -Albums $script:albums -AlbumsPath $script:albumsPath
        }
        Write-ScriptInformation "Album generation completed"
    }

    # Handle album export if requested
    if ($ExportAlbum -eq 'yes') {
        Write-ScriptInformation "Starting album export..."
        Export-Album -AlbumName 'yes' -AlbumsPath $script:albumsPath -ExportPath $script:exportPath
    }

    Write-ScriptInformation "All operations completed successfully"
}
catch {
    Write-Error "Script failed: $_"
    exit 1
}

function Write-JsonError {
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [array]$ErrorItems
    )
    
    ConvertTo-Json -InputObject $ErrorItems | Set-Content -Path $FilePath -Encoding UTF8
}

function Process-AlbumsInPlace {
    param (
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [hashtable]$Albums,
        [Parameter(Mandatory)]
        [string]$AlbumsPath,
        [int]$ThrottleLimit = 8
    )

    $albumUpdates = [ConcurrentBag[PSCustomObject]]::new()

    try {
        # Process files in parallel
        @(Get-ChildItem -Path $SourcePath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4") | 
        ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $albums = $using:Albums
            $albumUpdates = $using:albumUpdates
            
            try {
                $currentFolder = Split-Path (Split-Path $_.FullName -Parent) -Leaf
                $folderNameLower = $currentFolder.ToLower()
                
                if ($albums.ContainsKey($folderNameLower)) {
                    # Get relative path from source
                    $relativePath = $_.DirectoryName.Replace($using:SourcePath, '').TrimStart('\')
                    if ([string]::IsNullOrEmpty($relativePath)) {
                        $relativePath = "."
                    }
                    
                    $fileName = [System.IO.Path]::GetFileName($_.FullName)
                    
                    $albumUpdates.Add([PSCustomObject]@{
                        Album = $folderNameLower
                        Item = [PSCustomObject]@{
                            name = $fileName
                            relativePath = $relativePath
                            fullPath = if ($relativePath -eq ".") { $fileName } else { Join-Path $relativePath $fileName }
                        }
                    })
                }
            }
            catch {
                Write-Warning "Error processing file $($_.FullName) for albums: $_"
            }
        }

        # Process album updates with retry strategy
        $retryStrategy = @{
            MaxRetries = 5
            RetryDelay = 100
            BackoffMultiplier = 2
        }
        
        $albumUpdates.ToArray() | Group-Object -Property Album | ForEach-Object {
            $albumName = $_.Name
            $albumPath = Join-Path $AlbumsPath "$albumName.json"
            $lockFile = Join-Path $AlbumsPath "$albumName.lock"
            $success = $false
            $retryCount = 0
            $currentDelay = $retryStrategy.RetryDelay
            
            while (-not $success -and $retryCount -lt $retryStrategy.MaxRetries) {
                $lockStream = $null
                try {
                    $lockStream = [System.IO.File]::Open(
                        $lockFile, 
                        [System.IO.FileMode]::CreateNew,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::None
                    )
                    
                    $currentItems = @()
                    if (Test-Path $albumPath) {
                        $content = Get-Content -Path $albumPath -Raw -ErrorAction Stop
                        if ($content) {
                            $currentItems = @(ConvertFrom-Json -InputObject $content -ErrorAction Stop)
                        }
                    }
                    
                    # Add new items avoiding duplicates
                    $newItems = @($_.Group.Item)
                    $existingPaths = @($currentItems | Select-Object -ExpandProperty fullPath)
                    $uniqueNewItems = $newItems | Where-Object { $existingPaths -notcontains $_.fullPath }
                    
                    if ($uniqueNewItems) {
                        $updatedItems = @($currentItems) + @($uniqueNewItems)
                        $json = ConvertTo-Json -InputObject $updatedItems -Depth 10
                        [System.IO.File]::WriteAllText($albumPath, $json, [System.Text.Encoding]::UTF8)
                    }
                    
                    $success = $true
                }
                catch [System.IO.IOException] {
                    $retryCount++
                    if ($retryCount -lt $retryStrategy.MaxRetries) {
                        Start-Sleep -Milliseconds $currentDelay
                        $currentDelay *= $retryStrategy.BackoffMultiplier
                    }
                }
                catch {
                    Write-Error "Failed to update album $albumName : $_"
                    break
                }
                finally {
                    if ($lockStream) {
                        $lockStream.Dispose()
                        $null = Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            
            if (-not $success) {
                Write-Error "Failed to update album $albumName after $($retryStrategy.MaxRetries) retries"
            }
        }
    }
    catch {
        Write-Error "Failed to process albums: $_"
        throw
    }
}
