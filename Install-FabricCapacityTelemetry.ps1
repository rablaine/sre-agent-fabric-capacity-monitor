[CmdletBinding(SupportsShouldProcess)]
param(
    [guid] $TenantId,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,39}$')]
    [string] $WorkspacePrefix = 'SRE-Fabric-Monitoring'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
trap {
    Write-Warning "Setup stopped: $($_.Exception.Message)"
    Write-Verbose $_.ScriptStackTrace
    exit 1
}

$fabric = 'https://api.fabric.microsoft.com/v1'
$powerBi = 'https://api.powerbi.com/v1.0/myorg'
$tokens = @{}
$feeds = @(
    @{ Name = 'Overview'; Table = 'FabricCapacityOverview'; Source = 'FabricCapacityOverviewEvents'; Event = 'Microsoft.Fabric.Capacity.Summary' }
    @{ Name = 'Operations'; Table = 'FabricCapacityOperations'; Source = 'FabricCapacityOperationEvents'; Event = 'Microsoft.Fabric.CapacityOperationEvents.Operation' }
)

function Find-DeploymentPowerShell {
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $path = if ($command) { $command.Source }
    elseif ($env:ProgramFiles) {
        $standardPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $standardPath -PathType Leaf) { $standardPath }
    }
    if ($path) {
        $version = & $path -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        if ($LASTEXITCODE -eq 0 -and ($version -as [version]) -ge [version]'7.2') { $path }
    }
}

function Get-MissingLocalPrerequisites($ModernPowerShell) {
    if ($PSVersionTable.PSVersion -lt [version]'7.2' -and -not $ModernPowerShell) {
        @{ Name = 'PowerShell 7.2 or later'; Package = 'Microsoft.PowerShell'; Url = 'https://learn.microsoft.com/powershell/scripting/install/installing-powershell' }
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        @{ Name = 'Azure CLI (az)'; Package = 'Microsoft.AzureCLI'; Url = 'https://learn.microsoft.com/cli/azure/install-azure-cli' }
    }
}

function Show-MissingLocalPrerequisites($Missing) {
    foreach ($tool in $Missing) { Write-Host "  $($tool.Name): $($tool.Url)" }
}

function Install-LocalPrerequisites($Missing) {
    Write-Host 'Local prerequisites still needed:'
    Show-MissingLocalPrerequisites $Missing
    if ($WhatIfPreference) {
        Write-Warning 'Preview cannot continue until the missing tools are installed. No tools were installed.'
        return $false
    }
    if ($env:OS -ne 'Windows_NT' -or -not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning 'Automatic installation requires Windows Package Manager (winget). Use the links above to install manually, then open a new terminal and rerun.'
        if ($env:OS -eq 'Windows_NT') { Write-Host '  Windows Package Manager: https://learn.microsoft.com/windows/package-manager/winget/' }
        return $false
    }
    do {
        $answer = (Read-Host 'Install the missing tools with WinGet? [Y/n]').Trim()
        if ($answer -notin '', 'y', 'n') { Write-Warning 'Enter Y or N.' }
    } while ($answer -notin '', 'y', 'n')
    if ($answer -eq 'n') {
        Write-Warning 'Setup blocked. Install the missing tools using the links above, then rerun.'
        return $false
    }
    $originalEncoding = [Console]::OutputEncoding
    try {
        # WinGet emits UTF-8, but Windows PowerShell can decode native output using an OEM code page.
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        foreach ($tool in $Missing) {
            Write-Host "Installing $($tool.Name) with WinGet..."
            winget install --id $tool.Package --exact --source winget --accept-package-agreements --accept-source-agreements |
                ForEach-Object {
                    $line = $_.Trim()
                    if ($line -and $line -notmatch '^(?:[-\\|/]|[\u2580-\u259F]+(?:\s+.*)?)$') {
                        Write-Host "  $line"
                    }
                }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "WinGet returned exit code $LASTEXITCODE for $($tool.Name). Checking whether the tool is available before continuing."
            }
        }
    }
    finally { [Console]::OutputEncoding = $originalEncoding }
    $env:Path = (@($env:Path,
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }) -join ';'
    $true
}

