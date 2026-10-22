#requires -Version 7.4
# Copyright 2026 Sonny Guardian. Boost Software License, Version 1.0.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('msvc','clang-cl')][string]$Compiler,
  [Parameter(Mandatory)][ValidateSet('debug','release')][string]$Variant,
  [Parameter(Mandatory)][string]$OutputRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Base = 'ef305d587660e28edcb492060a68464e69cba6b7'
$Patched = 'ea825d5ba5c386a11011e84c73a2a592653579b8'
$BoostPin = '0c5c43929bc7feafa16c87efd1aaec691b8f182d'
$Header = 'include/boost/numeric/interval/rounded_arith.hpp'
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw 'OutputRoot must be a new directory.' }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$script:SetupIndex = 0
$Records = [Collections.Generic.List[object]]::new()
$Problems = [Collections.Generic.List[string]]::new()

function Invoke-Recorded([string]$Executable, [string[]]$Arguments, [string]$Log) {
  $command = [ordered]@{ executable = $Executable; arguments = $Arguments; working_directory = (Get-Location).Path } | ConvertTo-Json -Compress
  $command | Set-Content -LiteralPath ($Log + '.command.json') -Encoding utf8
  $lines = @(& $Executable @Arguments 2>&1)
  $code = $LASTEXITCODE
  $lines | ForEach-Object { "$_" } | Set-Content -LiteralPath $Log -Encoding utf8
  $code | Set-Content -LiteralPath ($Log + '.exit') -Encoding ascii
  $lines | ForEach-Object { Write-Host "$_" }
  return [int]$code
}
function Checked([string]$Executable, [string[]]$Arguments) {
  $script:SetupIndex++
  $log = Join-Path $OutputRoot ('setup-{0:d2}.log' -f $script:SetupIndex)
  $code = Invoke-Recorded $Executable $Arguments $log
  if ($code -ne 0) { throw "Setup command failed ($code): $Executable; see $log" }
}
function Export-Blob([string]$Repo, [string]$Revision, [string]$Path, [string]$Destination) {
  # PowerShell 7.4 preserves native stdout bytes under redirection.
  & git -C $Repo cat-file blob "$Revision`:$Path" > $Destination
  if ($LASTEXITCODE -ne 0) { throw "Cannot export pinned blob $Revision`:$Path" }
}

