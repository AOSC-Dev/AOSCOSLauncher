[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StoreBundle,
    [string]$AppId = '9NMDF21NV65Z',
    [string]$SubmissionId,
    [string]$PackageZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ApiRoot = 'https://manage.devcenter.microsoft.com/v1.0/my'
$ApiResource = 'https://manage.devcenter.microsoft.com'

function Get-StoreAccessToken {
    foreach ($name in @('STORE_TENANT_ID', 'STORE_CLIENT_ID', 'STORE_CLIENT_SECRET')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Required Partner Center credential $name is not set."
        }
    }

    $client = [System.Net.Http.HttpClient]::new()
    try {
        $form = [System.Collections.Generic.Dictionary[string, string]]::new()
        $form.Add('grant_type', 'client_credentials')
        $form.Add('client_id', $env:STORE_CLIENT_ID)
        $form.Add('client_secret', $env:STORE_CLIENT_SECRET)
        $form.Add('resource', $ApiResource)
        $content = [System.Net.Http.FormUrlEncodedContent]::new($form)
        $tokenUri = "https://login.microsoftonline.com/$env:STORE_TENANT_ID/oauth2/token"
        $response = $client.PostAsync($tokenUri, $content).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Partner Center authentication failed with HTTP $([int]$response.StatusCode): $body"
        }

        $token = ($body | ConvertFrom-Json).access_token
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw 'Partner Center authentication returned no access token.'
        }
        return $token
    }
    finally {
        $client.Dispose()
    }
}

function Invoke-StoreApi {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$AccessToken,
        [object]$Body = $null
    )

    $client = [System.Net.Http.HttpClient]::new()
    $request = $null
    try {
        $client.Timeout = [TimeSpan]::FromMinutes(10)
        $httpMethod = [System.Net.Http.HttpMethod]::new($Method)
        $request = [System.Net.Http.HttpRequestMessage]::new($httpMethod, $Uri)
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $AccessToken)
        if ($null -ne $Body) {
            $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 -Compress }
            $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
        }
        elseif ($Method -in @('POST', 'PUT')) {
            $request.Content = [System.Net.Http.StringContent]::new('', [System.Text.Encoding]::UTF8, 'application/json')
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            if ($responseBody.Length -gt 4000) {
                $responseBody = $responseBody.Substring(0, 4000)
            }
            throw "Store API $Method $Uri failed with HTTP $([int]$response.StatusCode): $responseBody"
        }
        if ([string]::IsNullOrWhiteSpace($responseBody)) {
            return $null
        }
        return ($responseBody | ConvertFrom-Json)
    }
    finally {
        if ($null -ne $request) {
            $request.Dispose()
        }
        $client.Dispose()
    }
}

function New-SubmissionZip {
    param(
        [string]$BundlePath,
        [string]$ZipPath
    )

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    $archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $entryName = [System.IO.Path]::GetFileName($BundlePath)
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $BundlePath,
            $entryName,
            [System.IO.Compression.CompressionLevel]::NoCompression
        ) | Out-Null
    }
    finally {
        $archive.Dispose()
    }
}

function Send-SubmissionZip {
    param(
        [string]$UploadUrl,
        [string]$ZipPath
    )

    $client = [System.Net.Http.HttpClient]::new()
    $stream = [System.IO.File]::OpenRead($ZipPath)
    $content = [System.Net.Http.StreamContent]::new($stream)
    $request = $null
    try {
        $client.Timeout = [TimeSpan]::FromHours(4)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/zip')
        $content.Headers.ContentLength = $stream.Length
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, $UploadUrl)
        $request.Content = $content
        $request.Headers.Add('x-ms-blob-type', 'BlockBlob')
        $request.Headers.Add('x-ms-version', '2017-04-17')

        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($responseBody.Length -gt 4000) {
                $responseBody = $responseBody.Substring(0, 4000)
            }
            throw "Store package upload failed with HTTP $([int]$response.StatusCode): $responseBody"
        }
    }
    finally {
        if ($null -ne $request) {
            $request.Dispose()
        }
        $content.Dispose()
        $stream.Dispose()
        $client.Dispose()
    }
}

