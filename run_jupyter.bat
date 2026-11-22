@echo off
REM ============================================================================
REM  run_jupyter.bat - Jalankan JupyterLab untuk notebook SDN
REM    run_jupyter.bat wsl  -> JupyterLab di WSL2 sebagai root (MODE='mininet')
REM    run_jupyter.bat win  -> JupyterLab di Windows (MODE='sim')
REM    run_jupyter.bat      -> wsl jika venv WSL tersedia, selain itu win
REM ============================================================================
setlocal EnableExtensions
chcp 65001 >nul
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "TARGET=%~1"

if "%TARGET%"=="" (
    set "TARGET=win"
    wsl -e test -x /bin/sh >nul 2>&1 && wsl -e bash -lc "test -x $HOME/.venvs/sdn-ryu-mininet/bin/jupyter" >nul 2>&1 && set "TARGET=wsl"
)

if /I "%TARGET%"=="wsl" goto :wsl
if /I "%TARGET%"=="win" goto :win
echo [error] Argumen tidak dikenal: %TARGET%  (gunakan: wsl atau win)
exit /b 1

:wsl
set "ROOT_FWD=%ROOT:\=/%"
set "WSL_ROOT="
for /f "usebackq delims=" %%P in (`wsl -e wslpath -a "%ROOT_FWD%"`) do set "WSL_ROOT=%%P"
if not defined WSL_ROOT ( echo [error] WSL tidak tersedia. Jalankan setup_env.bat wsl terlebih dahulu. & exit /b 1 )
echo [info] Menjalankan JupyterLab di WSL2 (root) - buka URL http://127.0.0.1:8888/lab?token=... di browser Windows.
wsl -e bash -lc "cd '%WSL_ROOT%' && sed -i 's/\r$//' run_jupyter.sh && VENV_DIR=$HOME/.venvs/sdn-ryu-mininet bash ./run_jupyter.sh"
exit /b %errorlevel%

:win
if not exist "%ROOT%\.venv-win\Scripts\python.exe" (
    echo [error] venv Windows belum ada. Jalankan: setup_env.bat win
    exit /b 1
)
echo [info] Menjalankan JupyterLab di Windows (MODE='sim', tanpa Mininet).
"%ROOT%\.venv-win\Scripts\python.exe" -m jupyterlab --notebook-dir "%ROOT%\notebooks"
exit /b %errorlevel%
