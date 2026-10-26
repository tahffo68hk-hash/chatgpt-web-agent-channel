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
  [string]$Root = (Join-Path $env:USERPROFILE '.chatgpt-web-mcp')
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

foreach ($file in @('index.js', 'browser.js', 'config.js', 'agent-policy.js')) {
  if (-not (Test-Path -LiteralPath (Join-Path $templateSource $file))) { throw "Template runtime is missing $file." }
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
$agentsRoot = Join-Path $rootPath 'agents'
$agentRoot = Join-Path $rootPath "agents\$AgentId"
$profilePath = Join-Path $rootPath "profiles\$AgentId"
$statePath = Join-Path $rootPath "state\$AgentId"
$logPath = Join-Path $rootPath "logs\$AgentId"
$bindingPath = Join-Path $rootPath "bindings\$AgentId.json"

foreach ($candidate in @($agentRoot, $profilePath, $statePath, $logPath, $bindingPath)) {
  if (Test-Path -LiteralPath $candidate) { throw "Refusing to overwrite an existing Agent resource: $candidate" }
}
$existingManifest = Get-ChildItem -LiteralPath $agentsRoot -Filter 'instance.json' -File -Recurse -ErrorAction SilentlyContinue |
  ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json } |
  Where-Object { $_.agent_id -eq $AgentId }
if ($existingManifest) { throw "AGENT_ID already exists: $AgentId" }

$null = New-Item -ItemType Directory -Path $rootPath -Force
foreach ($sharedDir in @($agentsRoot, (Join-Path $rootPath 'profiles'), (Join-Path $rootPath 'state'), (Join-Path $rootPath 'logs'), (Join-Path $rootPath 'bindings'))) {
  $null = New-Item -ItemType Directory -Path $sharedDir -Force
}
$null = New-Item -ItemType Directory -Path $agentRoot -Force:$false
$null = New-Item -ItemType Directory -Path $profilePath -Force:$false
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
  browser_profile = $profilePath
  state_dir = $statePath
  log_dir = $logPath
  binding_file = $bindingPath
  request_log_file = Join-Path $logPath 'messages.jsonl'
  browser_state_file = Join-Path $statePath 'browser-state.json'
  runtime_state_file = Join-Path $statePath 'runtime-state.json'
  operation_lock_file = Join-Path $statePath 'browser-operation.lock'
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
  browser_profile = $profilePath
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
  Profile = $profilePath
  State = $statePath
  Logs = $logPath
  Binding = $bindingPath
  Config = $configPath
  RuntimeTemplate = $templateSource
  NextStep = "Run agent-call.mjs chatgpt_status, sign in to this Profile if needed, then bind a new conversation."
}
