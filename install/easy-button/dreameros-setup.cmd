@echo off
rem DreamerOS easy setup - double-click entry point.
rem Double-clicking a .ps1 opens Notepad on a default Windows install.
rem This shim is what makes the script a button.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dreameros-easy-setup.ps1" %*
pause
