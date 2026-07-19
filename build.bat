@echo off
setlocal enabledelayedexpansion

set git_version=vs18.0
pushd _work\msbuild
git checkout "%git_version%"
git reset --hard
git branch -D "rules_msbuild/%git_version%" 2>nul || echo.
git checkout -b "rules_msbuild/%git_version%"
popd

pushd Converter
echo "Running converter for git version %git_version%"
dotnet run
if errorlevel 1 exit /b 1
popd

pushd _work\msbuild
set buildProj=%cd%\src\Build\Microsoft.Build.csproj
set frameworkProj=%cd%\src\Framework\Microsoft.Build.Framework.csproj

echo Building Microsoft.Build.Framework...
call build.cmd -pack -projects "%frameworkProj%" -configuration Release /p:UsingToolVisualStudioIbcTraining=false
if errorlevel 1 exit /b 1

echo Building Microsoft.Build...
call build.cmd -pack -projects "%buildProj%" -configuration Release /p:UsingToolVisualStudioIbcTraining=false
if errorlevel 1 exit /b 1

rmdir /s /q "%USERPROFILE%\.nuget\packages\samhowes.microsoft.build" 2>nul || echo.
rmdir /s /q "%USERPROFILE%\.nuget\packages\samhowes.microsoft.build.framework" 2>nul || echo.
popd