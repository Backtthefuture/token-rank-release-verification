param([string]$Site='https://kaifa.zhenganhuo.com')
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$Config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release-config.json') -Raw | ConvertFrom-Json
$Expected=[string]$Config.sha256
$Version=[string]$Config.version
$Commit=[string]$Config.commit
$Previous='42e6ac85ccf6899738be81b7e33baf018fa4450dd68986d8945544419780f664'
$CandidateUrl=$Site+[string]$Config.candidate_artifact_url
$TestArtifactUrl=$Site+[string]$Config.test_artifact_url
$PreviousUrl=[string]$Config.previous_artifact_url
$LocalSite='http://127.0.0.1:8765'
$Root=Join-Path $env:RUNNER_TEMP ('Token Rank '+[char]0x4e2d+[char]0x6587+' acceptance')
[void](New-Item -ItemType Directory -Path $Root -Force)
$Utf8=New-Object Text.UTF8Encoding($true)
$Results=New-Object 'System.Collections.Generic.List[object]'
$env:POWERSHELL_TELEMETRY_OPTOUT='1'
$env:TOKEN_RANK_DATA_DIR=Join-Path $Root 'data'
Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
$env:CODEX_CONFIG_DIR=Join-Path $Root 'empty-codex'
[void](New-Item -ItemType Directory -Path $env:TOKEN_RANK_DATA_DIR,$env:CODEX_CONFIG_DIR -Force)
$NativePowerShell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$Bin=Join-Path $Root 'token-rank.exe'
function Assert([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Digest([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function WriteText([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text,$Utf8) }
function Run([string]$Name,[string]$Program,[string[]]$Arguments,[int]$Timeout=120) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Program
    foreach($arg in $Arguments){Assert (-not $arg.Contains('"')) 'Unexpected quote in test argument'}
    $info.Arguments=($Arguments | ForEach-Object {'"'+$_+'"'}) -join ' '
    $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try {
        [void]$process.Start();$handle=$process.Handle
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($Timeout*1000)){ $process.Kill();throw ('Timeout: '+$Name) }
        $process.WaitForExit();Assert ($null -ne $process.ExitCode) 'Missing process exit code'
        $result=[ordered]@{name=$Name;exit=$process.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        WriteText (Join-Path $Root ($Name+'.json')) ($result|ConvertTo-Json -Depth 15)
        $Results.Add(@{name=$Name;exit=$result.exit})
        Write-Output -InputObject $result
    } finally { $process.Dispose() }
}
function ParseScript([string]$Path) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) ('PowerShell parse failure: '+$Path)
    return $ast
}
function Counts($inputCount,$cached,$outputCount,$reasoning){
    return @{input_tokens=$inputCount;cached_input_tokens=$cached;cache_write_input_tokens=0;output_tokens=$outputCount;reasoning_output_tokens=$reasoning;total_tokens=($inputCount+$outputCount)}
}
function ScanFixture([string]$Name,[bool]$Duplicate,[bool]$Gap,[bool]$Paged=$false,[bool]$Upstream=$false,[bool]$Estimated=$false) {
    $case=Join-Path $Root $Name;$sessions=Join-Path $case 'sessions'
    [void](New-Item -ItemType Directory -Path $sessions -Force)
    $env:CODEX_CONFIG_DIR=$case
    $thread='11111111-1111-4111-8111-111111111111';$parent='22222222-2222-4222-8222-222222222222'
    $ts=[DateTimeOffset]::UtcNow.AddMinutes(-10).ToUnixTimeMilliseconds()
    $first=Counts 1000000 10000 159276 1000;$second=Counts 90000 9000 4975 500;$total=Counts 1090000 19000 164251 1500
    if($Gap){$total.input_tokens++;$total.total_tokens++}
    $rows=@(
        @{timestamp=($ts-2000);type='session_meta';payload=@{id=$thread;parent_thread_id=$parent}},
        @{timestamp=($ts-1000);type='turn_context';payload=@{model='test-model'}},
        @{timestamp=$ts;type='token_usage_record';payload=@{thread_id=$thread;session_id=$parent;response_id='first';usage=$first;thread_token_usage=$first}},
        @{timestamp=($ts+1000);type='event_msg';payload=@{type='token_count';info=@{last_token_usage=$first;total_token_usage=$first}}},
        @{timestamp=($ts+2000);type='token_usage_record';payload=@{thread_id=$thread;session_id=$parent;response_id='second';usage=$second;thread_token_usage=$total}}
    )
    if($Duplicate){$rows+=,$rows[-1]}
    $rows+=,@{timestamp=($ts+3000);type='event_msg';payload=@{type='token_count';info=@{last_token_usage=$second;total_token_usage=$second}}}
    if($Estimated){
        $rows[3].payload.info.last_token_usage=@{input_tokens=0;cached_input_tokens=0;output_tokens=0;reasoning_output_tokens=0;total_tokens=777}
        $rows[-1].payload.info.last_token_usage=@{input_tokens=0;cached_input_tokens=0;output_tokens=0;reasoning_output_tokens=0;total_tokens=999}
        $rows[-1].payload.info.total_token_usage=$total
    }
    $path=Join-Path $sessions ('rollout-'+$thread+'.jsonl')
    [IO.File]::WriteAllText($path,(($rows|ForEach-Object {$_|ConvertTo-Json -Depth 15 -Compress}) -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
    $secondPath=$null;$secondBefore=$null
    if($Paged){
        $rows[0].payload.history_mode='paginated';$rows[0].payload.session_id=$thread
        $firstRows=@($rows[0..3])
        $pageRows=@(
            @{timestamp=($ts+1500);type='session_meta';payload=@{id=$thread;session_id=$thread;history_mode='paginated';parent_thread_id=$parent;history_base=@{thread_id=$thread;end_ordinal_exclusive=86;end_byte_offset=1564981}}},
            @{timestamp=($ts+1600);type='turn_context';payload=@{model='test-model'}}
        ) + @($rows[4..($rows.Count-1)])
        $secondPath=Join-Path $sessions 'rollout-33333333-3333-4333-8333-333333333333.jsonl'
        [IO.File]::WriteAllText($path,(($firstRows|ForEach-Object {$_|ConvertTo-Json -Depth 15 -Compress}) -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($secondPath,(($pageRows|ForEach-Object {$_|ConvertTo-Json -Depth 15 -Compress}) -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
        if($Upstream){
            $firstRows[0].payload.session_id=$parent;$pageRows[0].payload.session_id=$parent
            Remove-Item -LiteralPath $secondPath
            $secondPath=Join-Path $sessions ('rollout-'+$thread+'_33333333-3333-4333-8333-333333333333.jsonl')
            [IO.File]::WriteAllText($path,(($firstRows|ForEach-Object {$_|ConvertTo-Json -Depth 15 -Compress}) -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($secondPath,(($pageRows|ForEach-Object {$_|ConvertTo-Json -Depth 15 -Compress}) -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
        }
        $secondBefore=Digest $secondPath
    }
    $before=Digest $path
    foreach($pass in @(1,2)){
        $run=Run ($Name+'-'+$pass) $Bin @('scan','--client','codex','--days','30','--json')
        $expectedExit=0;if($Gap){$expectedExit=22}
        Assert ($run.exit -eq $expectedExit) ('Unexpected scan exit: '+$Name+'/'+$run.exit)
        $scan=$run.stdout|ConvertFrom-Json
        if($Gap){
            Assert (@($scan.sources.codex.blocked_dates).Count -gt 0) 'Counter gap was not held'
            Assert ($run.stdout.Contains('ledger_thread_discontinuity')) 'Missing exact gap diagnostic'
            Assert (@($scan.hourly_model).Count -eq 0 -and @($scan.sessions).Count -eq 0) 'Blocked date emitted uploadable rows'
        }else{
            Assert (@($scan.sources.codex.blocked_dates | Where-Object { $null -ne $_ }).Count -eq 0) 'Unexpected blocked date'
            Assert ($scan.sources.codex.status -eq 'ready' -and @($scan.sources.codex.verified_dates).Count -gt 0) 'Verified coverage was not reported'
            $hour=($scan.hourly_model|Measure-Object -Property total_tokens -Sum).Sum
            $session=($scan.sessions|Measure-Object -Property total_tokens -Sum).Sum
            Assert ($hour -eq 1254251 -and $session -eq 1254251) ('Incorrect accounting: '+$hour+'/'+$session)
        }
        Assert ((Digest $path) -eq $before) 'Scan modified original fixture'
        if($Paged){Assert ((Digest $secondPath) -eq $secondBefore) 'Scan modified continuation fixture'}
    }
    Assert (-not (Test-Path (Join-Path $env:TOKEN_RANK_DATA_DIR 'client-state.json'))) 'Account state created by read-only scan'
}
$TaskCreated=$false
$ServerProcess=$null
try {
    Invoke-WebRequest -UseBasicParsing -Uri $CandidateUrl -OutFile $Bin -TimeoutSec 120
    Assert ((Digest $Bin) -eq $Expected) 'Candidate hash mismatch'
    $SignatureStatus=[string](Get-AuthenticodeSignature -LiteralPath $Bin).Status
    Assert ((Digest (Join-Path $PSScriptRoot 'manifest-v1.json')) -eq [string]$Config.validation_manifest_sha256) 'Validation manifest hash mismatch'
    Assert ((Digest (Join-Path $PSScriptRoot 'manifest-v1.json.sig')) -eq [string]$Config.validation_signature_sha256) 'Validation signature hash mismatch'
    $ValidationManifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest-v1.json') -Raw|ConvertFrom-Json
    Assert ($ValidationManifest.channel -eq 'validation') 'Validation channel mismatch'
    $WindowsRelease=$ValidationManifest.releases|Where-Object {$_.target -eq 'x86_64-pc-windows-msvc'}
    Assert ($WindowsRelease.sha256 -eq $Expected -and $WindowsRelease.rollout_percent -eq 100) 'Validation release mismatch'
    $ServerRoot=Join-Path $env:RUNNER_TEMP 'token-rank-validation-site'
    $ServerDl=Join-Path $ServerRoot 'token-rank/dl'
    [void](New-Item -ItemType Directory -Path $ServerDl -Force)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'manifest-v1.json') -Destination (Join-Path $ServerDl 'manifest-v1.json')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'manifest-v1.json.sig') -Destination (Join-Path $ServerDl 'manifest-v1.json.sig')
    $RelativeArtifact=([string]$WindowsRelease.artifact_url).TrimStart('/').Replace('/',[IO.Path]::DirectorySeparatorChar)
    $LocalArtifact=Join-Path $ServerRoot $RelativeArtifact
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $LocalArtifact) -Force)
    Copy-Item -LiteralPath $Bin -Destination $LocalArtifact
    $Python=(Get-Command python).Source
    $ServerProcess=Start-Process -FilePath $Python -ArgumentList @('-m','http.server','8765','--bind','127.0.0.1','--directory',$ServerRoot) -PassThru -WindowStyle Hidden
    $ServerReady=$false
    foreach($attempt in 1..20){try{$null=Invoke-WebRequest -UseBasicParsing -Uri ($LocalSite+'/token-rank/dl/manifest-v1.json') -TimeoutSec 3;$ServerReady=$true;break}catch{Start-Sleep -Seconds 1}}
    Assert $ServerReady 'Local signed validation server did not start'
    $identity=Run 'version' $Bin @('version','--json');$v=$identity.stdout|ConvertFrom-Json
    Assert ($identity.exit -eq 0 -and $v.version -eq $Version -and $v.commit -eq $Commit -and $v.target -eq 'x86_64-pc-windows-msvc') 'Candidate identity mismatch'
    $keyring=Run 'keyring' $Bin @('update','verify-keyring','--json');$keys=$keyring.stdout|ConvertFrom-Json
    Assert ($keyring.exit -eq 0 -and $keys.status -eq 'ready' -and $keys.key_count -eq 2) 'Keyring mismatch'
    ScanFixture 'normal' $false $false
    ScanFixture 'duplicate' $true $false
    ScanFixture 'gap' $false $true
    ScanFixture 'paged-normal' $false $false $true
    ScanFixture 'paged-duplicate' $true $false $true
    ScanFixture 'paged-gap' $false $true $true
    ScanFixture 'subagent-normal' $false $false $true $true
    ScanFixture 'subagent-duplicate' $true $false $true $true
    ScanFixture 'subagent-gap' $false $true $true $true
    ScanFixture 'estimated-normal' $false $false $false $false $true
    ScanFixture 'estimated-duplicate' $true $false $false $false $true
    ScanFixture 'estimated-gap' $false $true $false $false $true
    $installScript=Join-Path $Root 'install.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri ($Site+'/token-rank/install.ps1') -OutFile $installScript -TimeoutSec 45
    $null=ParseScript $installScript
    $old=Join-Path $Root 'previous.exe'
    Invoke-WebRequest -UseBasicParsing -Uri $PreviousUrl -OutFile $old -TimeoutSec 120
    Assert ((Digest $old) -eq $Previous) 'Previous release hash mismatch'
    $env:TOKEN_RANK_DATA_DIR=Join-Path $Root 'upgrade data'
    $env:CODEX_CONFIG_DIR=Join-Path $Root 'empty-codex'
    [void](New-Item -ItemType Directory -Path $env:TOKEN_RANK_DATA_DIR -Force)
    Assert (-not (Get-ScheduledTask -TaskName TokenRankSync -ErrorAction SilentlyContinue)) 'Unexpected pre-existing task on disposable runner'
    $service=Run 'service-install' $Bin @('service','install','--site',$LocalSite,'--interval','1800')
    $TaskCreated=$true
    $taskQuery=Run 'task-query' (Join-Path $env:WINDIR 'System32/schtasks.exe') @('/Query','/TN','TokenRankSync','/XML')
    $taskExport=Export-ScheduledTask -TaskName TokenRankSync
    WriteText (Join-Path $Root 'task-xml.json') (@{expected=[IO.File]::ReadAllText((Join-Path $env:TOKEN_RANK_DATA_DIR 'token-rank-task.xml'));actual=$taskExport}|ConvertTo-Json -Depth 5)
    Assert ($service.exit -eq 0) 'Native task installation failed'
    $task=Get-ScheduledTask -TaskName TokenRankSync
    Assert ($task.Actions.Execute -match 'wscript.exe') 'Unexpected task launcher'
    Disable-ScheduledTask -TaskName TokenRankSync | Out-Null
    $wrapper=Join-Path $env:TOKEN_RANK_DATA_DIR 'token-rank-sync.ps1'
    $ast=ParseScript $wrapper
    $original=[IO.File]::ReadAllText($wrapper)
    $helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-TokenRankUpdateCommand'},$true).Extent.Text
    Assert (-not [string]::IsNullOrWhiteSpace($helper)) 'Generated update helper missing'
    foreach($kind in @('update','sync')){
        $codes=@(0,7);if($kind -eq 'update'){$codes=@(0,7,80)}
        foreach($code in $codes){
            $stub=Join-Path $Root ($kind+'-'+$code+'.cmd');$log=Join-Path $Root ($kind+'-'+$code+'.log');$invoke=Join-Path $Root ($kind+'-'+$code+'.ps1')
            [IO.File]::WriteAllText($stub,"@echo off`r`necho harmless-fixture-stderr 1>&2`r`nexit /b $code`r`n",[Text.Encoding]::ASCII)
            if($kind -eq 'update'){
                $body="`$ErrorActionPreference='Stop'`n`$LogPath='$log'`n"+$helper+"`ntry { `$code=Invoke-TokenRankUpdateCommand -Program '$stub' -Arguments @('update','stage','--json'); if (`$ErrorActionPreference -ne 'Stop') { exit 98 }; exit `$code } catch { exit 99 }"
            }else{
                $body=$original.Replace("`$Bin = '$Bin'","`$Bin = '$stub'").Replace("`$UpdatesEnabled = `$true","`$UpdatesEnabled = `$false").Replace("`$LogPath = '"+(Join-Path $env:TOKEN_RANK_DATA_DIR 'sync.log')+"'","`$LogPath = '$log'")
                Assert ($body.Contains("`$Bin = '$stub'")) 'Test binding replacement failed'
            }
            WriteText $invoke $body
            $run=Run ($kind+'-exit-'+$code) $NativePowerShell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$invoke)
            Assert ($run.exit -eq $code) ('Native PowerShell exit code mismatch: '+$kind+'/'+$code+'/'+$run.exit)
            Assert ((Get-Content -LiteralPath $log -Raw).Contains('harmless-fixture-stderr')) 'Native stderr was lost'
        }
    }
    $newWrapperHash=Digest $wrapper
    Copy-Item -LiteralPath $old -Destination $Bin -Force
    $legacyService=Run 'legacy-service-install' $Bin @('service','install','--site',$LocalSite,'--interval','1800')
    Assert ($legacyService.exit -eq 1 -and $legacyService.stderr.Contains('read-back validation failed')) 'Legacy reproduction changed unexpectedly'
    Disable-ScheduledTask -TaskName TokenRankSync | Out-Null
    Assert ((Digest $wrapper) -eq $newWrapperHash) 'The installed legacy updater differs from the fixed release updater'
    $stage=Run 'signed-stage' $Bin @('update','stage','--site',$LocalSite,'--channel','validation','--json')
    Assert ($stage.exit -eq 80) 'Signed candidate did not stage'
    $pending=Get-Content -LiteralPath (Join-Path $env:TOKEN_RANK_DATA_DIR 'pending-update.json') -Raw|ConvertFrom-Json
    Assert ($pending.artifact_sha256 -eq $Expected) 'Staged hash mismatch'
    $wrapperRun=Run 'native-wrapper' $NativePowerShell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$wrapper) 240
    Assert ((Digest $Bin) -eq $Expected) 'Native wrapper did not promote candidate'
    Assert ((Digest ($Bin+'.previous')) -eq $Previous) 'Previous binary was not retained'
    Assert ((Get-Content -LiteralPath (Join-Path $env:TOKEN_RANK_DATA_DIR 'sync.log') -Raw).Contains('Signed update promoted')) 'Missing successful post-update check'
    $after=Run 'after-upgrade' $Bin @('version','--json');$identity=$after.stdout|ConvertFrom-Json
    Assert ($after.exit -eq 0 -and $identity.version -eq $Version -and $identity.commit -eq $Commit) 'Upgraded identity mismatch'
    $again=Run 'no-update' $Bin @('update','stage','--site',$LocalSite,'--channel','validation','--json')
    Assert ($again.exit -eq 0 -and ($again.stdout|ConvertFrom-Json).status -eq 'no_update') 'Second update was not a no-op'
    Assert (-not (Test-Path (Join-Path $env:TOKEN_RANK_DATA_DIR 'client-state.json'))) 'Account unexpectedly created'
    $sixty=Run 'service-install-60' $Bin @('service','install','--site',$LocalSite,'--interval','3600')
    Assert ($sixty.exit -eq 0) 'Normalized one-hour task readback failed'
    Disable-ScheduledTask -TaskName TokenRankSync | Out-Null
    $testBinary=Join-Path $Root 'token-rank-tests.exe'
    Invoke-WebRequest -UseBasicParsing -Uri $TestArtifactUrl -OutFile $testBinary -TimeoutSec 120
    Assert ((Digest $testBinary) -eq [string]$Config.test_sha256) 'Native test executable hash mismatch'
    $unit=Run 'native-task-unit-tests' $testBinary @('windows_task','--nocapture')
    Assert ($unit.exit -eq 0 -and $unit.stdout.Contains('3 passed; 0 failed')) 'Native scheduler unit regressions failed'
    $pagesUnit=Run 'native-pages-unit-tests' $testBinary @('codex_pages::tests','--nocapture')
    Assert ($pagesUnit.exit -eq 0 -and $pagesUnit.stdout.Contains('13 passed; 0 failed')) 'Native page accounting regressions failed'
    $estimateUnit=Run 'native-estimate-unit-tests' $testBinary @('estimated_notification','--nocapture')
    Assert ($estimateUnit.exit -eq 0 -and $estimateUnit.stdout.Contains('5 passed; 0 failed')) 'Native estimated notification regressions failed'
    $ledgerUnit=Run 'native-ledger-unit-tests' $testBinary @('codex_ledger::tests','--nocapture')
    Assert ($ledgerUnit.exit -eq 0 -and $ledgerUnit.stdout.Contains('22 passed; 0 failed')) 'Native ledger diagnostics regressions failed'
    $healthUnit=Run 'native-health-unit-tests' $testBinary @('source_health_reports_bounded_dates_and_known_codes_without_file_details','--nocapture')
    Assert ($healthUnit.exit -eq 0 -and $healthUnit.stdout.Contains('1 passed; 0 failed')) 'Native source health privacy regression failed'
    $report=@{version=$Version;status='native_windows_passed_unsigned_release_blocked';os=[Environment]::OSVersion.VersionString;powershell=$PSVersionTable.PSVersion.ToString();native_wrapper_powershell='Windows PowerShell 5.1';sha256=$Expected;commit=$Commit;checks=$Results;wrapper_final_exit_without_account=$wrapperRun.exit;real_user_data_used=$false;authenticode_status=$SignatureStatus;release_allowed=$false;validation_channel='validation'}
    WriteText (Join-Path $Root 'receipt.json') ($report|ConvertTo-Json -Depth 12)
    Write-Host ($report|ConvertTo-Json -Depth 12 -Compress)
} finally {
    if($TaskCreated){Unregister-ScheduledTask -TaskName TokenRankSync -Confirm:$false -ErrorAction SilentlyContinue}
    if($null -ne $ServerProcess -and -not $ServerProcess.HasExited){Stop-Process -Id $ServerProcess.Id -Force -ErrorAction SilentlyContinue}
    Assert (-not (Get-ScheduledTask -TaskName TokenRankSync -ErrorAction SilentlyContinue)) 'Temporary scheduled task remained'
    foreach($file in Get-ChildItem -LiteralPath $Root -Filter '*.json'){
        Write-Host ('=== '+$file.Name+' ===');Write-Host ([IO.File]::ReadAllText($file.FullName))
    }
    $log=Join-Path $env:TOKEN_RANK_DATA_DIR 'sync.log';if(Test-Path $log){Write-Host '=== wrapper sync log ===';Write-Host ([IO.File]::ReadAllText($log))}
}
