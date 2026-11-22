#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '..\Install-FabricCapacityTelemetry.ps1'
$fixtureCapacities = @(
    @{ id = '11111111-1111-4111-8111-111111111111'; displayName = 'East workload'; region = 'East US'; sku = 'F16'; state = 'Active' }
    @{ id = '22222222-2222-4222-8222-222222222222'; displayName = 'West workload'; region = 'West US 3'; sku = 'F16'; state = 'Active' }
    @{ id = '33333333-3333-4333-8333-333333333333'; displayName = 'East host'; region = 'East US'; sku = 'F32'; state = 'Active' }
    @{ id = '44444444-4444-4444-8444-444444444444'; displayName = 'West paused'; region = 'West US 3'; sku = 'F16'; state = 'Inactive' }
)
$state = @{ Answers = [Collections.Generic.Queue[string]]::new(); Workspaces = @{}; Items = @{}; Definitions = @{}; Writes = 0; Pending = $null; Warning = $false; FailLro = $false; SignedIn = $true; Expired = $false; LoginCount = 0 }
$eventhouseOperationId = '51515151-5151-4151-8151-515151515151'

function Get-Command {
    param([string] $Name, $ErrorAction)
    if ($Name -eq 'az' -and $state.MissingAz) { return }
    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
}

function winget {
    $state.WingetCalls++
    if ($args -notcontains 'Microsoft.AzureCLI' -or $args -notcontains '--exact') { throw 'Unexpected package install.' }
    '   -', '   \', '   |', '   /', ''
    "  $([char]0x2588)$([char]0x2592)  18.0 MB / 67.7 MB"
    "  $([char]0x2592)$([char]0x2592)  0%"
    'Found Microsoft Azure CLI'
    'Starting package install...'
    if ($state.FailWinget) {
        'Installer failed: access denied'
        $global:LASTEXITCODE = 5
        return
    }
    'Successfully installed'
    $state.MissingAz = $false
    $global:LASTEXITCODE = 0
}

function az {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'login') {
        $state.LoginCount++
        $state.SignedIn = $true
        $state.Expired = $false
    } elseif (-not $state.SignedIn -or ($args[1] -eq 'get-access-token' -and $state.Expired)) {
        $global:LASTEXITCODE = 1
    } elseif ($args[1] -eq 'show') { '{"user":{"type":"user","name":"mock-user"},"tenantId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}' }
    else { 'mock-token' }
}

function Read-Host([string] $Prompt) {
    if (-not $state.Answers.Count) { throw "Unexpected prompt: $Prompt" }
    $state.Answers.Dequeue()
}

function Start-Sleep { param($Seconds) }

function Write-Progress {
    param($Id, $ParentId, $Activity, $Status, $PercentComplete, [switch] $Completed)
    if (-not $Completed) { $state.Progress += "  $Activity [$Status]" }
}

