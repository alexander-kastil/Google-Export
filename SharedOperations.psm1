function New-MediaFolders {
    param (
        [Parameter(Mandatory)]
        [string]$BasePath
    )
    
    $picturesPath = Join-Path $BasePath "pictures"
    $moviesPath = Join-Path $BasePath "movies"
    $null = New-Item -ItemType Directory -Path $picturesPath -Force
    $null = New-Item -ItemType Directory -Path $moviesPath -Force
    
    return @{
        PicturesPath = $picturesPath
        MoviesPath = $moviesPath
    }
}

function Get-MediaType {
    param (
        [Parameter(Mandatory)]
        [string]$Extension
    )
    
    return if ($Extension.ToLower() -eq '.mp4') { "movies" } else { "pictures" }
}

function Write-ProgressStatus {
    param (
        [Parameter(Mandatory)]
        [int]$Current,
        [Parameter(Mandatory)]
        [int]$Total,
        [Parameter(Mandatory)]
        [string]$Operation,
        [Parameter(Mandatory)]
        [string]$ItemName
    )
    
    $status = "[$Current/$Total] $Operation`: $ItemName"
    $spaces = " " * [Math]::Max(0, [Console]::WindowWidth - $status.Length - 1)
    Write-Host "`r$status$spaces" -NoNewline
}

Export-ModuleMember -Function New-MediaFolders, Get-MediaType, Write-ProgressStatus