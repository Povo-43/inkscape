# SPDX-License-Identifier: GPL-v2-or-later
# Set up a complete development environment for Inkscape on Windows:
# - Install all build dependencies
# - Download and compile latest Inkscape source
# - Run the compiled Inkscape
# - Install and setup VSCode
#
# This script must be started with Admin permissions.


######################
# USER CONFIGURATION
######################

# Note: The script works out of the box without any changes.
# The default values give a result as if you follow the compilation instructions manually. (See doc/building/windows.md)
# If you have special wishes, you can change the configuration here.

# Git URL to Inkscape repository
$InkscapeGitURL = "https://gitlab.com/inkscape/inkscape.git"

# Git Branch of Inkscape repository
$InkscapeGitBranch = "master"

# Local folder for Inkscape source repository.
# If the folder does not exist yet, the repository will be downloaded automatically.
# Default: C:\msys64\home\your_username\inkscape
$InkscapeRepository = "C:/msys64/home/$env:USERNAME/master/"

# Install VSCode and copy the configuration for Inkscape?
$SetupVSCode = $true

# Install latest Inkscape dependencies via MSYS?
$SetupMSYS = $true
# Path to MSYS installation or to prepackaged inkscape dependencies (unpack .7Z file from https://gitlab.com/inkscape/infra/inkscape-ci-windows/-/releases .)
# (Do NOT modify if $SetupMSYS == true)
# TODO: Add option to automatically download the prepackaged 7Z
$MSYSPath = "C:/msys64/"
# MSYS Environment variant, e.g. UCRT64 https://www.msys2.org/docs/environments/
$MSYSVariant = "UCRT64"


######################
# PowerShell general configuration
######################

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
Set-PSDebug -Trace 1

######################
# Auxiliary functions
######################

# Test if a command (e.g., "git") is available on the PATH
function Test-CommandExists {
  param (
    $Command
  )
  [bool] (Get-Command -ErrorAction Ignore -Type Application $Command)
}

# Run in MSYS shell
function Start-MsysCommand {
  param (
    $Command
  )
  echo "Running command in MSYS $MSYSVariant shell: $Command"
  & $MSYSPath/usr/bin/env.exe CHERE_INVOKING=1 MSYSTEM=$MSYSVariant /usr/bin/bash -lc "$Command"
  if (-Not $?) {
    throw "Running command in MSYS $MSYSVariant shell failed: $Command"
  }
}

######################
# 0. Compatibility Check
######################

if (-Not ($env:PROCESSOR_ARCHITECTURE -eq "AMD64")) {
  throw "This script currently only works on x64 architecture. (FIXME: Auto-detect and set MSYSVariant, then remove this check)"
}


######################
# 1. Dependencies and Inkscape source
######################

# Install WinGet
if (-Not (Test-CommandExists winget)) {
  # see https://learn.microsoft.com/en-us/windows/package-manager/winget/#install-winget
  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
}

# Force-update WinGet
# workaround https://github.com/microsoft/winget-cli/issues/2879
# (Microsoft is stupid and does certificate pinning but updates their certs so often that old WinGet versions fail to update themselves from the MSStore...)
winget install --accept-package-agreements --accept-source-agreements winget --source winget

# Install Git for Windows, outside MSYS (needed by VSCode)
If (-Not (Test-CommandExists git)) {
  winget install --accept-package-agreements --accept-source-agreements git.git
  # work around a bug in winget https://github.com/microsoft/winget-cli/issues/222 (fixed in the latest beta)
  $env:PATH += ";C:/Program Files/git/cmd/"
}

# Run the core part of buildtools/windows-deps-clickHere.bat
# Note: We use the version from the directory of the current script, not the version from the Inkscape git repo.
# This is to simplify local development of this script.
& $PSScriptRoot/windows-deps-part2.ps1

# Clone Inkscape git repo if it doesn't exist yet
if (-Not (Test-Path $InkscapeRepository/)) {
    & git clone --recurse-submodules "$InkscapeGitURL" --branch "$InkscapeGitBranch" "$InkscapeRepository"
    if (-Not $?) {
      throw "git clone failed"
    }
}
# Check for complete checkout - are the files inside the submodules also available?
if (-Not (Test-Path $InkscapeRepository/share/extensions/README.md)) {
  throw "Repository folder $InkscapeRepository exists but is not a complete Inkscape source repository (including submodules). Suggested solution: Delete (or rename) the folder and restart the script, so that the repository is downloaded again."
}


######################
# 2. Setup VSCode
######################

if ($SetupVSCode) {
  # Install VSCode if not yet installed
  if (-Not (Test-CommandExists "code")) {
    winget install --accept-package-agreements --accept-source-agreements Microsoft.VisualStudioCode
    # work around a bug in winget https://github.com/microsoft/winget-cli/issues/222 (fixed in the latest beta)
    $env:PATH += ";$env:LOCALAPPDATA/Programs/Microsoft VS Code/bin/"
  }

  # Copy VSCode configuration to .vscode in repository if not already present
  cd $InkscapeRepository
  if (-Not (Test-Path .vscode/launch.json)) {
    mkdir -force .vscode
    cp doc/vscode/*.json .vscode/
  }

  code --install-extension ms-vscode.cpptools-extension-pack
}

######################
# 3. Compile Inkscape
######################

# Build Inkscape
cd $InkscapeRepository
mkdir -force build
cd build

Start-MsysCommand 'cmake -G Ninja -DCMAKE_INSTALL_PREFIX="${PWD}/install_dir" -DCMAKE_BUILD_TYPE=Debug -DBUILD_SHARED_LIBS=OFF -DWITH_INTERNAL_2GEOM=ON  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON ..'
try { 
  Start-MsysCommand "ninja install"
} catch {
  # If compiling fails, we may have hit the RAM limit. This happens e.g. if you have 6 CPU cores but only 10 GB RAM.
  # Retry with just one parallel job.
  Start-MsysCommand "ninja -j1 install"
}
if (-Not (Test-Path install_dir/bin/inkscape.exe)) {
  throw "Compilation failed."
}



######################
# 4. Open Inkscape in VSCode
######################

if ($SetupVSCode) {
  & code $InkscapeRepository
}

######################
# 5. Run Inkscape
######################

# Check that Inkscape can be launched
If (-Not (./install_dir/bin/inkscape.com --version | Select-String -Pattern "Inkscape")) {
  # open the bin folder with Explorer
  Invoke-Item ./install_dir/bin/
  throw "Inkscape was compiled but can not be started. Please try to start $InkscapeRepository/build/install_dir/bin/inkscape.exe manually and check for error messages."
}

# Open Inkscape GUI
& ./install_dir/bin/inkscape.exe

######################
# 6. Show success message
######################

Set-PSDebug -Trace 0

$doneMessage = @"

Inkscape source code is in $InkscapeRepository .
Inkscape binary was compiled and is in $InkscapeRepository/install_dir/bin/inkscape.exe

VSCode: Open $InkscapeRepository with VSCode.

MSYS Commandline: MSYS $MSYSVariant Shell is in $MSYSPath/$MSYSVariant.exe .
(Note: Within MSYS, the windows path C:\...\  must be written as '/c/.../' . ).

Done :-) -- Close the window to exit.
"@

Write-Host "$doneMessage" -ForegroundColor Green

# Print some empty lines because Windows sometimes places the PS window such that the bottom is hidden by the taskbar.
For ($i=0; $i -lt 10; $i += 1)
{
    echo ""
}
