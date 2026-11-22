@echo off
REM ============================================================================
REM  setup_env.bat - Setup network simulator SDN (Ryu + Mininet) dari Windows
REM
REM  Mininet hanya berjalan di Linux, sehingga script ini menyiapkan DUA hal:
REM    [win] venv Windows (.venv-win) untuk notebook MODE='sim' (simulasi murni
REM          Python, tanpa Mininet) - bisa langsung dipakai di Windows/VS Code.
REM    [wsl] environment Ryu + Mininet asli di WSL2 Ubuntu, dengan menjalankan
REM          setup_env.sh di dalam WSL (venv: ~/.venvs/sdn-ryu-mininet).
REM
REM  Pemakaian:
REM    setup_env.bat          -> win + wsl
REM    setup_env.bat win      -> hanya venv Windows (mode simulasi)
REM    setup_env.bat wsl      -> hanya Ryu + Mininet di WSL2
REM ============================================================================
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "WIN_VENV=%ROOT%\.venv-win"
set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=all"

echo ============================================================
echo  Setup SDN Simulator (Ryu + Mininet)  -  target: %TARGET%
echo  Folder proyek: %ROOT%
echo ============================================================

if /I "%TARGET%"=="wsl" goto :wsl
if /I not "%TARGET%"=="all" if /I not "%TARGET%"=="win" (
    echo [error] Argumen tidak dikenal: %TARGET%  ^(gunakan: win ^| wsl ^| kosong^)
    exit /b 1
)

REM ------------------------------------------------------------------ [win] --
:win
echo.
echo [1/2] Membuat venv Windows untuk mode simulasi ...
set "PY="
where py >nul 2>&1
if not errorlevel 1 (
    for %%V in (3.12 3.11 3.10 3.13 3.9) do (
        if not defined PY (
            py -%%V -c "import sys" >nul 2>&1
            if not errorlevel 1 set "PY=py -%%V"
        )
    )
)
if not defined PY (
    python -c "import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)" >nul 2>&1
    if not errorlevel 1 set "PY=python"
)
if not defined PY (
    echo [error] Python 3.9+ tidak ditemukan. Pasang dari https://www.python.org/downloads/
    echo         ^(centang "Add python.exe to PATH"^), lalu jalankan ulang script ini.
    exit /b 1
)
echo       Interpreter: %PY%

if not exist "%WIN_VENV%\Scripts\python.exe" (
    %PY% -m venv "%WIN_VENV%"
    if errorlevel 1 ( echo [error] Gagal membuat venv. & exit /b 1 )
)
"%WIN_VENV%\Scripts\python.exe" -m pip install --upgrade pip
"%WIN_VENV%\Scripts\python.exe" -m pip install -r "%ROOT%\requirements.txt"
if errorlevel 1 ( echo [error] Gagal memasang requirements. & exit /b 1 )
"%WIN_VENV%\Scripts\python.exe" -m ipykernel install --user --name sdn-sim-win --display-name "Python (SDN sim - Windows)"
if not exist "%ROOT%\results" mkdir "%ROOT%\results"
if not exist "%ROOT%\runtime" mkdir "%ROOT%\runtime"
if not exist "%ROOT%\ryu_apps" mkdir "%ROOT%\ryu_apps"
echo [ ok ] venv Windows siap: %WIN_VENV%
echo        Notebook akan otomatis memakai MODE='sim' di Windows.

if /I "%TARGET%"=="win" goto :done

REM ------------------------------------------------------------------ [wsl] --
:wsl
echo.
echo [2/2] Menyiapkan Ryu + Mininet di WSL2 ...
where wsl >nul 2>&1
if errorlevel 1 goto :nowsl
wsl -e true >nul 2>&1
if errorlevel 1 goto :nowsl

wsl -e sh -c "grep -qi ubuntu /etc/os-release"
if errorlevel 1 echo [warn] Distro WSL default bukan Ubuntu - script dirancang untuk Ubuntu 20.04/22.04/24.04.

set "ROOT_FWD=%ROOT:\=/%"
set "WSL_ROOT="
for /f "usebackq delims=" %%P in (`wsl -e wslpath -a "%ROOT_FWD%"`) do set "WSL_ROOT=%%P"
if not defined WSL_ROOT (
    echo [error] Gagal mengonversi path Windows ke path WSL.
    exit /b 1
)
echo       Path di WSL: %WSL_ROOT%
echo       Password sudo Ubuntu akan diminta di bawah.
echo.

REM sed menghapus CRLF jika file .sh sempat terkonversi oleh Git di Windows
wsl -e bash -lc "cd '%WSL_ROOT%' && sed -i 's/\r$//' setup_env.sh run_jupyter.sh && VENV_DIR=$HOME/.venvs/sdn-ryu-mininet bash ./setup_env.sh"
if errorlevel 1 (
    echo [error] setup_env.sh di WSL gagal - periksa pesan di atas.
    exit /b 1
)
echo [ ok ] Ryu + Mininet siap di WSL2 ^(venv: ~/.venvs/sdn-ryu-mininet^).
goto :done

:nowsl
echo.
echo [warn] WSL2 / distro Linux belum terpasang. Mininet tidak bisa berjalan native di Windows.
echo        Langkah memasang WSL2 + Ubuntu:
echo          1. Buka PowerShell sebagai Administrator
echo          2. wsl --install -d Ubuntu-22.04
echo          3. Restart Windows, buka "Ubuntu", buat username + password
echo          4. Jalankan lagi:  setup_env.bat wsl
echo        Sementara itu notebook tetap bisa dijalankan dalam MODE='sim' ^(setup_env.bat win^).
if /I "%TARGET%"=="wsl" exit /b 1

:done
echo.
echo ============================================================
echo  Selesai. Jalankan notebook dengan:
echo    run_jupyter.bat wsl   -^> Ryu + Mininet asli ^(MODE='mininet'^)
echo    run_jupyter.bat win   -^> simulasi murni Python ^(MODE='sim'^)
echo ============================================================
endlocal
exit /b 0
