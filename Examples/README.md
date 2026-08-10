# Examples

Small apps that exist to be driven, and the checks that drive them. Each was
developed with Loupe in the loop — look, change, look again — which is also the
fastest way to find out whether Loupe itself is pleasant to use.

| | |
| --- | --- |
| [TaskDemo](TaskDemo) | A universal SwiftUI app: filterable list, detail, add-via-sheet. Uses `NavigationSplitView`, so iPhone gets a push stack and iPad gets two columns — the same flow has to cope with both. |
| [electron-app.swift](electron-app.swift) | Driving an Electron app on macOS. Chromium keeps its accessibility tree off until asked, so this is the case that looks like "the app has no accessibility" until Loupe wakes it. |
| [login.swift](login.swift) | A login flow with a retry, showing how to race the screen you want against the app's own error message. |

## Running the checks

```bash
# iPhone
xcrun simctl boot "iPhone 17 Pro"
loupe script Examples/TaskDemo/flow.swift --target "sim:iPhone 17 Pro"

# the same file, iPad
xcrun simctl boot "iPad Pro 11-inch (M5)"
loupe script Examples/TaskDemo/flow.swift --target "sim:iPad Pro 11-inch (M5)"
```

Build and install TaskDemo first:

```bash
cd Examples/TaskDemo && xcodegen generate
xcodebuild build -project TaskDemo.xcodeproj -scheme TaskDemo \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"
xcrun simctl install booted <path-to>/TaskDemo.app
```

The first simulator run also builds Loupe's UI-test bridge (~40 s, cached in
`~/.loupe/bridge`); later runs start in a few seconds.