function Get-Token {
    param([string] $Resource, [switch] $Probe)
    if (-not $tokens.ContainsKey($Resource) -or $tokens[$Resource].RefreshAfter -lt [datetime]::UtcNow) {
        $tokenArgs = @('account', 'get-access-token', '--tenant', $TenantId, '--resource', $Resource, '--query', 'accessToken', '-o', 'tsv', '--only-show-errors')
        $value = if ($Probe) { az @tokenArgs 2>$null } else { az @tokenArgs }
        if ($LASTEXITCODE -ne 0 -or -not $value) {
            if ($Probe) { return }
            throw "Cannot get a token for $Resource. Sign in as a user in the Fabric tenant and check Conditional Access and delegated API permissions."
        }
        $tokens[$Resource] = @{
            Value = ConvertTo-SecureString ([string]$value) -AsPlainText -Force
            RefreshAfter = [datetime]::UtcNow.AddMinutes(20)
        }
    }
    $tokens[$Resource].Value
}

function Get-RetryDelay($Headers, [int] $Default = 3) {
    $seconds = 0
    if ([int]::TryParse([string]($Headers['Retry-After'] | Select-Object -First 1), [ref]$seconds) -and $seconds -gt 0) {
        return $seconds
    }
    $Default
}

function Invoke-Api([string] $Method, [uri] $Uri, [hashtable] $Body, [string] $Action) {
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https' -or -not $Uri.IsDefaultPort -or $Uri.UserInfo) {
        throw "Refusing an unexpected API URL for $Action."
    }
    $resource = switch -Regex ($Uri.DnsSafeHost) {
        '^api\.fabric\.microsoft\.com$' { 'https://api.fabric.microsoft.com' }
        '^api\.powerbi\.com$' { 'https://analysis.windows.net/powerbi/api' }
        '^[a-z0-9.-]+\.kusto\.fabric\.microsoft\.com$' { 'https://api.kusto.windows.net' }
        default { throw "Refusing an unexpected API host for $Action." }
    }
    $options = @{
        Method = $Method; Uri = $Uri; Authentication = 'Bearer'; Token = (Get-Token $resource)
        MaximumRedirection = 0; TimeoutSec = 60; SkipHttpErrorCheck = $true
        Headers = @{ Accept = 'application/json' }
    }
    if ($null -ne $Body) {
        $options.ContentType = 'application/json'
        $options.Body = ConvertTo-Json -InputObject $Body -Depth 25 -Compress
    }
    for ($attempt = 0; ; $attempt++) {
        try { $response = Invoke-WebRequest @options }
        catch { throw "$Action failed to connect. Check the network and the portal before rerunning. $($_.Exception.Message)" }
        $delay = Get-RetryDelay $response.Headers
        if ($Method -eq 'GET' -and $response.StatusCode -eq 429 -and $attempt -lt 2 -and $delay -le 60) {
            Start-Sleep -Seconds $delay
            continue
        }
        if ($response.StatusCode -notin 200, 201, 202) {
            $data = $null
            if ($response.Content -match '^\s*\{') {
                try { $data = ConvertFrom-Json -InputObject $response.Content -AsHashtable }
                catch { $data = @{ message = 'The service error body was not valid JSON.' } }
            }
            $hint = switch ([int]$response.StatusCode) {
                { $_ -in 401, 403 } { 'Check delegated scopes, Fabric roles, and tenant settings.' }
                409 { 'Check for an existing or in-progress item before rerunning.' }
                429 { "Rate limited; wait at least $delay seconds before rerunning." }
            }
            $errorCode = if ($data.errorCode) { $data.errorCode } else { $data.error.code }
            $message = if ($data.message) { $data.message } else { $data.error.message }
            throw "$Action failed (HTTP $($response.StatusCode)): $errorCode $message $hint Request ID: $($data.requestId)"
        }
        $data = if ($response.Content -and $response.Content -ne 'null') {
            ConvertFrom-Json -InputObject $response.Content -AsHashtable -NoEnumerate
        }
        return @{ Status = $response.StatusCode; Data = $data; Headers = $response.Headers }
    }
}

function Resolve-ApiLink([uri] $Origin, [string] $Link, [string] $Action) {
    $uri = [uri]::new($Origin, $Link)
    if ($uri.GetLeftPart([UriPartial]::Authority) -ne $Origin.GetLeftPart([UriPartial]::Authority) -or $uri.UserInfo) {
        throw "${Action}: Fabric or Power BI returned a URL outside the expected HTTPS origin. It was not followed."
    }
    $uri
}

function Get-ApiCollection([uri] $Uri, [string] $Action) {
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    while ($Uri) {
        if (-not $seen.Add($Uri.AbsoluteUri)) { throw "$Action returned a repeated continuation URL." }
        $page = (Invoke-Api GET $Uri $null $Action).Data
        if ($null -eq $page.value) { throw "$Action did not return a collection." }
        $page.value
        $next = if ($page.continuationUri) { $page.continuationUri } else { $page.'@odata.nextLink' }
        if ($page.continuationToken -and -not $next) { throw "$Action returned a continuation token without a URL." }
        $Uri = if ($next) { Resolve-ApiLink $Uri $next "Continue $Action" }
    }
}

