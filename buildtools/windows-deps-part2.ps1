# SPDX-License-Identifier: GPL-v2-or-later
#
# Part of the Inkscape Windows dependency installation.
# For the main script, see windows-deps-clickHere.bat
# 
# This script assumes to be started with Admin permissions.


$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
cd $scriptDir


echo "Part 2. Installing MSYS2"
winget  install --accept-package-agreements --accept-source-agreements MSYS2.MSYS2

echo "Installing WiX v4 and DotNetSDK (for building MSI installer)"
& .\windows-deps-install-wix4.ps1

function RunInMsys {
    # Run command in msys shell
    param (
        # MSYS architecture: MSYS2 / UCRT64 / MINGW64
        $MSYSVariant,
        # shell command to be run
        $Command
    )

    echo "Running in MSYS $MSYSVariant terminal: $Command"

    & C:/msys64/usr/bin/env.exe CHERE_INVOKING=1 MSYSTEM=$MSYSVariant /usr/bin/bash -lc "$Command"
    if (-Not $?) {
       throw "Running command in MSYS $MSYSVariant shell failed: $Command"
    }
}

# call MSYS system upgrade repeatedly. If the dependencies were already installed before, then this will upgrade everything. Repeating is needed because sometimes MSYS doesn't upgrade everything at once.
Echo "Running MSYS system upgrade multiple times..."
For ($i=0; $i -lt 5; $i += 1)
{
    RunInMsys "MSYS2" "pacman --noconfirm -Syuu"
}

# start msys2installdeps.sh
Echo "Installing Inkscape build dependencies"
RunInMsys "UCRT64" "./msys2installdeps.sh"

Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "Everything is installed that you need to compile Inkscape." -ForegroundColor Green
Write-Host ""
Write-Host "Done :-) Close the window to exit." -ForegroundColor Green

# Print some empty lines because Windows sometimes places the PS window such that the bottom is hidden by the taskbar.
For ($i=0; $i -lt 10; $i += 1)
{
    echo ""
}
