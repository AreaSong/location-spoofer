const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');
const path = require('node:path');
const root = path.join(__dirname, '..');
const script = new vm.Script(fs.readFileSync(path.join(root, 'ThirdParty/WlocScripts/dist/v1/wloc-probe.js'), 'utf8'));
const endpoint = 'https://location-spoofer.invalid/probe';
function run(url = endpoint, method = 'GET') {
  const results = [];
  const forbidden = new Proxy({}, { get() { throw Error('探测禁止访问存储或网络'); } });
  script.runInNewContext({ $request: { url, method }, $done: x => results.push(x),
    $persistentStore: forbidden, $prefs: forbidden, $httpClient: forbidden, $task: forbidden }, { timeout: 1000 });
  assert.equal(results.length, 1);
  return results[0].response;
}
test('固定响应不访问存储或网络', () => {
  const response = run();
  assert.equal(response.status, 200);
  assert.equal(response.headers['Cache-Control'], 'no-store');
  assert.deepEqual(JSON.parse(response.body), { protocol: 'location-spoofer-probe', version: '1', mode: 'no-storage' });
});
test('拒绝额外参数、写入动作、其他域名、HTTP与非GET方法', () => {
  for (const url of [endpoint + '?action=clear', endpoint + '?lon=1&lat=2',
    endpoint.replace('https:', 'http:'), endpoint.replace('.invalid', '.invalid.evil.com'), endpoint + '/save']) {
    assert.equal(run(url).status, 400);
  }
  assert.equal(run(endpoint, 'POST').status, 400);
});
test('探测模块只匹配固定地址，不替代正式坐标控制脚本', () => {
  const module = fs.readFileSync(path.join(root, 'ThirdParty/WlocScripts/modules/wloc-probe.module'), 'utf8');
  const pattern = new RegExp(module.match(/pattern=([^,]+)/)[1]);
  assert.ok(pattern.test(endpoint));
  assert.ok(!pattern.test(endpoint + '?action=clear'));
  assert.match(module, /location-spoofer\.invalid = 192\.0\.2\.1/);
  assert.match(module, /hostname = %APPEND% location-spoofer\.invalid/);
  assert.ok(!module.includes('apple.com'));
  const current = fs.readFileSync(path.join(root, 'ThirdParty/WlocScripts/modules/wloc.module'), 'utf8');
  assert.ok(current.includes('location-spoofer.invalid'));
  assert.ok(!current.includes('wloc-probe.js'));
  assert.ok(current.includes('wloc-settings.js'));
});
