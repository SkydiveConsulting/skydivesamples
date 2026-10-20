#Requires -Version 7.2
<#
.SYNOPSIS
    Validates and deploys Azure Synapse workspace artifacts from the Synapse Git
    folder layout, using Microsoft's Az.Synapse module.

.DESCRIPTION

    -ValidateOnly  : offline checks, no Azure connection needed (build stage).
                     * every *.json parses, has "name" + "properties", name == file name
                     * no duplicate names per artifact type
                     * every referenceName (LinkedService, Dataset, DataFlow,
                       Pipeline, Notebook, SparkJobDefinition, IntegrationRuntime,
                       Credential) resolves to a file in the repo
                     * no circular references within a type
                     * every path in the overrides file exists

    Deploy (default): run inside AzurePowerShell@5 (WIF service connection).
                     1. stop started triggers
                     2. deploy in dependency order:
                        linkedService > dataset > dataflow > notebook > sqlscript >
                        sparkJobDefinition > pipeline > trigger
                        (topologically sorted within each type)
                     3. optionally delete artifacts not in source (-DeleteNotInSource)
                     4. start triggers whose runtimeState is "Started" in source,
                        plus any running trigger outside source that was stopped in step 1

    NOT deployed (warned about): integration runtimes, credentials, managed private
    endpoints / managed VNet, Spark pools, KQL scripts, Spark configurations,
    lake databases. Manage those in Terraform or extend this script.

.PARAMETER OverridesFile
    Per-environment JSON file. Keys are "<folder>/<artifactName>", values map a
    dot-separated property path to the new value. Numeric segments index arrays.
    {
      "linkedService/LS_KeyVault": { "properties.typeProperties.baseUrl": "https://kv-prod.vault.azure.net/" },
      "trigger/TR_Daily":          { "properties.runtimeState": "Started" }
    }
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string] $RootFolder,
    [string] $WorkspaceName,
    [string] $OverridesFile,
    [switch] $ValidateOnly,
    [switch] $DeleteNotInSource
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------------
$RefTypeToFolder = @{
    LinkedServiceReference      = 'linkedService'
    DatasetReference            = 'dataset'
    DataFlowReference           = 'dataflow'
    PipelineReference           = 'pipeline'
    NotebookReference           = 'notebook'
    SparkJobDefinitionReference = 'sparkJobDefinition'
    IntegrationRuntimeReference = 'integrationRuntime'
    CredentialReference         = 'credential'
}
$DeployOrder = @('linkedService', 'dataset', 'dataflow', 'notebook', 'sqlscript', 'sparkJobDefinition', 'pipeline', 'trigger')
# Folders that are read for reference validation but deployed elsewhere (e.g. Terraform)
$ReferenceOnlyFolders = @('integrationRuntime', 'credential')
$GetRemoveCmdlets = [ordered]@{
    trigger            = @('Get-AzSynapseTrigger',            'Remove-AzSynapseTrigger')
    pipeline           = @('Get-AzSynapsePipeline',           'Remove-AzSynapsePipeline')
    sparkJobDefinition = @('Get-AzSynapseSparkJobDefinition', 'Remove-AzSynapseSparkJobDefinition')
    sqlscript          = @('Get-AzSynapseSqlScript',          'Remove-AzSynapseSqlScript')
    notebook           = @('Get-AzSynapseNotebook',           'Remove-AzSynapseNotebook')
    dataflow           = @('Get-AzSynapseDataFlow',           'Remove-AzSynapseDataFlow')
    dataset            = @('Get-AzSynapseDataset',            'Remove-AzSynapseDataset')
    linkedService      = @('Get-AzSynapseLinkedService',      'Remove-AzSynapseLinkedService')
}
# Workspace-managed defaults, never deleted
$ProtectedNamePattern = '-WorkspaceDefault(Storage|SqlServer)$'
# Synapse node sizes by vCores, for Set-AzSynapseNotebook -ExecutorSize
$ExecutorSizeByCores = @{ 4 = 'Small'; 8 = 'Medium'; 16 = 'Large'; 32 = 'XLarge'; 64 = 'XXLarge' }

