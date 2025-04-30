# Create-QuayTestData.ps1 - Script to create test data in Quay using Docker CLI
# Usage: .\Create-QuayTestData.ps1 -Server "localhost:9090" -Token "your_token" -Namespace "your_namespace" -RepositoryName "test-repo" -TagCount 20

param (
    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$true)]
    [string]$Token,

    [Parameter(Mandatory=$true)]
    [string]$Namespace,

    [Parameter(Mandatory=$true)]
    [string]$RepositoryName,

    [Parameter(Mandatory=$false)]
    [int]$TagCount = 10,

    [Parameter(Mandatory=$false)]
    [switch]$SimulateOnly
)

# Clean server string for Docker format (remove http:// or https://)
$ServerClean = $Server -replace "^https?://", ""

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

        # Make sure to use the original server value with http:// for API calls
        $serverWithProtocol = $Server
        if (-not $serverWithProtocol.StartsWith("http")) {
            $serverWithProtocol = "http://$Server"
        }

        $response = Invoke-RestMethod -Uri "$serverWithProtocol/api/v1/discovery" -Headers $headers -Method GET
        Write-Host "Successfully connected to Quay at $serverWithProtocol" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to connect to Quay: $_" -ForegroundColor Red
        return $false
    }
}

# Check if repository exists
function Test-QuayRepository {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName
    )

    try {
        $headers = @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        }

        # Make sure to use the original server value with http:// for API calls
        $serverWithProtocol = $Server
        if (-not $serverWithProtocol.StartsWith("http")) {
            $serverWithProtocol = "http://$Server"
        }

        $response = Invoke-RestMethod -Uri "$serverWithProtocol/api/v1/repository/$Namespace/$RepositoryName" -Headers $headers -Method GET -ErrorAction SilentlyContinue
        Write-Host "Repository $Namespace/$RepositoryName exists" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Repository $Namespace/$RepositoryName does not exist" -ForegroundColor Yellow
        return $false
    }
}

# Create a base image with busybox for testing
function Create-BaseImage {
    param (
        [string]$TagName
    )

    $tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "quay-test-$([Guid]::NewGuid().ToString())")
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

    $dockerfilePath = [System.IO.Path]::Combine($tempDir, "Dockerfile")

    @"
FROM busybox:latest
LABEL maintainer="QuayImageManager Test"
LABEL created_date="$(Get-Date -Format "yyyy-MM-dd")"
LABEL test="true"
CMD ["echo", "This is a test image"]
"@ | Out-File -FilePath $dockerfilePath -Encoding ascii

    try {
        Write-Host "Building base image with tag $TagName..." -ForegroundColor Cyan
        docker build -t $TagName -f $dockerfilePath $tempDir

        # Clean up
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        return $true
    }
    catch {
        Write-Host "Failed to build base image: $_" -ForegroundColor Red
        return $false
    }
}

