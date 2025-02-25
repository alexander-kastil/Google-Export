using namespace System.Collections.Concurrent
Import-Module $PSScriptRoot\SharedOperations.psm1

function Import-Albums {
    param (
        [Parameter(Mandatory)]
        [string]$AlbumsPath
    )

    $albums = @{}
    $albumsFile = Join-Path $PSScriptRoot "albums.txt"
    
    if (-not (Test-Path $albumsFile)) {
        Write-Error "albums.txt not found. This file is required when using -GenerateAlbums yes. Please create albums.txt with one album name per line."
        return $null
    }

    if ((Get-Content $albumsFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Measure-Object).Count -eq 0) {
        Write-Error "albums.txt is empty. Please add at least one album name when using -GenerateAlbums yes."
        return $null
    }

    # Read and process album names
    Get-Content $albumsFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $albumName = $_.Trim().ToLower()
        $albums[$albumName] = @{
            name = $albumName
            items = [ConcurrentBag[PSCustomObject]]::new()
        }
        
        # Create album folder and initialize metadata file
        $albumFolderPath = Join-Path $AlbumsPath $albumName
        $albumMetadataPath = Join-Path $albumFolderPath "album.json"
        $null = New-Item -ItemType Directory -Path $albumFolderPath -Force
        "[]" | Set-Content -Path $albumMetadataPath -Encoding UTF8
        Write-Information "Initialized album: $albumName"
    }

    return $albums
}

function Update-AlbumFiles {
    param (
        [Parameter(Mandatory)]
        [array]$AlbumUpdates,
        [Parameter(Mandatory)]
        [string]$AlbumsPath
    )

    $retryStrategy = @{
        MaxRetries = 5
        RetryDelay = 100
        BackoffMultiplier = 2
    }

    $AlbumUpdates | Group-Object -Property Album | ForEach-Object {
        $albumName = $_.Name
        $albumFolderPath = Join-Path $AlbumsPath $albumName
        $albumMetadataPath = Join-Path $albumFolderPath "album.json"
        $lockFile = Join-Path $albumFolderPath "album.lock"
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
                if (Test-Path $albumMetadataPath) {
                    $content = Get-Content -Path $albumMetadataPath -Raw -ErrorAction Stop
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
                    [System.IO.File]::WriteAllText($albumMetadataPath, $json, [System.Text.Encoding]::UTF8)
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

function Export-Album {
    param (
        [Parameter(Mandatory)]
        [string]$AlbumsPath,
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    # Create export directory
    $null = New-Item -ItemType Directory -Path $ExportPath -Force

    # Get list of all albums to process
    $albumsToProcess = Get-ChildItem -Path $AlbumsPath -Directory | ForEach-Object { 
        $_.Name 
    }
    
    if ($albumsToProcess.Count -eq 0) {
        Write-Error "No albums found in '$AlbumsPath'"
        return $false
    }

    # Process each album
    foreach ($album in $albumsToProcess) {
        Write-Information "Processing album: $album"
        
        $albumFolderPath = Join-Path $AlbumsPath $album
        $albumMetadataPath = Join-Path $albumFolderPath "album.json"
        $albumContent = Get-Content -Path $albumMetadataPath -Raw | ConvertFrom-Json
        
        if ($albumContent.Count -eq 0) {
            Write-Warning "Album '$album' is empty, skipping..."
            continue
        }

        $albumExportPath = Join-Path $ExportPath $album
        $null = New-Item -ItemType Directory -Path $albumExportPath -Force
        
        # Create media folders
        $mediaFolders = New-MediaFolders -BasePath $albumExportPath

        $albumContent | ForEach-Object {
            $sourcePath = Join-Path $PSScriptRoot $_.fullPath
            if (Test-Path $sourcePath) {
                $subFolder = Get-MediaType -Extension ([System.IO.Path]::GetExtension($_.name))
                $destFolder = if ($subFolder -eq "movies") { $mediaFolders.MoviesPath } else { $mediaFolders.PicturesPath }
                $destPath = Join-Path $destFolder $_.name
                Copy-Item -Path $sourcePath -Destination $destPath -Force
                Write-Information "Exported: $($_.name)"
            } else {
                Write-Warning "File not found: $($_.fullPath)"
            }
        }
    }

    return $true
}

Export-ModuleMember -Function Import-Albums, Update-AlbumFiles, Export-Album