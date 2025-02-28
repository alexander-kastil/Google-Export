using namespace System.Collections.Concurrent
Import-Module $PSScriptRoot\SharedOperations.psm1

function Expand-ZipFiles {
    param (
        [Parameter(Mandatory)]
        [string]$ExtractedPath
    )
    
    $extractErrors = [ConcurrentBag[string]]::new()
    Write-Host "Starting ZIP extraction..." -ForegroundColor Cyan
    
    $zipFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter "*.zip")
    $totalZips = $zipFiles.Count
    $processedZips = 0
    
    $errorBag = $extractErrors  # Create a reference that can be used with $using:
    $scriptRoot = $PSScriptRoot  # Store script root for parallel scope

    $zipFiles | ForEach-Object -ThrottleLimit 4 -Parallel {
        try {
            # Import required module in parallel scope
            Import-Module "$using:scriptRoot\SharedOperations.psm1"

            $current = [System.Threading.Interlocked]::Increment([ref]$using:processedZips)
            Write-ProgressStatus -Current $current -Total $using:totalZips -Operation "Extracting" -ItemName $_.Name
            $null = Expand-Archive -Path $_.FullName -DestinationPath $using:ExtractedPath -Force
        }
        catch {
            Write-Host ""  # New line after error
            $errorMessage = "Failed to extract $($_.Name): $_"
            ($using:errorBag).Add($errorMessage)
        }
    }
    Write-Host "`nZIP extraction completed" -ForegroundColor Green
    
    if ($extractErrors.Count -gt 0) {
        Write-Warning "Some archives failed to extract:"
        $extractErrors | ForEach-Object { Write-Warning $_ }
    }
    Write-Host "ZIP extraction completed" -ForegroundColor Green
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

    $duplicates = [ConcurrentBag[PSCustomObject]]::new()
    $errors = [ConcurrentBag[PSCustomObject]]::new()
    $albumUpdates = [ConcurrentBag[PSCustomObject]]::new()
    
    # Create thread-safe counter
    $processedFiles = [ref]0

    try {
        Write-Host "Organizing files into year-based folders..." -ForegroundColor Cyan
        $files = @(Get-ChildItem -Path $SourcePath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4")
        $totalFiles = $files.Count
        
        # Create references for parallel scope
        $dupBag = $duplicates
        $errorBag = $errors
        $albumBag = $albumUpdates
        $counter = $processedFiles
        $scriptRoot = $PSScriptRoot

        $files | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            try {
                Import-Module -Name "$using:scriptRoot\SharedOperations.psm1" -Force
                
                $current = [System.Threading.Interlocked]::Increment($using:counter)
                $fileName = [System.IO.Path]::GetFileName($_.FullName)
                Write-ProgressStatus -Current $current -Total $using:totalFiles -Operation "Sorting" -ItemName $fileName

                $currentFolder = Split-Path (Split-Path $_.FullName -Parent) -Leaf
                $exifData = exiftool -json $_.FullName | ConvertFrom-Json
                
                if ($exifData.CreateDate) {
                    $dateTime = [DateTime]::ParseExact(
                        $exifData.CreateDate,
                        "yyyy:MM:dd HH:mm:ss",
                        [System.Globalization.CultureInfo]::InvariantCulture
                    )
                    $yearValue = $dateTime.Year.ToString()
                    $yearPath = Join-Path $using:DestinationRoot $yearValue
                    $null = New-Item -ItemType Directory -Path $yearPath -Force
                    
                    # Create media folders and determine destination
                    $mediaFolders = New-MediaFolders -BasePath $yearPath
                    $subFolder = Get-MediaType -Extension $_.Extension
                    $yearSubPath = if ($subFolder -eq "movies") { $mediaFolders.MoviesPath } else { $mediaFolders.PicturesPath }

                    $destFileName = $_.Name
                    $destPath = Join-Path $yearSubPath $destFileName

                    # Handle duplicates
                    if (Test-Path $destPath) {
                        $fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                        $extension = [System.IO.Path]::GetExtension($_.Name)
                        $random = Get-Random -Maximum 99999
                        $newFileName = "${fileNameWithoutExt}_duplicate_${random}${extension}"
                        $destPath = Join-Path $yearSubPath $newFileName
                        
                        $duplicateInfo = [PSCustomObject]@{
                            Path = $_.FullName
                            Message = "Duplicate file renamed to: $newFileName"
                        }
                        ($using:dupBag).Add($duplicateInfo)
                    }

                    # Move file
                    $null = Move-Item -Path $_.FullName -Destination $destPath -Force

                    # Track album if enabled
                    if ($using:TrackAlbums) {
                        $folderNameLower = $currentFolder.ToLower()
                        if (($using:Albums).ContainsKey($folderNameLower)) {
                            $relativePath = $yearSubPath.Replace($using:DestinationRoot, '').TrimStart('\')
                            $fileName = [System.IO.Path]::GetFileName($destPath)
                            
                            $albumInfo = [PSCustomObject]@{
                                Album = $folderNameLower
                                Item = [PSCustomObject]@{
                                    name = $fileName
                                    relativePath = $relativePath
                                    fullPath = Join-Path $relativePath $fileName
                                }
                            }
                            ($using:albumBag).Add($albumInfo)
                        }
                    }
                }
                else {
                    $errorInfo = [PSCustomObject]@{
                        Path = $_.FullName
                        Message = "No date found in EXIF data"
                    }
                    ($using:errorBag).Add($errorInfo)
                }
            }
            catch {
                $errorInfo = [PSCustomObject]@{
                    Path = $_.FullName
                    Message = "Error moving file: $_"
                }
                ($using:errorBag).Add($errorInfo)
            }
        }
        Write-Host "`nFile sorting completed" -ForegroundColor Green

        # Return results
        return @{
            Errors = $errors.ToArray()
            Duplicates = $duplicates.ToArray()
            AlbumUpdates = $albumUpdates.ToArray()
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

    $duplicates = [ConcurrentBag[PSCustomObject]]::new()
    $errors = [ConcurrentBag[PSCustomObject]]::new()
    $albumUpdates = [ConcurrentBag[PSCustomObject]]::new()
    
    # Create thread-safe counter
    $processedFiles = [ref]0

    try {
        Write-Host "Organizing files into pictures and movies folders..." -ForegroundColor Cyan
        
        # Create output folders
        $mediaFolders = New-MediaFolders -BasePath $DestinationRoot

        # Process files
        $files = @(Get-ChildItem -Path $SourcePath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4")
        $totalFiles = $files.Count
        
        # Create references for parallel scope
        $dupBag = $duplicates
        $errorBag = $errors
        $albumBag = $albumUpdates
        $counter = $processedFiles
        $scriptRoot = $PSScriptRoot

        $files | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            try {
                Import-Module -Name "$using:scriptRoot\SharedOperations.psm1" -Force
                
                $current = [System.Threading.Interlocked]::Increment($using:counter)
                $fileName = [System.IO.Path]::GetFileName($_.FullName)
                Write-ProgressStatus -Current $current -Total $using:totalFiles -Operation "Moving" -ItemName $fileName

                $currentFolder = Split-Path (Split-Path $_.FullName -Parent) -Leaf

                # Determine destination subfolder
                $subFolder = Get-MediaType -Extension $_.Extension
                $destFolder = Join-Path $using:DestinationRoot $subFolder

                $destFileName = $_.Name
                $destPath = Join-Path $destFolder $destFileName

                # Handle duplicates
                if (Test-Path $destPath) {
                    $fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                    $extension = [System.IO.Path]::GetExtension($_.Name)
                    $random = Get-Random -Maximum 99999
                    $newFileName = "${fileNameWithoutExt}_duplicate_${random}${extension}"
                    $destPath = Join-Path $destFolder $newFileName
                    
                    $duplicateInfo = [PSCustomObject]@{
                        Path = $_.FullName
                        Message = "Duplicate file renamed to: $newFileName"
                    }
                    ($using:dupBag).Add($duplicateInfo)
                }

                # Move file
                $null = Move-Item -Path $_.FullName -Destination $destPath -Force

                # Track album if enabled
                if ($using:TrackAlbums) {
                    $folderNameLower = $currentFolder.ToLower()
                    if (($using:Albums).ContainsKey($folderNameLower)) {
                        $relativePath = $subFolder
                        $fileName = [System.IO.Path]::GetFileName($destPath)
                        
                        $albumInfo = [PSCustomObject]@{
                            Album = $folderNameLower
                            Item = [PSCustomObject]@{
                                name = $fileName
                                relativePath = $relativePath
                                fullPath = Join-Path $relativePath $fileName
                            }
                        }
                        ($using:albumBag).Add($albumInfo)
                    }
                }
            }
            catch {
                $errorInfo = [PSCustomObject]@{
                    Path = $_.FullName
                    Message = "Error moving file: $_"
                }
                ($using:errorBag).Add($errorInfo)
            }
        }
        Write-Host "`nFile organization completed" -ForegroundColor Green

        # Return results
        return @{
            Errors = $errors.ToArray()
            Duplicates = $duplicates.ToArray()
            AlbumUpdates = $albumUpdates.ToArray()
        }
    }
    catch {
        Write-Error "Failed to process files: $_"
        throw
    }
}

Export-ModuleMember -Function Expand-ZipFiles, Move-ToYearFolders, Move-ToOneFolder