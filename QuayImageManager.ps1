# QuayImageManager.ps1 - Comprehensive script for managing Quay container images http://localhost:8080/api/v1/discovery
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
# Filter tags by age based on date in tag name
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

            # Try to extract date from tag name (format: v1.0.X-YYYYMMDD)
            $dateMatch = $tag.TagName -match ".*-(\d{8})$"
            if ($dateMatch) {
                $dateString = $Matches[1]
                $year = $dateString.Substring(0, 4)
                $month = $dateString.Substring(4, 2)
                $day = $dateString.Substring(6, 2)

                try {
                    $tagDate = [DateTime]::new($year, [int]$month, [int]$day)
                    $ageInDays = ([DateTime]::Now - $tagDate).TotalDays

                    # Update the tag object with the extracted age
                    $tag | Add-Member -NotePropertyName 'SimulatedAge' -NotePropertyValue ([math]::Round($ageInDays, 1)) -Force

                    if ($ageInDays -gt $OlderThanDays) {
                        $oldTags += $tag
                    }
                }
                catch {
                    Write-Verbose "Could not parse date for tag: $($tag.TagName)"
                    # Use actual age if date parsing fails
                    if ($tag.AgeInDays -gt $OlderThanDays) {
                        $oldTags += $tag
                    }
                }
            }
            else {
                # No date in tag name, use actual age
                if ($tag.AgeInDays -gt $OlderThanDays) {
                    $oldTags += $tag
                }
            }
        }
        return $oldTags
    }
}

# Function to generate a detailed tag cleanup report
function Export-QuayCleanupReport {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName,
        [int]$OlderThanDays = 90,
        [string]$OutputPath = ".\TagCleanupReport.html"
    )

    # Get all tags
    $allTags = Get-QuayTags -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName

    # Find tags older than specified limit
    $oldTags = Get-OldTags -Tags $allTags -OlderThanDays $OlderThanDays

    if ($oldTags.Count -eq 0) {
        Write-Host "No tags found that are older than $OlderThanDays days" -ForegroundColor Green
        return
    }

    # Group tags by their simulated age range
    $tagGroups = @{}
    foreach ($tag in $oldTags) {
        # Extract date from tag name
        $dateMatch = $tag.TagName -match ".*-(\d{8})$"
        $ageCategory = "No Date Pattern"

        if ($dateMatch) {
            $dateString = $Matches[1]
            $year = $dateString.Substring(0, 4)
            $month = $dateString.Substring(4, 2)

            $ageCategory = "$year-$month"
        }

        if (-not $tagGroups.ContainsKey($ageCategory)) {
            $tagGroups[$ageCategory] = @()
        }

        $tagGroups[$ageCategory] += $tag
    }

    # Create HTML report
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Quay Tag Cleanup Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        h2 { color: #666; margin-top: 20px; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        .summary { margin: 20px 0; padding: 10px; background-color: #f0f0f0; border-radius: 5px; }
        .instructions { margin: 20px 0; padding: 10px; background-color: #e6f7ff; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>Quay Tag Cleanup Report</h1>

    <div class="summary">
        <h2>Summary</h2>
        <p><strong>Repository:</strong> $Namespace/$RepositoryName</p>
        <p><strong>Server:</strong> $Server</p>
        <p><strong>Age Threshold:</strong> $OlderThanDays days</p>
        <p><strong>Total Tags for Cleanup:</strong> $($oldTags.Count)</p>
        <p><strong>Report Generated:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
    </div>

    <div class="instructions">
        <h2>Cleanup Instructions</h2>
        <p>These tags have been identified as candidates for deletion based on their age pattern (embedded date in tag name).</p>
        <p>To delete these tags:</p>
        <ol>
            <li>Log in to Quay at <a href="$Server">$Server</a></li>
            <li>Navigate to repository <strong>$Namespace/$RepositoryName</strong></li>
            <li>Go to the Tags tab</li>
            <li>Use the search function to find each tag</li>
            <li>Delete tags using the trash icon</li>
        </ol>
    </div>

    <h2>Tags Identified for Deletion</h2>
"@

    # Add each tag group to the report
    foreach ($group in $tagGroups.Keys | Sort-Object) {
        $html += @"
    <h3>$group</h3>
    <table>
        <tr>
            <th>Tag Name</th>
            <th>Size</th>
            <th>Created Date</th>
            <th>Simulated Age (days)</th>
        </tr>
"@

        foreach ($tag in $tagGroups[$group] | Sort-Object -Property TagName) {
            $html += @"
        <tr>
            <td>$($tag.TagName)</td>
            <td>$($tag.Size)</td>
            <td>$($tag.LastModified)</td>
            <td>$($tag.SimulatedAge)</td>
        </tr>
"@
        }

        $html += @"
    </table>
"@
    }

    # Close HTML
    $html += @"
</body>
</html>
"@

    # Save to file
    $html | Out-File -FilePath $OutputPath -Encoding utf8

    Write-Host "Report generated successfully at: $OutputPath" -ForegroundColor Green
    Write-Host "Open this file in a web browser to view the detailed cleanup report" -ForegroundColor Cyan

    # Return path for convenience
    return $OutputPath
}

# Delete tags using OAuth 2 token with API restrictions disabled
function Remove-QuayTag {
    param (
        [string]$Server,
        [string]$Token,  # This should be an OAuth 2 token, not a robot token
        [string]$Namespace,
        [string]$RepositoryName,
        [string]$TagName,
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Host "[WhatIf] Would delete tag $TagName from $Namespace/$RepositoryName" -ForegroundColor Yellow
        return $true
    }

    # Use a simple Invoke-RestMethod with the OAuth 2 token
    try {
        $url = "$Server/api/v1/repository/$Namespace/$RepositoryName/tag/$TagName"

        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
            "X-Requested-With" = "XMLHttpRequest"
        }

        Write-Host "Deleting tag $TagName with OAuth token..." -ForegroundColor Gray

        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method DELETE -ErrorAction Stop

        Write-Host "Successfully deleted tag $TagName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to delete tag $TagName : $($_.Exception.Message)" -ForegroundColor Red

        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                Write-Host "Error details: $responseBody" -ForegroundColor Red
            }
            catch {
                # Ignore errors reading the response
            }
        }

        Write-Host "`nIf you're still seeing CSRF errors, please ensure:" -ForegroundColor Yellow
        Write-Host "1. You've set BROWSER_API_CALLS_XHR_ONLY: false in Quay's config.yaml" -ForegroundColor Yellow
        Write-Host "2. You're using an OAuth 2 token, not a robot token" -ForegroundColor Yellow
        Write-Host "3. You've restarted your Quay instance after changing the config" -ForegroundColor Yellow

        return $false
    }
}

