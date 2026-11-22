@echo off
REM ============================================================================
REM  setup_env.bat - Setup network simulator SDN (Ryu + Mininet) dari Windows
REM
REM  Mininet hanya berjalan di Linux, sehingga script ini menyiapkan DUA hal:
REM    [win] venv Windows (.venv-win) untuk notebook MODE='sim' (simulasi murni
REM          Python, TANPA Ryu/Mininet - keduanya memang tidak bisa di Windows).
REM    [wsl] Ryu + Mininet asli di distro Ubuntu WSL2, dengan menjalankan
REM          setup_env.sh di dalam WSL (venv: ~/.venvs/sdn-ryu-mininet).
REM
REM  Pemakaian:
REM    setup_env.bat                     -> win + wsl
REM    setup_env.bat win                 -> hanya venv Windows (mode simulasi)
REM    setup_env.bat wsl                 -> hanya Ryu + Mininet di WSL2
REM    setup_env.bat wsl Ubuntu-22.04    -> pakai distro WSL tertentu
REM  Semua keluaran juga dicatat ke setup_env.log
REM ============================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "WIN_VENV=%ROOT%\.venv-win"
set "LOG=%ROOT%\setup_env.log"
set "TARGET=%~1"
set "DISTRO=%~2"
if "%TARGET%"=="" set "TARGET=all"

echo ============================================================
echo  Setup SDN Simulator (Ryu + Mininet)  -  target: %TARGET%
echo  Folder proyek: %ROOT%
echo  Log         : %LOG%
echo ============================================================
echo [%date% %time%] setup_env.bat %* > "%LOG%"

if /I "%TARGET%"=="wsl" goto :wsl
if /I "%TARGET%"=="win" goto :win
if /I "%TARGET%"=="all" goto :win
echo [error] Argumen tidak dikenal: %TARGET%   (gunakan: win, wsl, atau kosong)
goto :fail

REM ------------------------------------------------------------------ [win] --
:win
echo.
echo [1/2] venv Windows untuk mode simulasi ...
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
    echo [error] Python 3.9+ tidak ditemukan di Windows. Pasang dari https://www.python.org/downloads/
    goto :fail
)
echo       Interpreter: %PY%
if not exist "%WIN_VENV%\Scripts\python.exe" (
    %PY% -m venv "%WIN_VENV%" >> "%LOG%" 2>&1
    if errorlevel 1 ( echo [error] Gagal membuat venv - lihat setup_env.log & goto :fail )
)
echo       Memasang requirements (beberapa menit) ...
"%WIN_VENV%\Scripts\python.exe" -m pip install --upgrade pip >> "%LOG%" 2>&1
"%WIN_VENV%\Scripts\python.exe" -m pip install -r "%ROOT%\requirements.txt" >> "%LOG%" 2>&1
if errorlevel 1 ( echo [error] Gagal memasang requirements - lihat setup_env.log & goto :fail )
"%WIN_VENV%\Scripts\python.exe" -m ipykernel install --user --name sdn-sim-win --display-name "Python (SDN sim - Windows)" >> "%LOG%" 2>&1
for %%D in (results runtime ryu_apps) do if not exist "%ROOT%\%%D" mkdir "%ROOT%\%%D"
echo [ ok ] venv Windows siap (MODE='sim', tanpa Ryu/Mininet).
if /I "%TARGET%"=="win" goto :done

REM ------------------------------------------------------------------ [wsl] --
:wsl
echo.
echo [2/2] Ryu + Mininet di WSL2 ...
where wsl >nul 2>&1
if not "!errorlevel!"=="0" (
    echo [error] Perintah wsl tidak ada - WSL belum terpasang.
    goto :howto
)

echo       Distro WSL yang terpasang:
wsl -l -v
wsl -l -v >> "%LOG%" 2>&1

if defined DISTRO goto :check_distro
REM Coba nama distro Ubuntu yang umum secara langsung. (Parsing "wsl -l -q" tidak dipakai:
REM keluarannya UTF-16/CRLF sehingga nama distro terbawa karakter tersembunyi.)
for %%N in (Ubuntu Ubuntu-24.04 Ubuntu-22.04 Ubuntu-20.04) do (
    if not defined DISTRO (
        wsl -d %%N -e true >nul 2>&1
        if "!errorlevel!"=="0" set "DISTRO=%%N"
    )
)
if not defined DISTRO (
    echo.
    echo [error] Tidak ada distro Ubuntu yang bisa dijalankan. Pesan dari WSL:
    wsl -d Ubuntu -e echo ok
    goto :howto
)

