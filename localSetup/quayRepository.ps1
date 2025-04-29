# --------------------------------------------
# Quay Automation Script (PowerShell)
# Secure Login + Correct API Auth + Correct Docker Tagging
# --------------------------------------------
Clear-Host
# Variables
$quayUrl = "http://localhost:9090"        # Quay UI/API URL
$dockerRegistry = "localhost:9090"         # Docker Registry URL (no http://)
$username = "serviceaccount"              # Your Quay username
$password = "Dragon"             # Your Quay password
$repoName = "testrepo"                    # Repository Name

# ------------------------------------------------
# Step 1: Docker Login Securely
# ------------------------------------------------
Write-Output "Logging into Quay securely via Docker..."

$password | docker login $dockerRegistry -u $username --password-stdin

# ------------------------------------------------
# Step 2: Create Authorization Header for Quay API
# ------------------------------------------------
Write-Output "Preparing API Authorization Header..."

$pair = "${username}:${password}"
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$base64 = [Convert]::ToBase64String($bytes)

$headers = @{
    Authorization = "Basic $base64"
    "Content-Type" = "application/json"
}

# ------------------------------------------------
# Step 3: Create Repository (if not exists)
# ------------------------------------------------
Write-Output "Creating repository '$repoName'..."

$body = @{
    namespace = $username
    repository = $repoName
    visibility = "public"
    description = "This is a test repository created via automation."
} | ConvertTo-Json -Depth 10

try {
    Invoke-RestMethod -Uri "$quayUrl/api/v1/repository" `
        -Method Post `
        -Headers $headers `
        -Body $body
    Write-Output "Repository '$repoName' created successfully!"
}
catch {
    Write-Output "Repository might already exist or minor error. Continuing..."
}

# ------------------------------------------------
# Step 4: Pull Base Image
# ------------------------------------------------
Write-Output "Pulling base image (Alpine)..."
docker pull alpine:latest

# ------------------------------------------------
# Step 5: Tag and Push Multiple Versions
# ------------------------------------------------
foreach ($version in 1..3) {
    $tag = "v$version"
    Write-Output "Tagging and pushing version $tag..."

    docker tag alpine:latest "${dockerRegistry}/${username}/${repoName}:$tag"
    docker push "${dockerRegistry}/${username}/${repoName}:$tag"
}

# ------------------------------------------------
# Step 6: List All Tags in Repository
# ------------------------------------------------
Write-Output "Listing all tags in repository..."

$response = Invoke-RestMethod -Uri "$quayUrl/api/v1/repository/$username/$repoName/tag/" `
    -Method Get `
    -Headers $headers

foreach ($tag in $response.tags) {
    Write-Output "Found tag: $($tag.name)"
}

# ------------------------------------------------
# Step 7: Delete a Specific Tag (Optional Example)
# ------------------------------------------------
$tagToDelete = "v1"
Write-Output "Deleting tag '$tagToDelete'..."

try {
    Invoke-RestMethod -Uri "$quayUrl/api/v1/repository/$username/$repoName/tag/$tagToDelete" `
        -Method Delete `
        -Headers $headers
    Write-Output "Tag '$tagToDelete' deleted successfully!"
}
catch {
    Write-Output "Tag '$tagToDelete' could not be deleted. It might not exist."
}

Write-Output ""
Write-Output "✅ Script Execution Completed Successfully!"