function Invoke-WebRequest {
    param($Method, [uri] $Uri, $Authentication, $Token, $MaximumRedirection, $TimeoutSec,
          $SkipHttpErrorCheck, $Headers, $ContentType, $Body)
    $status = 200
    $replyHeaders = @{}
    if ($Uri.Host -notin 'api.fabric.microsoft.com', 'api.powerbi.com', 'mock.kusto.fabric.microsoft.com') {
        $state.UnexpectedHostRequests++
        throw "Unexpected HTTP host: $($Uri.Host)"
    }
    $path = $Uri.AbsolutePath
    $payload = if ($Body) { ConvertFrom-Json -AsHashtable -InputObject $Body }
    $result = switch -Regex ($path) {
        '^/v1.0/myorg/capacities$' {
            @{ value = @(
                for ($i = 0; $i -lt $fixtureCapacities.Count; $i++) {
                    if ($i -ne 3) {
                        @{ id = $fixtureCapacities[$i].id; capacityUserAccessRight = @('Admin', 'Admin', 'Assign')[$i] }
                    }
                }
            ) }
        }
        '^/v1/capacities$' {
            $page = if ($Uri.Query) { @{ value = @($fixtureCapacities[2..3]) } }
                else { @{ value = @($fixtureCapacities[0..1]); continuationUri = '/v1/capacities?continuationToken=second' } }
            if ($state.AllInactive) {
                $page.value = @($page.value | ForEach-Object {
                    $copy = $_.Clone()
                    $copy.state = 'Inactive'
                    $copy
                })
            }
            $page
        }
        '^/v1/workspaces$' {
            if ($Method -eq 'GET') { @{ value = @($state.Workspaces.Values) } }
            else {
                $state.Writes++
                $status = 201
                $payload.id = [guid]::NewGuid().ToString()
                $payload.type = 'Workspace'
                $state.Workspaces[$payload.id] = $payload
                $state.Items[$payload.id] = @{}
                $payload
            }
        }
        '^/v1/workspaces/([^/]+)$' { $state.Workspaces[$Matches[1]] }
        '^/v1/workspaces/([^/]+)/items$' { @{ value = @($state.Items[$Matches[1]].Values) } }
        '^/v1/workspaces/([^/]+)/(eventhouses|kqlDatabases|eventstreams)$' {
            $workspaceId = $Matches[1]
            $collection = $Matches[2]
            $state.Writes++
            $item = @{ id = [guid]::NewGuid().ToString(); displayName = $payload.displayName; description = $payload.description }
            switch ($collection) {
                eventhouses {
                    $item.type = 'Eventhouse'
                    $defaultDbId = [guid]::NewGuid().ToString()
                    $state.Items[$workspaceId][$defaultDbId] = @{
                        id = $defaultDbId; displayName = $item.displayName; type = 'KQLDatabase'; description = ''
                        properties = @{ parentEventhouseItemId = $item.id }
                    }
                    $state.Pending = $item
                    $status = 202
                    $replyHeaders.Location = "https://other.example/v1/operations/$eventhouseOperationId"
                    if (-not $state.OmitOperationId) { $replyHeaders['x-ms-operation-id'] = $eventhouseOperationId }
                }
                kqlDatabases {
                    $item.type = 'KQLDatabase'
                    $props = ConvertFrom-Json -AsHashtable -InputObject (Read-Part $payload.definition.parts 'DatabaseProperties.json')
                    $schema = Read-Part $payload.definition.parts 'DatabaseSchema.kql'
                    $columns = [regex]::Escape("(['id']:string, ['type']:string, ['time']:datetime, ['data']:dynamic)")
                    if ($schema -notmatch "table FabricCapacityOverview $columns" -or
                        $schema -notmatch "table FabricCapacityOperations $columns") {
                        throw 'The database definition did not create both event tables.'
                    }
                    $item.properties = $props
                    $item.properties.queryServiceUri = 'https://mock.kusto.fabric.microsoft.com'
                }
                eventstreams {
                    $item.type = 'Eventstream'
                    $graph = ConvertFrom-Json -AsHashtable -InputObject (Read-Part $payload.definition.parts 'eventstream.json')
                    $source = $graph.sources[0]
                    $dest = $graph.destinations[0].properties
                    $capacity = $fixtureCapacities | Where-Object id -eq $source.properties.capacityId
                    $hostId = $state.Workspaces[$workspaceId].capacityId
                    $hostCapacity = $fixtureCapacities | Where-Object id -eq $hostId
                    $destinationDb = $state.Items[$workspaceId][$dest.itemId]
                    if ($capacity.id -notin @($fixtureCapacities[0].id, $fixtureCapacities[1].id) -or $capacity.region -ne $hostCapacity.region -or
                        $destinationDb.type -ne 'KQLDatabase' -or $destinationDb.displayName -ne $dest.databaseName -or
                        $state.Items[$workspaceId][$destinationDb.properties.parentEventhouseItemId].type -ne 'Eventhouse' -or $dest.workspaceId -ne $workspaceId -or
                        $dest.dataIngestionMode -ne 'ProcessedIngestion' -or $dest.databaseName -ne 'CapacityTelemetry') {
                        throw 'Unexpected source or destination placement.'
                    }
                    $state.Definitions[$item.id] = $payload.definition
                    $state.Pending = $item
                    $status = 202
                    $replyHeaders.Location = '/v1/operations/test'
                }
            }
            if ($collection -ne 'eventstreams' -or -not $state.FailLro) { $state.Items[$workspaceId][$item.id] = $item }
            if ($status -ne 202) { $item }
        }
        "^/v1/operations/$eventhouseOperationId$" {
            $replyHeaders.Location = "https://other.example/v1/operations/$eventhouseOperationId/result"
            @{ status = 'Succeeded' }
        }
        "^/v1/operations/$eventhouseOperationId/result$" { $state.Pending }
        '^/v1/operations/test$' {
            if ($state.FailLro) { @{ status = 'Failed'; error = @{ errorCode = 'SubscriptionFailed' } } }
            else { $replyHeaders.Location = '/v1/operations/test/result'; @{ status = 'Succeeded' } }
        }
        '^/v1/operations/test/result$' { $state.Pending }
        '^/v1/workspaces/([^/]+)/kqlDatabases/([^/]+)$' { $state.Items[$Matches[1]][$Matches[2]] }
        '^/v1/workspaces/[^/]+/eventstreams/([^/]+)/getDefinition$' { @{ definition = $state.Definitions[$Matches[1]] } }
        '^/v1/workspaces/[^/]+/eventstreams/[^/]+/topology$' {
            $destination = if ($state.Warning) { 'Warning' } elseif ($state.DestinationCreating) {
                $state.DestinationCreating = $false
                'Creating'
            } else { 'Running' }
            @{
                sources = @(@{ name = 'CapacityEvents'; status = 'Running' })
                destinations = @(@{ name = 'EventhouseDestination'; status = $destination; error = $null })
            }
        }
        '^/v2/rest/query$' {
            if ($payload.csl -notmatch 'capacityId.+[0-9a-f-]{36}' -or $payload.db -ne 'CapacityTelemetry') { throw 'Ingestion query was not scoped.' }
            $stamp = if ($payload.csl -match 'FabricCapacityOverview') { '2026-11-22T16:00:00Z' }
            @(
                @{ FrameType = 'DataTable'; TableKind = 'PrimaryResult'; Columns = @(@{ ColumnName = 'LastEventUtc' }); Rows = ,@($stamp) }
                @{ FrameType = 'DataSetCompletion'; HasErrors = $false }
            ) | Write-Output
        }
        default { throw "Unexpected HTTP call: $Method $Uri" }
    }
    @{ StatusCode = $status; Headers = $replyHeaders; Content = (ConvertTo-Json -InputObject $result -Depth 25 -Compress) }
}