:check_distro
echo       Memakai distro: %DISTRO%
REM catatan: wsl.exe bisa mengembalikan errorlevel NEGATIF, jadi dicek dengan == 0
wsl -d %DISTRO% -e true >nul 2>&1
if not "!errorlevel!"=="0" (
    echo [error] Distro "%DISTRO%" tidak terpasang / tidak bisa dijalankan. Pesan dari WSL:
    wsl -d %DISTRO% -e echo ok
    echo         Jika baru dipasang, buka "%DISTRO%" sekali dari Start Menu untuk membuat
    echo         username/password, lalu jalankan ulang script ini.
    goto :howto
)
REM info kernel (tanpa pipe; deteksi WSL1 dilakukan oleh setup_env.sh di dalam Linux)
set "KREL="
for /f "usebackq delims=" %%K in (`wsl -d %DISTRO% -e uname -r`) do set "KREL=%%K"
echo       Kernel WSL : !KREL!

set "ROOT_FWD=%ROOT:\=/%"
set "WSL_ROOT="
REM C:\a\b -> /mnt/c/a/b  (dihitung langsung; wslpath hanya cadangan)
set "DRV=%ROOT:~0,1%"
for %%L in (a b c d e f g h i j k l m n o p q r s t u v w x y z) do if /I "%DRV%"=="%%L" set "DRV=%%L"
set "REST=%ROOT:~2%"
set "WSL_ROOT=/mnt/%DRV%%REST:\=/%"
if not "%ROOT:~1,1%"==":" set "WSL_ROOT="
if not defined WSL_ROOT for /f "usebackq delims=" %%P in (`wsl -d %DISTRO% -e wslpath -a %ROOT_FWD%`) do set "WSL_ROOT=%%P"
if not defined WSL_ROOT (
    echo [error] Gagal mengonversi path Windows ke path WSL.
    goto :fail
)
echo       Path di WSL: %WSL_ROOT%
echo.
echo       ^>^>^> Masukkan PASSWORD UBUNTU (bukan password Windows) saat diminta sudo.
echo       ^>^>^> Langkah ini bisa 5-15 menit (apt + Python 3.9 + Ryu). Jangan tutup jendela.
echo.
wsl -d %DISTRO% -e bash -lc "cd '%WSL_ROOT%' && sed -i 's/\r$//' setup_env.sh run_jupyter.sh && VENV_DIR=$HOME/.venvs/sdn-ryu-mininet bash ./setup_env.sh 2>&1 | tee setup_env_wsl.log; exit ${PIPESTATUS[0]}"
if not "!errorlevel!"=="0" (
    echo.
    echo [error] setup_env.sh di WSL gagal - pesan lengkap ada di setup_env_wsl.log
    goto :fail
)
echo WSL_DISTRO=%DISTRO%> "%ROOT%\.wsl_distro"
echo [ ok ] Ryu + Mininet siap di WSL2 (%DISTRO%, venv ~/.venvs/sdn-ryu-mininet).
goto :done

:howto
echo.
echo        Cara memasang WSL2 + Ubuntu:
echo          1. Buka PowerShell sebagai Administrator
echo          2. wsl --install -d Ubuntu      (nama distro: lihat wsl --list --online)
echo          3. Restart bila diminta, buka "Ubuntu" dari Start Menu, buat username + password
echo          4. Jalankan lagi:  setup_env.bat wsl
echo        Sementara itu notebook tetap bisa dicoba di MODE='sim':  run_jupyter.bat win
goto :fail

:done
echo.
echo ============================================================
echo  Selesai. Jalankan notebook dengan:
echo    run_jupyter.bat wsl   -^> Ryu + Mininet asli (MODE='mininet')
echo    run_jupyter.bat win   -^> simulasi murni Python (MODE='sim')
echo ============================================================
if not defined NOPAUSE pause
endlocal
exit /b 0

:fail
echo.
echo Setup BELUM selesai. Log: %LOG%
if not defined NOPAUSE pause
endlocal
exit /b 1
