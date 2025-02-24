Describe "Google Takeout Fixer Tests" {
    BeforeAll {
        $script:scriptPath = Join-Path $PSScriptRoot "fix-google-takeout.ps1"
        $script:tempWorkspace = Join-Path $env:TEMP "GoogleTakeoutTests"
        $script:albumName = "Giro"
        $script:exportPath = "e:\export-sample"

        $script:testRoot = $PSScriptRoot
        $script:mainScript = Join-Path $testRoot "fix-google-takeout.ps1"
        $script:testDataPath = Join-Path $testRoot "test_data"
        $script:extractedPath = Join-Path $testRoot "extracted"
        $script:sortedPath = Join-Path $testRoot "sorted"
        $script:outputPath = Join-Path $testRoot "output"
        $script:albumsPath = Join-Path $testRoot "photo-albums"
        $script:logsPath = Join-Path $testRoot "logs"

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

    BeforeEach {
        # Clean up test directories
        @(
            $script:testDataPath,
            $script:extractedPath,
            $script:sortedPath,
            $script:outputPath,
            $script:albumsPath,
            $script:logsPath
        ) | ForEach-Object {
            if (Test-Path $_) {
                Remove-Item -Path $_ -Recurse -Force
            }
            New-Item -ItemType Directory -Path $_ -Force | Out-Null
        }

        # Create test data
        $testJpg = Join-Path $script:testDataPath "test.jpg"
        $testMp4 = Join-Path $script:testDataPath "test.mp4"
        New-Item -ItemType File -Path $testJpg -Force | Out-Null
        New-Item -ItemType File -Path $testMp4 -Force | Out-Null

        # Mock EXIF data for test files
        function global:Mock-ExifTool {
            param($Path, [switch]$Json)
            if ($Json) {
                return @{
                    CreateDate = "2023:01:01 12:00:00"
                    FileType = if ($Path -like "*.mp4") { "MP4" } else { "JPEG" }
                } | ConvertTo-Json
            }
            return "FileType: JPEG"
        }
        Set-Item -Path function:exiftool -Value ${function:Mock-ExifTool}
    }

    AfterEach {
        # Clean up test directories
        @(
            $script:testDataPath,
            $script:extractedPath,
            $script:sortedPath,
            $script:outputPath,
            $script:albumsPath,
            $script:logsPath
        ) | ForEach-Object {
            if (Test-Path $_) {
                Remove-Item -Path $_ -Recurse -Force
            }
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

    Describe "Sorting Functionality Tests" {
        Context "No Sorting" {
            It "Should not move files when sorting is 'no'" {
                # Prepare test
                Copy-Item -Path (Join-Path $script:testDataPath "*.*") -Destination $script:extractedPath

                # Execute
                & $script:mainScript -Sorting no -ExtractZip no

                # Verify files remain in extracted folder
                $extractedFiles = Get-ChildItem -Path $script:extractedPath -File
                $extractedFiles.Count | Should -Be 2
                Test-Path (Join-Path $script:extractedPath "test.jpg") | Should -Be $true
                Test-Path (Join-Path $script:extractedPath "test.mp4") | Should -Be $true
            }
        }

        Context "Year-based Sorting" {
            It "Should sort files by year when sorting is 'years'" {
                # Prepare test
                Copy-Item -Path (Join-Path $script:testDataPath "*.*") -Destination $script:extractedPath

                # Execute
                & $script:mainScript -Sorting years -ExtractZip no

                # Verify files are in year folders
                $yearPath = Join-Path $script:sortedPath "2023"
                Test-Path (Join-Path $yearPath "test.jpg") | Should -Be $true
                Test-Path (Join-Path $yearPath "test.mp4") | Should -Be $true
            }
        }

        Context "One Folder Sorting" {
            It "Should sort files by type when sorting is 'onefolder'" {
                # Prepare test
                Copy-Item -Path (Join-Path $script:testDataPath "*.*") -Destination $script:extractedPath

                # Execute
                & $script:mainScript -Sorting onefolder -ExtractZip no

                # Verify files are in correct type folders
                Test-Path (Join-Path $script:outputPath "pictures\test.jpg") | Should -Be $true
                Test-Path (Join-Path $script:outputPath "movies\test.mp4") | Should -Be $true
            }
        }
    }

    Describe "Album Generation Tests" {
        Context "Album Generation with Different Sorting Modes" {
            BeforeEach {
                # Create test albums.txt
                $albumsFile = Join-Path $testRoot "albums.txt"
                "test-album" | Set-Content -Path $albumsFile -Force

                # Create test folder structure
                New-Item -ItemType Directory -Path (Join-Path $script:extractedPath "test-album") -Force | Out-Null
                Copy-Item -Path (Join-Path $script:testDataPath "*.*") -Destination (Join-Path $script:extractedPath "test-album")
            }

            AfterEach {
                if (Test-Path (Join-Path $testRoot "albums.txt")) {
                    Remove-Item -Path (Join-Path $testRoot "albums.txt") -Force
                }
            }

            It "Should generate albums with no sorting" {
                # Execute
                & $script:mainScript -Sorting no -GenerateAlbums yes -ExtractZip no

                # Verify album JSON
                $albumJson = Get-Content -Path (Join-Path $script:albumsPath "test-album.json") -Raw | ConvertFrom-Json
                $albumJson.Count | Should -Be 2
                $albumJson.fullPath -contains "test.jpg" | Should -Be $true
                $albumJson.fullPath -contains "test.mp4" | Should -Be $true
            }

            It "Should generate albums with year sorting" {
                # Execute
                & $script:mainScript -Sorting years -GenerateAlbums yes -ExtractZip no

                # Verify album JSON
                $albumJson = Get-Content -Path (Join-Path $script:albumsPath "test-album.json") -Raw | ConvertFrom-Json
                $albumJson.Count | Should -Be 2
                $albumJson.fullPath -contains "2023/test.jpg" | Should -Be $true
                $albumJson.fullPath -contains "2023/test.mp4" | Should -Be $true
            }

            It "Should generate albums with onefolder sorting" {
                # Execute
                & $script:mainScript -Sorting onefolder -GenerateAlbums yes -ExtractZip no

                # Verify album JSON
                $albumJson = Get-Content -Path (Join-Path $script:albumsPath "test-album.json") -Raw | ConvertFrom-Json
                $albumJson.Count | Should -Be 2
                $albumJson.fullPath -contains "pictures/test.jpg" | Should -Be $true
                $albumJson.fullPath -contains "movies/test.mp4" | Should -Be $true
            }
        }
    }
}