function Wait-FabricStatus([string] $Status, [int] $Seconds, [System.Diagnostics.Stopwatch] $Timer) {
    for ($remaining = $Seconds; $remaining -gt 0; $remaining -= $interval) {
        Write-Progress -Id 2 -ParentId 1 -Activity 'Fabric status' -Status "$Status ($([int]$Timer.Elapsed.TotalSeconds)s elapsed; next ${remaining}s)"
        $interval = [Math]::Min(5, $remaining)
        Start-Sleep -Seconds $interval
    }
}

function Invoke-FabricOperation([uri] $Uri, [hashtable] $Body, [string] $Action) {
    Write-Host "  $Action..."
    $response = Invoke-Api POST $Uri $Body $Action
    if ($response.Status -ne 202) { return $response.Data }
    $operationId = [guid]::Empty
    $idHeader = $response.Headers['x-ms-operation-id'] | Select-Object -First 1
    $useOperationId = $idHeader -and [guid]::TryParseExact([string]$idHeader, 'D', [ref]$operationId) -and $operationId -ne [guid]::Empty
    if ($useOperationId) {
        $poll = [uri]"$fabric/operations/$operationId"
    } else {
        $location = $response.Headers['Location'] | Select-Object -First 1
        if (-not $location) { throw "$Action was accepted but Fabric returned neither a valid operation ID nor a polling URL." }
        $poll = Resolve-ApiLink $Uri $location "$Action was accepted, but its status could not be checked"
    }
    $deadline = [datetime]::UtcNow.AddMinutes(10)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'Request accepted'
    try {
        while ([datetime]::UtcNow.AddSeconds((Get-RetryDelay $response.Headers)) -lt $deadline) {
            Wait-FabricStatus $status (Get-RetryDelay $response.Headers) $timer
            $response = Invoke-Api GET $poll $null "Poll $Action"
            switch ($response.Data.status) {
                'Succeeded' {
                    $result = if ($useOperationId) { "$fabric/operations/$operationId/result" } else {
                        $resultLink = $response.Headers['Location'] | Select-Object -First 1
                        if ($resultLink) { Resolve-ApiLink $Uri $resultLink "Read result for $Action" }
                        else { "$($poll.AbsoluteUri.TrimEnd('/'))/result" }
                    }
                    if ($result -eq $poll) { $result = "$($poll.AbsoluteUri.TrimEnd('/'))/result" }
                    return (Invoke-Api GET $result $null "Read result for $Action").Data
                }
                { $_ -in 'NotStarted', 'Running' } { $status = "Operation: $_" }
                default { throw "$Action did not succeed ($($response.Data.status)): $($response.Data.error | ConvertTo-Json -Depth 8 -Compress). Operation: $poll" }
            }
        }
        throw "$Action is still pending. Check operation $poll before rerunning."
    } finally {
        Write-Progress -Id 2 -ParentId 1 -Activity 'Fabric status' -Completed
    }
}

function Select-Numbers([string] $Text, [int] $Count, [switch] $Multiple) {
    if ($Multiple -and $Text.Trim() -in '', 'all') { return (0..($Count - 1)) }
    $parts = $Text.Split(',')
    if (-not $Multiple -and $parts.Count -ne 1) { throw [ArgumentException]::new('Choose a single number.') }
    $indexes = foreach ($part in $parts) {
        $number = 0
        if (-not [int]::TryParse($part.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $Count) {
            throw [ArgumentException]::new("Enter a number from 1 to $Count$(if ($Multiple) { ', comma-separated numbers, or press Enter for all' }).")
        }
        $number - 1
    }
    $indexes | Select-Object -Unique
}

function Get-RegionKey([string] $Region) {
    ($Region -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
}

function New-Part([string] $Path, [string] $Content) {
    @{ path = $Path; payloadType = 'InlineBase64'; payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content)) }
}

function Find-Owned($Items, [string] $Name, [string] $Type, [string] $Marker) {
    $matchesByName = @($Items | Where-Object displayName -eq $Name)
    if ($matchesByName.Count -eq 0) { return }
    if ($matchesByName.Count -ne 1 -or $matchesByName[0].type -ne $Type -or $matchesByName[0].description -cne $Marker) {
        throw "'$Name' exists but is not an unambiguous match for this setup. Inspect it in Fabric; nothing will overwrite it."
    }
    $matchesByName[0]
}

