"""Fresh child environments exercise real effective path semantics, no vendor initialization."""
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parents[2]
home = root / 'build/opencode-testing/revalidation-environment-home'
home.mkdir(parents=True, exist_ok=True)
data = home / '.local/share/opencode'
cases = [
    ('default', {}, str(data / 'opencode.db')),
    ('absolute XDG', {'XDG_DATA_HOME': str(home / 'data')}, str(home / 'data/opencode/opencode.db')),
    ('relative XDG ignored', {'XDG_DATA_HOME': 'relative'}, str(data / 'opencode.db')),
    ('empty XDG ignored', {'XDG_DATA_HOME': ''}, str(data / 'opencode.db')),
    ('absolute override', {'OPENCODE_DB': str(home / 'exact.db')}, str(home / 'exact.db')),
    ('relative override', {'OPENCODE_DB': '../alternate.db'}, str(data.parent / 'alternate.db')),
    ('config root irrelevant', {'OPENCODE_CONFIG_DIR': str(home / 'config')}, str(data / 'opencode.db')),
    ('memory', {'OPENCODE_DB': ':memory:'}, ':memory:'),
    ('empty database', {'OPENCODE_DB': ''}, ''),
]
failures = 0
for name, variables, expected in cases:
    env = dict(os.environ)
    for key in ['OPENCODE_DB', 'XDG_DATA_HOME', 'OPENCODE_BIN_PATH', 'OPENCODE_CONFIG_DIR']:
        env.pop(key, None)
    env.update(variables)
    env['CFFIXED_USER_HOME'] = str(home)
    result = subprocess.run([str(root / 'build/agent-sessions-harness/opencode-environment'), expected], env=env, text=True, capture_output=True)
    print(name + ':\n' + result.stdout, end='')
    failures += result.returncode != 0
print(f'RESULT {len(cases)} environments, {len(cases) * 2} assertions, {failures} failed children')
raise SystemExit(bool(failures))
