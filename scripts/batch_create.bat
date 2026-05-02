@echo off
python "%~dp0batch_create.py" %1 > %2 2>&1
exit /b %errorlevel%
