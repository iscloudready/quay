# QuayImageManager.ps1 - Comprehensive script for managing Quay container images
# Usage examples:
#   View repository info:     .\QuayImageManager.ps1 -Server "http://localhost:9090" -Token "your_token" -Namespace "your_namespace" -RepositoryName "your_repo"
#   List all repos and tags:  .\QuayImageManager.ps1 -Server "http://localhost:9090" -Token "your_token" -Namespace "your_namespace" -ListAllRepos
#   Export tags to CSV:       .\QuayImageManager.ps1 -Server "http://localhost:9090" -Token "your_token" -Namespace "your_namespace" -ListAllRepos -ExportToCSV
#   Clean up old tags:        .\QuayImageManager.ps1 -Server "http://localhost:9090" -Token "your_token" -Namespace "your_namespace" -RepositoryName "your_repo" -CleanupOldTags -OlderThanDays 60

param (
    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$true)]
    [string]$Token,

    [Parameter(Mandatory=$true)]
    [string]$Namespace,

    [Parameter(Mandatory=$false)]
    [string]$RepositoryName,

    [Parameter(Mandatory=$false)]
    [int]$OlderThanDays = 90,

    [Parameter(Mandatory=$false)]
    [switch]$CleanupOldTags,

    [Parameter(Mandatory=$false)]
    [switch]$ListAllRepos,

    [Parameter(Mandatory=$false)]
    [switch]$ExportToCSV,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\QuayReposTags.csv",

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

# Test connection to Quay
function Test-QuayConnection {
    param (
        [string]$Server,
        [string]$Token
    )

    try {
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }

        $response = Invoke-RestMethod -Uri "$Server/api/v1/discovery" -Headers $headers -Method GET
        Write-Host "Successfully connected to Quay at $Server" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to connect to Quay: $_" -ForegroundColor Red
        return $false
    }
}

# Get a specific repository
function Get-QuayRepository {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }

    try {
        $url = "$Server/api/v1/repository/$Namespace/$RepositoryName"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method GET
        return $response
    }
    catch {
        Write-Host "Failed to get repository: $_" -ForegroundColor Red
        return $null
    }
}

# Get all repositories in a namespace
function Get-QuayRepositories {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }

    # First try with public=true parameter (which worked earlier)
    try {
        $url = "$Server/api/v1/repository?namespace=$Namespace&public=true"
        Write-Host "Trying to get repositories with public=true parameter..." -ForegroundColor Gray
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method GET

        $publicRepos = @()
        if ($response.repositories) {
            $publicRepos = $response.repositories
            Write-Host "Found $($publicRepos.Count) public repositories" -ForegroundColor Green
        }

        # Also try with public=false to get private repos
        $url = "$Server/api/v1/repository?namespace=$Namespace&public=false"
        Write-Host "Trying to get repositories with public=false parameter..." -ForegroundColor Gray
        $privateResponse = Invoke-RestMethod -Uri $url -Headers $headers -Method GET

        $privateRepos = @()
        if ($privateResponse.repositories) {
            $privateRepos = $privateResponse.repositories
            Write-Host "Found $($privateRepos.Count) private repositories" -ForegroundColor Green
        }

        # Combine the results
        $allRepos = $publicRepos + $privateRepos

        if ($allRepos.Count -eq 0) {
            Write-Host "No repositories found in namespace: $Namespace" -ForegroundColor Yellow
        }
        else {
            Write-Host "Found a total of $($allRepos.Count) repositories in namespace: $Namespace" -ForegroundColor Cyan
        }

        return $allRepos
    }
    catch {
        Write-Host "Failed to get repositories: $_" -ForegroundColor Red
        return @()
    }
}

