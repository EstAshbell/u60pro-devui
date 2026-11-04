// Native File input + authenticated root bridge, exercised against real shell/validator.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const cp = require('node:child_process');
const [pluginPath, bundlePath, deviceRoot] = process.argv.slice(2);
const html = fs.readFileSync(pluginPath, 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const bundle = fs.readFileSync(bundlePath);
const statePath = '/data/plugins/.ashbell-devui';
const realState = deviceRoot + statePath;
const destination = path.join(realState, 'ashbell-devui.tar.gz');
const old = Buffer.from('previous package must survive');
const elements = [];
class Element {
  constructor(tag) { this.tagName = tag; this.children = []; this.style = {}; this.textContent = ''; this.disabled = false; elements.push(this); }
  append(...children) { this.children.push(...children); }
  setAttribute() {}
  remove() { this.removed = true; }
  click() { if (!this.disabled && this.onclick) return this.onclick(); }
}
function createUI(options = {}) {
  elements.length = 0;
  const body = new Element('body');
  const slot = new Element('div'); body.append(slot);
  const requests = [];
  let chunks = 0;
  const context = {
    window: {}, AbortController, URL, setTimeout, clearTimeout, Uint8Array,
    btoa: value => Buffer.from(value, 'binary').toString('base64'),
    common_headers: { 'test-auth-header': 'fixture' },
    document: {
      body, createElement: tag => new Element(tag),
      getElementById: id => elements.find(element => element.id === id && !element.removed) || null,
      querySelector: () => slot
    },
    fetch: async (url, request) => {
      assert.equal(url, '/api/run_shell');
      assert.equal(request.credentials, 'same-origin');
      assert.equal(request.headers['test-auth-header'], 'fixture');
      const {cmd, timeout} = JSON.parse(request.body);
      assert.ok(timeout >= 30000);
      requests.push(cmd);
      if (cmd.includes('上传偏移不符')) {
        chunks++;
        if (options.failChunk === chunks) return {ok: true, json: async () => ({success: true, content: 'simulated chunk failure\n__ASHBELL_RC__=9\n'})};
      }
      const rewritten = cmd.split(statePath).join(realState);
      const result = cp.spawnSync('sh', ['-c', rewritten], {
        env: {...process.env, ASHBELL_TEST_ROOT: deviceRoot, ASHBELL_TEST_MODE: '1'},
        encoding: 'utf8', maxBuffer: 1024 * 1024
      });
      if (result.error) throw result.error;
      return {ok: true, json: async () => ({success: result.status === 0, content: result.stdout + result.stderr})};
    }
  };
  vm.runInNewContext(script, context);
  elements.find(element => element.id === 'ashbell-desktop-button').click();
  const fileInput = elements.find(element => element.type === 'file');
  const output = elements.find(element => element.tagName === 'pre');
  async function select(bytes, name = 'ashbell-devui.tar.gz', size = bytes.length) {
    fileInput.files = [{name, size, arrayBuffer: async () => Uint8Array.from(bytes).buffer}];
    const pending = fileInput.onchange();
    assert.ok(elements.filter(element => element.tagName === 'button' && element.textContent !== '关闭' && element.id !== 'ashbell-desktop-button').every(element => element.disabled));
    await pending;
    assert.ok(!fileInput.disabled);
    return output.textContent;
  }
  return {select, requests, output, chunks: () => chunks};
}
function reset() {
  fs.rmSync(deviceRoot, {recursive: true, force: true});
  fs.mkdirSync(realState, {recursive: true});
  fs.mkdirSync(path.join(deviceRoot, 'etc/rc.d'), {recursive: true});
  fs.writeFileSync(destination, old);
}
function assertPreserved() {
  assert.deepEqual(fs.readFileSync(destination), old);
  assert.ok(!fs.existsSync(path.join(realState, 'upload.lock')));
  assert.ok(!fs.readdirSync(realState).some(name => name.startsWith('.upload-')));
}
(async () => {
  reset();
  let ui = createUI();
  let output = await ui.select(bundle);
  assert.match(output, /上传完成/);
  assert.match(output, /尚未执行安装/);
  assert.ok(ui.chunks() >= 2, 'fixture must exercise multiple 48 KiB chunks');
  assert.deepEqual(fs.readFileSync(destination), bundle);
  assert.ok(!fs.existsSync(path.join(deviceRoot, 'data/plugins/u60pro-devui')), 'upload must not install desktop');
  assert.ok(!fs.existsSync(path.join(realState, 'upload.lock')));

  reset(); ui = createUI();
  output = await ui.select(Buffer.from('not gzip'), 'bad.tar.gz');
  assert.match(output, /未完成/); assertPreserved();

  reset(); ui = createUI({failChunk: 2});
  output = await ui.select(bundle);
  assert.match(output, /simulated chunk failure/); assertPreserved();

  reset(); ui = createUI();
  output = await ui.select(bundle, 'wrong.zip');
  assert.match(output, /\.tar\.gz/); assert.equal(ui.requests.length, 0); assertPreserved();
  output = await ui.select(bundle, 'oversize.tar.gz', 21 * 1024 * 1024);
  assert.match(output, /20 MiB/); assert.equal(ui.requests.length, 0); assertPreserved();

  reset(); ui = createUI();
  const lock = path.join(realState, 'upload.lock'); fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'id'), 'another-upload');
  fs.writeFileSync(path.join(lock, 'updated'), String(Math.floor(Date.now() / 1000)));
  const anotherFile = path.join(realState, '.upload-another-upload.tar.gz'); fs.writeFileSync(anotherFile, 'other data');
  output = await ui.select(bundle);
  assert.match(output, /另一个离线包/);
  assert.equal(fs.readFileSync(path.join(lock, 'id'), 'utf8'), 'another-upload');
  assert.equal(fs.readFileSync(anotherFile, 'utf8'), 'other data');
  assert.deepEqual(fs.readFileSync(destination), old);
  console.log('UFI offline upload tests passed: multi-chunk, validation, failure recovery, limits, upload isolation.');
})().catch(error => { console.error(error); process.exitCode = 1; });
