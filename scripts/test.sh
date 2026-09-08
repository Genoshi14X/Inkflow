#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p bin output
xcrun swiftc -O App/Core.swift Tests/CoreTests.swift -o bin/core-tests
./bin/core-tests
xcrun swiftc -O -swift-version 5 App/Core.swift App/Model.swift Tests/ModelTests.swift -o bin/model-tests
./bin/model-tests
if [[ "${INKFLOW_PRIVATE_SAMPLES:-0}" == "1" ]]; then
    python3 scripts/evaluate.py
fi
