# M365 RecoveryGuard - self-healing SharePoint recycle-bin recovery engine
#
# Sanitized reference implementation derived from a real-world recovery architecture.
# No tenant URLs, customer names, user identities, production GUIDs, credentials,
# incident manifests, or production logs are included in this repository.
#
# IMPORTANT:
# - Review and test in a non-production tenant before use.
# - Recovery writes are intentionally gated.
# - Use least-privilege access appropriate to your environment.
#
#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Supervisor','Worker','Probe','Reconcile','Report','SelfTest','SelfTestWorker','ArmCheck')]
    [string]$Mode = 'Supervisor',
    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Config($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing config: $Path" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30
}

function Get-ConfigValue($Object,[string]$Name,$Default) {
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        $v=$Object.$Name
        if ($null -ne $v -and -not ([string]$v -eq '')) { return $v }
    }
    return $Default
}

function Ensure-Dir($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path -Force) }
}

function Write-JsonAtomic($Object,$Path) {
    Ensure-Dir (Split-Path -Parent $Path)
    $tmp = "$Path.tmp.$PID"
    $Object | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonSafe($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 30 } catch { $null }
}

function Append-JsonLine($Object,$Path) {
    Ensure-Dir (Split-Path -Parent $Path)
    Add-Content -LiteralPath $Path -Value ($Object | ConvertTo-Json -Depth 20 -Compress) -Encoding UTF8
}

function Get-Paths($Config) {
    $s = [string]$Config.Paths.StateDirectory
    Ensure-Dir $s
    [pscustomobject]@{
        StateDirectory=$s
        Checkpoint=(Join-Path $s 'checkpoint.json')
        Heartbeat=(Join-Path $s 'worker-heartbeat.json')
        Inflight=(Join-Path $s 'inflight.json')
        PauseFlag=(Join-Path $s 'pause.requested')
        Events=(Join-Path $s 'events.jsonl')
        Results=(Join-Path $s 'terminal-results.csv')
        Health=(Join-Path $s 'health.csv')
        Reconciliation=(Join-Path $s 'reconciliation.csv')
        ProbeResult=(Join-Path $s 'probe-result.json')
        ReconcileResult=(Join-Path $s 'reconcile-result.json')
        FinalSummary=(Join-Path $s 'final-summary.json')
        SelfTestDirectory=(Join-Path $s '_selftest')
        SelfTestResult=(Join-Path $s 'selftest-result.json')
        SupervisorPid=(Join-Path $s 'supervisor.pid')
        WorkerPid=(Join-Path $s 'worker.pid')
    }
}

function Write-Event($Paths,[string]$Type,[string]$Message,$Data=$null) {
    Append-JsonLine ([ordered]@{Timestamp=(Get-Date).ToString('o');Type=$Type;Message=$Message;Data=$Data}) $Paths.Events
}

function Escape-Csv($v) { if($null -eq $v){'""'}else{'"'+([string]$v).Replace('"','""')+'"'} }
function Append-CsvRow($Path,$Headers,$Values) {
    if (-not (Test-Path -LiteralPath $Path)) { ($Headers -join ',') | Set-Content -LiteralPath $Path -Encoding UTF8 }
    (($Values | ForEach-Object { Escape-Csv $_ }) -join ',') | Add-Content -LiteralPath $Path -Encoding UTF8
}

function Get-RowGuid($Row) {
    foreach($n in @('RecycleBinId','Id','GUID','Guid')){if($Row.PSObject.Properties.Name -contains $n){$v=[string]$Row.$n;if(-not[string]::IsNullOrWhiteSpace($v)){return $v.Trim().ToLowerInvariant()}}};$null
}
function Get-RowDestination($Row) {
    if($Row.PSObject.Properties.Name -contains 'Destination'){$d=[string]$Row.Destination;if(-not[string]::IsNullOrWhiteSpace($d)){return $d.Trim()}}
    $dir=[string]$Row.DirName;$leaf=[string]$Row.LeafName;if([string]::IsNullOrWhiteSpace($leaf)){$leaf=[string]$Row.Title};if([string]::IsNullOrWhiteSpace($dir)-or[string]::IsNullOrWhiteSpace($leaf)){return $null};$dir=$dir.Trim();if(-not$dir.StartsWith('/')){$dir='/'+$dir};$dir.TrimEnd('/')+'/'+$leaf.TrimStart('/')
}
function Get-OriginalSequence($Row,[int]$Index,$Config) {
    if($Row.PSObject.Properties.Name -contains 'OriginalSequence' -and -not[string]::IsNullOrWhiteSpace([string]$Row.OriginalSequence)){return [int]$Row.OriginalSequence};[int](Get-ConfigValue $Config.Recovery 'OriginalSequenceBase' 1)+$Index
}

