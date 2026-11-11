@echo off
rem Re-run the CSV -> .tres import pipeline and verify the generated cards.
C:\Progra~1\Godot_v4.7.1-stable_win64.exe --headless --path "%~dp0." -s res://scripts/tools/run_import_cli.gd