# PowerShell 7.5+ can keep date strings as strings; older versions convert them to
# DateTime, which can change trigger start times when re-serialised. Unmodified
# files are therefore always deployed from the original file.
$JsonReadArgs = @{ Depth = 100 }
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $JsonReadArgs.DateKind = 'String' }

$script:ValidationErrors = [System.Collections.Generic.List[string]]::new()

function Add-ValidationError([string] $Message) {
    $script:ValidationErrors.Add($Message)
    Write-Host "##vso[task.logissue type=error]$Message"
}
function Write-PipelineWarning([string] $Message) {
    Write-Host "##vso[task.logissue type=warning]$Message"
}
function New-NameSet { , [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }

# --------------------------------------------------------------------------------
# JSON helpers
# --------------------------------------------------------------------------------
function Get-References {
    param($Node, [System.Collections.Generic.List[object]] $Acc)
    if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return }
    if ($Node -is [System.Collections.IList]) {
        foreach ($n in $Node) { Get-References $n $Acc }
        return
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $props = $Node.PSObject.Properties
        $rn = $props['referenceName']; $ty = $props['type']
        # Expression-valued (dynamic) references are objects, not strings, and are skipped
        if ($rn -and $ty -and $rn.Value -is [string] -and $ty.Value -is [string]) {
            $Acc.Add([pscustomobject]@{ Type = $ty.Value; Name = $rn.Value })
        }
        foreach ($p in $props) { Get-References $p.Value $Acc }
    }
}

function Get-JsonChild($Node, [string] $Segment) {
    if ($Node -is [System.Collections.IList] -and $Segment -match '^\d+$') {
        if ([int]$Segment -lt $Node.Count) { return , $Node[[int]$Segment] }
        return $null
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $p = $Node.PSObject.Properties[$Segment]
        if ($p) { return , $p.Value }
    }
    return $null
}

function Set-JsonPath($Object, [string] $Path, $Value) {
    $segments = $Path -split '\.'
    $current = $Object
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $current = Get-JsonChild $current $segments[$i]
        if ($null -eq $current) { throw "segment '$($segments[$i])' not found" }
    }
    $last = $segments[-1]
    if ($current -is [System.Collections.IList] -and $last -match '^\d+$') {
        if ([int]$last -ge $current.Count) { throw "index $last out of range" }
        $current[[int]$last] = $Value
    }
    elseif ($current -is [System.Management.Automation.PSCustomObject]) {
        if ($current.PSObject.Properties[$last]) { $current.$last = $Value }
        else { $current | Add-Member -NotePropertyName $last -NotePropertyValue $Value }
    }
    else { throw "parent of '$last' is not an object or array" }
}

# --------------------------------------------------------------------------------
# Dependency ordering
# --------------------------------------------------------------------------------
function Visit-Node {
    param($Item, [string] $Folder, [hashtable] $ByName, [hashtable] $State,
          [System.Collections.Generic.List[object]] $Result, [string[]] $Chain)
    if ($State[$Item.Name] -eq 'done') { return }
    if ($State[$Item.Name] -eq 'visiting') {
        Add-ValidationError "Circular reference in ${Folder}: $((@($Chain) + $Item.Name) -join ' -> ')"
        return
    }
    $State[$Item.Name] = 'visiting'
    foreach ($ref in $Item.Refs) {
        if ($ref.Folder -eq $Folder -and $ref.Name -ne $Item.Name -and $ByName.ContainsKey($ref.Name)) {
            Visit-Node $ByName[$ref.Name] $Folder $ByName $State $Result (@($Chain) + $Item.Name)
        }
    }
    $State[$Item.Name] = 'done'
    $Result.Add($Item)
}

function Sort-ByDependency([object[]] $Items, [string] $Folder) {
    $byName = @{}
    foreach ($i in $Items) { $byName[$i.Name] = $i }
    $state  = @{}
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($i in $Items) { Visit-Node $i $Folder $byName $state $result @() }
    return , $result.ToArray()
}

# --------------------------------------------------------------------------------
# 1. Load
# --------------------------------------------------------------------------------
if (-not (Test-Path $RootFolder -PathType Container)) { throw "RootFolder '$RootFolder' not found." }
$RootFolder = (Resolve-Path $RootFolder).Path

