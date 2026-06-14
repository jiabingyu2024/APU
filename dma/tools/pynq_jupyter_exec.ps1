param(
    [Parameter(Mandatory = $true)]
    [string]$Code,
    [string]$HostUrl = "http://192.168.137.2:9090",
    [string]$Password = "xilinx",
    [int]$TimeoutMinutes = 30
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

$headers = @{ "X-XSRFToken" = $xsrf }
$kernelBody = @{ name = "python3" } | ConvertTo-Json -Compress
$kernel = Invoke-RestMethod -Uri "$HostUrl/api/kernels" -Method Post `
    -WebSession $session -Headers $headers -Body $kernelBody `
    -ContentType "application/json"
$kernelId = $kernel.id
$ws = $null

try {
    $ws = [Net.WebSockets.ClientWebSocket]::new()
    $cookies = $session.Cookies.GetCookies([uri]$HostUrl)
    $parts = @()
    foreach ($cookie in $cookies) {
        $parts += "$($cookie.Name)=$($cookie.Value)"
    }
    $ws.Options.SetRequestHeader("Cookie", ($parts -join "; "))

    $wsBase = $HostUrl -replace '^http:', 'ws:'
    $wsBase = $wsBase -replace '^https:', 'wss:'
    $ct = [Threading.CancellationToken]::None
    $ws.ConnectAsync([uri]"$wsBase/api/kernels/$kernelId/channels", $ct).Wait()

    $sessionId = [guid]::NewGuid().ToString()
    $message = @{
        header = @{
            msg_id = [guid]::NewGuid().ToString()
            username = "codex"
            session = $sessionId
            msg_type = "execute_request"
            version = "5.3"
        }
        parent_header = @{}
        metadata = @{}
        content = @{
            code = $Code
            silent = $false
            store_history = $false
            user_expressions = @{}
            allow_stdin = $false
            stop_on_error = $true
        }
        channel = "shell"
    } | ConvertTo-Json -Depth 20 -Compress

    $bytes = [Text.Encoding]::UTF8.GetBytes($message)
    $ws.SendAsync(
        [ArraySegment[byte]]::new($bytes),
        [Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        $ct
    ).Wait()

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $ms = [IO.MemoryStream]::new()
        do {
            $buffer = New-Object byte[] 65536
            $result = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $ct).Result
            if ($result.Count -gt 0) {
                $ms.Write($buffer, 0, $result.Count)
            }
        } while (-not $result.EndOfMessage)

        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        if (-not $text) {
            continue
        }
        $object = $text | ConvertFrom-Json
        if ($object.msg_type -eq "stream") {
            Write-Output $object.content.text.TrimEnd()
        } elseif ($object.msg_type -eq "execute_result" -and $object.content.data.'text/plain') {
            Write-Output $object.content.data.'text/plain'
        } elseif ($object.msg_type -eq "error") {
            Write-Output ($object.content.ename + ": " + $object.content.evalue)
            foreach ($line in $object.content.traceback) {
                Write-Output $line
            }
            throw "Remote execution failed"
        } elseif ($object.msg_type -eq "execute_reply") {
            Write-Output ("execute_reply: " + $object.content.status)
            break
        }
    }
}
finally {
    if ($ws) {
        $ws.Dispose()
    }
    if ($kernelId) {
        try {
            Invoke-WebRequest -Uri "$HostUrl/api/kernels/$kernelId" -Method Delete `
                -WebSession $session -Headers $headers -UseBasicParsing | Out-Null
        } catch {
        }
    }
}