$bundle = Get-Item -LiteralPath $StoreBundle -ErrorAction Stop
if ($bundle.Extension -notin @('.appxbundle', '.appxupload')) {
    throw "StoreBundle must be an .appxbundle or .appxupload file: $StoreBundle"
}
if ([string]::IsNullOrWhiteSpace($PackageZip)) {
    $PackageZip = Join-Path $bundle.DirectoryName 'StoreSubmission.zip'
}

$accessToken = Get-StoreAccessToken
$application = Invoke-StoreApi -Method 'GET' -Uri "$ApiRoot/applications/$AppId" -AccessToken $accessToken
$pendingId = $application.pendingApplicationSubmission.id

if ([string]::IsNullOrWhiteSpace($SubmissionId)) {
    if (-not [string]::IsNullOrWhiteSpace($pendingId)) {
        throw "Store app $AppId already has pending submission $pendingId. Supply -SubmissionId $pendingId only if this release should replace its packages."
    }

    Write-Host "Creating a new Store submission for $AppId"
    $created = Invoke-StoreApi -Method 'POST' -Uri "$ApiRoot/applications/$AppId/submissions?isMinimalResponse=true" -AccessToken $accessToken -Body ''
    $SubmissionId = $created.id
}
elseif (-not [string]::IsNullOrWhiteSpace($pendingId) -and $pendingId -cne $SubmissionId) {
    throw "Store app $AppId has pending submission $pendingId, not the requested $SubmissionId."
}

$submission = Invoke-StoreApi -Method 'GET' -Uri "$ApiRoot/applications/$AppId/submissions/$SubmissionId" -AccessToken $accessToken
if ($null -eq $submission -or $submission.id -cne $SubmissionId) {
    throw "Could not retrieve Store submission $SubmissionId."
}

foreach ($package in @($submission.applicationPackages)) {
    $package.fileStatus = 'PendingDelete'
}
$newPackage = [pscustomobject]@{
    fileName = $bundle.Name
    fileStatus = 'PendingUpload'
    minimumDirectXVersion = 'None'
    minimumSystemRam = 'None'
}
$submission.applicationPackages = @($submission.applicationPackages) + @($newPackage)

Write-Host "Replacing packages in Store submission $SubmissionId"
$updated = Invoke-StoreApi -Method 'PUT' -Uri "$ApiRoot/applications/$AppId/submissions/$SubmissionId" -AccessToken $accessToken -Body $submission
$uploadUrl = $updated.fileUploadUrl
if ([string]::IsNullOrWhiteSpace($uploadUrl)) {
    throw "Store submission $SubmissionId returned no upload URL."
}

Write-Host "Creating submission archive from $($bundle.Name)"
New-SubmissionZip -BundlePath $bundle.FullName -ZipPath $PackageZip
Write-Host "Uploading Store submission archive ($((Get-Item -LiteralPath $PackageZip).Length) bytes)"
Send-SubmissionZip -UploadUrl $uploadUrl -ZipPath $PackageZip
Remove-Item -LiteralPath $PackageZip -Force

Write-Host "Committing Store submission $SubmissionId for certification"
Invoke-StoreApi -Method 'POST' -Uri "$ApiRoot/applications/$AppId/submissions/$SubmissionId/Commit" -AccessToken $accessToken -Body '' | Out-Null

$statusResult = Invoke-StoreApi -Method 'GET' -Uri "$ApiRoot/applications/$AppId/submissions/$SubmissionId/status" -AccessToken $accessToken
$status = $statusResult.status
if ([string]::IsNullOrWhiteSpace($status) -or $status -in @('PendingCommit', 'PendingDelete')) {
    throw "Store submission $SubmissionId did not enter certification. Status: $status"
}

$verified = Invoke-StoreApi -Method 'GET' -Uri "$ApiRoot/applications/$AppId/submissions/$SubmissionId" -AccessToken $accessToken
if ($verified.applicationPackages.fileName -notcontains $bundle.Name) {
    throw "Store submission $SubmissionId does not contain $($bundle.Name)."
}

[pscustomobject]@{
    AppId = $AppId
    SubmissionId = $SubmissionId
    Status = $status
    Package = $bundle.Name
    Url = "https://partner.microsoft.com/dashboard/products/$AppId/submissions/$SubmissionId/"
}