function New-StreamGraph($Feed, [string] $CapacityId, [string] $WorkspaceId, [string] $DatabaseId, [string] $DatabaseName) {
    @{
        compatibilityLevel = '1.1'; operators = @()
        sources = @(@{ name = 'CapacityEvents'; type = $Feed.Source; properties = @{
            eventScope = 'Capacity'; capacityId = $CapacityId; includedEventTypes = @($Feed.Event); filters = @()
        } })
        streams = @(@{ name = 'CapacityStream'; type = 'DefaultStream'; properties = @{}; inputNodes = @(@{ name = 'CapacityEvents' }) })
        destinations = @(@{ name = 'EventhouseDestination'; type = 'Eventhouse'; inputNodes = @(@{ name = 'CapacityStream' }); properties = @{
            dataIngestionMode = 'ProcessedIngestion'; workspaceId = $WorkspaceId; itemId = $DatabaseId
            databaseName = $DatabaseName; tableName = $Feed.Table
            inputSerialization = @{ type = 'Json'; properties = @{ encoding = 'UTF8' } }
        } })
    }
}

function Assert-StreamDefinition($Definition, $Expected) {
    $part = @($Definition.definition.parts | Where-Object path -ceq 'eventstream.json')
    if ($part.Count -ne 1 -or $part[0].payloadType -ne 'InlineBase64') { throw 'Could not read the Eventstream definition.' }
    $graph = ConvertFrom-Json -AsHashtable -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part[0].payload)))
    if ($graph.operators.Count -ne 0) { throw 'Existing Eventstream has unexpected operators; it will not be changed.' }
    foreach ($kind in 'sources', 'streams', 'destinations') {
        $nodes = $graph[$kind]
        $target = $Expected[$kind][0]
        if ($nodes.Count -ne 1 -or $nodes[0].name -ne $target.name -or $nodes[0].type -ne $target.type -or
            ($nodes[0].inputNodes.name -join ',') -ne ($target.inputNodes.name -join ',')) {
            throw "Existing Eventstream has unexpected $kind; it will not be changed."
        }
        $p = $nodes[0].properties
        foreach ($key in $target.properties.Keys) {
            if ($key -eq 'inputSerialization') {
                if ($p.inputSerialization.type -ne 'Json' -or $p.inputSerialization.properties.encoding -ne 'UTF8') {
                    throw 'Existing Eventstream uses a different serialization; it will not be changed.'
                }
            } elseif (($p[$key] -join ',') -ne ($target.properties[$key] -join ',')) {
                throw "Existing Eventstream has a different '$key'; it will not be changed."
            }
        }
    }
}

function Assert-Topology([string] $StreamUri, [string] $Label) {
    $action = "Verify $Label Eventstream"
    Write-Host "  $action..."
    $deadline = [datetime]::UtcNow.AddMinutes(2)
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $topology = (Invoke-Api GET "$StreamUri/topology" $null 'Check Eventstream topology').Data
            $nodes = @($topology.sources) + @($topology.destinations)
            if ($topology.sources.Count -eq 1 -and $topology.destinations.Count -eq 1) {
                if (@($nodes | Where-Object { $_.status -in 'Warning', 'Failed', 'Stopped' -or $_.error }).Count) {
                    throw "Eventstream needs attention: $(($nodes | ForEach-Object { "$($_.name)=$($_.status) $($_.error | ConvertTo-Json -Depth 8 -Compress)" }) -join '; '). Inspect the source and destination in Fabric, then rerun."
                }
                if ($nodes[0].status -eq 'Running' -and $nodes[1].status -eq 'Running') { return }
            }
            $status = if ($topology.sources.Count -eq 1 -and $topology.destinations.Count -eq 1) {
                "Source: $($nodes[0].status) | Dest: $($nodes[1].status)"
            } else { 'Waiting for topology' }
            Wait-FabricStatus $status 5 $timer
        } while ([datetime]::UtcNow -lt $deadline)
        throw "Eventstream readiness not confirmed: $($nodes.status -join ', '). Check its topology in Fabric, then rerun."
    } finally {
        Write-Progress -Id 2 -ParentId 1 -Activity 'Fabric status' -Completed
    }
}

