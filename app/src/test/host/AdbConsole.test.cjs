const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
// Pass DevEco's bundled TypeScript directory when it is not installed locally.
const ts = require(process.argv[2] || 'typescript');

const tests = [];
const modules = new Map();
const durable = new Map();
let cache = new Map();
let initCalls = 0;
let failInit = false;
let failFlush = false;
let uuid = 0;
const prefs = {
  async get(key, fallback) { return cache.get(key) ?? fallback; },
  async put(key, value) { cache.set(key, value); },
  async flush() {
    if (failFlush) throw new Error('Disk unavailable');
    await new Promise(resolve => setTimeout(resolve, 1));
    for (const [key, value] of cache) durable.set(key, value);
  }
};
const mocks = {
  '@ohos/hypium': {
    describe: (_name, body) => body(),
    it: (name, _flags, body) => tests.push({ name, body }),
    expect: value => ({
      assertEqual: expected => assert.equal(value, expected),
      assertTrue: () => assert.equal(value, true),
      assertFalse: () => assert.equal(value, false),
      assertLarger: minimum => assert.ok(value > minimum)
    })
  },
  '@ohos.data.preferences': { default: {
    async getPreferences(_context, name) {
      assert.equal(name, 'adb_console_prefs');
      initCalls++;
      if (failInit) throw new Error('Storage unavailable');
      return prefs;
    }
  } },
  '@kit.ArkTS': { util: { generateRandomUUID: () => `test-${++uuid}` } },
};
function load(file) {
  const full = path.resolve(file);
  if (modules.has(full)) return modules.get(full).exports;
  if (full.endsWith('helper/Logger.ets') || full.endsWith('helper\\Logger.ets')) {
    return { LoggerAdbConsole: { info() {}, warn() {}, error() {} } };
  }
  const result = { exports: {} };
  modules.set(full, result);
  const compiled = ts.transpileModule(fs.readFileSync(full, 'utf8'), {
    fileName: full.replace(/\.ets$/, '.ts'),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const localRequire = name => {
    if (mocks[name]) return mocks[name];
    if (name.startsWith('.')) return load(path.resolve(path.dirname(full), name + '.ets'));
    throw new Error(`Unexpected import: ${name}`);
  };
  vm.runInThisContext(`(function(require,module,exports){${compiled}\n})`, { filename: full })(localRequire, result, result.exports);
  return result.exports;
}

load('app/src/test/AdbCommandUtils.test.ets').default();
load('app/src/test/AdbCommandExecutor.test.ets').default();
if (process.argv[3]) {
  const { AdbCommandUtils } = load('app/src/main/ets/helper/AdbCommandUtils.ets');
  const bash = process.argv[3];
  tests.push({ name: 'shell runtime preserves quotes and pipeline syntax', body() {
    const command = `printf '%s\\n' "a'b | literal"; printf foo | tr o x`;
    const result = spawnSync(bash, ['-c', AdbCommandUtils.buildTimedCommand(command, 3)], { encoding: 'utf8', timeout: 5000 });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "a'b | literal\nfxx");
  } });
  tests.push({ name: 'shell runtime times out the entire pipeline and sequence', body() {
    const startedAt = Date.now();
    const script = AdbCommandUtils.buildTimedCommand('sleep 5 | cat; echo late', 1);
    // Keep the parent shell alive so MSYS reports a POSIX exit code after SIGKILL.
    const result = spawnSync(bash, ['-c', `${script}; rc=$?; printf '__TIMEOUT_EXIT__%s' "$rc"`], { encoding: 'utf8', timeout: 4000 });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /__TIMEOUT_EXIT__(124|137)$/);
    assert.ok(Date.now() - startedAt < 4000);
    assert.ok(!result.stdout.includes('late'));
  } });
}
const { QuickAdbCommandStore: Store } = load('app/src/main/ets/helper/QuickAdbCommandStore.ets');
const draft = (name, command = 'wm size') => ({ name, command, confirmBeforeRun: false, timeoutSeconds: 15 });
tests.push({ name: 'global store persists create/edit/reorder/delete across sessions', async body() {
  const firstSession = Store.getInstance();
  await Promise.all([firstSession.init({}), firstSession.init({})]);
  assert.equal(initCalls, 1);
  assert.equal(Store.getInstance(), firstSession);
  const a = await firstSession.addCommand(draft('A'));
  const b = await firstSession.addCommand(draft('B', 'dumpsys battery'));
  await firstSession.updateCommand(a.id, draft('Renamed', 'getprop ro.product.model'));
  await firstSession.moveCommand(0, 1);
  assert.deepEqual(firstSession.getCommands().map(item => item.name), ['B', 'Renamed']);
  const restarted = new Store();
  cache = new Map(durable);
  await restarted.init({});
  assert.deepEqual(restarted.getCommands(), firstSession.getCommands());
  await restarted.removeCommand(b.id);
  const thirdSession = new Store();
  cache = new Map(durable);
  await thirdSession.init({});
  assert.deepEqual(thirdSession.getCommands().map(item => item.name), ['Renamed']);
} });
tests.push({ name: 'concurrent writes preserve commands and enforce 50-item limit', async body() {
  durable.clear(); cache.clear();
  const store = new Store();
  await store.init({});
  await Promise.all(Array.from({ length: 55 }, (_, index) => store.addCommand(draft(`Command ${index}`))));
  assert.equal(store.getCommands().length, 50);
  assert.equal(new Set(store.getCommands().map(item => item.id)).size, 50);
  assert.equal(JSON.parse(durable.get('quick_commands_v1')).length, 50);
  assert.equal(store.canAddMore(), false);
} });
tests.push({ name: 'save failure rejects without publishing unsaved state and queue recovers', async body() {
  durable.clear(); cache.clear();
  const store = new Store();
  await store.init({});
  failFlush = true;
  await assert.rejects(store.addCommand(draft('Unsaved')));
  assert.equal(store.getCommands().length, 0);
  failFlush = false;
  await store.addCommand(draft('Saved'));
  assert.deepEqual(store.getCommands().map(item => item.name), ['Saved']);
  assert.equal(JSON.parse(durable.get('quick_commands_v1')).length, 1);
} });
tests.push({ name: 'initialization failure is retryable', async body() {
  const store = new Store();
  failInit = true;
  await assert.rejects(store.init({}));
  assert.equal(store.isReady(), false);
  failInit = false;
  await store.init({});
  assert.equal(store.isReady(), true);
} });
tests.push({ name: 'history deduplicates, caps at 20 and survives restart', async body() {
  durable.clear(); cache.clear();
  const store = new Store();
  await store.init({});
  await Promise.all(Array.from({ length: 25 }, (_, index) => store.recordHistory(`echo ${index}`)));
  await store.recordHistory(' echo 20 ');
  assert.equal(store.getHistory().length, 20);
  assert.equal(store.getHistory()[0], 'echo 20');
  assert.equal(new Set(store.getHistory()).size, 20);
  const restarted = new Store();
  cache = new Map(durable);
  await restarted.init({});
  assert.deepEqual(restarted.getHistory(), store.getHistory());
  await restarted.clearHistory();
  assert.deepEqual(JSON.parse(durable.get('command_history_v1')), []);
} });
tests.push({ name: 'corrupt storage does not prevent initialization', async body() {
  cache = new Map([['quick_commands_v1', '{invalid'], ['command_history_v1', '[1," echo ok ","echo ok",null]']]);
  const store = new Store();
  await store.init({});
  assert.deepEqual(store.getCommands(), []);
  assert.deepEqual(store.getHistory(), ['echo ok']);
} });
(async () => {
  let passed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log(`PASS ${name}`); passed++; }
    catch (error) { console.error(`FAIL ${name}`, error); process.exitCode = 1; }
  }
  console.log(`${passed}/${tests.length} passed (host runner, HarmonyOS preferences mocked)`);
})();
