project := "CareMyMac.xcodeproj"
scheme := "CareMyMac"
derived := "build/DD"
destination := "platform=macOS,arch=" + `uname -m`

# List recipes
default:
    @just --list

# Build the app (config: Debug or Release)
build config="Debug":
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{config}} -destination '{{destination}}' -derivedDataPath {{derived}} build -quiet

# Build, quit any running copy, and launch the app
run config="Debug": (build config)
    -pkill -x CareMyMac
    open "{{derived}}/Build/Products/{{config}}/CareMyMac.app"

# Build and run in the foreground with logs in the terminal (Ctrl-C quits)
dev config="Debug": (build config)
    -pkill -x CareMyMac
    "{{derived}}/Build/Products/{{config}}/CareMyMac.app/Contents/MacOS/CareMyMac"

# Build and launch the optimized Release build
release: (run "Release")

# Run the engine tests
test:
    cd Packages/CareMyMacKit && swift test

# Render pages to PNG with a throwaway store (Debug only), e.g. `just snapshot overview,cpu:inspect dark`
snapshot screens="busy,allApps,background,developer,thisMac,thisMac:cpu,thisMac:memory,thisMac:disk,thisMac:network,thisMac:graphics,thisMac:battery,storage,timeline,alerts,markers,cleanup,uninstaller,optimize" appearance="dark" dir="/tmp/caremymac-shots": (build "Debug")
    "{{derived}}/Build/Products/Debug/CareMyMac.app/Contents/MacOS/CareMyMac" \
        -CareMyMacStore /tmp/caremymac-snapshot.sqlite \
        -CareMyMacSnapshotDir "{{dir}}/{{appearance}}" \
        -CareMyMacSnapshotScreens "{{screens}}" \
        -CareMyMacSnapshotWarmup 30 \
        -CareMyMacAppearance {{appearance}}
    @echo "Snapshots in {{dir}}/{{appearance}}"

# Build the update zip and signed appcast into build/release, e.g. `just package 0.2.0` (signs with the keychain key)
package version:
    scripts/release.sh {{version}}

# Tag a version and push the tag; the Release workflow builds and publishes it, e.g. `just publish 0.2.0`
publish version:
    git tag -a "v{{version}}" -m "CareMyMac {{version}}"
    git push origin "v{{version}}"

# Open the project in Xcode
xcode:
    open {{project}}

# Remove build products
clean:
    rm -rf build Packages/CareMyMacKit/.build
