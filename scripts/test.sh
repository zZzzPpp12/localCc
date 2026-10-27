#!/bin/bash
set -euo pipefail
ORBIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ORBIT_ROOT/.build/module-cache"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ORBIT_ROOT/.build/module-cache" \
  "$ORBIT_ROOT/Sources/CodexOrbit/Models.swift" "$ORBIT_ROOT/Sources/CodexOrbit/QuotaHUDAlert.swift" "$ORBIT_ROOT/Sources/CodexOrbit/ApprovalModels.swift" "$ORBIT_ROOT/Tests/ModelTests.swift" -o "$ORBIT_ROOT/.build/ModelTests"
"$ORBIT_ROOT/.build/ModelTests"
chmod +x "$ORBIT_ROOT/Tests/fake-codex.py"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ORBIT_ROOT/.build/module-cache" \
  "$ORBIT_ROOT/Sources/CodexOrbit/Models.swift" "$ORBIT_ROOT/Sources/CodexOrbit/AppServerClient.swift" \
  "$ORBIT_ROOT/Tests/ClientTests.swift" -o "$ORBIT_ROOT/.build/ClientTests"
"$ORBIT_ROOT/.build/ClientTests" "$ORBIT_ROOT/Tests/fake-codex.py"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ORBIT_ROOT/.build/module-cache" \
  "$ORBIT_ROOT/Sources/CodexOrbit/EdgeDock.swift" "$ORBIT_ROOT/Sources/CodexOrbit/QuotaHUDGeometry.swift" "$ORBIT_ROOT/Tests/EdgeDockTests.swift" -o "$ORBIT_ROOT/.build/EdgeDockTests"
"$ORBIT_ROOT/.build/EdgeDockTests"

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$ORBIT_ROOT/.build/module-cache" \
  "$ORBIT_ROOT/Sources/CodexOrbit/HarnessActivity.swift" "$ORBIT_ROOT/Tests/ActivityTests.swift" -o "$ORBIT_ROOT/.build/ActivityTests"
"$ORBIT_ROOT/.build/ActivityTests"

xcrun swiftc -swift-version 5 -parse-as-library -lsqlite3 -module-cache-path "$ORBIT_ROOT/.build/module-cache" \
 "$ORBIT_ROOT/Sources/CodexOrbit/Models.swift" "$ORBIT_ROOT/Sources/CodexOrbit/DashboardModels.swift" "$ORBIT_ROOT/Sources/CodexOrbit/LocalSessionTokens.swift" "$ORBIT_ROOT/Tests/DashboardTests.swift" -o "$ORBIT_ROOT/.build/DashboardTests"
"$ORBIT_ROOT/.build/DashboardTests"
chmod +x "$ORBIT_ROOT/Tests/fake-dashboard.py"
xcrun swiftc -swift-version 5 -parse-as-library -lsqlite3 -module-cache-path "$ORBIT_ROOT/.build/module-cache" \
 "$ORBIT_ROOT/Sources/CodexOrbit/Models.swift" "$ORBIT_ROOT/Sources/CodexOrbit/AppServerClient.swift" "$ORBIT_ROOT/Sources/CodexOrbit/DashboardModels.swift" "$ORBIT_ROOT/Sources/CodexOrbit/LocalSessionTokens.swift" "$ORBIT_ROOT/Sources/CodexOrbit/DashboardStore.swift" "$ORBIT_ROOT/Tests/DashboardStoreTests.swift" -o "$ORBIT_ROOT/.build/DashboardStoreTests"
"$ORBIT_ROOT/.build/DashboardStoreTests" "$ORBIT_ROOT/Tests/fake-dashboard.py"
