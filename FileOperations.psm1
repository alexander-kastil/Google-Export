using namespace System.Collections.Concurrent

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
    
    $zipFiles | ForEach-Object -ThrottleLimit 4 -Parallel {
        try {
            $current = [System.Threading.Interlocked]::Increment([ref]$using:processedZips)
            $status = "[$current/$using:totalZips] Extracting: $($_.Name)"
            $spaces = " " * [Math]::Max(0, [Console]::WindowWidth - $status.Length - 1)
            Write-Host "`r$status$spaces" -NoNewline
            $null = Expand-Archive -Path $_.FullName -DestinationPath $using:ExtractedPath -Force
        }
        catch {
            Write-Host ""  # New line after error
            $(using:extractErrors).Add("Failed to extract $($_.Name): $_")
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

    $scriptRoot = $PSScriptRoot
    $duplicates = [ConcurrentBag[PSCustomObject]]::new()
    $errors = [ConcurrentBag[PSCustomObject]]::new()
    $albumUpdates = [ConcurrentBag[PSCustomObject]]::new()

    try {
        Write-Host "Organizing files into year-based folders..." -ForegroundColor Cyan
        $files = @(Get-ChildItem -Path $SourcePath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4")
        $totalFiles = $files.Count
        $processedFiles = 0
        
        $files | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $current = [System.Threading.Interlocked]::Increment([ref]$using:processedFiles)
            $fileName = [System.IO.Path]::GetFileName($_.FullName)
            $status = "[$current/$using:totalFiles] Sorting: $fileName"
            $spaces = " " * [Math]::Max(0, [Console]::WindowWidth - $status.Length - 1)
            Write-Host "`r$status$spaces" -NoNewline

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

                $destFileName = $_.Name
                $destPath = Join-Path $yearPath $destFileName

                # Handle duplicates
                while (Test-Path $destPath) {
                    $fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                    $extension = [System.IO.Path]::GetExtension($_.Name)
                    $random = Get-Random -Maximum 99999
                    $newFileName = "${fileNameWithoutExt}_duplicate_${random}${extension}"
                    $destPath = Join-Path $yearPath $newFileName
                    
                    if (-not (Test-Path $destPath)) {
                        $(using:duplicates).Add([PSCustomObject]@{
                            Path = $_.FullName
                            Message = "Duplicate file renamed to: $newFileName"
                        })
                        break
                    }
                }

                # Move file
                $null = Move-Item -Path $_.FullName -Destination $destPath -Force

                # Track album if enabled
                if ($using:TrackAlbums) {
                    $folderNameLower = $currentFolder.ToLower()
                    if ($(using:Albums).ContainsKey($folderNameLower)) {
                        $relativePath = $yearPath.Replace($using:scriptRoot, '').TrimStart('\')
                        $fileName = [System.IO.Path]::GetFileName($destPath)
                        
                        $(using:albumUpdates).Add([PSCustomObject]@{
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
            else {
                $(using:errors).Add([PSCustomObject]@{
                    Path = $_.FullName
                    Message = "No date found in EXIF data"
                })
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

    $scriptRoot = $PSScriptRoot
    $duplicates = [ConcurrentBag[PSCustomObject]]::new()
    $errors = [ConcurrentBag[PSCustomObject]]::new()
    $albumUpdates = [ConcurrentBag[PSCustomObject]]::new()

    try {
        Write-Host "Organizing files into pictures and movies folders..." -ForegroundColor Cyan
        
        # Create output folders
        $picturesPath = Join-Path $DestinationRoot "pictures"
        $moviesPath = Join-Path $DestinationRoot "movies"
        $null = New-Item -ItemType Directory -Path $picturesPath -Force
        $null = New-Item -ItemType Directory -Path $moviesPath -Force

        # Process files
        $files = @(Get-ChildItem -Path $SourcePath -Recurse -Include "*.jpg","*.heic","*.png","*.mp4")
        $totalFiles = $files.Count
        $processedFiles = 0
        
        $files | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            try {
                $current = [System.Threading.Interlocked]::Increment([ref]$using:processedFiles)
                $fileName = [System.IO.Path]::GetFileName($_.FullName)
                $status = "[$current/$using:totalFiles] Moving: $fileName"
                $spaces = " " * [Math]::Max(0, [Console]::WindowWidth - $status.Length - 1)
                Write-Host "`r$status$spaces" -NoNewline

                $currentFolder = Split-Path (Split-Path $_.FullName -Parent) -Leaf

                # Determine destination subfolder
                $ext = $_.Extension.ToLower()
                $subFolder = if ($ext -eq '.mp4') { "movies" } else { "pictures" }
                $destFolder = Join-Path $using:DestinationRoot $subFolder

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
                        $(using:duplicates).Add([PSCustomObject]@{
                            Path = $_.FullName
                            Message = "Duplicate file renamed to: $newFileName"
                        })
                        break
                    }
                }

                # Move file
                $null = Move-Item -Path $_.FullName -Destination $destPath -Force

                # Track album if enabled
                if ($using:TrackAlbums) {
                    $folderNameLower = $currentFolder.ToLower()
                    if ($(using:Albums).ContainsKey($folderNameLower)) {
                        $relativePath = $subFolder
                        $fileName = [System.IO.Path]::GetFileName($destPath)
                        
                        $(using:albumUpdates).Add([PSCustomObject]@{
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
                Write-Host ""  # New line after error
                $(using:errors).Add([PSCustomObject]@{
                    Path = $_.FullName
                    Message = "Error moving file: $_"
                })
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