# Get tags for a repository
function Get-QuayTags {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }

    try {
        $url = "$Server/api/v1/repository/$Namespace/$RepositoryName/tag/"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method GET

        $tagsWithMetadata = @()

        foreach ($tag in $response.tags) {
            # Add additional metadata
            $modifiedDate = [DateTime]::Parse($tag.last_modified)
            $ageInDays = ([DateTime]::Now - $modifiedDate).TotalDays

            $tagInfo = [PSCustomObject]@{
                Repository = "$Namespace/$RepositoryName"
                TagName = $tag.name
                LastModified = $modifiedDate
                AgeInDays = [math]::Round($ageInDays, 1)
                Size = if ($tag.size) { [math]::Round($tag.size / 1MB, 2).ToString() + " MB" } else { "N/A" }
                ManifestDigest = $tag.manifest_digest
            }

            $tagsWithMetadata += $tagInfo
        }

        return $tagsWithMetadata
    }
    catch {
        Write-Host "Failed to get tags for repository $Namespace/$RepositoryName : $_" -ForegroundColor Red
        return @()
    }
}

# Filter tags by age
function Get-OldTags {
    param (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [Array]$Tags,

        [int]$OlderThanDays = 90,

        [string[]]$ExcludeTags = @("latest", "prod", "stable")
    )

    process {
        $oldTags = @()
        foreach ($tag in $Tags) {
            # Skip excluded tags
            if ($ExcludeTags -contains $tag.TagName) {
                Write-Verbose "Excluding protected tag: $($tag.TagName)"
                continue
            }

            # Check age
            if ($tag.AgeInDays -gt $OlderThanDays) {
                $oldTags += $tag
            }
        }
        return $oldTags
    }
}

# Delete a specific tag
function Remove-QuayTag {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName,
        [string]$TagName,
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Host "[WhatIf] Would delete tag $TagName from $Namespace/$RepositoryName" -ForegroundColor Yellow
        return $true
    }

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
        "X-Requested-With" = "XMLHttpRequest"
    }

    try {
        $url = "$Server/api/v1/repository/$Namespace/$RepositoryName/tag/$TagName"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method DELETE
        Write-Host "Deleted tag $TagName from $Namespace/$RepositoryName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to delete tag $TagName : $_" -ForegroundColor Red
        return $false
    }
}

# Clean up old tags with age-based policy
function Clear-OldTags {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName,
        [int]$OlderThanDays = 90,
        [string[]]$ExcludeTags = @("latest", "prod", "stable"),
        [switch]$WhatIf
    )

    Write-Host "Cleaning up tags older than $OlderThanDays days in $Namespace/$RepositoryName" -ForegroundColor Cyan

    # Get all tags
    $allTags = Get-QuayTags -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName

    if (-not $allTags -or $allTags.Count -eq 0) {
        Write-Host "No tags found" -ForegroundColor Yellow
        return
    }

    Write-Host "Found $($allTags.Count) total tags" -ForegroundColor White

    # Find old tags
    $oldTags = Get-OldTags -Tags $allTags -OlderThanDays $OlderThanDays -ExcludeTags $ExcludeTags

    if (-not $oldTags -or $oldTags.Count -eq 0) {
        Write-Host "No tags older than $OlderThanDays days found" -ForegroundColor Green
        return
    }

    Write-Host "Found $($oldTags.Count) tags older than $OlderThanDays days" -ForegroundColor Yellow

    # Sort tags by age (oldest first)
    $sortedTags = $oldTags | Sort-Object -Property LastModified

    # Delete old tags
    foreach ($tag in $sortedTags) {
        $formattedDate = $tag.LastModified.ToString("yyyy-MM-dd")
        Write-Host "- $($tag.TagName) (Created: $formattedDate, Age: $($tag.AgeInDays) days)" -ForegroundColor Gray

        Remove-QuayTag -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName -TagName $tag.TagName -WhatIf:$WhatIf
    }

    Write-Host "Cleanup complete" -ForegroundColor Cyan
}