$artifacts = [System.Collections.Generic.List[object]]::new()
foreach ($dir in Get-ChildItem -Path $RootFolder -Directory) {
    $known = $DeployOrder + $ReferenceOnlyFolders
    if ($dir.Name -notin $known) {
        Write-PipelineWarning "Folder '$($dir.Name)' is not handled by this script and will not be deployed."
        continue
    }
    $names = New-NameSet
    foreach ($file in Get-ChildItem -Path $dir.FullName -Filter '*.json' -File) {
        $rel = "$($dir.Name)/$($file.Name)"
        try   { $json = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json @JsonReadArgs }
        catch { Add-ValidationError "${rel}: invalid JSON - $($_.Exception.Message)"; continue }

        if (-not ($json -is [System.Management.Automation.PSCustomObject]) -or
            -not $json.PSObject.Properties['name'] -or -not $json.PSObject.Properties['properties']) {
            Add-ValidationError "${rel}: missing 'name' or 'properties'"; continue
        }
        if ($json.name -ne $file.BaseName) {
            Add-ValidationError "${rel}: name '$($json.name)' does not match file name"
        }
        if (-not $names.Add($json.name)) {
            Add-ValidationError "${rel}: duplicate $($dir.Name) name '$($json.name)'"; continue
        }
        $artifacts.Add([pscustomobject]@{
            Folder   = $dir.Name
            Name     = [string]$json.name
            Path     = $file.FullName
            Json     = $json
            Modified = $false
            Refs     = @()
        })
    }
}
Write-Host "Loaded $($artifacts.Count) artifacts from $RootFolder"

$index = @{}   # "folder/name" -> artifact (case-insensitive)
foreach ($a in $artifacts) { $index["$($a.Folder)/$($a.Name)"] = $a }

# --------------------------------------------------------------------------------
# 2. Overrides
# --------------------------------------------------------------------------------
if ($OverridesFile) {
    try   { $overrides = Get-Content -Raw -Path $OverridesFile | ConvertFrom-Json @JsonReadArgs }
    catch { throw "Overrides file '$OverridesFile' could not be read: $($_.Exception.Message)" }

    foreach ($entry in $overrides.PSObject.Properties) {
        $target = $index[$entry.Name]
        if (-not $target) { Add-ValidationError "Override target '$($entry.Name)' not found in source"; continue }
        foreach ($setting in $entry.Value.PSObject.Properties) {
            try {
                Set-JsonPath $target.Json $setting.Name $setting.Value
                $target.Modified = $true
            }
            catch { Add-ValidationError "Override '$($entry.Name)' -> '$($setting.Name)': $($_.Exception.Message)" }
        }
    }
}

# --------------------------------------------------------------------------------
# 3. Reference validation
# --------------------------------------------------------------------------------
foreach ($a in $artifacts) {
    $acc = [System.Collections.Generic.List[object]]::new()
    Get-References $a.Json.properties $acc
    $refs = foreach ($r in $acc) {
        $folder = $RefTypeToFolder[$r.Type]
        if (-not $folder) { continue }   # e.g. BigDataPoolReference, SqlPoolReference: workspace compute
        if (-not $index.ContainsKey("$folder/$($r.Name)") -and $r.Name -ne 'AutoResolveIntegrationRuntime') {
            Add-ValidationError "$($a.Folder)/$($a.Name): references missing $folder '$($r.Name)'"
        }
        [pscustomobject]@{ Folder = $folder; Name = $r.Name }
    }
    $a.Refs = @($refs)
}

$sorted = @{}
foreach ($folder in $DeployOrder) {
    $sorted[$folder] = Sort-ByDependency @($artifacts | Where-Object Folder -eq $folder) $folder
}

if ($script:ValidationErrors.Count -gt 0) {
    throw "Validation failed with $($script:ValidationErrors.Count) error(s)."
}
Write-Host 'Validation succeeded.'
foreach ($f in $ReferenceOnlyFolders) {
    $n = @($artifacts | Where-Object Folder -eq $f).Count
    if ($n) { Write-Host "  $f ($n): reference-only, not deployed by this script" }
}
if ($ValidateOnly) { return }