function Read-Part($Parts, [string] $Name) {
    $part = $Parts | Where-Object path -eq $Name
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload))
}

function Run-Installer([string[]] $Answers, [hashtable] $Options = @{}) {
    $state.Answers.Clear()
    foreach ($answer in $Answers) { $state.Answers.Enqueue($answer) }
    $messages = [Collections.Generic.List[string]]::new()
    try {
        & $installer @Options 2>&1 3>&1 6>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { throw "Unexpected PowerShell error: $_" }
            $messages.Add($_.ToString())
        }
        $code = $LASTEXITCODE
    }
    catch { throw "$($_.Exception.Message)`n$($messages -join "`n")" }
    if ($state.Answers.Count) { throw 'Not all expected inputs were consumed.' }
    @{ Code = $code; Text = $messages -join "`n" }
}

function Assert-InstallerBlocked($Result, [string] $Message) {
    if ($Result.Code -ne 1 -or $Result.Text -notlike "*$Message*") {
        throw "Expected a clean failure reporting '$Message', got exit code $($Result.Code):`n$($Result.Text)"
    }
}

$planInputs = @('all', '1', '1')
$state.MissingAz = $true
Assert-InstallerBlocked (Run-Installer @() @{ WhatIf = $true }) 'Azure CLI (az): https://learn.microsoft.com/cli/azure/install-azure-cli*No tools were installed'
Assert-InstallerBlocked (Run-Installer @('n')) 'Setup blocked'
if ($state.WingetCalls -or $state.Writes) { throw 'Prerequisite checks installed software without consent.' }
$originalPath = $env:Path
$originalEncoding = [Console]::OutputEncoding.CodePage
try {
    $state.FailWinget = $true
    $failedInstall = Run-Installer @('y')
    Assert-InstallerBlocked $failedInstall 'Installer failed: access denied*WinGet returned exit code 5*Setup blocked'
    $state.FailWinget = $false
    $bootstrapped = Run-Installer (@('maybe', '') + $planInputs + 'n')
}
finally { $env:Path = $originalPath }
if ($bootstrapped.Code -ne 0 -or $state.WingetCalls -ne 2 -or $bootstrapped.Text -notmatch 'Enter Y or N\.' -or
    $bootstrapped.Text -notmatch 'Cancelled' -or $state.Writes -or [Console]::OutputEncoding.CodePage -ne $originalEncoding) {
    throw 'Accepting the default prerequisite install did not continue into configuration with the original console encoding.'
}
if ($bootstrapped.Text -notmatch '(?s)Installing Azure CLI \(az\) with WinGet.*Found Microsoft Azure CLI.*Starting package install.*Successfully installed' -or
    $bootstrapped.Text -match '(?m)^[ \t]*[-\\|/][ \t]*\r?$|[\u2580-\u259F]|18\.0 MB / 67\.7 MB') {
    throw "Expected readable WinGet status without spinner or progress-bar lines:`n$($bootstrapped.Text)"
}

