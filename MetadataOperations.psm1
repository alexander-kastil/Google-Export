function Install-ExifTool {
    param (
        [string]$ExifToolUrl = "https://exiftool.org/exiftool-12.70.zip",
        [string]$InstallPath = (Join-Path $PSScriptRoot "ExifTool")
    )

    Write-Information "Installing ExifTool..."
    $downloadPath = Join-Path $PSScriptRoot "exiftool.zip"

    try {
        # Download ExifTool using newer HTTP client
        $webClient = [System.Net.Http.HttpClient]::new()
        $response = $webClient.GetByteArrayAsync($ExifToolUrl).GetAwaiter().GetResult()
        [System.IO.File]::WriteAllBytes($downloadPath, $response)
        Write-Information "ExifTool downloaded successfully"

        # Create ExifTool directory and extract
        $null = New-Item -ItemType Directory -Path $InstallPath -Force
        Expand-Archive -Path $downloadPath -DestinationPath $InstallPath -Force
        Write-Information "ExifTool archive extracted"

        # Rename the executable
        $oldExePath = Join-Path $InstallPath "exiftool(-k).exe"
        if (Test-Path $oldExePath) {
            $null = Rename-Item -Path $oldExePath -NewName "exiftool.exe" -Force
        }

        # Clean up zip file
        $null = Remove-Item $downloadPath -Force

        # Add to temporary path for current session
        $env:Path = "$InstallPath;$env:Path"
        Write-Information "ExifTool installed successfully"
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
        [Parameter(Mandatory)]
        [string]$FilePath
    )

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
            exiftool -json "$path" | ConvertFrom-Json -AsHashTable
        } -ArgumentList $FilePath

        Write-Host "Reading metadata: $([System.IO.Path]::GetFileName($FilePath))" -ForegroundColor DarkGray

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
                    
                    # If target file already exists, try incremental naming
                    if (Test-Path $newPath) {
                        $fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
                        $directory = [System.IO.Path]::GetDirectoryName($FilePath)
                        $counter = 1
                        
                        do {
                            $newFileName = "${fileNameWithoutExt}_${counter}${correctExtension}"
                            $newPath = Join-Path $directory $newFileName
                            $counter++
                        } while (Test-Path $newPath)
                    }
                    
                    Write-Host "Correcting extension: $([System.IO.Path]::GetFileName($FilePath)) -> $([System.IO.Path]::GetFileName($newPath))"
                    Move-Item -Path $FilePath -Destination $newPath -Force
                    $FilePath = $newPath
                }
            }
        }

        # Process dates
        $takenTime = $null
        $metadataFile = "$FilePath.supplemental-metadata.json"

        if (Test-Path $metadataFile) {
            Write-Host "Reading metadata from supplemental JSON..." -ForegroundColor DarkGray
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
                    Write-Warning "Failed to parse metadata date: $formatted"
                }
            }
        }

        if ($null -eq $takenTime) {
            Write-Host "Reading EXIF dates..." -ForegroundColor DarkGray
            # Try to parse EXIF dates, handling timezone offsets
            $dateFormats = @(
                "yyyy:MM:dd HH:mm:ss",
                "yyyy:MM:dd HH:mm:ssK", # Format with timezone offset
                "yyyy:MM:dd HH:mm:ss.fff",
                "yyyy:MM:dd HH:mm:ss.fffK" # Format with timezone offset and milliseconds
            )

            # Convert hashtable keys to lowercase for case-insensitive lookup
            $exifDataLower = @{}
            foreach ($key in $exifData.Keys) {
                $exifDataLower[$key.ToLower()] = $exifData[$key]
            }

            foreach ($dateField in @('datetimeoriginal', 'createdate', 'filemodifydate')) {
                if ($exifDataLower.ContainsKey($dateField)) {
                    $dateStr = $exifDataLower[$dateField]
                    
                    # Remove any timezone name (like UTC) keeping only offset if present
                    $dateStr = $dateStr -replace '\s+UTC$', ''
                    
                    foreach ($format in $dateFormats) {
                        try {
                            $takenTime = [DateTime]::ParseExact(
                                $dateStr,
                                $format,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor
                                [System.Globalization.DateTimeStyles]::AssumeLocal
                            )
                            break
                        }
                        catch {
                            # Continue to next format
                            continue
                        }
                    }
                    
                    if ($null -ne $takenTime) {
                        break
                    }
                }
            }
        }

        if ($null -eq $takenTime) {
            Write-Warning "No date found in metadata or EXIF for: $FilePath"
            return $false
        }

        # Use exiftool to set creation and modification dates
        $dateStr = $takenTime.ToString("yyyy:MM:dd HH:mm:ss")
        Write-Information "Setting date to: $dateStr"
        $result = exiftool "-AllDates=$dateStr" "-overwrite_original" "$FilePath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "ExifTool failed: $result"
        }
        
        Write-Information "✓ Processed: $([System.IO.Path]::GetFileName($FilePath))"
        Write-Host "✓ Successfully updated metadata" -ForegroundColor DarkGreen
        return $true
    }
    catch {
        Write-Error "Error processing file $FilePath : $_"
        return $false
    }
    finally {
        if ($fileTypeTask) { Remove-Job -Job $fileTypeTask -Force -ErrorAction SilentlyContinue }
        if ($exifDataTask) { Remove-Job -Job $exifDataTask -Force -ErrorAction SilentlyContinue }
        $ErrorActionPreference = 'Continue'
    }
}

Export-ModuleMember -Function Install-ExifTool, Update-FileMetadata