function Get-LatestEvent($Db, [string] $DatabaseName, $Feed, [guid] $CapacityId) {
    $origin = [uri]$Db.properties.queryServiceUri
    if (-not $origin.IsAbsoluteUri -or $origin.AbsolutePath -ne '/' -or $origin.Query -or $origin.Fragment) {
        throw 'Fabric returned an unexpected Eventhouse query URI.'
    }
    $query = @"
$($Feed.Table)
| where ['time'] between (ago(2h) .. now())
| where ['type'] == '$($Feed.Event)' and tostring(parse_json(tostring(data)).capacityId) =~ '$CapacityId'
| summarize LastEventUtc = max(['time'])
"@
    $frames = (Invoke-Api POST "$($origin.GetLeftPart([UriPartial]::Authority))/v2/rest/query" @{ db = $DatabaseName; csl = $query } 'Verify Eventhouse rows').Data
    $completion = @($frames | Where-Object FrameType -eq 'DataSetCompletion')
    $table = @($frames | Where-Object { $_.FrameType -eq 'DataTable' -and $_.TableKind -eq 'PrimaryResult' })
    if ($completion.Count -ne 1 -or $completion[0].HasErrors -ne $false -or $completion[0].Cancelled -eq $true -or
        $table.Count -ne 1 -or ($table[0].Columns.ColumnName -join ',') -cne 'LastEventUtc' -or $table[0].Rows.Count -ne 1) {
        throw 'Eventhouse query did not return a complete ingestion check.'
    }
    $table[0].Rows[0][0]
}

function Invoke-RegionalSetup($Plan) {
    $marker = "Fabric capacity telemetry setup v1: $($Plan.WorkspaceName)"
    $ws = $Plan.Workspace
    if (-not $ws) {
        $ws = Invoke-FabricOperation "$fabric/workspaces" @{
            displayName = $Plan.WorkspaceName; description = $marker; capacityId = $Plan.HostCapacity.id
        } "Create workspace $($Plan.WorkspaceName)"
    }
    $root = "$fabric/workspaces/$($ws.id)"
    Write-Host "  Verify workspace '$($Plan.WorkspaceName)' and check existing items..."
    $ws = (Invoke-Api GET $root $null 'Verify workspace capacity assignment').Data
    if ($ws.capacityId -ne $Plan.HostCapacity.id -or $ws.description -cne $marker) {
        throw 'Workspace is not on the selected host capacity or does not match this setup. No items will be created there.'
    }
    $items = @(Get-ApiCollection "$root/items" 'List workspace items')
    # Fabric creates a default KQL database with the same display name as its Eventhouse.
    $house = Find-Owned @($items | Where-Object type -ne 'KQLDatabase') 'CapacityTelemetryEventhouse' 'Eventhouse' $marker
    $dbItem = Find-Owned $items 'CapacityTelemetry' 'KQLDatabase' $marker
    if (-not $house) {
        if ($dbItem) { throw 'The monitoring database already exists without its expected Eventhouse.' }
        $house = Invoke-FabricOperation "$root/eventhouses" @{ displayName = 'CapacityTelemetryEventhouse'; description = $marker } 'Create Eventhouse'
    }
    if (-not $dbItem) {
        $schema = ($feeds | ForEach-Object { ".create-merge table $($_.Table) (['id']:string, ['type']:string, ['time']:datetime, ['data']:dynamic)" }) -join "`n"
        $dbItem = Invoke-FabricOperation "$root/kqlDatabases" @{
            displayName = 'CapacityTelemetry'; description = $marker
            definition = @{ parts = @(
                New-Part 'DatabaseProperties.json' (ConvertTo-Json -Compress @{ databaseType = 'ReadWrite'; parentEventhouseItemId = $house.id })
                New-Part 'DatabaseSchema.kql' $schema
            ) }
        } 'Create telemetry database and tables'
    }
    $db = (Invoke-Api GET "$root/kqlDatabases/$($dbItem.id)" $null 'Verify telemetry database').Data
    if ($db.properties.parentEventhouseItemId -ne $house.id -or $db.properties.databaseType -ne 'ReadWrite' -or $db.description -cne $marker) {
        throw 'Telemetry database does not match the expected Eventhouse and setup.'
    }
    $dbName = if ($db.properties.databaseName) { $db.properties.databaseName } else { $db.displayName }
    $verified = $true
    foreach ($capacity in $Plan.Capacities) {
        foreach ($feed in $feeds) {
            $name = "Capacity$($feed.Name)_$(([guid]$capacity.id).ToString('N'))"
            $label = "$($capacity.displayName) [$($feed.Name)]"
            try {
                $stream = Find-Owned $items $name 'Eventstream' $marker
                $graph = New-StreamGraph $feed $capacity.id $ws.id $db.id $dbName
                if ($stream) {
                    $definition = Invoke-FabricOperation "$root/eventstreams/$($stream.id)/getDefinition?format=eventstream" $null 'Read existing Eventstream definition'
                    Assert-StreamDefinition $definition $graph
                } else {
                    $stream = Invoke-FabricOperation "$root/eventstreams" @{
                        displayName = $name; description = $marker
                        definition = @{ format = 'eventstream'; parts = @(New-Part 'eventstream.json' (ConvertTo-Json -InputObject $graph -Depth 20 -Compress)) }
                    } "Create $label Eventstream"
                }
                Assert-Topology "$root/eventstreams/$($stream.id)" $label
            } catch {
                Write-Warning "$label - Setup not verified: $($_.Exception.Message)"
                $verified = $false
                continue
            }
            try {
                Write-Host "  Check $label for recent events..."
                $last = Get-LatestEvent $db $dbName $feed $capacity.id
                if ($last) { Write-Host "  $label - Receiving data; last event UTC: $last" }
                else { Write-Host "  $label - Configured; waiting for events (no matching row in the last two hours)." }
            } catch {
                Write-Warning "$label - Configured; ingestion check failed: $($_.Exception.Message)"
                $verified = $false
            }
        }
    }
    if ($verified) {
        @{
            Region = $Plan.Region
            WorkspaceLine = "Workspace: $($ws.displayName) | Eventhouse: $($house.displayName) | Database: $dbName"
            ConnectorLine = "Suggested connector: FabricCapacity_$($Plan.RegionKey)"
            McpLine = "MCP URI: $fabric/mcp/dataPlane/workspaces/$($ws.id)/items/$($db.id)/kqlEndpoint"
        }
    }
}

