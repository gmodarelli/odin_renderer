@echo off
setlocal enabledelayedexpansion

set build_path=%~1
set name=%~2
set config=%~3

echo [%name%]
echo [%config%]

if not exist %build_path% ( mkdir %build_path% )

set build_options=-out:%build_path%\%name%.exe
if %config%==Debug set build_options=%build_options% -debug -pdb-name:%build_path%\%name%.pdb -o:none
if %config%==Release set build_options=%build_options% -o:minimal

odin build . %build_options%

xcopy "%ODIN_PATH%\vendor\sdl2\SDL2.dll" "%build_path%\SDL2.dll"* /S /Y /D