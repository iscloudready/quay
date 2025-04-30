<#
.SYNOPSIS
    Creates and pushes multiple tagged test images to a Quay registry using a robot account.

.PARAMETER QuayRegistry
    Hostname and port of the Quay instance (e.g., localhost:8080)

.PARAMETER Namespace
    Quay namespace/org (e.g., serviceaccount)

.PARAMETER Repository
    Quay repository name (e.g., sa-repo)

.PARAMETER Username
    Robot account username (e.g., serviceaccount+robot)

.PARAMETER Password
    Robot account token (not the Bearer token!)

.PARAMETER TagCount
    Number of test tags to create and push (default: 5)
#>

param (
    [string]$QuayRegistry = "localhost:8080",
    [string]$Namespace = "serviceaccount",
    [string]$Repository = "sa-repo",
    [string]$Username = "serviceaccount+robot",
    [string]$Password = "robotTokenHere",
    [int]$TagCount = 5
)

Write-Host "Logging into $QuayRegistry as $Username..."
$Password | docker login $QuayRegistry -u $Username --password-stdin

if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker login failed. Check your robot credentials and registry address."
    exit 1
}

Write-Host "Pulling base image (alpine:latest)..."
docker pull alpine:latest

Write-Host "Creating and pushing $TagCount tags to $Namespace/$Repository..."

for ($i = 1; $i -le $TagCount; $i++) {
    $tagName = "v$i"
    $imageTag = "{0}/{1}/{2}:{3}" -f $QuayRegistry, $Namespace, $Repository, $tagName

    Write-Host "Tagging $imageTag"
    docker tag alpine:latest $imageTag

    Write-Host "Pushing $imageTag"
    docker push $imageTag

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to push $imageTag"
    }
    else {
        Write-Host "Successfully pushed $imageTag"
    }
}

Write-Host "Completed pushing all tags."
