#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p bin output
xcrun swiftc -O App/Core.swift Tests/CoreTests.swift -o bin/core-tests
./bin/core-tests
xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/TextLayers.swift App/Model.swift Tests/ModelTests.swift -o bin/model-tests
./bin/model-tests
if [[ "${INKFLOW_PRIVATE_SAMPLES:-0}" == "1" ]]; then
    python3 scripts/evaluate.py
fi
xcrun swiftc -O App/Core.swift Tests/BrowserTranslationTests.swift -o bin/browser-translation-tests
./bin/browser-translation-tests
xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/TextLayers.swift App/Model.swift Tests/UpscaleTests.swift -o bin/upscale-tests
./bin/upscale-tests

xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/TextLayers.swift App/Model.swift Tests/HealingTests.swift -o bin/healing-tests
./bin/healing-tests
if [[ -n "${INKFLOW_HEALING_PYTHON:-}" ]]; then
    "$INKFLOW_HEALING_PYTHON" Tests/test_healing.py
fi
xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/TextLayers.swift App/Model.swift Tests/TextLayerTests.swift -o bin/text-layer-tests
./bin/text-layer-tests