# Corrected tag deletion function using proper PowerShell syntax for curl
function __Remove-QuayTag {
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

    # Use PowerShell's native Invoke-WebRequest with CSRF headers
    try {
        $url = "$Server/api/v1/repository/$Namespace/$RepositoryName/tag/$TagName"

        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
            "X-Requested-With" = "XMLHttpRequest"
        }

        Write-Host "Deleting tag $TagName..." -ForegroundColor Gray

        # Use Invoke-WebRequest with proper headers
        $response = Invoke-WebRequest -Uri $url -Headers $headers -Method DELETE -ErrorAction Stop

        if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 204) {
            Write-Host "Successfully deleted tag $TagName" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "Failed to delete tag $TagName : Unexpected status code $($response.StatusCode)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        # Try alternative method if the first one fails
        try {
            Write-Host "First method failed, trying alternative approach..." -ForegroundColor Yellow

            # Using cmd.exe /c curl to avoid PowerShell parsing issues
            $curlCommand = "cmd.exe /c curl -X DELETE -H `"Authorization: Bearer $Token`" -H `"Content-Type: application/json`" -H `"X-Requested-With: XMLHttpRequest`" $url"

            $result = Invoke-Expression -Command $curlCommand

            if ($result -match "error") {
                Write-Host "Failed to delete tag $TagName : $result" -ForegroundColor Red
                return $false
            }
            else {
                Write-Host "Successfully deleted tag $TagName" -ForegroundColor Green
                return $true
            }
        }
        catch {
            Write-Host "Failed to delete tag $TagName : $($_.Exception.Message)" -ForegroundColor Red

            Write-Host "`nTo delete this tag manually:" -ForegroundColor Yellow
            Write-Host "1. Log in to the Quay UI at $Server" -ForegroundColor Yellow
            Write-Host "2. Navigate to repository $Namespace/$RepositoryName" -ForegroundColor Yellow
            Write-Host "3. Find and delete tag $TagName" -ForegroundColor Yellow

            return $false
        }
    }
}

