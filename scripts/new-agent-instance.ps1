[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^ag-[a-z0-9][a-z0-9-]{7,80}$')]
  [string]$AgentId,

  [string]$TemplateAgentRoot,

  [Parameter(Mandatory)]
  [string]$SourceDir,

  [Parameter(Mandatory)]
  [string]$NodeExecutable,

  [Parameter(Mandatory)]
  [string]$CodexConfigPath,

  [string]$ChromeExecutable,
  [string]$ThreadId,
  [string]$Root = (Join-Path $env:USERPROFILE '.chatgpt-web-mcp'),
  [string]$BrowserHostRoot,
  [string]$BrowserHostProfile
)

$ErrorActionPreference = 'Stop'

function Resolve-ExistingPath([string]$Path, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "$Label does not exist: $Path" }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Write-NewJson([string]$Path, [object]$Value) {
  $json = $Value | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

$skillRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Resolve-ExistingPath $SourceDir 'chatgpt-web-mcp source'
$nodePath = Resolve-ExistingPath $NodeExecutable 'Node executable'
$configPath = Resolve-ExistingPath $CodexConfigPath 'Codex MCP config'
$sourcePackagePath = Join-Path $sourceRoot 'package.json'
if (-not (Test-Path -LiteralPath $sourcePackagePath)) { throw 'SourceDir must contain package.json.' }
$sourcePackage = Get-Content -Raw -LiteralPath $sourcePackagePath | ConvertFrom-Json
$sourceNodeModules = Join-Path $sourceRoot 'node_modules'
if (-not (Test-Path -LiteralPath $sourceNodeModules)) { throw 'Existing node_modules were not found; this helper does not install dependencies.' }

if ($TemplateAgentRoot) {
  $templateRoot = Resolve-ExistingPath $TemplateAgentRoot 'Template Agent root'
  $templateManifestPath = Join-Path $templateRoot 'instance.json'
  if (-not (Test-Path -LiteralPath $templateManifestPath)) { throw 'Template Agent root must contain instance.json.' }
  $templateManifest = Get-Content -Raw -LiteralPath $templateManifestPath | ConvertFrom-Json
  if ([System.IO.Path]::GetFullPath($templateManifest.shared_source_dir).TrimEnd('\') -ine $sourceRoot.TrimEnd('\')) {
    throw 'Template Agent and new instance must use the same shared source directory.'
  }
  $templateSource = Join-Path $templateRoot 'runtime\src'
} else {
  $runtimeMetadataPath = Join-Path $skillRoot 'templates\runtime-template.json'
  $runtimeMetadata = Get-Content -Raw -LiteralPath $runtimeMetadataPath | ConvertFrom-Json
  if ($sourcePackage.version -ne $runtimeMetadata.upstream_version) {
    throw "Bundled runtime overlay targets chatgpt-web-mcp $($runtimeMetadata.upstream_version); found $($sourcePackage.version). Supply a compatible -TemplateAgentRoot or adapt the overlay first."
  }

  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git -and (Test-Path -LiteralPath (Join-Path $sourceRoot '.git'))) {
    $sourceCommit = (& $git.Source -C $sourceRoot rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $sourceCommit -ne $runtimeMetadata.upstream_commit) {
      throw "Bundled runtime overlay targets commit $($runtimeMetadata.upstream_commit); found $sourceCommit. Supply a compatible -TemplateAgentRoot or adapt the overlay first."
    }
    if ($LASTEXITCODE -eq 0) {
      & $git.Source -C $sourceRoot diff --quiet HEAD -- src/config.js src/browser.js src/index.js
      if ($LASTEXITCODE -ne 0) {
        throw 'The bundled overlay files have local source changes. Supply a compatible -TemplateAgentRoot or review the overlay against this checkout.'
      }
    }
  }
  $templateSource = Join-Path $skillRoot 'templates\runtime-src'
}

foreach ($file in @('index.js', 'browser.js', 'config.js', 'agent-policy.js', 'browser-host.js')) {
  if (-not (Test-Path -LiteralPath (Join-Path $templateSource $file))) { throw "Template runtime is missing $file." }
}
$browserRuntimeTemplate = Get-Content -Raw -LiteralPath (Join-Path $templateSource 'browser.js')
if (-not $browserRuntimeTemplate.Contains('assertBrowserHostState') -or
    -not $browserRuntimeTemplate.Contains('connectOverCDP') -or
    -not $browserRuntimeTemplate.Contains('operationLockPath') -or
    -not $browserRuntimeTemplate.Contains('withSendSlot')) {
  throw 'TemplateAgentRoot does not contain the shared Browser Host runtime overlay. Supply a compatible template or adapt the bundled overlay.'
}
$indexRuntimeTemplate = Get-Content -Raw -LiteralPath (Join-Path $templateSource 'index.js')
if (-not $indexRuntimeTemplate.Contains('assertConversationIsUnclaimed') -or
    -not $indexRuntimeTemplate.Contains('conversationId: binding?.conversation_id || null')) {
  throw 'TemplateAgentRoot does not include the per-conversation binding and operation routing changes required by a shared Browser Host.'
}

if (-not $ChromeExecutable) {
  $chromeCandidates = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
  )
  $ChromeExecutable = $chromeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
$chromePath = Resolve-ExistingPath $ChromeExecutable 'Chrome executable'

$rootPath = [System.IO.Path]::GetFullPath($Root)
$browserHostProfileWasProvided = -not [string]::IsNullOrWhiteSpace($BrowserHostProfile)
$browserHostRootPath = [System.IO.Path]::GetFullPath(
  $(if ($BrowserHostRoot) { $BrowserHostRoot } else { Join-Path $rootPath 'browser-host' })
)
$browserHostProfilePath = if ($browserHostProfileWasProvided) {
  [System.IO.Path]::GetFullPath($BrowserHostProfile)
} else {
  $null
}
$browserHostManifestPath = Join-Path $browserHostRootPath 'host.json'
$browserHostManagerPath = Join-Path $browserHostRootPath 'browser-host.ps1'
$browserHostManagerSource = Join-Path $skillRoot 'scripts\browser-host.ps1'
$browserOperationLockDir = Join-Path $browserHostRootPath 'locks'
$sendSchedulerFile = Join-Path $browserHostRootPath 'send-scheduler.json'
$agentsRoot = Join-Path $rootPath 'agents'
$agentRoot = Join-Path $rootPath "agents\$AgentId"
$statePath = Join-Path $rootPath "state\$AgentId"
$logPath = Join-Path $rootPath "logs\$AgentId"
$bindingPath = Join-Path $rootPath "bindings\$AgentId.json"

foreach ($candidate in @($agentRoot, $statePath, $logPath, $bindingPath)) {
  if (Test-Path -LiteralPath $candidate) { throw "Refusing to overwrite an existing Agent resource: $candidate" }
}
$existingManifest = Get-ChildItem -LiteralPath $agentsRoot -Filter 'instance.json' -File -Recurse -ErrorAction SilentlyContinue |
  ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json } |
  Where-Object { $_.agent_id -eq $AgentId }
