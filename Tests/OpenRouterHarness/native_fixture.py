#!/usr/bin/env python3
"""Launch the built debug app with disposable config and a loopback-only synthetic API.

Avoidance stays OFF and its app predicate matches a nonexistent disposable ID. No
permission request, credential write, user config, or private API is used. Do not
open Widgets/builder in this launch: production preview demand starts unrelated
services. Ctrl-C stops only this child and server, never an installed Sidelight.
"""
import argparse
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]


def prepare(directory):
    product = ROOT / '.build/out/Products/Debug'
    app = directory / 'SidelightPass2.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources').mkdir()
    shutil.copy2(product / 'Sidelight', contents / 'MacOS/SidelightPass2')
    # Preserve @loader_path and the already-built binary; no re-signing/grants.
    shutil.copytree(product / 'Sparkle.framework', contents / 'MacOS/Sparkle.framework', symlinks=True)
    shutil.copytree(product / 'Sidelight_Sidelight.bundle', contents / 'Resources/Sidelight_Sidelight.bundle')
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    info.update(CFBundleIdentifier='app.getsidelight.validation.pass2', CFBundleName='SidelightPass2',
                CFBundleDisplayName='Sidelight Pass2', CFBundleExecutable='SidelightPass2')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    config = json.loads((ROOT / 'Tests/SidelightCoreTests/ReleasedConfigurations/v0.5.0.json').read_text())
    config['windowAvoidance'] = 'off'
    config['displays'] = []
    config['panel'].update(position='left', shownOn='main', length='fill', width=200)
    config['hotkey'] = {'keyCode': 1, 'modifiers': 2304, 'key': 'S'}
    config['details'] = {'closeHotkey': {'keyCode': 1, 'modifiers': 6400, 'key': 'S'}, 'usesCustomStyle': False}
    background = config['appearance']['background']
    background.update(kind='color', grain=0)
    background['color'].update(color='#152436', opacity=1, fill='solid', isAnimated=False)
    config['appearance']['cards'].update(style='solid', showsTitles=True)
    config['sections'] = [{'id': str(uuid.uuid4()), 'alignment': 'start', 'share': 1,
                           'widgets': [{'id': str(uuid.uuid4()), 'kind': 'openRouterModels',
                                        'showsInSidePanel': True, 'showsInBar': True, 'settings': {'sync': 'manual'}}]}]
    (directory / 'config.json').write_text(json.dumps(config, indent=2))
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=pathlib.Path)
    parser.add_argument('--prepare-only', action='store_true', help='Run config safety gate without launching')
    args = parser.parse_args()
    directory = args.directory or pathlib.Path(tempfile.mkdtemp(prefix='openrouter-pass2-native-'))
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise SystemExit("Use a new empty disposable directory")
    app = prepare(directory)
    with (directory / 'preflight.log').open('w') as preflight_log:
        preflight = subprocess.run(['make', '-C', str(ROOT / 'Tests/OpenRouterHarness'), 'native-preflight'],
                                   env={**os.environ, 'SIDELIGHT_NATIVE_FIXTURE': str(directory / 'config.json')},
                                   stdout=preflight_log, stderr=subprocess.STDOUT)
    if preflight.returncode:
        raise SystemExit(f'Native preflight failed; nothing launched. Read {directory / "preflight.log"}')
    if args.prepare_only:
        print(f'Native fixture passed decoder safety gate: {directory}', flush=True)
        return 0
    models = [{'id': f'fixture/model-{i:03}', 'name': f'Fixture: Model {i:03}',
               'created': 1791849600 - i * 3600, 'context_length': 128000,
               'architecture': {'input_modalities': ['text'], 'output_modalities': ['text']},
               'pricing': {'prompt': '0.0000005', 'completion': '0.000001'}} for i in range(240)]
    models[0]['name'] = 'Fixture: A very long model name for clipping and layout validation'
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            # Persist paths only, never headers/credentials.
            with (directory / 'requests.jsonl').open('a') as stream:
                stream.write(json.dumps({'time': time.time(), 'path': self.path}) + '\n')
            status, data = (200, {'data': models}) if self.path.startswith('/models?') else (500, {'error': 'Fixture unavailable'})
            mode = directory / 'api-mode.txt'
            if mode.exists() and mode.read_text().strip() == 'error':
                status, data = 503, {'error': 'Fixture unavailable'}
            body = json.dumps(data).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    output = (directory / 'app.log').open('w')
    process = subprocess.Popen([str(app / 'Contents/MacOS/SidelightPass2'),
        '-SidelightConfigurationFile', str(directory / 'config.json'),
        '-SidelightOpenRouterURL', f'http://127.0.0.1:{server.server_port}/',
        '-SidelightKeychainService', 'app.getsidelight.validation.' + str(uuid.uuid4()),
        '-SidelightMovesWindowsOf', 'app.getsidelight.validation.no-windows'], stdout=output, stderr=output)
    (directory / 'pid.txt').write_text(str(process.pid))
    print(f'Native fixture: {directory}\nApp: {app}\nPID: {process.pid}', flush=True)
    try:
        return process.wait()
    except KeyboardInterrupt:
        process.terminate()
        process.wait(timeout=10)
    finally:
        server.shutdown()
        output.close()


if __name__ == '__main__':
    raise SystemExit(main())