function Get-CliAccount {
    $json = az account show --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and $json) { ConvertFrom-Json -InputObject ($json -join "`n") }
}

$modernPowerShell = if ($PSVersionTable.PSVersion -lt [version]'7.2') { Find-DeploymentPowerShell }
$missing = @(Get-MissingLocalPrerequisites $modernPowerShell)
if ($missing.Count) {
    if (-not (Install-LocalPrerequisites $missing)) { exit 1 }
    $modernPowerShell = if ($PSVersionTable.PSVersion -lt [version]'7.2') { Find-DeploymentPowerShell }
    $missing = @(Get-MissingLocalPrerequisites $modernPowerShell)
    if ($missing.Count) {
        Write-Warning 'Setup blocked. If a tool was just installed but is not detected, open a new terminal and rerun. Otherwise, install the remaining tools manually:'
        Show-MissingLocalPrerequisites $missing
        exit 1
    }
}
if ($modernPowerShell) {
    $childArgs = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath)
    if ($TenantId) { $childArgs += @('-TenantId', $TenantId.ToString()) }
    $childArgs += @('-WorkspacePrefix', $WorkspacePrefix)
    foreach ($switch in 'WhatIf', 'Confirm', 'Verbose', 'Debug') {
        if ($PSBoundParameters.ContainsKey($switch)) {
            if ($PSBoundParameters[$switch]) { $childArgs += "-$switch" }
            else { $childArgs += "-${switch}:`$false" }
        }
    }
    if ($WhatIfPreference -and -not $PSBoundParameters.ContainsKey('WhatIf')) { $childArgs += '-WhatIf' }
    & $modernPowerShell @childArgs
    exit $LASTEXITCODE
}
$account = Get-CliAccount
$hasMatchingUser = $account.user.type -eq 'user' -and $account.tenantId -and
    (-not $TenantId -or [guid]$account.tenantId -eq $TenantId)
if ($hasMatchingUser -and -not $TenantId) { $TenantId = [guid]$account.tenantId }
$hasUsableSession = $hasMatchingUser -and (Get-Token 'https://api.fabric.microsoft.com' -Probe) -and
    (Get-Token 'https://analysis.windows.net/powerbi/api' -Probe)
if (-not $hasUsableSession) {
    Write-Host 'Azure CLI sign-in is required. Sign in with your Fabric user account.'
    $argsForLogin = @('login', '--allow-no-subscriptions', '--output', 'none')
    if ($TenantId) { $argsForLogin += @('--tenant', $TenantId) }
    az @argsForLogin
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Setup blocked: Azure CLI sign-in did not complete. Sign in to the Fabric tenant, then rerun.'
        exit 1
    }
    $tokens.Clear()
    $account = Get-CliAccount
}
if ($account.user.type -ne 'user' -or -not $account.tenantId -or ($TenantId -and [guid]$account.tenantId -ne $TenantId)) {
    Write-Warning 'Setup blocked: Azure CLI does not have a user session in the requested Fabric tenant. Sign in to that tenant and rerun.'
    exit 1
}
if (-not $TenantId) { $TenantId = [guid]$account.tenantId }
Write-Host "Fabric tenant: $TenantId | Signed in as: $($account.user.name)"