# --------------------------------------------------------------------------------
# 4. Deploy
# --------------------------------------------------------------------------------
if (-not $WorkspaceName) { throw '-WorkspaceName is required unless -ValidateOnly is set.' }
Import-Module Az.Synapse

$tempDir = Join-Path ([IO.Path]::GetTempPath()) "synapse-deploy-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tempDir | Out-Null

function Get-DeployFile($Item) {
    if (-not $Item.Modified) { return $Item.Path }
    $out = Join-Path $tempDir "$($Item.Folder)__$($Item.Name).json"
    $Item.Json | ConvertTo-Json -Depth 100 | Set-Content -Path $out -Encoding utf8NoBOM
    return $out
}
function Get-FolderPath($Item) {
    $f = Get-JsonChild $Item.Json.properties 'folder'
    if ($f) { return [string](Get-JsonChild $f 'name') }
    return $null
}
function Get-TriggerRuntimeState($Trigger) {
    foreach ($candidate in @($Trigger.Properties, $Trigger)) {
        if ($candidate -and $candidate.PSObject.Properties['RuntimeState'] -and $candidate.RuntimeState) {
            return [string]$candidate.RuntimeState
        }
    }
    return $null
}

$sourceNames = @{}
foreach ($folder in $DeployOrder) {
    $set = New-NameSet
    foreach ($i in $sorted[$folder]) { [void]$set.Add($i.Name) }
    $sourceNames[$folder] = $set
}

# 4a. Stop running triggers
$restartOutsideSource = [System.Collections.Generic.List[string]]::new()
foreach ($t in @(Get-AzSynapseTrigger -WorkspaceName $WorkspaceName)) {
    if ((Get-TriggerRuntimeState $t) -ne 'Started') { continue }
    Write-Host "Stopping trigger $($t.Name)"
    Stop-AzSynapseTrigger -WorkspaceName $WorkspaceName -Name $t.Name -Confirm:$false
    if (-not $sourceNames.trigger.Contains($t.Name) -and -not $DeleteNotInSource) {
        $restartOutsideSource.Add($t.Name)
    }
}