try {
  if (-not $IsWindows) { throw 'This runner requires Windows.' }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  $vs = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
  if ($LASTEXITCODE -ne 0 -or $vs.Count -ne 1) { throw 'Cannot locate one Visual Studio C++ toolchain.' }
  $devcmd = Join-Path $vs[0] 'Common7/Tools/VsDevCmd.bat'
  $devEnvironment = @(& cmd.exe /d /c "call `"$devcmd`" -arch=x86 -host_arch=x64 >nul && set")
  if ($LASTEXITCODE -ne 0) { throw 'VsDevCmd failed.' }
  foreach ($line in $devEnvironment) {
    if ($line -match '^([^=]+)=(.*)$') {
      [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    }
  }
  if ($env:VSCMD_ARG_TGT_ARCH -ne 'x86') { throw 'Visual Studio did not select x86.' }
  if ($Compiler -eq 'msvc') { $cc = (Get-Command cl.exe).Source }
  else {
    $clang = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
    if ($clang) { $cc = $clang.Source }
    else {
      $candidates = @((Join-Path $env:ProgramFiles 'LLVM/bin/clang-cl.exe'),
                     (Join-Path $vs[0] 'VC/Tools/Llvm/x64/bin/clang-cl.exe'))
      $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ })
      if ($found.Count -eq 0) { throw 'No installed clang-cl was found.' }
      $cc = $found[0]
    }
  }
  $flags = @('/nologo','/EHsc','/W4','/fp:strict','/arch:SSE2')
  if ($Variant -eq 'debug') { $flags += @('/Od','/Ob0','/MDd') }
  else { $flags += @('/O2','/Ob2','/MD') }
  if ($Compiler -eq 'clang-cl') { $flags += @('--target=i686-pc-windows-msvc','/clang:-std=c++03') }
  # CL has no C++03 language switch; its default mode builds this C++03 source.
  $versionArgs = if ($Compiler -eq 'msvc') { @('/Bv') } else { @('--version') }
  $null = Invoke-Recorded $cc $versionArgs (Join-Path $OutputRoot 'compiler-version.log')

  $ScratchRoot = Join-Path (Split-Path $OutputRoot) 'pr61-build-scratch'
  if (Test-Path -LiteralPath $ScratchRoot) { throw 'Scratch directory already exists; use a fresh workspace.' }
  New-Item -ItemType Directory -Path $ScratchRoot | Out-Null
  $BoostRoot = Join-Path $ScratchRoot 'boost'
  Checked git @('init',$BoostRoot)
  Checked git @('-C',$BoostRoot,'remote','add','origin','https://github.com/boostorg/boost.git')
  Checked git @('-C',$BoostRoot,'fetch','--depth=1','origin',$BoostPin)
  Checked git @('-C',$BoostRoot,'checkout','--detach','FETCH_HEAD')
  Checked git @('-C',$BoostRoot,'submodule','update','--init','--depth=1','tools/boostdep','tools/build','libs/numeric/interval')
  $IntervalRoot = Join-Path $BoostRoot 'libs/numeric/interval'
  foreach ($ref in @($Base,$Patched)) {
    Checked git @('-C',$IntervalRoot,'fetch','--depth=1','https://github.com/boostorg/interval.git',$ref)
  }
  Checked git @('-C',$IntervalRoot,'checkout','--detach',$Patched)
  Push-Location $BoostRoot
  try {
    Checked python @('tools/boostdep/depinst/depinst.py','--include','test','numeric/interval')
    Checked cmd.exe @('/d','/c','bootstrap.bat')
    Checked (Join-Path $BoostRoot 'b2.exe') @('-d0','headers')
  } finally { Pop-Location }
  $dependencies = @(& git -C $BoostRoot submodule status --recursive)
  if ($LASTEXITCODE -ne 0) { throw 'Cannot inventory dependency pins.' }
  $dependencies | Set-Content -LiteralPath (Join-Path $OutputRoot 'dependency-commits.txt')

  $PinnedTest = Join-Path $OutputRoot 'pinned-sqrt_point.cpp'
  Export-Blob $IntervalRoot $Patched 'test/sqrt_point.cpp' $PinnedTest
  $TestSource = Join-Path $PSScriptRoot 'sqrt_point.cpp'
  if ((Get-FileHash $PinnedTest).Hash -ne (Get-FileHash $TestSource).Hash) {
    throw 'Vendored regression differs from the pinned PR test.'
  }
  $Overlay = Join-Path $OutputRoot 'overlay'
  $OverlayHeader = Join-Path $Overlay 'boost/numeric/interval/rounded_arith.hpp'
  New-Item -ItemType Directory -Path (Split-Path $OverlayHeader) -Force | Out-Null
  $BuildRoot = Join-Path $ScratchRoot 'build'
  New-Item -ItemType Directory -Path $BuildRoot | Out-Null
  $common = $flags + @("/I$Overlay", "/I$BoostRoot")
  @{ base=$Base; patched=$Patched; boost=$BoostPin; compiler=$cc; flags=$common;
     variant=$Variant; test_sha256=(Get-FileHash $TestSource).Hash.ToLowerInvariant();
     probe_sha256=(Get-FileHash (Join-Path $PSScriptRoot 'probe.cpp')).Hash.ToLowerInvariant();
     language_note='clang-cl uses C++03 mode; CL has no C++03 mode switch.' } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputRoot 'configuration.json')

  foreach ($case in @(@{name='base';ref=$Base}, @{name='patched';ref=$Patched})) {
    $CaseRoot = Join-Path $OutputRoot $case.name
    New-Item -ItemType Directory -Path $CaseRoot | Out-Null
    Export-Blob $IntervalRoot $case.ref $Header $OverlayHeader
    Copy-Item -LiteralPath $OverlayHeader -Destination (Join-Path $CaseRoot 'rounded_arith.hpp')
    foreach ($kind in @('sqrt_point','probe')) {
      try {
        $source = Join-Path $PSScriptRoot ($kind + '.cpp')
        # Arguments, source paths, include order and output paths match between headers.
        $argsForCompiler = $common + @('/FA',"/Fa:$kind.asm","/Fo:$kind.obj","/Fe:$kind.exe",$source)
        Push-Location $BuildRoot
        try {
          $compileCode = Invoke-Recorded $cc $argsForCompiler (Join-Path $CaseRoot "$kind-compile.log")
          if ($compileCode -ne 0) { throw "$($case.name)/$kind compilation failed ($compileCode)." }
          $runCode = Invoke-Recorded (Join-Path $BuildRoot "$kind.exe") @() (Join-Path $CaseRoot "$kind-run.log")
          foreach ($extension in @('asm','exe','obj')) {
            $artifact = Join-Path $BuildRoot "$kind.$extension"
            if (Test-Path -LiteralPath $artifact) { Copy-Item -LiteralPath $artifact -Destination $CaseRoot }
          }
        } finally { Pop-Location }
        $runText = Get-Content -LiteralPath (Join-Path $CaseRoot "$kind-run.log") -Raw
        if ($kind -eq 'sqrt_point') {
          $m = [regex]::Matches($runText,'(?m)^inputs=96 misses=([0-9]+)\s*$')
          if ($m.Count -ne 1) { throw "$($case.name): missing unique 96-input summary (crash or incomplete run)." }
          $misses = [int]$m[0].Groups[1].Value
          if ($misses -gt 96 -or (($misses -eq 0) -ne ($runCode -eq 0)) -or $runCode -lt 0 -or $runCode -gt 192) {
            throw "$($case.name): invalid summary/exit combination." }
          $Records.Add(@{header=$case.name; kind=$kind; exit=$runCode; inputs=96; misses=$misses;
            header_sha256=(Get-FileHash $OverlayHeader).Hash.ToLowerInvariant()})
        } else {
          if ($runCode -ne 0 -or $runText -notmatch 'probe_inputs=4 restore_errors=0' -or
              ([regex]::Matches($runText,'(?m)^call=')).Count -ne 12) {
            throw "$($case.name): probe failed or output is incomplete." }
          $Records.Add(@{header=$case.name; kind=$kind; exit=$runCode; inputs=4;
            header_sha256=(Get-FileHash $OverlayHeader).Hash.ToLowerInvariant()})
        }
      } catch { $Problems.Add($_.Exception.Message); Write-Warning $_.Exception.Message }
    }
  }
  foreach ($kind in @('sqrt_point','probe')) {
    $a = Get-Content -LiteralPath (Join-Path $OutputRoot "base/$kind-compile.log.command.json") -Raw
    $b = Get-Content -LiteralPath (Join-Path $OutputRoot "patched/$kind-compile.log.command.json") -Raw
    if ($a -cne $b) { $Problems.Add("Compiler arguments differ between headers for $kind.") }
  }
} catch { $Problems.Add($_.Exception.Message); Write-Warning $_.Exception.Message }
finally {
  @{records=@($Records.ToArray()); infrastructure_errors=@($Problems.ToArray());
    interpretation='Nonzero enclosure counts are evidence, not an expected-failure pass. Probe instrumentation can change optimization.'} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputRoot 'summary.json')
  # Downloaded dependency sources stay in the separate scratch directory.
}
if ($Problems.Count -ne 0 -or $Records.Count -ne 4) { throw 'Comparison incomplete; inspect summary.json and logs.' }
if (@($Records | Where-Object { $_.kind -eq 'sqrt_point' -and $_.misses -ne 0 }).Count -ne 0) {
  throw 'Comparison complete: enclosure failures recorded. Both headers were tested; inspect summary.json.'
}
