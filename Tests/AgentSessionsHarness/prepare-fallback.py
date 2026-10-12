"""Test-only boundary injection. No production edits or accelerated production timers."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[2]
out = root / 'build/agent-sessions-harness/fallback'
out.mkdir(parents=True, exist_ok=True)
manifest = {}
p = root / 'Sources/SidelightCore/Process/FileSystemWatchers.swift'
s = p.read_text()
manifest[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
s = s[s.index('/// Recursive file-level'):]
s = s.replace('FileEventStream', 'BoundaryFileEventStream')
# Real Create/context/release callback remain intact. Only C start/teardown calls are observed.
for old, new in [('FSEventStreamStart(', 'StartBoundary.start('),
                 ('FSEventStreamStop(', 'StartBoundary.stop('),
                 ('FSEventStreamInvalidate(', 'StartBoundary.invalidate('),
                 ('FSEventStreamRelease(', 'StartBoundary.release(')]:
    s = s.replace(old, new)
(out / 'FileEventStream.swift').write_text('import CoreServices\nimport Foundation\n' + s)
for name in ['OpenCodeSessionsService', 'CursorChatsService']:
    p = root / f'Sources/Sidelight/Widgets/AgentSessions/{name}.swift'
    manifest[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    s = p.read_text().replace('private ', '').replace('FileEventStream', 'BoundaryFileEventStream')
    (out / f'{name}.swift').write_text(s)
(out / 'source-hashes.json').write_text(json.dumps(manifest, indent=2))
print('Generated exact wrapper and service bodies with test-only start boundary; real 120s sweep.')
