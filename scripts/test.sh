#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p bin output
xcrun swiftc -O App/Core.swift Tests/CoreTests.swift -o bin/core-tests
./bin/core-tests
xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift Tests/ModelTests.swift -o bin/model-tests
./bin/model-tests
if [[ "${INKFLOW_PRIVATE_SAMPLES:-0}" == "1" ]]; then
    python3 scripts/evaluate.py
fi
xcrun swiftc -O App/Core.swift App/TranslationImport.swift Tests/BrowserTranslationTests.swift -o bin/browser-translation-tests
./bin/browser-translation-tests
xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift Tests/UpscaleTests.swift -o bin/upscale-tests
./bin/upscale-tests

xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift Tests/HealingTests.swift -o bin/healing-tests
./bin/healing-tests
if [[ -n "${INKFLOW_HEALING_PYTHON:-}" ]]; then
    "$INKFLOW_HEALING_PYTHON" Tests/test_healing.py
    "$INKFLOW_HEALING_PYTHON" Tests/test_cleaning.py
fi
xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift Tests/TextLayerTests.swift -o bin/text-layer-tests
./bin/text-layer-tests

xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift Tests/TranslationAnchorTests.swift -o bin/translation-anchor-tests
./bin/translation-anchor-tests
xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift Tests/TranslationImportTests.swift -o bin/translation-import-tests
./bin/translation-import-tests

xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift Tests/TypesettingTests.swift -o bin/typesetting-tests
./bin/typesetting-tests

xcrun swiftc -O -swift-version 5 App/Core.swift App/Upscale.swift App/Healing.swift App/Cleaning.swift App/TextLayers.swift App/TranslationImport.swift App/PageExport.swift App/Model.swift Tests/CleaningTests.swift -o bin/cleaning-tests
./bin/cleaning-tests
