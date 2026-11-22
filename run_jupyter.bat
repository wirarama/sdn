@echo off
REM ============================================================================
REM  run_jupyter.bat - Jalankan JupyterLab untuk notebook SDN
REM    run_jupyter.bat wsl  -> JupyterLab di WSL2 sebagai root (MODE='mininet', Ryu + Mininet)
REM    run_jupyter.bat win  -> JupyterLab di Windows (MODE='sim', TANPA Ryu/Mininet)
REM    run_jupyter.bat      -> wsl jika setup WSL sudah selesai, selain itu win
REM ============================================================================
setlocal EnableExtensions
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "TARGET=%~1"
set "DISTRO="
if exist "%ROOT%\.wsl_distro" for /f "usebackq tokens=2 delims==" %%D in ("%ROOT%\.wsl_distro") do set "DISTRO=%%D"

if "%TARGET%"=="" (
    if defined DISTRO ( set "TARGET=wsl" ) else ( set "TARGET=win" )
)
if /I "%TARGET%"=="wsl" goto :wsl
if /I "%TARGET%"=="win" goto :win
echo [error] Argumen tidak dikenal: %TARGET%  (gunakan: wsl atau win)
goto :fail

:wsl
if not defined DISTRO (
    echo [error] Setup WSL belum selesai ^(file .wsl_distro tidak ada^). Jalankan dulu: setup_env.bat wsl
    goto :fail
)
set "ROOT_FWD=%ROOT:\=/%"
set "WSL_ROOT="
REM C:\a\b -> /mnt/c/a/b  (dihitung langsung; wslpath hanya cadangan)
set "DRV=%ROOT:~0,1%"
for %%L in (a b c d e f g h i j k l m n o p q r s t u v w x y z) do if /I "%DRV%"=="%%L" set "DRV=%%L"
set "REST=%ROOT:~2%"
set "WSL_ROOT=/mnt/%DRV%%REST:\=/%"
if not "%ROOT:~1,1%"==":" set "WSL_ROOT="
if not defined WSL_ROOT for /f "usebackq delims=" %%P in (`wsl -d %DISTRO% -e wslpath -a %ROOT_FWD%`) do set "WSL_ROOT=%%P"
if not defined WSL_ROOT ( echo [error] Distro %DISTRO% tidak bisa dijalankan. & goto :fail )
echo [info] JupyterLab di WSL2 (%DISTRO%, root, Ryu + Mininet).
echo [info] Buka URL http://127.0.0.1:8888/lab?token=... yang tampil di bawah pada browser Windows.
echo [info] Masukkan password Ubuntu bila diminta sudo. Ctrl+C dua kali untuk berhenti.
wsl -d %DISTRO% -e bash -lc "cd '%WSL_ROOT%' && sed -i 's/\r$//' run_jupyter.sh && VENV_DIR=$HOME/.venvs/sdn-ryu-mininet bash ./run_jupyter.sh"
goto :end

:win
if not exist "%ROOT%\.venv-win\Scripts\python.exe" (
    echo [error] venv Windows belum ada. Jalankan: setup_env.bat win
    goto :fail
)
echo [info] JupyterLab di Windows: MODE='sim' (Ryu/Mininet memang TIDAK tersedia di Windows).
"%ROOT%\.venv-win\Scripts\python.exe" -m jupyterlab --notebook-dir "%ROOT%\notebooks"
goto :end

:fail
pause
endlocal
exit /b 1

:end
endlocal
exit /b 0
