#!/bin/bash

set -e

version="vs18.0"
pushd _work/msbuild
git checkout "$version"
git reset --hard
git branch -D "rules_msbuild/$version" || echo ""
git checkout -b "rules_msbuild/$version"
popd


pushd Converter
dotnet run
popd

pushd _work/msbuild
proj="$(pwd)/src/Build/Microsoft.Build.csproj"
./build.sh -pack -projects "$proj" -configuration Release
rm -rf ~/.nuget/packages/samhowes.microsoft.build

framework_proj="$(pwd)/src/Framework/Microsoft.Build.Framework.csproj"
./build.sh -pack -projects "$framework_proj" -configuration Release
rm -rf ~/.nuget/packages/samhowes.microsoft.build.framework
popd