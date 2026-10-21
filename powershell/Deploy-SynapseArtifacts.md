# Deploy-SynapseArtifacts.ps1

Validates and deploys Azure Synapse workspace artifacts from the Synapse Git folder layout, using Microsoft's
`Az.Synapse` module. The same script is used in the build stage (offline validation) and in the deploy stages.

**Deployed**, in this order (each folder is sorted by its internal dependencies):
`linkedService` > `dataset` > `dataflow` > `notebook` > `sqlscript` > `sparkJobDefinition` > `pipeline` > `trigger`.
Managed private endpoints (`managedVirtualNetwork/<vnet>/managedPrivateEndpoint/*.json`) are always validated, but only
deployed when `-DeployManagedPrivateEndpoints` is set.

**Not deployed** (manage these in Terraform or extend the script): integration runtimes, credentials, the managed VNet
itself, Spark pools, KQL scripts, Spark configurations and lake databases. Integration runtimes and credentials are
still read, so references to them can be validated.

## Prerequisites

- PowerShell 7.2 or later.
- Deploy only: the `Az.Synapse` module (`Install-Module Az.Synapse -Scope CurrentUser`), plus a signed-in identity
  with Synapse RBAC on the workspace. *Synapse Artifact Publisher* is enough for artifacts and triggers. Managed private
  endpoints need a role that can manage them, such as *Synapse Linked Data Manager* or *Synapse Administrator*.
  `-DryRun` only reads, so *Synapse Artifact User* is enough. See
  [Synapse RBAC roles](https://learn.microsoft.com/azure/synapse-analytics/security/synapse-workspace-synapse-rbac-roles).

## Parameters

| Parameter | Description |
|---|---|
| `-RootFolder` | Synapse Git root folder (contains `linkedService/`, `pipeline/`, ...). Required. |
| `-WorkspaceName` | Target Synapse workspace. Required unless `-ValidateOnly`. |
| `-ValidateOnly` | Validate only; no Azure connection needed. |
| `-DeleteNotInSource` | Delete workspace artifacts that are not in the folder. |
| `-DeployManagedPrivateEndpoints` | Create managed private endpoints from `managedVirtualNetwork/`. |
| `-DryRun` | Read the workspace and log every change (prefixed `[DryRun]`) without making it. |

## Build: validate

```powershell
./powershell/Deploy-SynapseArtifacts.ps1 -RootFolder ./synapse -ValidateOnly
```

The script checks that:

- every `*.json` file parses, has `name` and `properties`, and its `name` matches the file name
- no artifact type has duplicate names
- every reference resolves to a file in the folder
- no type has circular references
- managed private endpoints have `privateLinkResourceId` and `groupId`

Each failure is logged as a pipeline error (`##vso[task.logissue]`), and the script exits non-zero.

## Deploy

Sign in and select the subscription first:

```powershell
Connect-AzAccount
Set-AzContext -Subscription '<subscription id>'
```

```powershell
# Dry run: show what would change
./powershell/Deploy-SynapseArtifacts.ps1 -RootFolder ./synapse -WorkspaceName synw-skydivesample1-dev -DryRun

# Deploy (create / update only)
./powershell/Deploy-SynapseArtifacts.ps1 -RootFolder ./synapse -WorkspaceName synw-skydivesample1-dev

# Full sync: also delete artifacts not in source, and deploy managed private endpoints
./powershell/Deploy-SynapseArtifacts.ps1 -RootFolder ./synapse -WorkspaceName synw-skydivesample1-dev `
    -DeleteNotInSource -DeployManagedPrivateEndpoints
```

Every deploy validates first, then:

1. creates missing managed private endpoints (only with `-DeployManagedPrivateEndpoints`)
2. stops started triggers
3. deploys the artifacts in the order above
4. deletes artifacts not in source (only with `-DeleteNotInSource`)
5. starts triggers whose `runtimeState` is `Started` in source, plus any trigger outside source that it stopped in step 2

## In Azure Pipelines

[azure-pipelines.yml](../azure-pipelines/azure-pipelines.yml) runs the script in two kinds of stage:

- **Build**: `PowerShell@2` with `-ValidateOnly`. It then publishes the Synapse folder and the script as the pipeline
  artifact `SynapseArtifact`.
- **Deploy_&lt;env&gt;**: one `AzurePowerShell@5` stage per entry in the `environments` parameter. Each uses its own
  Workload Identity Federation service connection. Approvals are configured on the Azure DevOps environment.

```yaml
ScriptPath: $(Pipeline.Workspace)/$(artifactName)/Deploy-SynapseArtifacts.ps1
ScriptArguments: >-
  -RootFolder '$(Pipeline.Workspace)/$(artifactName)/workspace'
  -WorkspaceName '${{ env.workspaceName }}'
  -DeleteNotInSource:$${{ env.deleteNotInSource }}
  -DeployManagedPrivateEndpoints:$${{ env.deployManagedPrivateEndpoints }}
  -DryRun:$${{ parameters.dryRun }}
```

To do a dry run, queue the pipeline manually and tick **Dry run**.

## Notes

- Workspace defaults (`*-WorkspaceDefaultStorage`, `*-WorkspaceDefaultSqlServer`) and workspace-created managed
  private endpoints (`synapse-ws-*`) are never deployed or deleted.
- Existing managed private endpoints are not updated. If the `privateLinkResourceId` in source differs, the script logs
  a warning; to change the endpoint, delete it and redeploy. The private endpoint connection still has to be approved
  on the target resource.
- Managed private endpoints are only deleted when the folder defines at least one. If the folder has none, the script
  assumes endpoints are managed elsewhere and leaves them alone.