if ($existingManifest) { throw "AGENT_ID already exists: $AgentId" }

$null = New-Item -ItemType Directory -Path $rootPath -Force
foreach ($sharedDir in @($agentsRoot, (Join-Path $rootPath 'state'), (Join-Path $rootPath 'logs'), (Join-Path $rootPath 'bindings'), $browserHostRootPath)) {
  $null = New-Item -ItemType Directory -Path $sharedDir -Force
}
$existingHostManager = Test-Path -LiteralPath $browserHostManagerPath -PathType Leaf
if ($existingHostManager) {
  $existingHash = (Get-FileHash -LiteralPath $browserHostManagerPath -Algorithm SHA256).Hash
  $sourceHash = (Get-FileHash -LiteralPath $browserHostManagerSource -Algorithm SHA256).Hash
  if ($existingHash -ne $sourceHash) {
    throw "A different Browser Host manager already exists at $browserHostManagerPath. Review and upgrade it explicitly before provisioning another Agent."
  }
} else {
  $temporaryManagerPath = "$browserHostManagerPath.$PID.tmp"
  Copy-Item -LiteralPath $browserHostManagerSource -Destination $temporaryManagerPath
  try {
    [System.IO.File]::Move($temporaryManagerPath, $browserHostManagerPath)
  } catch {
    if (-not (Test-Path -LiteralPath $browserHostManagerPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $browserHostManagerPath -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $browserHostManagerSource -Algorithm SHA256).Hash) {
      throw
    }
  } finally {
    if (Test-Path -LiteralPath $temporaryManagerPath) { Remove-Item -LiteralPath $temporaryManagerPath -Force -ErrorAction SilentlyContinue }
  }
}

