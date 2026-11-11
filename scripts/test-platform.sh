#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tmp/platform-checks

# Compile the production service/model against small macOS SDK doubles.
# This checks our state and callback boundaries; it does not emulate iOS shielding.
python3 - <<'PY'
from pathlib import Path
import re
out=Path('build/tmp/platform-checks')
service=Path('Platform/ScreenTimeService.swift').read_text()
service=re.sub(r'(?m)^import (DaywellCore|DeviceActivity|FamilyControls|ManagedSettings)\n','',service)
service=re.sub(r'static var isSimulator: Bool \{.*?\n  \}', 'static let isSimulator = false', service, count=1, flags=re.S)
service=re.sub(r'init\(\) throws \{\n    let directory: URL.*?\n    storage =', 'init() throws {\n    let directory = World.directory!\n    storage =', service, count=1, flags=re.S)
(out/'ScreenTimeService.swift').write_text(service)
model=Path('App/DaywellModel.swift').read_text()
model=re.sub(r'(?m)^[ \t]*import (DaywellCore|FamilyControls|ManagedSettings)\n','',model)
(out/'DaywellModel.swift').write_text(model)
PY
xcrun swiftc -parse-as-library -warnings-as-errors -module-cache-path build/tmp/platform-checks/module-cache Sources/DaywellCore/*.swift Tests/ScreenTimeChecks/{SDK,Checks}.swift build/tmp/platform-checks/{ScreenTimeService,DaywellModel}.swift -o build/tmp/platform-checks/checks
if [[ "$#" -eq 0 ]]; then
  set -- start-callback stop-callback morning-callback exemption-callback oversized-allowlist fitness fitness-websites fitness-no-allowlist sleep sleep-websites selection-additions selection-during-exemption selection-union-limit selection-after-empty-reselection retry verification busy storage-error authorization-revoked authorization-cold-denied authorization-restore-error authorization-restore-cancelled authorization-data-access
fi
for daywell_scenario in "$@"; do
  build/tmp/platform-checks/checks "$daywell_scenario"
done