# Get all repositories and their tags
function Get-AllQuayReposTags {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace
    )

    # Get all repositories
    $repos = Get-QuayRepositories -Server $Server -Token $Token -Namespace $Namespace

    if ($repos.Count -eq 0) {
        Write-Host "No repositories found. Cannot proceed with getting tags." -ForegroundColor Yellow
        return @()
    }

    $allTags = @()

    # Get tags for each repository
    foreach ($repo in $repos) {
        $repoName = $repo.name
        Write-Host "Getting tags for repository: $Namespace/$repoName" -ForegroundColor Cyan

        $tags = Get-QuayTags -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $repoName

        if ($tags.Count -eq 0) {
            Write-Host "  No tags found for this repository" -ForegroundColor Yellow
        }
        else {
            Write-Host "  Found $($tags.Count) tags" -ForegroundColor Green
            $allTags += $tags
        }
    }

    Write-Host "`nTotal tags across all repositories: $($allTags.Count)" -ForegroundColor Cyan

    return $allTags
}

# Export data to CSV
function Export-DataToCSV {
    param (
        [Array]$Data,
        [string]$FilePath
    )

    try {
        $Data | Export-Csv -Path $FilePath -NoTypeInformation
        Write-Host "Successfully exported data to: $FilePath" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to export data to CSV: $_" -ForegroundColor Red
        return $false
    }
}

# Get repository information and tags
function Show-RepositoryInfo {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName
    )

    $repo = Get-QuayRepository -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName

    if (-not $repo) {
        Write-Host "Repository $Namespace/$RepositoryName not found" -ForegroundColor Red
        return
    }

    Write-Host "Repository Information:" -ForegroundColor Cyan
    Write-Host "- Name: $($repo.name)" -ForegroundColor White
    Write-Host "- Namespace: $($repo.namespace)" -ForegroundColor White
    Write-Host "- Description: $($repo.description)" -ForegroundColor White
    Write-Host "- Visibility: $(if ($repo.is_public) {'Public'} else {'Private'})" -ForegroundColor White
    Write-Host "- Kind: $($repo.kind)" -ForegroundColor White

    $tags = Get-QuayTags -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName

    if (-not $tags -or $tags.Count -eq 0) {
        Write-Host "`nNo tags found" -ForegroundColor Yellow
        return
    }

    # Sort tags by age
    $sortedTags = $tags | Sort-Object -Property AgeInDays -Descending

    Write-Host "`nTags ($($tags.Count) total):" -ForegroundColor Cyan
    Write-Host "Tag Name".PadRight(30) + "Created Date".PadRight(20) + "Age (days)".PadRight(15) + "Size" -ForegroundColor Yellow
    Write-Host "-".PadRight(80, "-") -ForegroundColor Yellow

    foreach ($tag in $sortedTags) {
        $formattedDate = $tag.LastModified.ToString("yyyy-MM-dd")
        Write-Host "$($tag.TagName)".PadRight(30) + "$formattedDate".PadRight(20) + "$($tag.AgeInDays)".PadRight(15) + "$($tag.Size)"
    }
}

# Main script execution

# 1. Login and test connection
$connected = Test-QuayConnection -Server $Server -Token $Token
if (-not $connected) {
    exit 1
}

# 2. Process command based on parameters
if ($ListAllRepos) {
    # Get all repositories and their tags
    $allTags = Get-AllQuayReposTags -Server $Server -Token $Token -Namespace $Namespace

    if ($allTags.Count -gt 0) {
        # Display results in a table format
        Write-Host "`nTag Summary:" -ForegroundColor Cyan
        $allTags | Format-Table -Property Repository, TagName, LastModified, AgeInDays, Size -AutoSize

        # Export to CSV if requested
        if ($ExportToCSV) {
            Export-DataToCSV -Data $allTags -FilePath $OutputPath
        }
    }
}
elseif ($RepositoryName) {
    # Show repository information
    Show-RepositoryInfo -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName

    # Clean up old tags if requested
    if ($CleanupOldTags) {
        Write-Host "`n"
        Clear-OldTags -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName -OlderThanDays $OlderThanDays -WhatIf:$WhatIf
    }
}
else {
    Write-Host "Please specify either -RepositoryName or -ListAllRepos to perform an action." -ForegroundColor Yellow
}