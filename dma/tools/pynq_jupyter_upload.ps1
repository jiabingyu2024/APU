param(
    [Parameter(Mandatory = $true)]
    [string]$LocalPath,
    [Parameter(Mandatory = $true)]
    [string]$RemotePath,
    [string]$HostUrl = "http://192.168.137.2:9090",
    [string]$Password = "xilinx"
)

$ErrorActionPreference = "Stop"

function Get-XsrfToken {
    param([string]$Html)
    if ($Html -match 'name="_xsrf"\s+value="([^"]+)"') {
        return $Matches[1]
    }
    throw "Unable to find Jupyter _xsrf token"
}

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$loginUri = [uri]"$HostUrl/login?next=%2Ftree"
$loginPage = Invoke-WebRequest -Uri $loginUri -WebSession $session -UseBasicParsing
$xsrf = Get-XsrfToken $loginPage.Content
Invoke-WebRequest -Uri $loginUri -Method Post -WebSession $session -Body @{
    _xsrf = $xsrf
    password = $Password
} -UseBasicParsing | Out-Null

$bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $LocalPath))
$body = @{
    type = "file"
    format = "base64"
    content = [Convert]::ToBase64String($bytes)
} | ConvertTo-Json -Compress
$escapedPath = (($RemotePath -replace '\\', '/') -split '/' | ForEach-Object {
    [uri]::EscapeDataString($_)
}) -join '/'
$headers = @{ "X-XSRFToken" = $xsrf }
Invoke-RestMethod -Uri "$HostUrl/api/contents/$escapedPath" -Method Put `
    -WebSession $session -Headers $headers -Body $body -ContentType "application/json" | Out-Null
Write-Output "Uploaded $LocalPath -> $RemotePath"