$state.AllInactive = $true
$inactive = Run-Installer @()
Assert-InstallerBlocked $inactive 'None of the visible Fabric F SKU capacities are active*Resume*No resources were created'
if ($inactive.Text -notmatch 'East host \(F32\) - Inactive; Not a Capacity Admin \(reported access: Assign\)' -or
    $inactive.Text -notmatch 'West paused \(F16\) - Inactive; Capacity Admin access could not be verified') {
    throw 'Expected a single Inactive label followed by any applicable permission reason.'
}
if ($state.Writes -ne 0) { throw 'Preflight wrote resources with all capacities inactive.' }
$state.AllInactive = $false
Assert-InstallerBlocked (Run-Installer @('99')) 'Setup stopped: Enter a number'

$plan = Run-Installer $planInputs @{ WhatIf = $true }
if ($plan.Code -ne 0 -or $state.Writes -ne 0 -or $plan.Text -notmatch 'East host' -or $plan.Text -notmatch 'Plan only' -or $plan.Text -match 'Local prerequisites') { throw 'Read-only plan did not succeed or printed unnecessary prerequisite output.' }
if ($plan.Text -notmatch "(?s)West US 3 for the monitoring workspace:.*?assign it to the capacity you choose.*?route events.*?into Eventhouse tables") {
    throw 'The host picker did not explain where the workspace and event data go.'
}
if ($plan.Text -notmatch 'Visible but not selectable for monitoring:' -or
    $plan.Text -notmatch '- East US: East host \(F32\) - Not a Capacity Admin' -or
    $plan.Text -notmatch "Reuse workspace.*|Create workspace '[^']+' on 'East host'" -or
    $plan.Text -match 'feeds each for: [^\r\n]*East host') {
    throw 'The assignment-only capacity should be excluded as a source but selectable as a host.'
}
$retryPlan = Run-Installer @('all', 'skip', '1', '1') @{ WhatIf = $true }
if ($retryPlan.Code -ne 0 -or $retryPlan.Text -notmatch 'Enter a number from 1 to 2' -or
    $retryPlan.Text -notmatch "Create workspace '[^']+' on 'East host'" -or $state.Writes -ne 0) {
    throw 'An invalid host choice should prompt again without dropping a region from the plan.'
}
$cancelled = Run-Installer ($planInputs + @('maybe', 'n'))
if ($cancelled.Code -ne 0 -or $cancelled.Text -notmatch 'Cancelled; no resources created' -or $state.Writes -ne 0 -or $state.LoginCount -ne 0) {
    throw 'Cancellation did not exit cleanly without resource changes.'
}
if ($cancelled.Text -notmatch 'Enter Y or N') { throw 'Invalid confirmation did not prompt again.' }

