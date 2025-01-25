@echo off
setlocal
cd /D "%~dp0"

if not exist build mkdir build
if not exist local mkdir local

pushd build
call cl /Od /I..\d3d12ma.c\code\ /I..\d3d12na.c\local\ /nologo /FC /Z7 /c ..\d3d12ma.c\code\samples\samples_simple_d3d12ma_main.cpp
call lib samples_simple_d3d12ma_main.obj /out:d3d12ma.lib
popd
