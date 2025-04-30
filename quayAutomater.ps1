# QuayAutomater.ps1 - Script for basic Quay operations using API only
# Usage: ./QuayAutomater.ps1 -Server "http://localhost:9090" -Token "your_token" -Namespace "your_namespace"

param (
    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$true)]
    [string]$Token,

    [Parameter(Mandatory=$true)]
    [string]$Namespace,

    [Parameter(Mandatory=$false)]
    [string]$RepositoryName
)

# 1. Function to login to Quay and check connectivity
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

# 2. Function to create a repository if it doesn't exist
function New-QuayRepositoryIfNotExists {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName
    )

    # Check if repository exists
    try {
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }

        $checkResponse = Invoke-RestMethod -Uri "$Server/api/v1/repository/$Namespace/$RepositoryName" -Headers $headers -Method GET -ErrorAction SilentlyContinue
        Write-Host "Repository $Namespace/$RepositoryName already exists" -ForegroundColor Yellow
        return $checkResponse
    }
    catch {
        # Repository doesn't exist, create it using the API
        try {
            Write-Host "Creating repository $Namespace/$RepositoryName via API..." -ForegroundColor Cyan

            # Using Authorization token with specific headers to avoid CSRF issues
            $headers = @{
                "Authorization" = "Bearer $Token"
                "Content-Type" = "application/json"
                "X-Requested-With" = "XMLHttpRequest"  # This helps bypass CSRF in many APIs
            }

            $body = @{
                "namespace" = $Namespace
                "repository" = $RepositoryName
                "visibility" = "private"
                "description" = "Created by PowerShell script"
            } | ConvertTo-Json

            $createResponse = Invoke-RestMethod -Uri "$Server/api/v1/repository" -Headers $headers -Method POST -Body $body
            Write-Host "Successfully created repository $Namespace/$RepositoryName" -ForegroundColor Green
            return $createResponse
        }
        catch {
            Write-Host "Failed to create repository: $_" -ForegroundColor Red

            # Provide instructions for manual creation
            Write-Host "`nTo create this repository manually:" -ForegroundColor Yellow
            Write-Host "1. Log in to $Server" -ForegroundColor Yellow
            Write-Host "2. Click 'Create New Repository'" -ForegroundColor Yellow
            Write-Host "3. Enter '$RepositoryName' as the name" -ForegroundColor Yellow
            Write-Host "4. Select '$Namespace' as the namespace" -ForegroundColor Yellow

            return $null
        }
    }
}