# Create test tags using Docker CLI (handles CSRF issues by avoiding the API for creation)
function New-TestTags {
    param (
        [string]$Server,
        [string]$Token,
        [string]$Namespace,
        [string]$RepositoryName,
        [int]$TagCount,
        [bool]$SimulateOnly
    )

    Write-Host "Creating $TagCount test tags in $Namespace/$RepositoryName" -ForegroundColor Cyan

    # Create some standard tags
    $standardTags = @("latest", "prod", "dev", "staging")

    # Check if docker command is available
    $dockerAvailable = $false
    if (-not $SimulateOnly) {
        try {
            $dockerVersion = docker --version
            $dockerAvailable = $true
            Write-Host "Docker CLI is available: $dockerVersion" -ForegroundColor Green

            # Login to docker registry - we'll skip this since it's causing issues
            # We'll rely on docker's ability to push without login when needed
            Write-Host "Note: Skipping docker login which can be problematic. Docker will attempt authentication during push if needed." -ForegroundColor Yellow

            # Create a base image to use (busybox-based)
            $baseImageName = "quay-test-base:latest"
            $baseImageCreated = Create-BaseImage -TagName $baseImageName

            if (-not $baseImageCreated) {
                Write-Host "Could not create base image. Will tag and push simple busybox image instead." -ForegroundColor Yellow
                $baseImageName = "busybox:latest"

                # Make sure we have busybox
                docker pull busybox:latest
            }
        }
        catch {
            Write-Host "Docker CLI is not available or not in PATH. Will simulate only." -ForegroundColor Yellow
            $SimulateOnly = $true
        }
    }

    # Process standard tags
    foreach ($tag in $standardTags) {
        Write-Host "Processing standard tag: $tag" -ForegroundColor Yellow

        if ($SimulateOnly -or -not $dockerAvailable) {
            Write-Host "  [SIMULATION] docker tag $baseImageName ${ServerClean}/${Namespace}/${RepositoryName}:${tag}" -ForegroundColor Gray
            Write-Host "  [SIMULATION] docker push ${ServerClean}/${Namespace}/${RepositoryName}:${tag}" -ForegroundColor Gray
        }
        else {
            try {
                $taggedImage = "${ServerClean}/${Namespace}/${RepositoryName}:${tag}"

                # Tag and push the image
                Write-Host "  Tagging image: $taggedImage" -ForegroundColor Cyan
                docker tag $baseImageName $taggedImage

                Write-Host "  Pushing image: $taggedImage" -ForegroundColor Cyan
                docker push $taggedImage

                Write-Host "  Successfully pushed $taggedImage" -ForegroundColor Green
            }
            catch {
                Write-Host "  Failed to tag/push image: $_" -ForegroundColor Red
            }
        }
    }

    # Create dated tags with various age patterns
    for ($i = 1; $i -le $TagCount; $i++) {
        # Create a date that's a random number of days in the past (up to 120 days)
        $daysAgo = Get-Random -Minimum 1 -Maximum 120
        $date = (Get-Date).AddDays(-$daysAgo).ToString("yyyyMMdd")
        $tag = "v1.0.$i-$date"

        Write-Host "Processing dated tag: $tag (simulated $daysAgo days old)" -ForegroundColor Yellow

        if ($SimulateOnly -or -not $dockerAvailable) {
            Write-Host "  [SIMULATION] docker tag $baseImageName ${ServerClean}/${Namespace}/${RepositoryName}:${tag}" -ForegroundColor Gray
            Write-Host "  [SIMULATION] docker push ${ServerClean}/${Namespace}/${RepositoryName}:${tag}" -ForegroundColor Gray
        }
        else {
            try {
                $taggedImage = "${ServerClean}/${Namespace}/${RepositoryName}:${tag}"

                # Tag and push the image
                Write-Host "  Tagging image: $taggedImage" -ForegroundColor Cyan
                docker tag $baseImageName $taggedImage

                Write-Host "  Pushing image: $taggedImage" -ForegroundColor Cyan
                docker push $taggedImage

                Write-Host "  Successfully pushed $taggedImage" -ForegroundColor Green
            }
            catch {
                Write-Host "  Failed to tag/push image: $_" -ForegroundColor Red
            }
        }
    }

    Write-Host "`nTest data creation complete!" -ForegroundColor Green

    if ($SimulateOnly) {
        Write-Host "`nThis was a simulation only. To create actual test data:" -ForegroundColor Cyan
        Write-Host "1. Ensure Docker CLI is installed and in your PATH" -ForegroundColor White
        Write-Host "2. Run this script without the -SimulateOnly parameter" -ForegroundColor White
        Write-Host "3. Or manually push images to ${ServerClean}/${Namespace}/${RepositoryName}" -ForegroundColor White
    }
}

# Main script execution

# 1. Login and test connection
$connected = Test-QuayConnection -Server $Server -Token $Token
if (-not $connected) {
    exit 1
}

# 2. Check if repository exists (don't try to create it via API due to CSRF issues)
$repoExists = Test-QuayRepository -Server $Server -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName

if (-not $repoExists) {
    Write-Host "The repository doesn't exist. You have two options:" -ForegroundColor Yellow
    Write-Host "1. Create the repository manually through the Quay UI" -ForegroundColor White
    Write-Host "2. Continue with Docker push which will create the repository automatically (if permissions allow)" -ForegroundColor White

    $continue = Read-Host "Do you want to continue? (Y/N)"
    if ($continue -ne "Y") {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        exit 1
    }
}

# 3. Create test tags
New-TestTags -Server $ServerClean -Token $Token -Namespace $Namespace -RepositoryName $RepositoryName -TagCount $TagCount -SimulateOnly:$SimulateOnly