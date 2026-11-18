#Requires -Version 7.4
<#
.SYNOPSIS
  One command that checks, deploys and rolls back the Harbor & Pine order-status page.
  People, agents and GitHub Actions all run this same script.

.EXAMPLE
  ./build.ps1                    # check: pre-flight checks, lint, tests, build
  ./build.ps1 deploy -DryRun     # show what a deploy would do, change nothing
  ./build.ps1 deploy             # restore-point tag, deploy, health check
  ./build.ps1 rollback           # redeploy the restore point before the live one
  ./build.ps1 rollback -To deploy-20261118-185604   # redeploy a named restore point
  From bash, CI or an agent: pwsh -File ./build.ps1 [command]
#>
[CmdletBinding()]
param(
  [ValidateSet("check", "deploy", "rollback")] [string] $Command = "check",
  [switch] $DryRun,
  [string] $To   # rollback only: the restore-point tag to go back to
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
# Read and write tool output as UTF-8 on every machine (Windows consoles default to an older code page).
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$SiteUrl = "https://harbor-pine-supply.github.io/harbor-pine-lab-hygiene"
$HealthTimeoutSeconds = 300
$TextExtensions = ".ps1", ".js", ".mjs", ".json", ".md", ".yml", ".yaml", ".html", ".css", ".csv", ".txt", ".example", ".gitignore", ".gitattributes", ".editorconfig", ".node-version"

# Short summary on screen; every detail goes to the log file.
New-Item -ItemType Directory -Force .logs | Out-Null
$LogName = ".logs/build-{0:yyyyMMdd-HHmmss-fff}.log" -f (Get-Date).ToUniversalTime()   # shown to people
$LogPath = Join-Path $PSScriptRoot $LogName   # written by full path, wherever the script is working
$Timer = [System.Diagnostics.Stopwatch]::StartNew()
function Write-Log([string[]] $Lines) { Add-Content -Path $LogPath -Value $Lines -Encoding utf8NoBOM }
function Ok([string] $Message) { Write-Host "ok    $Message"; Write-Log "ok    $Message" }
function Fail([string] $Message, [string] $Fix) {
  Write-Host "FAIL  $Message"
  if ($Fix) { Write-Host "      Fix: $Fix" }
  Write-Host "      Full log: $LogName"
  Write-Log "FAIL  $Message", "      Fix: $Fix"
  exit 1   # a non-zero exit code: people, agents and CI all see that it failed
}
# Run a tool; its full output goes to the log, never to the screen.
function Invoke-Logged([string] $Exe, [string[]] $ArgList) {
  Write-Log "", "> $Exe $($ArgList -join ' ')"
  $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  Write-Log $out
  [pscustomobject]@{ Code = $code; Out = @($out) }
}
# Git commands must succeed; the few that may fail use Invoke-Logged directly and check .Code.
function Invoke-Git([string[]] $ArgList) {
  $r = Invoke-Logged git $ArgList
  if ($r.Code -ne 0) { Fail "git $($ArgList[0]) failed (exit code $($r.Code))" "see the log" }
  $r.Out
}

Write-Log "build.ps1 $Command$(if ($DryRun) { ' -DryRun' }) at $((Get-Date).ToUniversalTime().ToString('u'))"

# ---- Pre-flight checks: fail fast, before anything runs -----------------------------------
function Test-Tools {
  $pinned = (Get-Content .node-version -Raw).Trim()
  $node = (Invoke-Logged node @("--version")).Out[0]
  # "22" pins the major version; "22.15.0" pins an exact version.
  if ($node -notmatch "^v$([regex]::Escape($pinned))(\.|$)") {
    Fail "tools: Node $node, but .node-version pins $pinned" "install Node $pinned (the version in .node-version)"
  }
  Ok "tools: PowerShell $($PSVersionTable.PSVersion), Node $node (pinned $pinned)"
}
function Test-Branch([string] $Want) {
  $branch = (Invoke-Git @("branch", "--show-current")) -join ""
  if ($Want -eq "main" -and $branch -ne "main") { Fail "branch: deploys run from main, you're on '$branch'" "git switch main; git pull" }
  if ($Want -ne "main" -and $branch -eq "main") { Fail "branch: you're on main; changes go through a branch and a pull request" "git switch -c <short-branch-name>" }
  Ok "branch: $(if ($branch) { $branch } else { 'detached (CI checkout)' })$(if ($Want -ne 'main') { ' (not main)' })"
}
function Test-Clean {
  $dirty = @(@(Invoke-Git @("status", "--porcelain")) | Where-Object { $_ })
  if ($dirty.Count) { Fail "working tree: $($dirty.Count) uncommitted change(s): $(($dirty | ForEach-Object { $_.Substring(3) }) -join ', ')" "commit or stash them, so the check tests exactly what you'll push" }
  Ok "working tree clean"
}
# Tracked files of the types listed in $TextExtensions (add yours). NUL-separated, so names with
# spaces or non-ASCII characters come through as they are.
function Get-TrackedFiles { @(((Invoke-Git @("-c", "core.quotePath=false", "ls-files", "-z")) -join "") -split "`0" | Where-Object { $_ }) }
function Get-TextFiles { @(Get-TrackedFiles | Where-Object { $TextExtensions -contains [IO.Path]::GetExtension($_) -or $TextExtensions -contains [IO.Path]::GetFileName($_) }) }
function Test-Encoding {
  $files = @(Get-TextFiles)
  foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $f))
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Fail "encoding: $f starts with a UTF-8 byte-order mark (BOM)" "save it as UTF-8 without BOM" }
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { Fail "encoding: $f is UTF-16, not UTF-8" "save it as UTF-8 without BOM" }
    try { $null = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) } catch { Fail "encoding: $f isn't valid UTF-8" "save it as UTF-8 without BOM" }
  }
  # Line endings: what Git has committed (the index), the same on every machine. A Windows working
  # copy can hold CRLF that .gitattributes turns into LF on commit, so the files on disk aren't checked.
  $crlf = @(@(Invoke-Git @("-c", "core.quotePath=false", "ls-files", "--eol")) | Where-Object { $_ -match '^i/(crlf|mixed)\s' })
  if ($crlf.Count) { Fail "line endings: $(($crlf[0] -split "`t")[-1]) is committed with Windows (CRLF) line endings" "check .gitattributes (eol=lf), then git add --renormalize ." }
  Ok "encoding: $($files.Count) text files, UTF-8 without BOM, LF line endings"   # text files = the extensions in $TextExtensions
}
function Test-Secrets {
  $tracked = @(Get-TrackedFiles | Where-Object { $_ -match '(^|/)\.env' -and $_ -notmatch '\.example$' })
  if ($tracked) { Fail "secrets: $($tracked -join ', ') is tracked by Git" "git rm --cached <file>, keep it in .gitignore, and rotate anything it held" }
  # A backstop, not a scanner: a quoted literal assigned to a secret-like name, an account key in a
  # connection string, or a private key block. Reading a value from the environment doesn't match.
  $pattern = '(?i)(password|passwd|secret|api[_-]?key|access[_-]?key)["'']?\s*[:=]\s*["''][^"''\s]{8,}["'']|accountkey=[A-Za-z0-9+/=]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  $files = @(Get-TextFiles)
  foreach ($f in $files) {
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot $f))) {
      $n++
      if ($line -match $pattern) { Fail "secrets: $f line $n looks like a secret (value not shown)" "move it to .env (ignored) or a vault and read it from the environment; if it was ever pushed, rotate it" }
    }
  }
  Ok "secrets: none found in $($files.Count) files; no .env tracked"
}
function Test-Lint {
  $js = @(Get-TextFiles | Where-Object { $_ -match '\.(m?js)$' })
  foreach ($f in $js) { if ((Invoke-Logged node @("--check", $f)).Code -ne 0) { Fail "lint: $f has a syntax error" "see the log for the line" } }
  Ok "lint: $($js.Count) files pass node --check"
}
function Test-Tests {
  $r = Invoke-Logged node @("--test", "--test-reporter=tap")
  $pass = ($r.Out | Where-Object { $_ -match '^# pass (\d+)' } | ForEach-Object { [int]($_ -replace '\D', '') }) | Select-Object -First 1
  $failed = @($r.Out | Where-Object { $_ -match '^\s*not ok \d+ - ' } | ForEach-Object { ($_ -replace '^\s*not ok \d+ - ', '').Trim() })
  if ($r.Code -ne 0) { Fail "tests: $($failed.Count) failed: $($failed -join '; ')" "open the log for the assertion, or run node --test" }
  Ok "tests: $pass passed, 0 failed"
}
function Build-Site([string] $Sha) {
  Remove-Item -Recurse -Force dist -ErrorAction Ignore
  New-Item -ItemType Directory dist | Out-Null
  $html = (Invoke-Git @("show", "${Sha}:site/index.html")) -join "`n"
  if ($html -notmatch '\{\{VERSION\}\}') { Fail "build: site/index.html at $($Sha.Substring(0, 7)) has no {{VERSION}} placeholder" "the health check needs the version on the page" }
  Set-Content dist/index.html ($html.Replace("{{VERSION}}", $Sha.Substring(0, 7))) -Encoding utf8NoBOM -NoNewline
  Set-Content dist/version.txt $Sha -Encoding utf8NoBOM
}
function Invoke-Checks([string] $BranchRule) {
  Test-Tools; Test-Branch $BranchRule; Test-Clean; Test-Encoding; Test-Secrets; Test-Lint; Test-Tests
}

