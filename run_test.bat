@echo off
rem Run the STEP-3 hotseat turn loop test in headless console mode.
set GODOT_EXE=%~dp0Godot_v4.7.1-stable_win64.exe
"%GODOT_EXE%" --headless --path "%~dp0." res://scenes/turn_loop_test.tscn