# 4b. Create / update
foreach ($folder in $DeployOrder) {
    foreach ($item in $sorted[$folder]) {
        Write-Host "Deploying $folder/$($item.Name)"
        $common = @{ WorkspaceName = $WorkspaceName; Name = $item.Name; Confirm = $false }

        switch ($folder) {
            'linkedService' { Set-AzSynapseLinkedService @common -DefinitionFile (Get-DeployFile $item) | Out-Null }
            'dataset'       { Set-AzSynapseDataset       @common -DefinitionFile (Get-DeployFile $item) | Out-Null }
            'dataflow'      { Set-AzSynapseDataFlow      @common -DefinitionFile (Get-DeployFile $item) | Out-Null }
            'pipeline'      { Set-AzSynapsePipeline      @common -DefinitionFile (Get-DeployFile $item) | Out-Null }
            'trigger'       { Set-AzSynapseTrigger       @common -DefinitionFile (Get-DeployFile $item) | Out-Null }

            'sparkJobDefinition' {
                $args_ = $common.Clone()
                $fp = Get-FolderPath $item; if ($fp) { $args_.FolderPath = $fp }
                Set-AzSynapseSparkJobDefinition @args_ -DefinitionFile (Get-DeployFile $item) | Out-Null
            }

            'notebook' {
                # Git stores the notebook as {name, properties:{nbformat, cells, metadata, bigDataPool, ...}};
                # the cmdlet takes a notebook file, so write "properties" out as .ipynb.
                $p = $item.Json.properties
                $nbFile = Join-Path $tempDir "notebook__$($item.Name).ipynb"
                $p | ConvertTo-Json -Depth 100 | Set-Content -Path $nbFile -Encoding utf8NoBOM

                $args_ = $common.Clone()
                $fp = Get-FolderPath $item; if ($fp) { $args_.FolderPath = $fp }
                $pool = Get-JsonChild (Get-JsonChild $p 'bigDataPool') 'referenceName'
                $sess = Get-JsonChild $p 'sessionProperties'
                $execCount = Get-JsonChild $sess 'numExecutors'
                if ($pool -is [string] -and $execCount) {
                    $args_.SparkPoolName = $pool
                    $args_.ExecutorCount = [int]$execCount
                    $cores = Get-JsonChild $sess 'executorCores'
                    if ($cores -and $ExecutorSizeByCores.ContainsKey([int]$cores)) {
                        $args_.ExecutorSize = $ExecutorSizeByCores[[int]$cores]
                    }
                }
                Set-AzSynapseNotebook @args_ -DefinitionFile $nbFile | Out-Null
            }

            'sqlscript' {
                # Git stores {name, properties:{content:{query, currentConnection, resultLimit}, folder, description}};
                # the cmdlet takes a .sql file plus connection parameters.
                $p = $item.Json.properties
                $content = Get-JsonChild $p 'content'
                $sqlFile = Join-Path $tempDir "sqlscript__$($item.Name).sql"
                Set-Content -Path $sqlFile -Value ([string](Get-JsonChild $content 'query')) -NoNewline -Encoding utf8NoBOM

                $args_ = $common.Clone()
                $fp = Get-FolderPath $item; if ($fp) { $args_.FolderPath = $fp }
                $desc = Get-JsonChild $p 'description'; if ($desc) { $args_.Description = [string]$desc }
                $limit = Get-JsonChild $content 'resultLimit'; if ($null -ne $limit) { $args_.ResultLimit = [int]$limit }
                $conn = Get-JsonChild $content 'currentConnection'
                $poolName = Get-JsonChild $conn 'poolName'
                $dbName = Get-JsonChild $conn 'databaseName'
                if ($poolName -and $poolName -ne 'Built-in' -and $dbName) {
                    $args_.SqlPoolName = [string]$poolName
                    $args_.SqlDatabaseName = [string]$dbName
                }
                elseif ($poolName -eq 'Built-in') {
                    Write-PipelineWarning "sqlscript/$($item.Name): serverless (Built-in) connection is not set by Set-AzSynapseSqlScript; verify after deploy."
                }
                Set-AzSynapseSqlScript @args_ -DefinitionFile $sqlFile | Out-Null
            }
        }
    }
}

# 4c. Delete artifacts not in source (dependents first; retry for intra-type dependencies)
if ($DeleteNotInSource) {
    foreach ($folder in $GetRemoveCmdlets.Keys) {
        $get, $remove = $GetRemoveCmdlets[$folder]
        $pending = [System.Collections.Generic.List[string]]::new()
        foreach ($existing in @(& $get -WorkspaceName $WorkspaceName)) {
            if ($sourceNames[$folder].Contains($existing.Name)) { continue }
            if ($existing.Name -match $ProtectedNamePattern) { continue }
            $pending.Add($existing.Name)
        }
        for ($pass = 1; $pending.Count -gt 0 -and $pass -le 5; $pass++) {
            $failed = [System.Collections.Generic.List[string]]::new()
            foreach ($name in $pending) {
                try {
                    Write-Host "Removing $folder/$name"
                    & $remove -WorkspaceName $WorkspaceName -Name $name -Force -Confirm:$false | Out-Null
                }
                catch { $failed.Add($name); $lastError = $_ }
            }
            if ($failed.Count -eq $pending.Count) { break }   # no progress
            $pending = $failed
        }
        if ($pending.Count -gt 0) {
            throw "Could not remove $folder artifact(s): $($pending -join ', '). Last error: $lastError"
        }
    }
}

# 4d. Start triggers
$toStart = [System.Collections.Generic.List[string]]::new()
foreach ($t in $sorted.trigger) {
    if ((Get-JsonChild $t.Json.properties 'runtimeState') -eq 'Started') { $toStart.Add($t.Name) }
}
$toStart.AddRange($restartOutsideSource)
foreach ($name in $toStart) {
    Write-Host "Starting trigger $name"
    Start-AzSynapseTrigger -WorkspaceName $WorkspaceName -Name $name | Out-Null
}

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Deployment to '$WorkspaceName' completed."
