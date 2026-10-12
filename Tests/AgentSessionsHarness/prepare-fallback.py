"""Test-only boundary injection. No production edits or accelerated production timers."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[2]
out = root / 'build/agent-sessions-harness/fallback'
out.mkdir(parents=True, exist_ok=True)
for stale in out.glob('*.swift'):  # copies of files that no longer exist must not be compiled
    stale.unlink()
manifest = {}
p = root / 'Sources/SidelightCore/Process/FileSystemWatchers.swift'
s = p.read_text()
manifest[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
# The class and its main-actor convenience initializer, without FileWatcher and its extension between them.
s = s[s.index('/// Recursive file-level'):s.index('extension FileWatcher {')] + s[s.index('extension FileEventStream {'):]
s = s.replace('FileEventStream', 'BoundaryFileEventStream')
# Real Create/context/release callback remain intact. Only C start/teardown calls are observed.
for old, new in [('FSEventStreamStart(', 'StartBoundary.start('),
                 ('FSEventStreamStop(', 'StartBoundary.stop('),
                 ('FSEventStreamInvalidate(', 'StartBoundary.invalidate('),
                 ('FSEventStreamRelease(', 'StartBoundary.release(')]:
    s = s.replace(old, new)
(out / 'FileEventStream.swift').write_text('import CoreServices\nimport Foundation\n' + s)
# Both services are one generic class now; its collaborators are copied verbatim.
index = root / 'Sources/Sidelight/Widgets/AgentSessions/WatchedSessionIndex.swift'
manifest[str(index.relative_to(root))] = hashlib.sha256(index.read_bytes()).hexdigest()
s = index.read_text().replace('private ', '').replace('FileEventStream', 'BoundaryFileEventStream')
(out / 'WatchedSessionIndex.swift').write_text(s)
for name in ['DataService', 'CoalescedReload', 'RepeatingTask']:
    p = root / f'Sources/Sidelight/Services/{name}.swift'
    manifest[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    (out / f'{name}.swift').write_text(p.read_text())
(out / 'source-hashes.json').write_text(json.dumps(manifest, indent=2))
print('Generated exact wrapper and the shared session index with its collaborators with test-only start boundary; real 120s sweep.')
