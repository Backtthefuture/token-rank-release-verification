param(
    [string]$ArtifactUrl = 'https://www.zhenganhuo.com/token-rank/dl/v0.5.18/f511ac261e77a41fe60279cd7650e13fd79d682065304c9090e8bced07b72fd6/token-rank.exe',
    [string]$ExpectedSha256 = 'f511ac261e77a41fe60279cd7650e13fd79d682065304c9090e8bced07b72fd6'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = Join-Path $env:RUNNER_TEMP 'token-rank-security-scan'
$Bin = Join-Path $Root 'token-rank-0.5.18-held.exe'
$Receipt = Join-Path $Root 'security-scan-receipt.json'
[void](New-Item -ItemType Directory -Path $Root -Force)

function Hex([uint32]$Value) { return ('0x{0:x8}' -f $Value) }
function Read-U16([byte[]]$Bytes, [int]$Offset) { return [BitConverter]::ToUInt16($Bytes, $Offset) }
function Read-U32([byte[]]$Bytes, [int]$Offset) { return [BitConverter]::ToUInt32($Bytes, $Offset) }
function Safe-Property($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) { return $null }
    return $Property.Value
}

$Report = [ordered]@{
    schema_version = 1
    purpose = 'independent_native_windows_antivirus_scan'
    artifact_url = $ArtifactUrl
    expected_sha256 = $ExpectedSha256
    runner = [ordered]@{
        os = [Environment]::OSVersion.VersionString
        powershell = $PSVersionTable.PSVersion.ToString()
        github_repository = $env:GITHUB_REPOSITORY
        github_run_id = $env:GITHUB_RUN_ID
        github_sha = $env:GITHUB_SHA
    }
    artifact = $null
    defender = $null
    scan = $null
    verdict = 'scan_not_completed'
}