# 3. Function to get all repositories in a namespace (Enhanced version)
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

    Write-Host "Trying to list repositories in namespace '$Namespace'..." -ForegroundColor Cyan

    try {
        # Use the successful query parameter approach with public=true parameter
        $url = "$Server/api/v1/repository?namespace=$Namespace&public=true"
        Write-Host "Using API URL with public parameter: $url" -ForegroundColor Gray

        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method GET

        Write-Host "API Response:" -ForegroundColor Gray
        Write-Host ($response | ConvertTo-Json -Depth 1) -ForegroundColor Gray

        # If we need to check both public and private repos, we can add that here
        $publicRepos = $response.repositories

        # Try to get private repos as well
        try {
            $privateUrl = "$Server/api/v1/repository?namespace=$Namespace&public=false"
            Write-Host "Also checking for private repositories: $privateUrl" -ForegroundColor Gray

            $privateResponse = Invoke-RestMethod -Uri $privateUrl -Headers $headers -Method GET

            if ($privateResponse.repositories -and $privateResponse.repositories.Count -gt 0) {
                Write-Host "Found $($privateResponse.repositories.Count) private repositories" -ForegroundColor Green
                # Combine the lists
                if ($publicRepos) {
                    $response.repositories = $publicRepos + $privateResponse.repositories
                } else {
                    $response.repositories = $privateResponse.repositories
                }
            }
        }
        catch {
            Write-Host "Unable to check private repositories: $_" -ForegroundColor Yellow
        }

        # Process and display repositories
        if (-not $response.repositories -or $response.repositories.Count -eq 0) {
            Write-Host "No repositories found in namespace $Namespace" -ForegroundColor Yellow

            # Try direct access to the repository we know exists as a final check
            if ($RepositoryName) {
                try {
                    $directUrl = "$Server/api/v1/repository/$Namespace/$RepositoryName"
                    Write-Host "Checking direct repository access: $directUrl" -ForegroundColor Gray

                    $directResponse = Invoke-RestMethod -Uri $directUrl -Headers $headers -Method GET
                    Write-Host "Direct repository access succeeded:" -ForegroundColor Green
                    Write-Host "- $($directResponse.name)" -ForegroundColor White
                    Write-Host "  Description: $($directResponse.description)" -ForegroundColor Gray
                    Write-Host "  Visibility: $(if ($directResponse.is_public) {'Public'} else {'Private'})" -ForegroundColor Gray

                    Write-Host "`nNOTE: Direct repository access works, but listing all repositories returned empty." -ForegroundColor Yellow
                    Write-Host "This could be due to token permissions or API limitations." -ForegroundColor Yellow
                }
                catch {
                    Write-Host "Direct repository access also failed: $_" -ForegroundColor Red
                }
            }
        }
        else {
            Write-Host ""
            Write-Host "Repositories in namespace $Namespace" -ForegroundColor Cyan
            foreach ($repo in $response.repositories) {
                Write-Host "- $($repo.name)" -ForegroundColor White
                Write-Host "  Description: $($repo.description)" -ForegroundColor Gray
                Write-Host "  Visibility: $(if ($repo.is_public) {'Public'} else {'Private'})" -ForegroundColor Gray
                Write-Host "  Last Modified: $($repo.last_modified)" -ForegroundColor Gray
                Write-Host ""
            }

            Write-Host "Total repositories: $($response.repositories.Count)" -ForegroundColor Cyan
        }

        return $response.repositories
    }
    catch {
        Write-Host "Failed to get repositories: $_" -ForegroundColor Red

        # Try to get more detailed error information
        Write-Host "Error details:" -ForegroundColor Red
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

        return @()
    }
}

# 3. Function to get all repositories in a namespace (Original version kept for reference)
function _Get-QuayRepositories {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
    }

    try {
        $response = Invoke-RestMethod -Uri "$Server/api/v1/repository?namespace=$Namespace" -Headers $headers -Method GET

        if ($response.repositories.Count -eq 0) {
            Write-Host "No repositories found in namespace $Namespace" -ForegroundColor Yellow
        }
        else {
            Write-Host ""
            Write-Host "Repositories in namespace $Namespace :" -ForegroundColor Cyan
            foreach ($repo in $response.repositories) {
                Write-Host "- $($repo.name)" -ForegroundColor White
                Write-Host "  Description: $($repo.description)" -ForegroundColor Gray
                Write-Host "  Visibility: $(if ($repo.is_public) {'Public'} else {'Private'})" -ForegroundColor Gray
                Write-Host "  Last Modified: $($repo.last_modified)" -ForegroundColor Gray
                Write-Host ""
            }

            Write-Host "Total repositories: $($response.repositories.Count)" -ForegroundColor Cyan
        }

        return $response.repositories
    }
    catch {
        Write-Host "Failed to get repositories: $_" -ForegroundColor Red
        return @()
    }
}

# 4. Function to update repository details
function Update-QuayRepository {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName,
        [string]$Description,
        [string]$Visibility
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type" = "application/json"
        "X-Requested-With" = "XMLHttpRequest"
    }

    try {
        # Create body based on provided parameters
        $body = @{}
        if ($Description) { $body.description = $Description }
        if ($Visibility) { $body.visibility = $Visibility }

        $bodyJson = $body | ConvertTo-Json

        $response = Invoke-RestMethod -Uri "$Server/api/v1/repository/$Namespace/$RepositoryName" -Headers $headers -Method PUT -Body $bodyJson
        Write-Host "Successfully updated repository $Namespace/$RepositoryName" -ForegroundColor Green
        return $response
    }
    catch {
        Write-Host "Failed to update repository: $_" -ForegroundColor Red
        return $null
    }
}