# ---- Deploy helpers ----------------------------------------------------------------------
function Get-LiveVersion {
  try {
    $r = Invoke-WebRequest "$SiteUrl/version.txt?nocache=$([guid]::NewGuid())" -SkipHttpErrorCheck -TimeoutSec 20
    Write-Log "GET $SiteUrl/version.txt -> $($r.StatusCode)"
    if ($r.StatusCode -eq 200) { return ([string]$r.Content).Trim() }
  } catch { Write-Log "GET $SiteUrl/version.txt failed: $_" }
  return ""
}
function Publish-Site([string] $Sha) {
  $gitDir = (Invoke-Git @("rev-parse", "--absolute-git-dir")) -join ""
  Invoke-Logged git @("fetch", "-q", "origin", "gh-pages") | Out-Null   # fine if it doesn't exist yet
  $env:GIT_INDEX_FILE = Join-Path $gitDir "deploy-index"
  try {
    Remove-Item $env:GIT_INDEX_FILE -ErrorAction Ignore
    Push-Location dist; try { Invoke-Git @("--git-dir=$gitDir", "--work-tree=.", "add", "-A", ".") | Out-Null } finally { Pop-Location }
    $tree = (Invoke-Git @("write-tree")) -join ""
  } finally { Remove-Item Env:GIT_INDEX_FILE }
  $parent = (Invoke-Logged git @("rev-parse", "-q", "--verify", "refs/remotes/origin/gh-pages")).Out -join ""
  $commitArgs = @("commit-tree", $tree, "-m", "Deploy $Sha")
  if ($parent) { $commitArgs += @("-p", $parent) }
  $commit = (Invoke-Git $commitArgs) -join ""
  $push = Invoke-Logged git @("push", "-q", "origin", "${commit}:refs/heads/gh-pages")
  if ($push.Code -ne 0) { Fail "deploy: push to gh-pages failed" "see the log" }
}
function Wait-Healthy([string] $Sha) {
  $start = $Timer.Elapsed.TotalSeconds
  while ($Timer.Elapsed.TotalSeconds - $start -lt $HealthTimeoutSeconds) {
    $live = Get-LiveVersion
    if ($live -eq $Sha) { Ok "health check: $SiteUrl/ serves $($Sha.Substring(0, 7)) (after $([int]($Timer.Elapsed.TotalSeconds - $start)) s)"; return }
    Start-Sleep -Seconds 10
  }
  Fail "health check: the site doesn't serve $($Sha.Substring(0, 7)) after $HealthTimeoutSeconds s (live: '$live')" "if the live version is the previous one, nothing broke: fix and deploy again; if it's broken, ./build.ps1 rollback -To <restore-point tag>"
}
function Get-RestorePoints {
  Invoke-Logged git @("fetch", "-q", "--tags", "origin") | Out-Null
  @(Invoke-Git @("tag", "--list", "deploy-*", "--sort=-refname")) | Where-Object { $_ } |
    ForEach-Object { [pscustomobject]@{ Tag = $_; Sha = (Invoke-Git @("rev-list", "-n", "1", $_)) -join "" } }
}
function Done([string] $What) {
  $msg = "{0} in {1:0.0} s | full log: {2}" -f $What, $Timer.Elapsed.TotalSeconds, $LogName
  Write-Host $msg; Write-Log $msg; exit 0
}