function Get-QueueHash($Config) {
    $p=[string]$Config.Paths.QueueCsv
    if(-not(Test-Path -LiteralPath $p)){throw "Queue CSV missing: $p"}
    (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-EngineHash {
    if ([string]::IsNullOrWhiteSpace([string]$PSCommandPath) -or
        -not (Test-Path -LiteralPath $PSCommandPath)) {
        throw 'Unable to resolve current engine path for SHA256 validation.'
    }
    (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-ArmTimestamp($Arm) {
    $raw=[string](Get-ConfigValue $Arm 'ApprovedAtUtc' '')
    if([string]::IsNullOrWhiteSpace($raw)){throw 'WRITE GATE CLOSED: arm approval timestamp missing.'}
    $dto=[datetimeoffset]::MinValue
    if(-not [datetimeoffset]::TryParse($raw,[ref]$dto)){throw 'WRITE GATE CLOSED: arm approval timestamp is invalid.'}
    if($dto.ToUniversalTime() -gt [datetimeoffset]::UtcNow.AddMinutes(5)){throw 'WRITE GATE CLOSED: arm approval timestamp is in the future.'}
    $dto
}

function Assert-QueueSafety($Config) {
    $queue=@(Import-Csv -LiteralPath ([string]$Config.Paths.QueueCsv))
    if($queue.Count -lt 1){throw 'Queue is empty.'}
    $s=$Config.Safety
    $expectedCount=[int](Get-ConfigValue $s 'ExpectedQueueCount' $queue.Count)
    $expectedFirst=[int](Get-ConfigValue $s 'ExpectedFirstSequence' (Get-OriginalSequence $queue[0] 0 $Config))
    $expectedLast=[int](Get-ConfigValue $s 'ExpectedLastSequence' (Get-OriginalSequence $queue[-1] ($queue.Count-1) $Config))
    $expectedFirstGuid=[string](Get-ConfigValue $s 'ExpectedFirstGuid' (Get-RowGuid $queue[0]))
    $expectedHash=[string](Get-ConfigValue $s 'QueueSha256' '')
    $actualHash=Get-QueueHash $Config
    if($queue.Count -ne $expectedCount){throw "Safety envelope failed: queue count $($queue.Count) != $expectedCount"}
    if((Get-OriginalSequence $queue[0] 0 $Config) -ne $expectedFirst){throw 'Safety envelope failed: first sequence mismatch.'}
    if((Get-OriginalSequence $queue[-1] ($queue.Count-1) $Config) -ne $expectedLast){throw 'Safety envelope failed: last sequence mismatch.'}
    if((Get-RowGuid $queue[0]) -ne $expectedFirstGuid.ToLowerInvariant()){throw 'Safety envelope failed: first GUID mismatch.'}
    if(-not[string]::IsNullOrWhiteSpace($expectedHash) -and $actualHash -ne $expectedHash.ToLowerInvariant()){throw 'Safety envelope failed: queue SHA256 changed.'}
    [pscustomobject]@{Count=$queue.Count;FirstSequence=$expectedFirst;LastSequence=$expectedLast;FirstGuid=(Get-RowGuid $queue[0]);QueueSha256=$actualHash}
}

function Assert-WriteArmed($Config) {
    $s=$Config.Safety
    $enabled=[bool](Get-ConfigValue $s 'WriteEnabled' $false)
    if(-not $enabled){throw 'WRITE GATE CLOSED: Safety.WriteEnabled is false.'}

    $arm=[string](Get-ConfigValue $s 'ArmFile' '')
    if([string]::IsNullOrWhiteSpace($arm) -or -not(Test-Path -LiteralPath $arm)){
        throw 'WRITE GATE CLOSED: valid Safety.ArmFile is required.'
    }

    $a=Read-JsonSafe $arm
    if($null -eq $a -or -not[bool](Get-ConfigValue $a 'Approved' $false)){
        throw 'WRITE GATE CLOSED: arm file is not approved.'
    }

    $armId=[string](Get-ConfigValue $a 'ArmId' '')
    $parsedArmId=[guid]::Empty
    if([string]::IsNullOrWhiteSpace($armId) -or -not [guid]::TryParse($armId,[ref]$parsedArmId)){
        throw 'WRITE GATE CLOSED: arm file ArmId is missing or invalid.'
    }

    [void](Assert-ArmTimestamp $a)

    $q=Assert-QueueSafety $Config
    $engineHash=Get-EngineHash
    $expectedEngine=[string](Get-ConfigValue $s 'ExpectedEngineSha256' '')
    if(-not [string]::IsNullOrWhiteSpace($expectedEngine) -and
       $expectedEngine.ToLowerInvariant() -ne $engineHash){
        throw 'WRITE GATE CLOSED: configured expected engine SHA256 mismatch.'
    }

    $armEngine=[string](Get-ConfigValue $a 'EngineSha256' '')
    if([string]::IsNullOrWhiteSpace($armEngine) -or $armEngine.ToLowerInvariant() -ne $engineHash){
        throw 'WRITE GATE CLOSED: arm-file engine SHA256 mismatch.'
    }

    $armQueue=[string](Get-ConfigValue $a 'QueueSha256' '')
    if([string]::IsNullOrWhiteSpace($armQueue) -or $armQueue.ToLowerInvariant() -ne $q.QueueSha256){
        throw 'WRITE GATE CLOSED: arm-file queue SHA256 mismatch.'
    }

    if([int](Get-ConfigValue $a 'QueueCount' -1) -ne [int]$q.Count){
        throw 'WRITE GATE CLOSED: arm-file queue count mismatch.'
    }

    if([int](Get-ConfigValue $a 'FirstSequence' -1) -ne [int]$q.FirstSequence){
        throw 'WRITE GATE CLOSED: arm-file first sequence mismatch.'
    }

    if([int](Get-ConfigValue $a 'LastSequence' -1) -ne [int]$q.LastSequence){
        throw 'WRITE GATE CLOSED: arm-file last sequence mismatch.'
    }

    $armFirstGuid=[string](Get-ConfigValue $a 'FirstGuid' '')
    if([string]::IsNullOrWhiteSpace($armFirstGuid) -or
       $armFirstGuid.ToLowerInvariant() -ne ([string]$q.FirstGuid).ToLowerInvariant()){
        throw 'WRITE GATE CLOSED: arm-file first GUID mismatch.'
    }

    $armSite=[string](Get-ConfigValue $a 'SiteUrl' '')
    $cfgSite=[string]$Config.SharePoint.SiteUrl
    if($armSite.TrimEnd('/').ToLowerInvariant() -ne $cfgSite.TrimEnd('/').ToLowerInvariant()){
        throw 'WRITE GATE CLOSED: arm-file site mismatch.'
    }

    $armVersion=[string](Get-ConfigValue $a 'ProgramVersion' '')
    if($armVersion -ne [string]$Config.ProgramVersion){
        throw 'WRITE GATE CLOSED: arm-file program version mismatch.'
    }

    $armClient=[string](Get-ConfigValue $a 'ClientId' '')
    $cfgClient=[string]$Config.Authentication.ClientId
    if($armClient.ToLowerInvariant() -ne $cfgClient.ToLowerInvariant()){
        throw 'WRITE GATE CLOSED: arm-file ClientId mismatch.'
    }

    $population=[int](Get-ConfigValue $Config.Reporting 'IncidentPopulation' 0)
    if([int](Get-ConfigValue $a 'IncidentPopulation' -1) -ne $population){
        throw 'WRITE GATE CLOSED: arm-file incident population mismatch.'
    }

    [pscustomobject]@{
        Count=$q.Count
        FirstSequence=$q.FirstSequence
        LastSequence=$q.LastSequence
        FirstGuid=$q.FirstGuid
        QueueSha256=$q.QueueSha256
        EngineSha256=$engineHash
        ArmId=$armId
        ApprovedAtUtc=[string]$a.ApprovedAtUtc
        SiteUrl=$cfgSite
        ProgramVersion=[string]$Config.ProgramVersion
        ClientId=$cfgClient
        IncidentPopulation=$population
    }
}

function Write-Heartbeat($Paths,$Phase,$Sequence,$Guid) { Write-JsonAtomic ([ordered]@{Timestamp=(Get-Date).ToString('o');Pid=$PID;Phase=$Phase;Sequence=$Sequence;RecycleBinId=$Guid}) $Paths.Heartbeat }
function Write-Inflight($Paths,$Sequence,$Guid,$Destination,$RestoreInvoked,$Phase) { Write-JsonAtomic ([ordered]@{Timestamp=(Get-Date).ToString('o');Pid=$PID;Sequence=$Sequence;RecycleBinId=$Guid;Destination=$Destination;RestoreInvoked=[bool]$RestoreInvoked;Phase=$Phase}) $Paths.Inflight }
function Clear-Inflight($Paths){if(Test-Path $Paths.Inflight){Remove-Item $Paths.Inflight -Force}}
function Write-Checkpoint($Paths,$NextIndex,$Sequence,$Guid,$Result){Write-JsonAtomic ([ordered]@{Timestamp=(Get-Date).ToString('o');NextIndex=$NextIndex;LastOriginalSequence=$Sequence;LastRecycleBinId=$Guid;LastResult=$Result}) $Paths.Checkpoint}

function Append-Result($Paths,$RunId,$Index,$Sequence,$Guid,$Title,$Destination,$RestoreInvoked,$PreExisting,$Attempt,$Result,$Error,$Duration) {
    $h=@('Timestamp','RunId','LocalIndex','OriginalSequence','RecycleBinId','Title','Destination','RestoreInvoked','PreExistingDestination','Attempt','Result','Error','DurationSeconds','WorkerPid')
    $v=@((Get-Date).ToString('o'),$RunId,$Index,$Sequence,$Guid,$Title,$Destination,$RestoreInvoked,$PreExisting,$Attempt,$Result,$Error,[math]::Round([double]$Duration,3),$PID)
    Append-CsvRow $Paths.Results $h $v
}

function Connect-RecoveryPnP($Config) {
    Import-Module PnP.PowerShell -ErrorAction Stop
    $site=[string]$Config.SharePoint.SiteUrl;$auth=$Config.Authentication;$mode=[string]$auth.Mode;$client=[string]$auth.ClientId
    if($mode -eq 'InteractivePersisted'){Connect-PnPOnline -Url $site -Interactive -PersistLogin -ClientId $client}
    elseif($mode -eq 'CertificateThumbprint'){Connect-PnPOnline -Url $site -Tenant ([string]$auth.Tenant) -ClientId $client -Thumbprint ([string]$auth.CertificateThumbprint)}
    else{throw "Unsupported Authentication.Mode: $mode"}
    $w=Get-PnPWeb -ErrorAction Stop;if($w.Url.TrimEnd('/') -ne $site.TrimEnd('/')){throw "Wrong site: $($w.Url)"};$w
}

function Test-Network($Config){$h=([uri][string]$Config.SharePoint.SiteUrl).Host;$dns=$false;$tcp=$false;$d='';try{Resolve-DnsName $h -ErrorAction Stop|Out-Null;$dns=$true}catch{$d+='DNS '+$_.Exception.Message+';'};try{$t=Test-NetConnection $h -Port 443 -WarningAction SilentlyContinue;$tcp=[bool]$t.TcpTestSucceeded;if(-not$tcp){$d+='TCP443 failed;'}}catch{$d+='TCP '+$_.Exception.Message+';'};[pscustomobject]@{Dns=$dns;Tcp=$tcp;Detail=$d}}
function Test-StateStore($Paths){try{$p=Join-Path $Paths.StateDirectory "state-test-$PID.tmp";$v=[guid]::NewGuid().ToString();Set-Content $p $v -Encoding UTF8;$ok=((Get-Content $p -Raw).Trim()-eq$v);Remove-Item $p -Force;$ok}catch{$false}}
function Test-Database($Config){$db=$Config.Health.Database;if(-not[bool](Get-ConfigValue $db 'Enabled' $false)){return [pscustomobject]@{Healthy=$true;Detail='DISABLED'}};$envName=[string]$db.ConnectionStringEnvVar;$cs=[Environment]::GetEnvironmentVariable($envName);if([string]::IsNullOrWhiteSpace($cs)){return [pscustomobject]@{Healthy=$false;Detail="Missing env $envName"}};try{$cn=[System.Data.SqlClient.SqlConnection]::new($cs);$cn.Open();$cmd=$cn.CreateCommand();$cmd.CommandText='SELECT 1';[void]$cmd.ExecuteScalar();$cn.Close();[pscustomobject]@{Healthy=$true;Detail='SELECT 1 PASS'}}catch{[pscustomobject]@{Healthy=$false;Detail=$_.Exception.Message}}}

function Get-RecycleState($Config,$Guid) {
    try {$o=Get-PnPRecycleBinItem -Identity $Guid -ErrorAction Stop;if($null -ne $o){[pscustomobject]@{State='PRESENT';Detail=''}}else{[pscustomobject]@{State='ABSENT';Detail='NULL'}}}
    catch{$m=[string]$_.Exception.Message;$p=[string]$Config.SharePoint.RecycleAbsentErrorPattern;if(-not[string]::IsNullOrWhiteSpace($p)-and$m -like "*$p*"){[pscustomobject]@{State='ABSENT';Detail=$m}}else{[pscustomobject]@{State='UNKNOWN_ERROR';Detail=$m}}}
}
function Get-DestinationState($Destination){try{$o=Get-PnPFile -Url $Destination -AsListItem -ErrorAction Stop;if($null-ne$o){[pscustomobject]@{State='EXISTS';Detail=''}}else{[pscustomobject]@{State='ABSENT';Detail=''}}}catch{[pscustomobject]@{State='UNKNOWN_ERROR';Detail=$_.Exception.Message}}}

function Reconcile-Inflight($Config,$Paths,$Inflight) {
    $delay=[int](Get-ConfigValue $Config.Supervisor 'ReconcileStabilityDelaySeconds' 5)
    $r1=Get-RecycleState $Config ([string]$Inflight.RecycleBinId);$d1=Get-DestinationState ([string]$Inflight.Destination)
    if($delay -gt 0){Start-Sleep -Seconds $delay}
    $r2=Get-RecycleState $Config ([string]$Inflight.RecycleBinId);$d2=Get-DestinationState ([string]$Inflight.Destination)
    $stable=($r1.State -eq $r2.State -and $d1.State -eq $d2.State)
    if(-not$stable){$c='MANUAL_REVIEW_REQUIRED'}
    elseif($r2.State -eq 'ABSENT' -and $d2.State -eq 'EXISTS'){$c='COMMITTED'}
    elseif($r2.State -eq 'PRESENT' -and $d2.State -eq 'ABSENT'){$c='NOT_COMMITTED'}
    elseif($r2.State -eq 'PRESENT' -and $d2.State -eq 'EXISTS'){$c='CONFLICT'}
    else{$c='MANUAL_REVIEW_REQUIRED'}
    $h=@('Timestamp','Sequence','RecycleBinId','Destination','RecycleState','DestinationState','StableTwoRead','Classification','Detail')
    $v=@((Get-Date).ToString('o'),$Inflight.Sequence,$Inflight.RecycleBinId,$Inflight.Destination,$r2.State,$d2.State,$stable,$c,("R1={0};D1={1};R2={2};D2={3};RD={4};DD={5}" -f $r1.State,$d1.State,$r2.State,$d2.State,$r2.Detail,$d2.Detail))
    Append-CsvRow $Paths.Reconciliation $h $v
    [pscustomobject]@{Classification=$c;RecycleState=$r2.State;DestinationState=$d2.State;Stable=$stable}
}

function Get-HangTimeout($Config,$Paths){$min=[double](Get-ConfigValue $Config.Supervisor 'MinimumHangTimeoutSeconds' 180);$max=[double](Get-ConfigValue $Config.Supervisor 'MaximumHangTimeoutSeconds' 600);$mult=[double](Get-ConfigValue $Config.Supervisor 'P95Multiplier' 12);if(-not(Test-Path $Paths.Results)){return [int]$min};try{$a=@(Import-Csv $Paths.Results|Select-Object -Last 200|ForEach-Object{$v=0.0;if([double]::TryParse([string]$_.DurationSeconds,[ref]$v)-and$v-gt0){$v}}|Sort-Object);if($a.Count-lt20){return [int]$min};$idx=[math]::Max(0,[math]::Ceiling($a.Count*.95)-1);$p95=[double]$a[$idx];[int][math]::Ceiling([math]::Min($max,[math]::Max($min,$p95*$mult)))}catch{[int]$min}}

function Invoke-Probe($Config,$Paths){$n=Test-Network $Config;$s=Test-StateStore $Paths;$db=Test-Database $Config;$sp=$false;$spDetail='';if($n.Dns-and$n.Tcp){try{$web=Connect-RecoveryPnP $Config;$sp=$true;$spDetail=$web.Url}catch{$spDetail=$_.Exception.Message}};$healthy=($n.Dns-and$n.Tcp-and$s-and$db.Healthy-and$sp);$r=[ordered]@{Timestamp=(Get-Date).ToString('o');Healthy=$healthy;Dns=$n.Dns;Tcp=$n.Tcp;StateStore=$s;SharePoint=$sp;Database=$db.Healthy;Detail=("Net={0};SP={1};DB={2}" -f $n.Detail,$spDetail,$db.Detail)};Write-JsonAtomic $r $Paths.ProbeResult;$h=@('Timestamp','Dns','Tcp','StateStore','SharePoint','Database','Detail');$v=@($r.Timestamp,$r.Dns,$r.Tcp,$r.StateStore,$r.SharePoint,$r.Database,$r.Detail);Append-CsvRow $Paths.Health $h $v;if($healthy){exit 0}else{exit 30}}

function Invoke-ReconcileMode($Config,$Paths){$inflight=Read-JsonSafe $Paths.Inflight;if($null-eq$inflight){throw 'No inflight state exists for reconciliation.'};[void](Connect-RecoveryPnP $Config);$r=Reconcile-Inflight $Config $Paths $inflight;Write-JsonAtomic ([ordered]@{Timestamp=(Get-Date).ToString('o');Classification=$r.Classification;RecycleState=$r.RecycleState;DestinationState=$r.DestinationState;Stable=$r.Stable;Sequence=$inflight.Sequence;RecycleBinId=$inflight.RecycleBinId;Destination=$inflight.Destination}) $Paths.ReconcileResult;if($r.Classification-eq'MANUAL_REVIEW_REQUIRED'){exit 31}else{exit 0}}

function Invoke-ReportMode($Config,$Paths){$queue=@(Import-Csv -LiteralPath ([string]$Config.Paths.QueueCsv));$rows=if(Test-Path $Paths.Results){@(Import-Csv $Paths.Results)}else{@()};$restored=@($rows|Where-Object{$_.Result-in@('RESTORED','RECOVERED_COMMITTED_AFTER_HANG')}).Count;$conflicts=@($rows|Where-Object{$_.Result-eq'CONFLICT'}).Count;$failures=@($rows|Where-Object{$_.Result-in@('FAILED_REVIEW_REQUIRED','AMBIGUOUS_RESTORE_ABORT','ABORT_BEFORE_RESTORE','BAD_PATH')}).Count;$hangs=0;$healthFailures=0;if(Test-Path $Paths.Events){foreach($line in Get-Content $Paths.Events){try{$e=$line|ConvertFrom-Json;if($e.Type-eq'HANG_DETECTED'){$hangs++}}catch{}}};if(Test-Path $Paths.Health){$healthFailures=@(Import-Csv $Paths.Health|Where-Object{$_.Dns-ne'True'-or$_.Tcp-ne'True'-or$_.StateStore-ne'True'-or$_.SharePoint-ne'True'-or$_.Database-ne'True'}).Count};$rep=$Config.Reporting;$baseR=[int](Get-ConfigValue $rep 'RestoredBaseline' 0);$baseC=[int](Get-ConfigValue $rep 'ConflictsBaseline' 0);$population=[int](Get-ConfigValue $rep 'IncidentPopulation' ($baseR+$baseC+$queue.Count));$summary=[ordered]@{GeneratedAt=(Get-Date).ToString('o');ProgramVersion=[string]$Config.ProgramVersion;QueueCount=$queue.Count;CurrentRunRestored=$restored;CurrentRunConflicts=$conflicts;CurrentRunFailures=$failures;IncidentRestored=($baseR+$restored);IncidentConflicts=($baseC+$conflicts);IncidentPopulation=$population;IncidentPending=($population-($baseR+$restored)-($baseC+$conflicts));DetectedWorkerHangs=$hangs;FailedHealthProbes=$healthFailures;TerminalLog=$Paths.Results;HealthLog=$Paths.Health;ReconciliationLog=$Paths.Reconciliation;EventLog=$Paths.Events};Write-JsonAtomic $summary $Paths.FinalSummary;$summary|Format-List}

function Invoke-Worker($Config,$Paths){[void](Assert-WriteArmed $Config);$queue=@(Import-Csv -LiteralPath ([string]$Config.Paths.QueueCsv));$runId=Get-Date -Format 'yyyyMMdd-HHmmss';$cp=Read-JsonSafe $Paths.Checkpoint;$i=if($null-eq$cp){0}else{[int]$cp.NextIndex};[void](Connect-RecoveryPnP $Config);Write-Event $Paths 'WORKER_START' 'Worker started.' @{Pid=$PID;Index=$i}
 while($i-lt$queue.Count){if(Test-Path $Paths.PauseFlag){Write-Heartbeat $Paths 'PAUSED_BETWEEN_ITEMS' $null $null;exit 20};$item=$queue[$i];$guid=Get-RowGuid $item;$dest=Get-RowDestination $item;$seq=Get-OriginalSequence $item $i $Config;$title=[string]$item.Title;if([string]::IsNullOrWhiteSpace($guid)-or[string]::IsNullOrWhiteSpace($dest)){Write-Event $Paths 'BAD_PATH' 'Missing GUID/destination.' @{Index=$i};exit 44};$start=Get-Date;Write-Inflight $Paths $seq $guid $dest $false 'DESTINATION_LOOKUP';Write-Heartbeat $Paths 'DESTINATION_LOOKUP' $seq $guid;try{$existing=Get-PnPFile -Url $dest -AsListItem -ErrorAction Stop}catch{Write-Event $Paths 'ABORT_BEFORE_RESTORE' $_.Exception.Message @{Sequence=$seq};exit 43};if($null-ne$existing){Append-Result $Paths $runId $i $seq $guid $title $dest $false $true 0 'CONFLICT' 'Destination occupied before restore.' (((Get-Date)-$start).TotalSeconds);Write-Checkpoint $Paths ($i+1) $seq $guid 'CONFLICT';Clear-Inflight $Paths;Write-Heartbeat $Paths 'TERMINAL_CONFLICT' $seq $guid;$i++;continue};$attempt=0;$done=$false;while(-not$done){$attempt++;Write-Inflight $Paths $seq $guid $dest $true 'RESTORE_INVOKED';Write-Heartbeat $Paths 'RESTORE_INVOKED' $seq $guid;try{Restore-PnPRecycleBinItem -Identity $guid -Force -ErrorAction Stop;Append-Result $Paths $runId $i $seq $guid $title $dest $true $false $attempt 'RESTORED' '' (((Get-Date)-$start).TotalSeconds);Write-Checkpoint $Paths ($i+1) $seq $guid 'RESTORED';Clear-Inflight $Paths;Write-Heartbeat $Paths 'TERMINAL_RESTORED' $seq $guid;$i++;$done=$true}catch{$m=[string]$_.Exception.Message;if($m-match'-2147024816|already exists|same name'){Append-Result $Paths $runId $i $seq $guid $title $dest $true $false $attempt 'CONFLICT' $m (((Get-Date)-$start).TotalSeconds);Write-Checkpoint $Paths ($i+1) $seq $guid 'CONFLICT';Clear-Inflight $Paths;Write-Heartbeat $Paths 'TERMINAL_CONFLICT' $seq $guid;$i++;$done=$true;continue};if(($m-match'\b429\b|throttl')-and$attempt-lt[int](Get-ConfigValue $Config.Recovery 'MaxThrottleAttempts' 5)){$delay=[math]::Pow(2,$attempt)*[double](Get-ConfigValue $Config.Recovery 'ThrottleBaseDelaySeconds' 2);Write-Event $Paths 'THROTTLE_RETRY' $m @{Sequence=$seq;Attempt=$attempt;Delay=$delay};Start-Sleep -Seconds ([int][math]::Ceiling($delay));continue};Write-Event $Paths 'POST_INVOKE_ABORT' $m @{Sequence=$seq;Guid=$guid;Destination=$dest};exit 42}}};Write-Heartbeat $Paths 'QUEUE_COMPLETE' $null $null;exit 0}

function Start-Child($ChildMode,$ConfigPath){$pwsh=(Get-Process -Id $PID).Path;Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',("`"$PSCommandPath`""),'-Mode',$ChildMode,'-ConfigPath',("`"$ConfigPath`"")) -PassThru}
function Run-ProbeChild($Config,$Paths,$ConfigPath){if(Test-Path $Paths.ProbeResult){Remove-Item $Paths.ProbeResult -Force};$p=Start-Child 'Probe' $ConfigPath;$timeout=[int](Get-ConfigValue $Config.Health 'ProbeTimeoutSeconds' 30);$ok=$p.WaitForExit($timeout*1000);if(-not$ok){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;return [pscustomobject]@{Healthy=$false;Detail='PROBE_TIMEOUT'}};$r=Read-JsonSafe $Paths.ProbeResult;if($null-eq$r){return [pscustomobject]@{Healthy=$false;Detail='NO_PROBE_RESULT'}};$r}
function Run-ReconcileChild($Config,$Paths,$ConfigPath){$max=[int](Get-ConfigValue $Config.Supervisor 'MaxReconcileAttempts' 3);$timeout=[int](Get-ConfigValue $Config.Health 'ReconcileTimeoutSeconds' 45);$attempt=0;while($attempt-lt$max){$attempt++;if(Test-Path $Paths.ReconcileResult){Remove-Item $Paths.ReconcileResult -Force};$p=Start-Child 'Reconcile' $ConfigPath;$ok=$p.WaitForExit($timeout*1000);if(-not$ok){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue;Write-Event $Paths 'RECONCILE_TIMEOUT' 'Reconciliation child timed out.' @{Attempt=$attempt};Start-Sleep -Seconds ([int](Get-ConfigValue $Config.Supervisor 'UnhealthyBackoffSeconds' 30));continue};$r=Read-JsonSafe $Paths.ReconcileResult;if($null-ne$r){return $r};Start-Sleep -Seconds ([int](Get-ConfigValue $Config.Supervisor 'UnhealthyBackoffSeconds' 30))};[pscustomobject]@{Classification='MANUAL_REVIEW_REQUIRED';RecycleState='UNKNOWN_ERROR';DestinationState='UNKNOWN_ERROR';Stable=$false}}

function Get-MutexName($Paths){$bytes=[Text.Encoding]::UTF8.GetBytes($Paths.StateDirectory.ToLowerInvariant());$sha=[Security.Cryptography.SHA256]::Create();$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').Substring(0,24);"M365Recovery_$hash"}

function Resolve-InflightAfterStop($Config,$Paths,$ConfigPath,$queue,$inflight,[string]$EventType){do{$probe=Run-ProbeChild $Config $Paths $ConfigPath;if(-not$probe.Healthy){Start-Sleep -Seconds ([int](Get-ConfigValue $Config.Supervisor 'UnhealthyBackoffSeconds' 30))}}until($probe.Healthy);$recon=Run-ReconcileChild $Config $Paths $ConfigPath;Write-Event $Paths $EventType 'Inflight item reconciled.' $recon;$idx=@(for($x=0;$x-lt$queue.Count;$x++){if((Get-OriginalSequence $queue[$x] $x $Config)-eq[int]$inflight.Sequence){$x}});if($idx.Count-ne1){throw 'Could not uniquely map inflight sequence.'};$ri=[int]$idx[0];if($recon.Classification-eq'COMMITTED'){Append-Result $Paths 'SUPERVISOR' $ri ([int]$inflight.Sequence) ([string]$inflight.RecycleBinId) '' ([string]$inflight.Destination) ([bool]$inflight.RestoreInvoked) $false 0 'RECOVERED_COMMITTED_AFTER_HANG' 'Two-read exact reconciliation proved commit.' 0;Write-Checkpoint $Paths ($ri+1) ([int]$inflight.Sequence) ([string]$inflight.RecycleBinId) 'RECOVERED_COMMITTED_AFTER_HANG';Clear-Inflight $Paths}elseif($recon.Classification-eq'CONFLICT'){Append-Result $Paths 'SUPERVISOR' $ri ([int]$inflight.Sequence) ([string]$inflight.RecycleBinId) '' ([string]$inflight.Destination) ([bool]$inflight.RestoreInvoked) $true 0 'CONFLICT' 'Two-read reconciliation found conflict.' 0;Write-Checkpoint $Paths ($ri+1) ([int]$inflight.Sequence) ([string]$inflight.RecycleBinId) 'CONFLICT';Clear-Inflight $Paths}elseif($recon.Classification-eq'NOT_COMMITTED'){Clear-Inflight $Paths}else{throw 'Reconciliation requires manual review.'}}

function Invoke-Supervisor($Config,$Paths,$ConfigPath){$mutex=$null;try{$name=Get-MutexName $Paths;$created=$false;$mutex=[Threading.Mutex]::new($true,$name,[ref]$created);if(-not$created){throw 'Another supervisor already owns this state directory.'};Set-Content -LiteralPath $Paths.SupervisorPid -Value $PID -Encoding ASCII;Write-Event $Paths 'SUPERVISOR_START' 'Supervisor process initialized and owns state mutex.' @{Pid=$PID};$safety=Assert-WriteArmed $Config;$queue=@(Import-Csv -LiteralPath ([string]$Config.Paths.QueueCsv));Write-Event $Paths 'SAFETY_ENVELOPE_PASS' 'Queue safety envelope and arm file validated.' $safety;$probe=Run-ProbeChild $Config $Paths $ConfigPath;if(-not$probe.Healthy){throw "Initial health probe failed: $($probe.Detail)"};$worker=$null;$lastProbe=Get-Date;$healthyStreak=1
 while($true){$cp=Read-JsonSafe $Paths.Checkpoint;$next=if($null-eq$cp){0}else{[int]$cp.NextIndex};if($next-ge$queue.Count){Write-Event $Paths 'COMPLETE' 'Checkpoint reached end.' @{Count=$queue.Count};return};if($null-eq$worker-or$worker.HasExited){if($null-ne$worker){if(Test-Path -LiteralPath $Paths.WorkerPid){Remove-Item -LiteralPath $Paths.WorkerPid -Force -ErrorAction SilentlyContinue};$exit=$worker.ExitCode;Write-Event $Paths 'WORKER_EXIT' 'Worker exited.' @{ExitCode=$exit;Pid=$worker.Id};if($exit-eq44){throw 'Permanent/manual-review worker error.'};if($exit-in@(42,43)){$inflight=Read-JsonSafe $Paths.Inflight;if($null-eq$inflight){throw 'Worker aborted without inflight state.'};Resolve-InflightAfterStop $Config $Paths $ConfigPath $queue $inflight 'RECONCILE_AFTER_ABORT'}};$probe=Run-ProbeChild $Config $Paths $ConfigPath;if(-not$probe.Healthy){if(-not(Test-Path $Paths.PauseFlag)){Set-Content $Paths.PauseFlag (Get-Date).ToString('o')};Start-Sleep -Seconds ([int](Get-ConfigValue $Config.Supervisor 'UnhealthyBackoffSeconds' 30));continue};if(Test-Path $Paths.PauseFlag){Remove-Item $Paths.PauseFlag -Force};$worker=Start-Child 'Worker' $ConfigPath;Set-Content -LiteralPath $Paths.WorkerPid -Value $worker.Id -Encoding ASCII;Write-Event $Paths 'WORKER_LAUNCH' 'Worker launched.' @{Pid=$worker.Id;NextIndex=$next};Start-Sleep 2};if(((Get-Date)-$lastProbe).TotalSeconds-ge[double](Get-ConfigValue $Config.Health 'ProbeIntervalSeconds' 60)){$probe=Run-ProbeChild $Config $Paths $ConfigPath;$lastProbe=Get-Date;if(-not$probe.Healthy){$healthyStreak=0;if(-not(Test-Path $Paths.PauseFlag)){Set-Content $Paths.PauseFlag (Get-Date).ToString('o');Write-Event $Paths 'PAUSE_REQUESTED' 'Health probe failed.' @{Detail=$probe.Detail}}}else{$healthyStreak++;if($healthyStreak-ge[int](Get-ConfigValue $Config.Health 'RequiredConsecutiveHealthyProbes' 2)-and(Test-Path $Paths.PauseFlag)){Remove-Item $Paths.PauseFlag -Force;Write-Event $Paths 'HEALTH_RECOVERED' 'Healthy probes restored.' @{Count=$healthyStreak}}}};if($null-ne$worker-and-not$worker.HasExited){$hb=Read-JsonSafe $Paths.Heartbeat;if($null-ne$hb){$age=((Get-Date)-([datetimeoffset]::Parse([string]$hb.Timestamp)).LocalDateTime).TotalSeconds;$timeout=Get-HangTimeout $Config $Paths;if($age-gt$timeout){Write-Event $Paths 'HANG_DETECTED' 'Worker heartbeat stale.' @{Pid=$worker.Id;AgeSeconds=$age;TimeoutSeconds=$timeout;Phase=$hb.Phase;Sequence=$hb.Sequence;Guid=$hb.RecycleBinId};Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue;$worker.WaitForExit();if(Test-Path -LiteralPath $Paths.WorkerPid){Remove-Item -LiteralPath $Paths.WorkerPid -Force -ErrorAction SilentlyContinue};$inflight=Read-JsonSafe $Paths.Inflight;if($null-eq$inflight){throw 'Hung worker had no inflight state.'};Resolve-InflightAfterStop $Config $Paths $ConfigPath $queue $inflight 'HANG_RECONCILIATION';$worker=$null;continue}}};Start-Sleep -Seconds ([int](Get-ConfigValue $Config.Supervisor 'PollSeconds' 5))}}
 finally{if(Test-Path -LiteralPath $Paths.WorkerPid){Remove-Item -LiteralPath $Paths.WorkerPid -Force -ErrorAction SilentlyContinue};if(Test-Path -LiteralPath $Paths.SupervisorPid){$sp=(Get-Content -LiteralPath $Paths.SupervisorPid -Raw -ErrorAction SilentlyContinue).Trim();if($sp -eq [string]$PID){Remove-Item -LiteralPath $Paths.SupervisorPid -Force -ErrorAction SilentlyContinue}};if($null-ne$mutex){try{$mutex.ReleaseMutex()}catch{};$mutex.Dispose()}}}

function Invoke-ArmCheck($Config,$Paths) {
    $s=Assert-WriteArmed $Config
    $result=[ordered]@{
        Timestamp=(Get-Date).ToString('o')
        Passed=$true
        ArmId=$s.ArmId
        ApprovedAtUtc=$s.ApprovedAtUtc
        EngineSha256=$s.EngineSha256
        QueueSha256=$s.QueueSha256
        QueueCount=$s.Count
        FirstSequence=$s.FirstSequence
        LastSequence=$s.LastSequence
        FirstGuid=$s.FirstGuid
        SiteUrl=$s.SiteUrl
        ProgramVersion=$s.ProgramVersion
        ClientId=$s.ClientId
        IncidentPopulation=$s.IncidentPopulation
    }
    $result | ConvertTo-Json -Depth 10
    exit 0
}

function Invoke-SelfTestWorker($Config,$Paths){$d=$Paths.SelfTestDirectory;Ensure-Dir $d;$hb=Join-Path $d 'heartbeat.json';for($i=1;$i-le3;$i++){Write-JsonAtomic ([ordered]@{Timestamp=(Get-Date).ToString('o');Pid=$PID;Phase='SELFTEST_ACTIVE';Tick=$i}) $hb;Start-Sleep 1};Write-JsonAtomic ([ordered]@{Timestamp=(Get-Date).ToString('o');Pid=$PID;Phase='SELFTEST_INTENTIONAL_HANG';Tick=4}) $hb;Start-Sleep 120;exit 99}

function Invoke-SelfTest($Config,$Paths,$ConfigPath){$start=Get-Date;$checks=[ordered]@{};Ensure-Dir $Paths.SelfTestDirectory;Get-ChildItem $Paths.SelfTestDirectory -Force -ErrorAction SilentlyContinue|Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
 try{$q=Assert-QueueSafety $Config;$checks.QueueSafety=$true;$checks.QueueSha256=$q.QueueSha256}catch{$checks.QueueSafety=$false;$checks.QueueSafetyError=$_.Exception.Message}
 $checks.StateStore=Test-StateStore $Paths
 $probePass=0;$probeDetails=@();for($i=1;$i-le3;$i++){$p=Run-ProbeChild $Config $Paths $ConfigPath;$probeDetails+=@{Attempt=$i;Healthy=[bool]$p.Healthy;Detail=[string]$p.Detail};if($p.Healthy){$probePass++};Start-Sleep 1};$checks.ThreeSequentialProbes=($probePass-eq3);$checks.ProbeDetails=$probeDetails
 $child=Start-Child 'SelfTestWorker' $ConfigPath;$hbPath=Join-Path $Paths.SelfTestDirectory 'heartbeat.json';$deadline=(Get-Date).AddSeconds(25);$detected=$false;$killed=$false;$staleAge=0.0
 while((Get-Date)-lt$deadline -and -not$child.HasExited){$hb=Read-JsonSafe $hbPath;if($null-ne$hb){$staleAge=((Get-Date)-([datetimeoffset]::Parse([string]$hb.Timestamp)).LocalDateTime).TotalSeconds;if($staleAge-gt5){$detected=$true;Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue;$child.WaitForExit();$killed=$true;break}};Start-Sleep 1}
 if(-not$child.HasExited){Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue;$child.WaitForExit()}
 $checks.WatchdogDetectedIntentionalHang=$detected;$checks.WatchdogKilledHungWorker=$killed;$checks.WatchdogStaleAgeSeconds=[math]::Round($staleAge,2)
 $testCp=Join-Path $Paths.SelfTestDirectory 'checkpoint.json';Write-JsonAtomic ([ordered]@{NextIndex=123;Marker='atomic-checkpoint'}) $testCp;$cp=Read-JsonSafe $testCp;$checks.AtomicCheckpoint=($null-ne$cp-and[int]$cp.NextIndex-eq123-and[string]$cp.Marker-eq'atomic-checkpoint')
 $checks.PidPathSchema=$false
 try{
   $pn=@($Paths.PSObject.Properties.Name)
   $checks.PidPathSchema=($pn -contains 'SupervisorPid' -and $pn -contains 'WorkerPid' -and
     -not [string]::IsNullOrWhiteSpace([string]$Paths.SupervisorPid) -and
     -not [string]::IsNullOrWhiteSpace([string]$Paths.WorkerPid))
   $checks.SupervisorPidPath=[string]$Paths.SupervisorPid
   $checks.WorkerPidPath=[string]$Paths.WorkerPid
 }catch{$checks.PidPathSchemaError=$_.Exception.Message}
 $checks.EngineHashReadable=$false
 $checks.EngineHashMatchesExpected=$false
 try{
   $eh=Get-EngineHash
   $checks.EngineHashReadable=(-not [string]::IsNullOrWhiteSpace($eh))
   $checks.EngineSha256=$eh
   $expectedEh=[string](Get-ConfigValue $Config.Safety 'ExpectedEngineSha256' '')
   $checks.ExpectedEngineSha256=$expectedEh
   $checks.EngineHashMatchesExpected=(-not [string]::IsNullOrWhiteSpace($expectedEh) -and $eh -eq $expectedEh.ToLowerInvariant())
 }catch{$checks.EngineHashError=$_.Exception.Message}
 $checks.WriteGateClosedByDefault= -not [bool](Get-ConfigValue $Config.Safety 'WriteEnabled' $false)
 $all=($checks.QueueSafety -and $checks.StateStore -and $checks.ThreeSequentialProbes -and $checks.WatchdogDetectedIntentionalHang -and $checks.WatchdogKilledHungWorker -and $checks.AtomicCheckpoint -and $checks.PidPathSchema -and $checks.EngineHashReadable -and $checks.EngineHashMatchesExpected -and $checks.WriteGateClosedByDefault)
 $r=[ordered]@{Timestamp=(Get-Date).ToString('o');Passed=$all;DurationSeconds=[math]::Round(((Get-Date)-$start).TotalSeconds,2);Checks=$checks};Write-JsonAtomic $r $Paths.SelfTestResult;$r|ConvertTo-Json -Depth 20;if($all){exit 0}else{exit 40}}

$Config=Read-Config $ConfigPath
$Paths=Get-Paths $Config
switch($Mode){'Probe'{Invoke-Probe $Config $Paths};'Reconcile'{Invoke-ReconcileMode $Config $Paths};'Report'{Invoke-ReportMode $Config $Paths};'ArmCheck'{Invoke-ArmCheck $Config $Paths};'Worker'{Invoke-Worker $Config $Paths};'Supervisor'{Invoke-Supervisor $Config $Paths $ConfigPath};'SelfTestWorker'{Invoke-SelfTestWorker $Config $Paths};'SelfTest'{Invoke-SelfTest $Config $Paths $ConfigPath}}
