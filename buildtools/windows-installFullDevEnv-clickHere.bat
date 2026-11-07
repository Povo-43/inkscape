:: SPDX-License-Identifier: GPL-v2-or-later
:: 
:: This script sets up a whole Inkscape development environment on Windows, including VSCode, and compiles Inkscape.
::
:: To run the script, just double-click on this .bat file.
::
:: For customization, please edit the configuration in windows-installFullDevEnv-part2.ps1 .
:: 
:: For more information please read the following "echo" lines:
::
@echo off
echo Automatic installation/update of Inkscape development environment, including VSCode.
echo.
echo For documentation please see doc/building/windows.md and windows-installFullDevEnv-part2.ps1 .
echo.
echo This script will set up a complete Inkscape development environment.
echo - Get sourcecode
echo - Install dependencies
echo - Compile and run Inkscape
echo - Install and set up VSCode
echo.
echo This script will download the following software and install it, partly with Administrator rights:
echo - Microsoft WinGet
echo - Git for Windows
echo - Microsoft VSCode and its CPP Extension Pack
echo - MSYS2 https://msys2.org/
echo - many MSYS2 packages, see ./msys2installdeps.sh
echo - Microsoft DotNet SDK
echo - WiX https://wixtoolset.org/
echo.
echo Do you want to continue? Press Enter to continue. Close the window to abort.
echo.
pause

:: set $CDSHORTPATH to the DOS 8.3 shortpath of the current directory (to get rid of spaces)
FOR %%I IN ("%CD%") DO SET "cdshortpath=%%~sI"

echo "Starting part 2 with Administrator rights..."
:: We don't use -Wait because sometimes, at the end of the powershell script, the PS window closes but the process doesn't exit.
powershell -Command "Start-Process powershell -Verb runAs -ArgumentList '-NoExit','-ExecutionPolicy','bypass','-File','%cdshortpath%\windows-installFullDevEnv-part2.ps1'"

timeout 5