$state.SignedIn = $false
$state.Progress = @()
$state.DestinationCreating = $true
$applied = Run-Installer @('', '1', '1', '')
if ($applied.Code -ne 0 -or $state.LoginCount -ne 1 -or $state.Writes -ne 10 -or $state.Workspaces.Count -ne 2 -or
    $applied.Text -notmatch 'Receiving data' -or $applied.Text -notmatch 'waiting for events' -or $applied.Text -notmatch '/kqlEndpoint') {
    throw "A single run did not sign in, create, and verify the two distinct regional stacks:`n$($applied.Text)"
}
if ($applied.Text -notmatch 'Selected 2 capacities across 2 regions' -or
    $applied.Text -notmatch 'Region 2 of 2: West US 3' -or $applied.Text -notmatch 'Create telemetry database and tables' -or
    $applied.Text -notmatch 'Check .* for recent events' -or
    ($state.Progress -join "`n") -notmatch 'Fabric status \[Request accepted \(\d+s elapsed; next \d+s\)\]') {
    throw 'Deployment did not report its current step and waiting progress.'
}
$topologyProgress = @($state.Progress | Where-Object { $_ -like '*Dest: Creating*' })
if ($topologyProgress.Count -ne 1 -or $topologyProgress[0].Length -gt 79 -or
    $topologyProgress[0] -notmatch 'Fabric status \[Source: Running \| Dest: Creating \(\d+s elapsed; next 5s\)\]') {
    throw "Expected the full Eventstream wait status to fit in an 80-column terminal: $topologyProgress"
}
if ([regex]::Matches($applied.Text, 'SRE Agent handoff').Count -ne 1 -or
    $applied.Text -notmatch '(?s)Receiving data.*SRE Agent handoff\s+East US\s+Workspace: [^\n]+\n\s+Suggested connector: [^\n]+\n\s+MCP URI: [^\n]+\n\s+West US 3\s+Workspace: [^\n]+\n\s+Suggested connector: [^\n]+\n\s+MCP URI: [^\n]+$') {
    throw "Expected one final handoff with exactly three lines per region:`n$($applied.Text)"
}
$state.Expired = $true
$rerun = Run-Installer @('all', 'y')
if ($rerun.Code -ne 0 -or $state.LoginCount -ne 2 -or $state.Writes -ne 10) { throw 'Rerun did not renew an expired session or created duplicate items.' }

$state.Warning = $true
$failed = Run-Installer @('1', 'y')
Assert-InstallerBlocked $failed 'EventhouseDestination=Warning*verification failures'
if ($failed.Text -match 'SRE Agent handoff') { throw 'Unverified setup must not be presented as ready for handoff.' }
$state.Warning = $false

$state.FailLro = $true
Assert-InstallerBlocked (Run-Installer @('1', '1', 'y') @{ WorkspacePrefix = 'FailedTest' }) 'SubscriptionFailed*verification failures'
$state.FailLro = $false

$east = $state.Workspaces.Values | Where-Object displayName -eq 'SRE-Fabric-Monitoring-eastus'
$eastStream = $state.Items[$east.id].Values | Where-Object displayName -like 'CapacityOverview_*'
$part = $state.Definitions[$eastStream.id].parts[0]
$original = $part.payload
$json = (Read-Part @($part) 'eventstream.json').Replace('"FabricCapacityOverview"', '"DifferentTable"')
$part.payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
Assert-InstallerBlocked (Run-Installer @('1', 'y')) "different 'tableName'*verification failures"
$part.payload = $original

($state.Items[$east.id].Values | Where-Object type -eq 'Eventhouse').description = 'Customer-owned'
Assert-InstallerBlocked (Run-Installer @('1', 'y')) 'not an unambiguous match*verification failures'
if ($state.Writes -ne 15) { throw 'Conflicting item was changed.' }

$state.OmitOperationId = $true
Assert-InstallerBlocked (Run-Installer @('1', '1', 'y') @{ WorkspacePrefix = 'ForeignLocationTest' }) 'Create Eventhouse was accepted*outside the expected HTTPS origin*It was not followed'
if ($state.UnexpectedHostRequests) { throw 'The installer sent a request to an unexpected host.' }

Write-Host 'Fabric capacity telemetry installer mock tests passed.'