# 5. Function to get repository permissions
function Get-QuayRepositoryPermissions {
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
        $response = Invoke-RestMethod -Uri "$Server/api/v1/repository/$Namespace/$RepositoryName/permissions/user/" -Headers $headers -Method GET

        if ($response.permissions.Count -eq 0) {
            Write-Host "No custom permissions found for repository $Namespace/$RepositoryName" -ForegroundColor Yellow
        }
        else {
            Write-Host ""
            Write-Host "Permissions for repository $Namespace/$RepositoryName :" -ForegroundColor Cyan
            foreach ($perm in $response.permissions) {
                Write-Host "- User: $($perm.name)" -ForegroundColor White
                Write-Host "  Role: $($perm.role)" -ForegroundColor Gray
                Write-Host ""
            }
        }

        return $response.permissions
    }
    catch {
        Write-Host "Failed to get repository permissions: $_" -ForegroundColor Red
        return @()
    }
}

# Add this function to your script to try different auth methods
function Test-QuayAuthMethods {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RobotName # e.g. "serviceaccount+sa"
    )

    Write-Host "Testing different authentication methods..." -ForegroundColor Cyan

    # Method 1: Standard Bearer token
    try {
        $headers1 = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }
        Write-Host "Testing Bearer token auth..." -ForegroundColor Gray
        $response1 = Invoke-RestMethod -Uri "$Server/api/v1/repository/$Namespace/sa-repo" -Headers $headers1 -Method GET
        Write-Host "Bearer token auth successful!" -ForegroundColor Green
    }
    catch {
        Write-Host "Bearer token auth failed: $_" -ForegroundColor Red
    }

    # Method 2: Basic auth with robot credentials
    try {
        $robotCred = "$RobotName`:$Token"
        $robotCredBytes = [System.Text.Encoding]::ASCII.GetBytes($robotCred)
        $robotCredBase64 = [Convert]::ToBase64String($robotCredBytes)

        $headers2 = @{
            "Authorization" = "Basic $robotCredBase64"
            "Content-Type" = "application/json"
        }

        Write-Host "Testing Basic auth with robot credentials..." -ForegroundColor Gray
        $response2 = Invoke-RestMethod -Uri "$Server/api/v1/repository/$Namespace/sa-repo" -Headers $headers2 -Method GET
        Write-Host "Basic auth with robot credentials successful!" -ForegroundColor Green
    }
    catch {
        Write-Host "Basic auth with robot credentials failed: $_" -ForegroundColor Red
    }

    # Method 3: Try with specific query parameters
    try {
        $headers3 = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }

        Write-Host "Testing with specific query parameters..." -ForegroundColor Gray
        $response3 = Invoke-RestMethod -Uri "$Server/api/v1/repository?namespace=$Namespace&public=true" -Headers $headers3 -Method GET
        Write-Host "Query parameter method successful!" -ForegroundColor Green
        Write-Host "Found repositories: $($response3.repositories.Count)" -ForegroundColor Green
    }
    catch {
        Write-Host "Query parameter method failed: $_" -ForegroundColor Red
    }

    # Method 4: Try with direct redirect follow
    try {
        $headers4 = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }

        Write-Host "Testing with follow-redirect..." -ForegroundColor Gray
        $response4 = Invoke-WebRequest -Uri "$Server/api/v1/user/repositories" -Headers $headers4 -Method GET -MaximumRedirection 5
        Write-Host "Follow-redirect method successful!" -ForegroundColor Green
        Write-Host "Response content: $($response4.Content)" -ForegroundColor Gray
    }
    catch {
        Write-Host "Follow-redirect method failed: $_" -ForegroundColor Red
    }
}

# Main script execution

# 1. Login and test connection
$connected = Test-QuayConnection -Server $Server -Token $Token
if (-not $connected) {
    exit 1
}

# 1.5 Test different authentication methods (only run first time for diagnostics)
# Comment this out after successful testing
# Test-QuayAuthMethods -Server $Server -Token $Token -Namespace $Namespace -RobotName "serviceaccount+sa"

# 2. Create repository if specified and not exists
if ($RepositoryName) {
    $repo = New-QuayRepositoryIfNotExists -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName
}

# 3. Get all repositories
$repositories = Get-QuayRepositories -Server $Server -Token $Token -Namespace $Namespace