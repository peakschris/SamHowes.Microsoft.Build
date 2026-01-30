rem Start Visual Studio developer command prompt
rem build.bat

set version=vs17.11
pushd _work\msbuild
git checkout %version%
git reset --hard
git branch -D rules_msbuild/%version% || echo ""
git checkout -b rules_msbuild/%version%
popd

pushd Converter
set version=17.11.0
dotnet run
popd

pushd _work\msbuild
set "proj=%cd%\src\Build\Microsoft.Build.csproj"
.\build.cmd -pack -projects "%proj%" -configuration Release

rmdir /s /q %USERPROFILE%\.nuget\packages\samhowes.microsoft.build