# Delete a specific tag with CSRF token handling
function _Remove-QuayTag {
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

    # Add the X-Requested-With header to bypass CSRF protection
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
        "X-Requested-With" = "XMLHttpRequest"  # This helps bypass CSRF in many APIs
    }

    try {
        $url = "$Server/api/v1/repository/$Namespace/$RepositoryName/tag/$TagName"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method DELETE
        Write-Host "Deleted tag $TagName from $Namespace/$RepositoryName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to delete tag $TagName : $_" -ForegroundColor Red

        # Try to get more detailed error information
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                Write-Host $responseBody -ForegroundColor Red
            }
            catch {
                Write-Host "Unable to read error response details." -ForegroundColor Red
            }
        }

        return $false
    }
}

# Clean up old tags with age-based policy
# Modify the Clear-OldTags function to use the report generator when deletion fails
function Clear-OldTags {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName,
        [int]$OlderThanDays = 90,
        [string[]]$ExcludeTags = @("latest", "prod", "stable"),
        [switch]$WhatIf,
        [switch]$GenerateReportOnFailure
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

    # Track deletion failures
    $deletionFailureCount = 0
    $maximumFailures = 3  # After this many failures, switch to report mode

    # Sort tags by age (oldest first)
    $sortedTags = $oldTags | Sort-Object -Property LastModified

    # Try to delete each tag
    foreach ($tag in $sortedTags) {
        Write-Host "- $($tag.TagName) (Created: $($tag.LastModified), Age: $($tag.AgeInDays) days)" -ForegroundColor Gray

        # Skip deletion if WhatIf is specified
        if ($WhatIf) {
            Write-Host "  [WhatIf] Would delete tag $($tag.TagName)" -ForegroundColor Yellow
            continue
        }

        # Try to delete the tag
        $result = Remove-QuayTag -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName -TagName $tag.TagName

        # Track failure
        if (-not $result) {
            $deletionFailureCount++

            # If we've had multiple failures, switch to report generation
            if ($deletionFailureCount -ge $maximumFailures) {
                Write-Host "`nMultiple tag deletion failures detected. Switching to report generation..." -ForegroundColor Yellow
                break
            }
        }
    }

    # If we had deletion failures and GenerateReportOnFailure is true, generate a report
    if ($deletionFailureCount -gt 0 -and ($GenerateReportOnFailure -or $deletionFailureCount -ge $maximumFailures)) {
        Write-Host "`nGenerating cleanup report for manual deletion..." -ForegroundColor Cyan
        $reportPath = Export-QuayCleanupReport -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName -OlderThanDays $OlderThanDays
        Write-Host "Report generated at: $reportPath" -ForegroundColor Green

        # Try to open the report in the default browser
        try {
            Start-Process $reportPath
        }
        catch {
            Write-Host "Couldn't open report automatically. Please open it manually." -ForegroundColor Yellow
        }
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
        Clear-OldTags -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName -OlderThanDays $OlderThanDays -WhatIf:$WhatIf -GenerateReportOnFailure
    }
    # Generate report only (skip deletion attempts)
    elseif ($GenerateReport) {
        Write-Host "`n"
        Write-Host "Generating cleanup report for tags older than $OlderThanDays days..." -ForegroundColor Cyan
        $reportPath = Export-QuayCleanupReport -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName -OlderThanDays $OlderThanDays

        # Try to open the report
        try {
            Write-Host "Opening report in default browser..." -ForegroundColor Cyan
            Start-Process $reportPath
        }
        catch {
            Write-Host "Couldn't open report automatically. Please open it manually at: $reportPath" -ForegroundColor Yellow
        }
    }
}
else {
    Write-Host "Please specify either -RepositoryName, -ListAllRepos, or -GenerateReport to perform an action." -ForegroundColor Yellow
}