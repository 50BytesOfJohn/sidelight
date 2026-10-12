"""Seed fabricated metadata in a scratch home, never a real provider directory."""
import datetime
import json
import pathlib
import sqlite3
import subprocess
import sys
import time

root = pathlib.Path(sys.argv[1]).resolve()
fixture_build = pathlib.Path(__file__).resolve().parents[2] / 'build'
if not (str(root).startswith('/private/tmp/') or str(root).startswith('/tmp/') or root.is_relative_to(fixture_build)):
    raise SystemExit('Fixtures require a scratch /tmp or this worktree build home')
if (root / '.codex/state_5.sqlite').exists():
    raise SystemExit('Use a fresh fixture home; existing fixture metadata is preserved')
root.mkdir(parents=True, exist_ok=True)
project = root / 'Demo Project'
project.mkdir(exist_ok=True)
(project / 'README.md').write_text('Synthetic Agent Sessions UI fixture. No prompts or model turns.\n')
config = root / 'Library/Application Support/Sidelight Dev/config.json'
config.parent.mkdir(parents=True, exist_ok=True)
config.write_bytes(pathlib.Path('/tmp/agent-stage3-config.json').read_bytes())
settings = json.loads(config.read_text())
settings['sections'][0]['widgets'][0]['settings']['sessionCount'] = 10
config.write_text(json.dumps(settings, indent=2))
now = int(time.time() * 1000)
registry = root / '.claude/sessions'
registry.mkdir(parents=True, exist_ok=True)
pids = []
for index, (status, title) in enumerate([
    ('waiting', 'Fixture needs permission'), ('busy', 'Fixture running turn'),
    ('idle', 'Fixture completed turn'), ('future-status', 'Fixture unknown status'),
    ('idle', 'Fixture fresh session'),
]):
    process = subprocess.Popen(['/bin/sleep', '3600'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    pids.append(process.pid)
    changed = now - index * 60000
    record = dict(pid=process.pid, sessionId=f'fixture-claude-{index}', cwd=str(project), name=title,
                  nameSource='user', startedAt=now, status=status, statusUpdatedAt=changed,
                  kind='interactive', entrypoint='cli')
    if index == 2:
        record['statusUpdatedAt'] = now + 6000
    if index == 0:
        record['waitingFor'] = 'permission prompt'
    (registry / f'{process.pid}.json').write_text(json.dumps(record))
codex = root / '.codex'
codex.mkdir(exist_ok=True)
locks = codex / 'thread-writer-locks'
locks.mkdir(exist_ok=True)
sessions = codex / 'sessions'
sessions.mkdir(exist_ok=True)
db = sqlite3.connect(codex / 'state_5.sqlite')
db.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, updated_at INTEGER, source TEXT, cwd TEXT, name TEXT, originator TEXT, git_branch TEXT, created_at INTEGER)')
lock_paths = []
for index, (state, title) in enumerate([
    ('approval', 'Fixture approval request'), ('question', 'Fixture user question'),
    ('running', 'Fixture Codex running'), ('complete', 'Fixture Codex done'),
    ('aborted', 'Fixture Codex interrupted'),
]):
    ident = f'fixture-codex-{index}'
    lock = locks / f'{ident}.lock'
    lock.touch()
    lock_paths.append(str(lock))
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    lines = []
    def line(kind, payload):
        lines.append(json.dumps(dict(timestamp=stamp, type=kind, payload=payload), separators=(',', ':')))
    line('event_msg', dict(type='turn_started', turn_id='fixture'))
    if state in ('approval', 'question'):
        arguments = dict(cmd='echo fixture', sandbox_permissions='require_escalated', justification='Fixture reason')
        line('response_item', dict(type='function_call', call_id='fixture-call', name='request_user_input' if state == 'question' else 'exec_command', arguments=json.dumps(arguments)))
    if state == 'complete':
        line('event_msg', dict(type='turn_complete', turn_id='fixture', duration_ms=2000))
    if state == 'aborted':
        line('event_msg', dict(type='turn_aborted', turn_id='fixture'))
    rollout = sessions / f'{ident}.jsonl'
    rollout.write_text('\n'.join(lines) + '\n')
    db.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?)', (ident, str(rollout), now//1000, 'cli', str(project), title, 'codex-tui', 'fixture', now//1000))
db.commit()
db.close()
host = pathlib.Path(__file__).resolve().parents[2] / 'build/agent-sessions-harness/codex'
process = subprocess.Popen([str(host), *lock_paths], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, start_new_session=True)
pids.append(process.pid)
root.joinpath('fixture-processes.json').write_text(json.dumps(pids))
cursor = root / 'Library/Application Support/Cursor/User/globalStorage'
cursor.mkdir(parents=True, exist_ok=True)
db = sqlite3.connect(cursor / 'state.vscdb')
db.execute('CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, value BLOB, lastUpdatedAt INTEGER, createdAt INTEGER, isArchived INTEGER, isSubagent INTEGER)')
for index, title in enumerate(['Fixture Cursor project chat', 'Fixture a very long Cursor title that should truncate cleanly at narrow widths', 'Fixture Cursor without project']):
    header = dict(name=title, status='generating')
    if index != 2:
        header['workspaceIdentifier'] = dict(uri=dict(scheme='file', fsPath=str(project)))
    db.execute('INSERT INTO composerHeaders VALUES (?,?,?,?,0,0)', (f'fixture-cursor-{index}', json.dumps(header), now-index*60000, now-3600000))
db.commit()
db.close()
print('Seeded 5 Claude, 5 Codex and 3 Cursor synthetic rows; inert fixture hosts only.')
