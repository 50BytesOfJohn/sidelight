"""Structural tripwires complement actual compiled contracts and real UI tests.

No shell commands, Terminal transports, installed binaries or real user stores.
"""
from pathlib import Path
import re
import sys
import subprocess

root = Path(__file__).resolve().parents[2]
checks = failures = 0

def check(name, valid):
    global checks, failures
    checks += 1
    failures += not valid
    print(('PASS ' if valid else 'FAIL ') + name)

opener = (root / 'Sources/Sidelight/Widgets/AgentSessions/AgentSessionOpener.swift').read_text()
widget = (root / 'Sources/Sidelight/Widgets/AgentSessions/AgentSessionsWidget.swift').read_text()
core = (root / 'Sources/SidelightCore/OpenCode/OpenCodeSessionIndex.swift').read_text()
service = (root / 'Sources/Sidelight/Widgets/AgentSessions/WatchedSessionIndex.swift').read_text()
check('removed OpenCode command/discovery/Terminal APIs absent', all(token not in opener + core for token in [
    'terminalCommand', 'resumeInTerminal', 'OpenCodeSessionLinks', 'terminalScript(', 'opencode2',
    'ProcessRunner', 'osascript', 'case launch', 'OPENCODE_BIN_PATH']))
check('OpenCode route unconditional nil', 'case .openCode: return nil' in opener)
check('OpenCode copy menu uses only named context data',
      'ContextCopy(title: "Copy Session ID", systemImage: "number", text: openCode.id)' in opener
      and 'ContextCopy(title: "Copy Folder Path", systemImage: "folder", text: openCode.directory)' in opener
      and 'ForEach(AgentSessionOpener.contextCopies(of: session))' in widget
      and 'AgentSessionOpener.copy(context)' in widget)
# The hover fill moved into the shared hoverHighlight modifier: the row passes whether it has a route, and the
# modifier fills only while hovered and enabled.
hover = (root / 'Sources/Sidelight/DesignSystem/HoverRow.swift').read_text()
check('actual row action and hover require route',
      'if route != nil { AgentSessionOpener.open(session) }' in widget
      and '.hoverHighlight(isEnabled: route != nil' in widget
      and '.fill(.primary.opacity(isHovered && isEnabled ? opacity : 0))' in hover)
check('actual row AX hint and help share unavailable policy',
      '.accessibilityHint(' in widget
      and '? "" : AgentSessionOpener.unavailableHelp(for: session)' in widget
      and 'lines.append(route?.help ?? AgentSessionOpener.unavailableHelp(for: session))' in widget)
check('glance AX adds button trait only with action', '.accessibilityAddTraits(action == nil ? [] : .isButton)' in widget)
check('settings explain route and metadata limits',
      "Sessions aren't opened from here" in widget and "Sidelight can't tell which OpenCode server would resume it" in widget
      and 'sessions shown only by when they last changed' in widget)
summary = widget[widget.index('summary:'):widget.index('isBeta:')]
check('overview explicitly distinguishes OpenCode copy-only metadata policy',
      'OpenCode' in summary and 'cop' in summary.lower()
      and any(word in summary.lower() for word in ['metadata', "aren't opened", "can't be opened", 'not opened']))
check('README explicitly says metadata and no widget opening',
      "listed by when they last changed (copy their ID or folder; they aren't opened from the widget)" in (root / 'README.md').read_text())
# OpenCode shares one generic index with Cursor now, so its log calls go through `log` with the app's name as the
# only interpolation. Accept literal text plus exactly that name: any interpolation of an ID, title, directory or
# path (the database URL included) would make this assertion fail.
logs = re.findall(r'\blog\.(?:notice|info|error|debug|warning|fault)\("((?:[^"\\]|\\.)*)"\)', service)
name = r'\(self\.name, privacy: \.public\)'
check('all shared index log messages fixed text plus the app name only, none with ID title directory or path',
      len(logs) == 4 and all('\\(' not in re.sub(name, '', entry) for entry in logs)
      and sum(len(re.findall(name, entry)) for entry in logs) == service.count('privacy:')
      and 'No \\(self.name, privacy: .public) database found' in logs
      and len(re.findall(r'\blog\.[a-z]+\(', service)) == 4 and not re.search(r'\bdatabase\b[^\n]*privacy:', service))
check('OpenCode is named literally and logs under its own category',
      'OpenCodeSessionsService(name: "OpenCode", database: database, log: Log.openCode)' in service)
check('fixture tests and seeder have no research dependency', all('research/opencode-sessions/fixtures' not in p.read_text()
      for p in [root / 'Tests/SidelightCoreTests/OpenCodeSessionTests.swift', root / 'Tests/AgentSessionsHarness/opencode-fixtures.py']))
check('packaged fixture provenance and complete license present',
      '1f4d07a4a519185955ae8ab2ea3607805509e386' in (root / 'Tests/Fixtures/OpenCodeV2/README.md').read_text()
      and (root / 'Tests/Fixtures/OpenCodeV2/OpenCode-LICENSE.txt').read_bytes()
      == (root / 'Sources/Sidelight/Widgets/AgentSessions/Licenses/OpenCode-LICENSE.txt').read_bytes())
check('app has baseline Info.plist with no OpenCode transport usage declaration',
      (root / 'Resources/Info.plist').read_bytes() == subprocess.check_output(['git', 'show', 'HEAD:Resources/Info.plist'], cwd=root))
print(f'RESULT {checks} checks, {failures} failures; structural policy/privacy/package checks')
sys.exit(bool(failures))
