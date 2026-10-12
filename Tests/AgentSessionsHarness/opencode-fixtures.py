"""Owned metadata/UI fixtures; no providers, credentials, model turns, or background servers."""
from pathlib import Path
import json
import sqlite3
import subprocess
import time
import sys

repo = Path(__file__).resolve().parents[2]
home = repo / (sys.argv[1] if len(sys.argv) > 1 else 'build/opencode-testing/ui-home')
if not home.resolve().is_relative_to((repo / 'build').resolve()):
    raise SystemExit('Fixture home must be under owned build/')
if home.exists():
    raise SystemExit('Use a fresh owned fixture home')
home.mkdir(parents=True)
config = home / 'Library/Application Support/Sidelight Dev/config.json'
config.parent.mkdir(parents=True)
subprocess.run([str(repo / 'build/agent-sessions-harness/config'), str(config)], check=True)
settings = json.loads(config.read_text())
settings['sections'][0]['widgets'][0]['settings']['sessionCount'] = 10
settings['sections'][0]['widgets'][0]['settings']['recentHours'] = 24
config.write_text(json.dumps(settings, indent=2))
project = home / "Demo ' $() `fixture` Project"
(project / 'src/api').mkdir(parents=True)
store = home / '.local/share/opencode/opencode.db'
store.parent.mkdir(parents=True)
now = int(time.time() * 1000)
with sqlite3.connect(store) as db:
    db.executescript((repo / 'Tests/Fixtures/OpenCodeV2/v2.0.27-session-schema.sql').read_text())
    db.execute('UPDATE session_v2 SET time_updated = time_updated - 1700000009000 + ?, time_created = ? - 3600000, directory = ?', (now, now, str(project / 'src/api')))
    db.execute("UPDATE session_v2 SET title=NULL WHERE id='ses_synthetic_other_project'")
    db.execute("UPDATE session_v2 SET title='Synthetic OpenCode title with a deliberately long name for truncation' WHERE id='ses_synthetic_root'")
    db.execute("UPDATE session_v2 SET time_updated=? WHERE id='ses_synthetic_archived'", (now,))
cursor = home / 'Library/Application Support/Cursor/User/globalStorage/state.vscdb'
cursor.parent.mkdir(parents=True)
with sqlite3.connect(cursor) as db:
    db.execute('CREATE TABLE composerHeaders(composerId TEXT, value BLOB, lastUpdatedAt INTEGER)')
    db.execute('INSERT INTO composerHeaders VALUES (?,?,?)', ('synthetic_cursor', json.dumps({'name': 'Synthetic Cursor mixed row', 'workspaceIdentifier': {'uri': {'scheme': 'file', 'fsPath': str(project)}}}), now - 1000))
# A closed synthetic Codex row; no rollout, process, transcript or vendor executable.
codex = home / '.codex/state_5.sqlite'
codex.parent.mkdir(parents=True)
with sqlite3.connect(codex) as db:
    db.execute('CREATE TABLE threads(id TEXT, rollout_path TEXT, updated_at INTEGER, source TEXT, cwd TEXT, name TEXT, originator TEXT, git_branch TEXT, created_at INTEGER)')
    db.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?)', ('synthetic_codex', None, now//1000, 'cli', str(project), 'Synthetic Codex closed row', 'codex-tui', 'fixture', now//1000))
profile = repo / 'build/opencode-testing/ui.sb'
profile.write_text('''(version 1)
(allow default)
(deny network*)
(deny process-exec (subpath "/opt/homebrew") (subpath "/usr/local"))
''')
print(json.dumps({'home': str(home), 'store': str(store), 'config': str(config)}))
