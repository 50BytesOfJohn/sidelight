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

value = expose(source('Widgets/AgentSessions/CursorChatsService.swift'))
assert value.count('await Self.read(now: .now)') == 1
value = value.replace('await Self.read(now: .now)', 'await ControlledRead.read()')
(out / 'CursorChatsService.swift').write_text(value)
value = expose(source('Widgets/AgentSessions/OpenCodeSessionsService.swift'))
assert value.count('await Self.read(database, now: .now)') == 1
value = value.replace('await Self.read(database, now: .now)', 'await ControlledOpenCodeRead.read(database)')
(out / 'OpenCodeSessionsService.swift').write_text(value)
(out / 'AgentSessionSources.swift').write_text(source('Widgets/AgentSessions/AgentSessionSources.swift'))
value = source('Widgets/AgentSessions/AgentSessionsWidget.swift')
# Complete, verbatim declarations; the omitted top-level view needs the full app environment.
parts = [value[value.index('extension WidgetMetadata {'):value.index('extension AgentSessionsSettings {')],
         value[value.index('extension AgentSessionsSettings {'):value.index('// MARK: - Settings')],
         value[value.index('extension AgentSessionSources.State {'):value.index('private func caption')],
         value[value.index('private struct AgentSessionsContent:'):value.index('// MARK: - List')],
         value[value.index('private struct AgentSessionRow:'):]]
claude = source('Widgets/ClaudeSessions/ClaudeSessionsWidget.swift')
parts.append(claude[claude.index('extension ClaudeSession.Activity {'):claude.index('extension ClaudeSessionSurface {')])
(out / 'Views.swift').write_text('import SidelightCore\nimport SwiftUI\n' + expose('\n'.join(parts)))
(out / 'source-hashes.json').write_text(json.dumps(manifest, indent=2))
print('Generated current-source contract copies; no production edits or real dispatch.')