$capacityRoles = @{}
foreach ($item in @(Get-ApiCollection "$powerBi/capacities" 'Read Power BI capacity roles (requires Capacity.Read.All)')) {
    $capacityRoles[$item.id] = $item.capacityUserAccessRight
}
$inventory = @(Get-ApiCollection "$fabric/capacities" 'List Fabric capacities' | Sort-Object region, displayName, id -Unique)
$eligible = @()
$hosts = @()
$excluded = @()
foreach ($capacity in $inventory) {
    $reasons = @()
    if ($capacity.sku -notmatch '^F\d+$') {
        $reasons += 'Not an F SKU'
    } else {
        if ($capacity.state -eq 'Inactive') { $reasons += 'Inactive' }
        elseif ($capacity.state -ne 'Active') { $reasons += "Not active ($($capacity.state))" }
        if (-not (Get-RegionKey $capacity.region)) { $reasons += 'Region unknown' }
        if (-not $reasons.Count) { $hosts += $capacity }

        $role = $capacityRoles[$capacity.id]
        if ($role -in 'Assign', 'None') {
            $reasons += "Not a Capacity Admin (reported access: $role)"
        } elseif ($role -ne 'Admin') {
            $reasons += 'Capacity Admin access could not be verified'
        }
    }
    if ($reasons.Count) {
        $excluded += "  - $($capacity.region): $($capacity.displayName) ($($capacity.sku)) - $($reasons -join '; ')"
    } else {
        $eligible += $capacity
    }
}
if ($excluded.Count) {
    Write-Host "`nVisible but not selectable for monitoring:"
    foreach ($line in $excluded) { Write-Host $line }
}
if ($eligible.Count) { Write-Host "`nSelect from these capacities to monitor:" }
for ($i = 0; $i -lt $eligible.Count; $i++) {
    $capacity = $eligible[$i]
    $suffix = if (@($inventory | Where-Object displayName -eq $capacity.displayName).Count -gt 1) { " [ID ending $($capacity.id.Substring($capacity.id.Length - 8))]" }
    Write-Host "  $($i + 1). $($capacity.region): $($capacity.displayName) ($($capacity.sku), Active)$suffix"
}
if (-not $eligible.Count) {
    $fSkus = @($inventory | Where-Object sku -Match '^F\d+$')
    $reason = if (-not $fSkus.Count) {
        'No Fabric F SKU capacities are visible to this user. Check that you signed in to the correct tenant and have access to an existing F SKU.'
    } elseif (-not @($fSkus | Where-Object state -eq 'Active').Count) {
        'None of the visible Fabric F SKU capacities are active. If your intended capacity is paused, open Azure portal > Microsoft Fabric > your capacity > Resume. Resuming restarts billing. Wait until it is active, then rerun.'
    } else {
        'No active Fabric F SKU has both a known region and confirmed Capacity Admin access. Check the reasons listed above.'
    }
    Write-Warning "Setup blocked: $reason No resources were created."
    exit 1
}
$selected = @($eligible[@(Select-Numbers (Read-Host 'Enter capacity numbers (e.g. 1,3), or press Enter for all eligible capacities') $eligible.Count -Multiple)])
$regions = @($selected | Group-Object -Property { Get-RegionKey $_.region })
if ($regions.Count -gt 1) {
    Write-Host "`nSelected $($selected.Count) capacities across $($regions.Count) regions. Each region uses its own monitoring workspace so Capacity Operation events stay in the same region as their source."
}

