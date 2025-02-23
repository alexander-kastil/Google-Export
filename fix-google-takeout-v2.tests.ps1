BeforeAll {
    $script:testRoot = 'e:\Google-Export'
    $script:exportRoot = 'e:\export-sample'
    $script:scriptPath = Join-Path $testRoot 'fix-google-takeout-v2.ps1'
    $script:testZips = @(
        'takeout-20250222T072038Z-001.zip',
        'takeout-20250222T072038Z-002.zip'
    )

    # Cleanup function for each test
    function Reset-TestEnvironment {
        $foldersToRemove = @(
            (Join-Path $testRoot 'extracted'),
            (Join-Path $testRoot 'sorted'),
            (Join-Path $testRoot 'logs'),
            (Join-Path $testRoot 'photo-albums'),
            (Join-Path $testRoot 'ExifTool'),
            $script:exportRoot
        )
        
        foreach ($folder in $foldersToRemove) {
            if (Test-Path $folder) {
                Remove-Item $folder -Recurse -Force
            }
        }
    }

    # Create test albums.txt file
    $albumsTxtPath = Join-Path $testRoot 'albums.txt'
    'giro' | Set-Content -Path $albumsTxtPath -Force
}

AfterAll {
    Reset-TestEnvironment
}

Describe "Google Photos Takeout Processing" {
    BeforeEach {
        Reset-TestEnvironment
    }

    It "Should extract ZIP files" {
        $result = & $scriptPath -ExtractZip yes

        # Check if the script executed successfully
        $LASTEXITCODE | Should -Be 0

        # Verify that extracted folder exists and contains content
        Test-Path (Join-Path $testRoot 'extracted') | Should -Be $true
        $extractedFiles = Get-ChildItem (Join-Path $testRoot 'extracted') -Recurse
        $extractedFiles.Count | Should -BeGreaterThan 0
    }

    It "Should extract ZIP files and generate albums" {
        $result = & $scriptPath -ExtractZip yes -GenerateAlbums yes

        # Check if the script executed successfully
        $LASTEXITCODE | Should -Be 0

        # Verify that extracted and photo-albums folders exist
        Test-Path (Join-Path $testRoot 'extracted') | Should -Be $true
        Test-Path (Join-Path $testRoot 'photo-albums') | Should -Be $true

        # Verify that the Giro album JSON file was created
        $giroJsonPath = Join-Path $testRoot 'photo-albums' 'giro.json'
        Test-Path $giroJsonPath | Should -Be $true
    }

    It "Should extract ZIP files, generate albums and install ExifTool" {
        $result = & $scriptPath -ExtractZip yes -GenerateAlbums yes -InstallExif yes

        # Check if the script executed successfully
        $LASTEXITCODE | Should -Be 0

        # Verify that ExifTool was installed
        Test-Path (Join-Path $testRoot 'ExifTool') | Should -Be $true
        Test-Path (Join-Path $testRoot 'ExifTool' 'exiftool.exe') | Should -Be $true

        # Verify other folders exist
        Test-Path (Join-Path $testRoot 'extracted') | Should -Be $true
        Test-Path (Join-Path $testRoot 'photo-albums') | Should -Be $true
        Test-Path (Join-Path $testRoot 'sorted') | Should -Be $true
    }

    It "Should export albums to specified folder" {
        # First run the full process
        $result = & $scriptPath -ExtractZip yes -GenerateAlbums yes -InstallExif yes
        $LASTEXITCODE | Should -Be 0

        # Then export the albums
        $result = & $scriptPath -ExportAlbum yes
        $LASTEXITCODE | Should -Be 0

        # Verify export folder exists and contains content
        Test-Path (Join-Path $testRoot 'exported-albums') | Should -Be $true
        Test-Path (Join-Path $testRoot 'exported-albums' 'giro') | Should -Be $true
        
        $exportedFiles = Get-ChildItem (Join-Path $testRoot 'exported-albums' 'giro') -Recurse
        $exportedFiles.Count | Should -BeGreaterThan 0
    }
}