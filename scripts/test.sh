#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache Sources/Connections.swift Tests/CoreTests.swift -o .build/core-tests
.build/core-tests "$@"
python3 scripts/check-localizations.py
