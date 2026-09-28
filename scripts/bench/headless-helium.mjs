import {spawn} from 'node:child_process';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const output = resolve(process.argv[2]);
const directory = dirname(fileURLToPath(import.meta.url));
const profile = await mkdtemp(join(tmpdir(), 'lithium-perf-helium-'));
const child = spawn('/usr/bin/nice', ['-n', '15', '/Applications/Helium.app/Contents/MacOS/Helium', '--headless=new', '--mute-audio', '--no-first-run', '--no-default-browser-check', '--window-size=1280,800', '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank'], {stdio: ['ignore', 'ignore', 'pipe']});
let stderr = '';
child.stderr.on('data', data => { stderr += data; });
let socket;
const pending = new Map();
let sequence = 0;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const request = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++sequence;
  const timer = setTimeout(() => { pending.delete(id); reject(new Error('CDP timeout ' + method)); }, 30000);
  pending.set(id, message => {
    clearTimeout(timer);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  });
  socket.send(JSON.stringify({id, method, params}));
});
try {
  let port;
  for (let i = 0; i < 200; i++) {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; break; } catch {}
    if (child.exitCode !== null) throw new Error('Helium exited ' + child.exitCode);
    await sleep(100);
  }
  if (!port) throw new Error('No debugging port');
  const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  socket = new WebSocket(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
  };
  await request('Emulation.setDeviceMetricsOverride', {width:1280, height:800, deviceScaleFactor:1, mobile:false});
  await request('Runtime.evaluate', {expression: await readFile(join(directory, 'workloads.js'), 'utf8')});
  const records = [];
  for (const name of ['json', 'dom', 'layout', 'canvas']) {
    await sleep(300);
    const result = await request('Runtime.evaluate', {expression: `perfCase('${name}')`, returnByValue:true});
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    records.push({...result.result.value, variant:'helium'});
  }
  await writeFile(output, JSON.stringify(records, null, 2));
  console.log(JSON.stringify(records.map(x => ({name:x.name, samples:x.samples}))));
  await request('Browser.close');
} finally {
  socket?.close();
  if (child.exitCode === null) child.kill('SIGTERM');
  for (let i = 0; i < 50 && child.exitCode === null; i++) await sleep(100);
  if (child.exitCode === null) { child.kill('SIGKILL'); await sleep(300); }
  await writeFile(output + '.log', stderr);
  await rm(profile, {recursive:true, force:true});
}
