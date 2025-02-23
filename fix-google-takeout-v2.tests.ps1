BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot "fix-google-takeout-v2.ps1"
    $script:tempWorkspace = Join-Path $env:TEMP "GoogleTakeoutTests"
    $script:albumName = "Giro"
    $script:exportPath = "e:\export-sample"

    # Create temp workspace
    New-Item -ItemType Directory -Path $script:tempWorkspace -Force | Out-Null

    # Create albums.txt with test album
    Set-Content -Path (Join-Path $PSScriptRoot "albums.txt") -Value $script:albumName -Force
}

AfterAll {
    # Cleanup temp workspace
    if (Test-Path $script:tempWorkspace) {
        Remove-Item -Path $script:tempWorkspace -Recurse -Force
    }
    
    # Clean up test album file
    $albumFile = Join-Path $PSScriptRoot "albums.txt"
    if (Test-Path $albumFile) {
        Remove-Item -Path $albumFile -Force
    }

    # Clean up export path
    if (Test-Path $script:exportPath) {
        Remove-Item -Path $script:exportPath -Recurse -Force
    }
}

Describe "Google Photos Takeout Processing" -Tag "Integration" {
    Context "Basic ZIP extraction" -Tag "Extract" {
        BeforeAll {
            # Get first 2 ZIP files
            $zipFiles = Get-ChildItem -Path $PSScriptRoot -Filter "*.zip" | Select-Object -First 2
            foreach ($zip in $zipFiles) {
                Copy-Item -Path $zip.FullName -Destination $script:tempWorkspace
            }
            
            # Run script with ExtractZip
            $result = & $script:scriptPath -ExtractZip yes -InstallExif no -GenerateAlbums no
        }

        It "Should extract ZIP files successfully" {
            $extractedPath = Join-Path $PSScriptRoot "extracted"
            Test-Path $extractedPath | Should -BeTrue
            (Get-ChildItem -Path $extractedPath -Recurse -File).Count | Should -BeGreaterThan 0
        }
    }

    Context "Album generation with extracted files" -Tag "Albums" {
        BeforeAll {
            # Run script with ExtractZip and GenerateAlbums
            $result = & $script:scriptPath -ExtractZip no -InstallExif no -GenerateAlbums yes
        }

        It "Should create album JSON file" {
            $albumPath = Join-Path $PSScriptRoot "photo-albums" "$($script:albumName).json"
            Test-Path $albumPath | Should -BeTrue
        }

        It "Should populate album with photos" {
            $albumPath = Join-Path $PSScriptRoot "photo-albums" "$($script:albumName).json"
            $albumContent = Get-Content $albumPath | ConvertFrom-Json
            $albumContent.Count | Should -BeGreaterThan 0
        }
    }

    Context "Full processing with ExifTool installation" -Tag "ExifTool" {
        BeforeAll {
            # Run script with all features
            $result = & $script:scriptPath -ExtractZip no -InstallExif yes -GenerateAlbums yes
        }

        It "Should install ExifTool" {
            $exiftoolPath = Join-Path $PSScriptRoot "ExifTool\exiftool.exe"
            Test-Path $exiftoolPath | Should -BeTrue
        }

        It "Should process metadata successfully" {
            $errorPath = Join-Path $PSScriptRoot "logs\metadata.errors.json"
            $errors = Get-Content $errorPath -Raw | ConvertFrom-Json
            $errors.Count | Should -Be 0
        }
    }

    Context "Album export" -Tag "Export" {
        BeforeAll {
            # Run script with ExportAlbum
            $result = & $script:scriptPath -ExportAlbum yes
        }

        It "Should create export directory" {
            Test-Path $script:exportPath | Should -BeTrue
        }

        It "Should export album contents" {
            $albumExportPath = Join-Path $script:exportPath $script:albumName
            Test-Path $albumExportPath | Should -BeTrue
            (Get-ChildItem -Path $albumExportPath -Recurse -File).Count | Should -BeGreaterThan 0
        }
    }
}