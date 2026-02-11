@echo on
cd /d "%~dp0"

echo === GDToolkit ===
py -m pip show gdtoolkit

echo === Try linter as module ===
py -m gdtoolkit.linter AutoLoads/PartyManager.gd

echo === ExitCode ===
echo %ERRORLEVEL%

pause