$workspaces = @(Get-ApiCollection "$fabric/workspaces" 'List accessible Fabric workspaces')
$plans = @()
$blocked = @()
foreach ($group in $regions) {
    $region = $group.Group[0].region
    $workspaceName = "$WorkspacePrefix-$($group.Name)"
    try {
        $existing = Find-Owned $workspaces $workspaceName 'Workspace' "Fabric capacity telemetry setup v1: $workspaceName"
        $regionalHosts = @($hosts | Where-Object { (Get-RegionKey $_.region) -eq $group.Name })
        if ($existing) {
            $hostChoice = @($regionalHosts | Where-Object id -eq $existing.capacityId)
            if ($hostChoice.Count -ne 1) { throw "Existing workspace '$workspaceName' is not on an accessible active F SKU in this region." }
            $hostCapacity = $hostChoice[0]
        } else {
            Write-Host "`nChoose an existing Fabric capacity in $region for the monitoring workspace:"
            Write-Host "  After you confirm, setup will create workspace '$workspaceName' and assign it to the capacity you choose."
            Write-Host "  Inside that workspace, Eventstreams will route events from the capacities you selected for monitoring into Eventhouse tables."
            for ($i = 0; $i -lt $regionalHosts.Count; $i++) {
                $choice = $regionalHosts[$i]
                $tag = if ($choice.id -in $group.Group.id) { '; also monitored' }
                $suffix = if (@($regionalHosts | Where-Object displayName -eq $choice.displayName).Count -gt 1) { " [ID ending $($choice.id.Substring($choice.id.Length - 8))]" }
                Write-Host "  $($i + 1). $($choice.displayName) ($($choice.sku)$tag)$suffix"
            }
            do {
                $answer = Read-Host 'Enter the capacity number for the monitoring workspace'
                $hostIndex = $null
                try { $hostIndex = Select-Numbers $answer $regionalHosts.Count }
                catch [ArgumentException] { Write-Warning $_.Exception.Message }
            } while ($null -eq $hostIndex)
            $hostCapacity = $regionalHosts[$hostIndex]
        }
        $plans += @{ Region = $region; RegionKey = $group.Name; WorkspaceName = $workspaceName; Workspace = $existing; HostCapacity = $hostCapacity; Capacities = $group.Group }
    } catch {
        $blocked += $region
        Write-Warning "$region ($($group.Group.displayName -join ', ')): $($_.Exception.Message)"
    }
}
if (-not $plans.Count) {
    Write-Warning 'Setup stopped: No regions are ready for setup. No resources were created.'
    exit 1
}
Write-Host "`nDeployment plan (Eventstreams and Eventhouse consume Fabric capacity):"
foreach ($plan in $plans) {
    $action = if ($plan.Workspace) { 'Reuse workspace' } else { 'Create workspace' }
    Write-Host "  $($plan.Region): $action '$($plan.WorkspaceName)' on '$($plan.HostCapacity.displayName)'."
    Write-Host "    Ensure Eventhouse + database + two tables; two feeds each for: $($plan.Capacities.displayName -join ', ')"
}
if ($blocked.Count) { Write-Warning "Not in plan: $($blocked -join ', ')." }
if (-not $PSCmdlet.ShouldProcess(($plans.WorkspaceName -join ', '), 'Set up and verify Fabric capacity telemetry')) {
    Write-Host 'Plan only; no resources created.'
    exit 0
}
do {
    $answer = (Read-Host 'Apply this deployment plan? [Y/n]').Trim()
    if ($answer -notin '', 'y', 'n') { Write-Warning 'Enter Y or N.' }
} while ($answer -notin '', 'y', 'n')
if ($answer -eq 'n') {
    Write-Host 'Cancelled; no resources created.'
    exit 0
}

$needsAttention = $blocked.Count -gt 0
$handoffs = @()
$regionNumber = 0
foreach ($plan in $plans) {
    $regionNumber++
    $status = "Region $regionNumber of $($plans.Count): $($plan.Region)"
    Write-Host "`n$status"
    Write-Progress -Id 1 -Activity 'Set up Fabric capacity telemetry' -Status $status -PercentComplete ([Math]::Floor(100 * ($regionNumber - 1) / $plans.Count))
    try {
        $handoff = Invoke-RegionalSetup $plan
        if ($handoff) { $handoffs += $handoff } else { $needsAttention = $true }
    } catch {
        $needsAttention = $true
        Write-Warning "$($plan.Region) - Regional setup not verified: $($_.Exception.Message)"
    }
    Write-Progress -Id 1 -Activity 'Set up Fabric capacity telemetry' -Completed
}
if ($needsAttention) {
    Write-Warning 'Setup completed with skipped regions or verification failures. Some Fabric items may already exist. Review the warnings and check the workspace in Fabric before rerunning or configuring SRE Agent for affected capacities.'
}
if ($handoffs.Count) {
    Write-Host "`nSRE Agent handoff"
    foreach ($entry in $handoffs) {
        Write-Host "`n$($entry.Region)"
        Write-Host "  $($entry.WorkspaceLine)"
        Write-Host "  $($entry.ConnectorLine)"
        Write-Host "  $($entry.McpLine)"
    }
}
if ($needsAttention) { exit 1 }
exit 0