try {
    Invoke-WebRequest -UseBasicParsing -Uri $ArtifactUrl -OutFile $Bin -TimeoutSec 120
    $ActualSha = (Get-FileHash -LiteralPath $Bin -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha -ne $ExpectedSha256) { throw ('Artifact hash mismatch: ' + $ActualSha) }

    $Bytes = [IO.File]::ReadAllBytes($Bin)
    if ($Bytes.Length -lt 512 -or $Bytes[0] -ne 0x4d -or $Bytes[1] -ne 0x5a) { throw 'Not a valid MZ executable' }
    $PeOffset = [int](Read-U32 $Bytes 0x3c)
    if ((Read-U32 $Bytes $PeOffset) -ne 0x00004550) { throw 'Missing PE signature' }
    $Machine = Read-U16 $Bytes ($PeOffset + 4)
    $OptionalOffset = $PeOffset + 24
    $OptionalMagic = Read-U16 $Bytes $OptionalOffset
    if ($OptionalMagic -eq 0x20b) { $DataDirectoryOffset = $OptionalOffset + 112 }
    elseif ($OptionalMagic -eq 0x10b) { $DataDirectoryOffset = $OptionalOffset + 96 }
    else { throw ('Unknown optional header magic: ' + (Hex $OptionalMagic)) }
    $SecurityRva = Read-U32 $Bytes ($DataDirectoryOffset + (4 * 8))
    $SecuritySize = Read-U32 $Bytes ($DataDirectoryOffset + (4 * 8) + 4)
    $ClrRva = Read-U32 $Bytes ($DataDirectoryOffset + (14 * 8))
    $ClrSize = Read-U32 $Bytes ($DataDirectoryOffset + (14 * 8) + 4)
    $Signature = Get-AuthenticodeSignature -LiteralPath $Bin
    $Report.artifact = [ordered]@{
        sha256 = $ActualSha
        bytes = $Bytes.Length
        pe_machine = (Hex $Machine)
        pe_optional_magic = (Hex $OptionalMagic)
        clr_runtime_rva = (Hex $ClrRva)
        clr_runtime_size = $ClrSize
        authenticode_directory_rva = (Hex $SecurityRva)
        authenticode_directory_size = $SecuritySize
        authenticode_status = [string]$Signature.Status
        authenticode_subject = if ($null -ne $Signature.SignerCertificate) { $Signature.SignerCertificate.Subject } else { $null }
    }

    $Status = $null
    $StatusError = $null
    try { $Status = Get-MpComputerStatus }
    catch { $StatusError = $_.Exception.Message }
    $Report.defender = [ordered]@{
        cmdlets_available = [bool](Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)
        status_error = $StatusError
        am_service_enabled = Safe-Property $Status 'AMServiceEnabled'
        antivirus_enabled = Safe-Property $Status 'AntivirusEnabled'
        antispyware_enabled = Safe-Property $Status 'AntispywareEnabled'
        real_time_protection_enabled = Safe-Property $Status 'RealTimeProtectionEnabled'
        behavior_monitor_enabled = Safe-Property $Status 'BehaviorMonitorEnabled'
        antivirus_signature_version = Safe-Property $Status 'AntivirusSignatureVersion'
        antivirus_signature_last_updated = Safe-Property $Status 'AntivirusSignatureLastUpdated'
        engine_version = Safe-Property $Status 'AMEngineVersion'
        product_version = Safe-Property $Status 'AMProductVersion'
    }

    if ($null -eq $Status -or -not [bool](Safe-Property $Status 'AntivirusEnabled')) {
        $Report.verdict = 'defender_unavailable'
    }
    else {
        $UpdateError = $null
        try { Update-MpSignature -ErrorAction Stop }
        catch { $UpdateError = $_.Exception.Message }

        $Before = @(Get-MpThreatDetection -ErrorAction SilentlyContinue)
        $ScanError = $null
        $ScanStarted = Get-Date
        try { Start-MpScan -ScanType CustomScan -ScanPath $Bin -ErrorAction Stop }
        catch { $ScanError = $_.Exception.Message }
        $After = @(Get-MpThreatDetection -ErrorAction SilentlyContinue)
        $ThreatNames = @{}
        foreach ($Threat in @(Get-MpThreat -ErrorAction SilentlyContinue)) {
            $ThreatNames[[string](Safe-Property $Threat 'ThreatID')] = Safe-Property $Threat 'ThreatName'
        }
        $Relevant = @($After | Where-Object {
            $Resources = @($_.Resources | ForEach-Object { [string]$_ })
            ($Resources -join "`n") -like ('*' + $Bin + '*')
        })
        $Detections = @($Relevant | ForEach-Object {
            $ThreatId = Safe-Property $_ 'ThreatID'
            [ordered]@{
                threat_id = $ThreatId
                threat_name = $ThreatNames[[string]$ThreatId]
                threat_status_id = Safe-Property $_ 'ThreatStatusID'
                action_success = Safe-Property $_ 'ActionSuccess'
                initial_detection_time = Safe-Property $_ 'InitialDetectionTime'
                last_threat_status_change_time = Safe-Property $_ 'LastThreatStatusChangeTime'
                resources = @(Safe-Property $_ 'Resources' | ForEach-Object { [string]$_ })
            }
        })
        $Report.scan = [ordered]@{
            signature_update_error = $UpdateError
            started_at = $ScanStarted.ToUniversalTime().ToString('o')
            scan_error = $ScanError
            detections_before_count = $Before.Count
            detections_after_count = $After.Count
            relevant_detections = $Detections
            file_exists_after_scan = Test-Path -LiteralPath $Bin
        }
        if ($null -ne $ScanError) { $Report.verdict = 'scan_failed' }
        elseif ($Relevant.Count -gt 0) { $Report.verdict = 'defender_detected'
        } else { $Report.verdict = 'defender_no_detection' }
    }
}
catch {
    $Report.verdict = 'verification_failed'
    $Report['error'] = $_.Exception.Message
}
finally {
    $Report['completed_at'] = [DateTimeOffset]::UtcNow.ToString('o')
    $Json = $Report | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($Receipt, $Json, (New-Object Text.UTF8Encoding($false)))
    Write-Host $Json
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value ('verdict=' + $Report.verdict) }
}

if ($Report.verdict -in @('verification_failed', 'scan_failed', 'scan_not_completed')) { exit 2 }
