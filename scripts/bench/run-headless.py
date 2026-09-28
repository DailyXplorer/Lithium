#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
parser.add_argument('--skip-build', action='store_true')
parser.add_argument('--rounds', type=int, default=3)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)

class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/asset/'):
            data = b'window.loadedScripts = (window.loadedScripts || 0) + 1;'
            content_type = 'application/javascript'
        else:
            data = ('<!doctype html><title>Local resource fixture</title><script>window.loadedScripts=0</script>' + ''.join(f'<script defer src="/asset/{i}.js"></script>' for i in range(160)) + '<p>Local resource fixture</p><div class="audit-ad">Cosmetic rule fixture</div>').encode()
            content_type = 'text/html'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
manifest = {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted((root/'Sources').rglob('*')) if f.is_file()}
(output/'source-sha256.json').write_text(json.dumps(manifest, indent=2))
(output/'head.txt').write_bytes(subprocess.check_output(['git','rev-parse','HEAD'], cwd=root))
(output/'working.patch').write_bytes(subprocess.check_output(['git','diff','--binary'], cwd=root))
try:
    with tempfile.TemporaryDirectory(prefix='lithium-perf-home-') as home:
        env = dict(os.environ, CFFIXED_USER_HOME=home, LITHIUM_PERF_ROOT=str(root), LITHIUM_PERF_SERVER=f'http://127.0.0.1:{server.server_port}')
        for round_index in range(args.rounds):
            folder = output / f'round-{round_index + 1}'
            folder.mkdir(exist_ok=True)
            env['LITHIUM_PERF_OUTPUT'] = str(folder)
            env['LITHIUM_PERF_VARIANTS'] = 'webkit,previous,current' if round_index % 2 == 0 else 'current,previous,webkit'
            for name in ['page-font','farbling']:
                (folder/(name+'-head.js')).write_bytes(subprocess.check_output(['git','show',f'HEAD:Sources/Lithium/Resources/Scripts/{name}.js'], cwd=root))
            # HEAD's own web font: WOFF2 since it has one, the TTF before.
            for font in ['DMSans.woff2', 'DMSans.ttf']:
                try:
                    (folder/'font-head.bin').write_bytes(subprocess.check_output(['git','show',f'HEAD:Sources/Lithium/Resources/Fonts/{font}'], cwd=root, stderr=subprocess.DEVNULL))
                    break
                except subprocess.CalledProcessError:
                    continue
            command = ['nice','-n','15','swift','test','-c','release','-j','2','--no-parallel']
            if args.skip_build or round_index > 0:
                command.append('--skip-build')
            command += ['--filter', 'HeadlessPerformanceTests' if round_index == 0 else 'HeadlessPerformanceTests/webWorkloads']
            jobs = [('webkit', command), ('helium', ['node',str(root/'scripts/bench/headless-helium.mjs'),str(folder/'helium-workloads.json')])]
            if round_index % 2 == 1:
                jobs.reverse()
            for name, command in jobs:
                print(f'Round {round_index + 1}, {name}', flush=True)
                with (folder/(name+'.log')).open('w') as log:
                    subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
finally:
    server.shutdown()
    server.server_close()
print(output, flush=True)
