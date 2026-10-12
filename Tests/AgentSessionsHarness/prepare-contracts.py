"""Compile current source decisions with test-only access and dispatch substitutes.

Generated files stay under ignored build/. No production source is edited. Copies retain
all decision bodies; only private access and named system boundaries are substituted.
"""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[2]
out = root / 'build/agent-sessions-harness/contracts'
out.mkdir(parents=True, exist_ok=True)
for stale in out.glob('*.swift'):  # copies of files that no longer exist must not be compiled
    stale.unlink()
manifest = {}

def source(relative):
    path = root / 'Sources/Sidelight' / relative
    value = path.read_text()
    manifest[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return value

def expose(value):
    return value.replace('fileprivate ', '').replace('private ', '')

for path in ['AgentSessions/AgentSessionOpener.swift', 'CodexSessions/CodexSessionOpener.swift', 'ClaudeSessions/ClaudeSessionOpener.swift']:
    value = expose(source('Widgets/' + path))
    for old, new in [('NSWorkspace', 'MockWorkspace'), ('NSRunningApplication', 'MockApplication'), ('SessionHost.', 'MockHost.'), ('NSSound.', 'MockSound.')]:
        value = value.replace(old, new)
    if path == 'AgentSessions/AgentSessionOpener.swift':
        value = value.replace('ProcessRunner.output', 'MockProcessRunner.output')
    (out / Path(path).name).write_text(value)

# One generic index serves Cursor and OpenCode; only private access is exposed. Its read is an injected closure, so
# the harness controls the asynchronous read through the initializer and no body is rewritten.
value = expose(source('Widgets/AgentSessions/WatchedSessionIndex.swift'))
assert value.count('await read(database,') == 1
(out / 'WatchedSessionIndex.swift').write_text(value)
# Its collaborators are compiled as they are.
for name in ['DataService', 'CoalescedReload', 'RepeatingTask']:
    (out / f'{name}.swift').write_text(source(f'Services/{name}.swift'))
(out / 'AgentSessionSources.swift').write_text(source('Widgets/AgentSessions/AgentSessionSources.swift'))
value = source('Widgets/AgentSessions/AgentSessionsWidget.swift')
# Complete, verbatim declarations; the omitted top-level view needs the full app environment.
parts = [value[value.index('extension WidgetMetadata {'):value.index('extension AgentSessionsSettings {')],
         value[value.index('extension AgentSessionsSettings {'):value.index('// MARK: - Settings')],
         # Skips the settings editor, whose environment and shared settings views the contracts don't need.
         value[value.index('extension AgentSessionSources.State {'):value.index('// MARK: - Widget')],
         # The content branches (empty and error states are the shared WidgetMessage) up to the list stand-in.
         value[value.index('private struct AgentSessionsContent:'):value.index('// MARK: - List')],
         value[value.index('private struct AgentSessionRow:'):]]
claude = source('Widgets/ClaudeSessions/ClaudeSessionsWidget.swift')
parts.append(claude[claude.index('extension ClaudeSession.Activity {'):claude.index('extension ClaudeSessionSurface {')])
(out / 'Views.swift').write_text('import SidelightCore\nimport SwiftUI\n' + expose('\n'.join(parts)))
(out / 'source-hashes.json').write_text(json.dumps(manifest, indent=2))
print('Generated current-source contract copies; no production edits or real dispatch.')