# ---- Commands ----------------------------------------------------------------------------
switch ($Command) {
  "check" {
    Invoke-Checks "branch"
    $sha = (Invoke-Git @("rev-parse", "HEAD")) -join ""
    Build-Site $sha
    Ok "build: dist/ (index.html, version.txt) for $($sha.Substring(0, 7))"
    Done "PASS  check"
  }
  "deploy" {
    Invoke-Checks "main"
    Invoke-Git @("fetch", "-q", "origin", "main") | Out-Null
    $sha = (Invoke-Git @("rev-parse", "HEAD")) -join ""
    if ($sha -ne ((Invoke-Git @("rev-parse", "origin/main")) -join "")) { Fail "deploy: local main isn't the same as origin/main" "git pull (or push), then deploy" }
    $live = Get-LiveVersion
    if ($live -eq $sha) { Ok "already live: $($sha.Substring(0, 7)) is what the site serves. Nothing to deploy."; Done "PASS  deploy (no change)" }
    $tag = "deploy-{0:yyyyMMdd-HHmmss}" -f (Get-Date).ToUniversalTime()
    if ($DryRun) {
      Write-Host "plan  live now: $(if ($live) { $live.Substring(0, 7) } else { 'nothing' }) -> deploy $($sha.Substring(0, 7))"
      Write-Host "plan  restore-point tag $tag on $($sha.Substring(0, 7)), pushed to origin"
      Write-Host "plan  publish dist/ to the gh-pages branch, then check $SiteUrl/version.txt"
      Done "DRY RUN  nothing tagged, published or pushed"
    }
    Invoke-Git @("tag", "-a", $tag, "-m", "Restore point: deployed $sha") | Out-Null   # fails if the name exists
    if (((Invoke-Git @("rev-list", "-n", "1", $tag)) -join "") -ne $sha) { Fail "deploy: tag $tag doesn't point at $($sha.Substring(0, 7))" "see the log" }
    if ((Invoke-Logged git @("push", "-q", "origin", "refs/tags/${tag}")).Code -ne 0) { Fail "deploy: couldn't push the restore-point tag $tag" "see the log" }
    Ok "restore point: tag $tag on $($sha.Substring(0, 7))"
    Build-Site $sha
    Publish-Site $sha
    Ok "published $($sha.Substring(0, 7)) to gh-pages"
    Wait-Healthy $sha
    Done "PASS  deploy"
  }
  "rollback" {
    $live = Get-LiveVersion
    $points = @(Get-RestorePoints)
    if ($To) {
      # An explicit target: works even when the live site is down or serves something unknown.
      $target = $points | Where-Object { $_.Tag -eq $To } | Select-Object -First 1
      if (-not $target) { Fail "rollback: there's no restore point called $To" "git tag --list 'deploy-*'" }
      $from = if ($live) { $live.Substring(0, [Math]::Min(7, $live.Length)) } else { "nothing" }
    } else {
      # The default: the restore point before the one that's live now.
      $i = [Array]::FindIndex([object[]]$points, [Predicate[object]] { param($p) $p.Sha -eq $live })
      if ($i -lt 0) { Fail "rollback: the live version '$live' isn't a restore point" "name one: ./build.ps1 rollback -To <tag> (git tag --list 'deploy-*')" }
      $target = $points | Select-Object -Skip ($i + 1) | Where-Object { $_.Sha -ne $live } | Select-Object -First 1
      if (-not $target) { Fail "rollback: no restore point before $($points[$i].Tag)" "nothing older to roll back to" }
      $from = "$($live.Substring(0, 7)) ($($points[$i].Tag))"
    }
    if ($DryRun) {
      Write-Host "plan  live now: $from -> roll back to $($target.Sha.Substring(0, 7)) ($($target.Tag))"
      Done "DRY RUN  nothing published or pushed"
    }
    Ok "rollback: $from -> $($target.Tag) ($($target.Sha.Substring(0, 7)))"
    Build-Site $target.Sha
    Publish-Site $target.Sha
    Ok "published $($target.Sha.Substring(0, 7)) to gh-pages"
    Wait-Healthy $target.Sha
    Done "PASS  rollback"
  }
}