# Every Agent joins a verified Browser Host. The first setup may initialize the
# Host only from an explicitly selected, existing Chrome user-data directory.
if (Test-Path -LiteralPath $browserHostManifestPath -PathType Leaf) {
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $statusJson = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $browserHostManagerPath -Action Status -HostRoot $browserHostRootPath 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Existing Browser Host is not valid; no Agent instance was created. $($statusJson -join [Environment]::NewLine)" }
  $existingHost = ($statusJson -join [Environment]::NewLine) | ConvertFrom-Json
  $registeredProfile = [System.IO.Path]::GetFullPath([string]$existingHost.profile)
  if ($browserHostProfileWasProvided -and $registeredProfile.TrimEnd('\') -ine $browserHostProfilePath.TrimEnd('\')) {
    throw "Existing Browser Host uses a different Profile: $($existingHost.profile)"
  }
  $browserHostProfilePath = $registeredProfile
} else {
  if (-not $browserHostProfileWasProvided) {
    throw "No verified shared Browser Host exists at $browserHostRootPath. Supply -BrowserHostProfile with the existing signed-in Chrome user-data directory. This helper never creates a new Profile."
  }
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $statusJson = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $browserHostManagerPath `
    -Action Ensure -HostRoot $browserHostRootPath -ProfilePath $browserHostProfilePath -ChromeExecutable $chromePath 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Could not connect the selected existing Chrome Profile. No Agent instance was created. $($statusJson -join [Environment]::NewLine)"
  }
  $existingHost = ($statusJson -join [Environment]::NewLine) | ConvertFrom-Json
  if ([System.IO.Path]::GetFullPath([string]$existingHost.profile).TrimEnd('\') -ine $browserHostProfilePath.TrimEnd('\')) {
    throw 'Browser Host initialized with a different Profile; no Agent instance was created.'
  }
}
$null = New-Item -ItemType Directory -Path $agentRoot -Force:$false
$null = New-Item -ItemType Directory -Path $statePath -Force:$false
$null = New-Item -ItemType Directory -Path $logPath -Force:$false
$runtimeRoot = Join-Path $agentRoot 'runtime'
$runtimeSource = Join-Path $runtimeRoot 'src'
$null = New-Item -ItemType Directory -Path $runtimeSource -Force:$false
Get-ChildItem -LiteralPath $templateSource -Force | Copy-Item -Destination $runtimeSource -Recurse
$null = New-Item -ItemType Junction -Path (Join-Path $runtimeRoot 'node_modules') -Target $sourceNodeModules

$bindingMarker = "binding-$AgentId"
$instance = [ordered]@{
  schema_version = 1
  agent_id = $AgentId
  mcp_server_name = "chatgpt-web-$AgentId"
  mcp_instance_id = $AgentId
  codex_thread_id = $ThreadId
  shared_source_dir = $sourceRoot
  runtime_source_dir = $runtimeSource
  node_executable = $nodePath
  chrome_executable = $chromePath
  agent_root = $agentRoot
  browser_host_root = $browserHostRootPath
  browser_host_manifest = $browserHostManifestPath
  browser_host_manager_script = $browserHostManagerPath
  browser_host_id = $null
  browser_profile = $browserHostProfilePath
  state_dir = $statePath
  log_dir = $logPath
  binding_file = $bindingPath
  request_log_file = Join-Path $logPath 'messages.jsonl'
  browser_state_file = $browserHostManifestPath
  runtime_state_file = Join-Path $statePath 'runtime-state.json'
  browser_operation_lock_dir = $browserOperationLockDir
  send_scheduler_file = $sendSchedulerFile
  network_log_file = Join-Path $logPath 'network-diagnostics.jsonl'
  context_archive_dir = Join-Path $statePath 'conversation-context'
  codex_config_file = $configPath
  cdp_port = $null
  conversation_id = $null
  conversation_url = $null
  binding_marker = $bindingMarker
  last_sent_message_id = $null
  last_received_message_id = $null
  launch_script = Join-Path $agentRoot 'launcher.mjs'
}

$templates = Join-Path $skillRoot 'templates'
Copy-Item -LiteralPath (Join-Path $templates 'launcher.mjs') -Destination $instance.launch_script
Copy-Item -LiteralPath (Join-Path $templates 'agent-call.mjs') -Destination (Join-Path $agentRoot 'agent-call.mjs')
Copy-Item -LiteralPath (Join-Path $templates 'register-server.mjs') -Destination (Join-Path $agentRoot 'register-server.mjs')
Write-NewJson (Join-Path $agentRoot 'instance.json') $instance

$binding = [ordered]@{
  agent_id = $AgentId
  mcp_server_name = $instance.mcp_server_name
  mcp_instance_id = $AgentId
  cdp_port = $null
  browser_host_id = $null
  browser_profile = $browserHostProfilePath
  conversation_id = $null
  conversation_url = $null
  binding_marker = $bindingMarker
  last_sent_message_id = $null
  last_received_message_id = $null
}
Write-NewJson $bindingPath $binding

& $nodePath (Join-Path $agentRoot 'register-server.mjs')
if ($LASTEXITCODE -ne 0) { throw "MCP server registration failed; instance files are preserved at $agentRoot." }

[pscustomobject]@{
  AgentId = $AgentId
  Server = $instance.mcp_server_name
  AgentRoot = $agentRoot
  Profile = $browserHostProfilePath
  State = $statePath
  Logs = $logPath
  BrowserHostRoot = $browserHostRootPath
  BrowserHostProfile = $browserHostProfilePath
  Binding = $bindingPath
  Config = $configPath
  RuntimeTemplate = $templateSource
  NextStep = "Restart the named MCP or run agent-call.mjs chatgpt_status, then bind a new conversation in the existing shared Browser Host. No per-Agent Chrome Profile was created."
}
