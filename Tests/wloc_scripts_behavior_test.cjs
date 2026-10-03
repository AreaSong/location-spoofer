// 直接执行交付脚本；只模拟客户端边界，不加载或复制生产改写算法。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const { gzipSync } = require('node:zlib');

const scripts = Object.fromEntries(['wloc', 'wloc-settings'].map(name => [name,
  new vm.Script(fs.readFileSync(path.join(__dirname,
    `../ThirdParty/WlocScripts/dist/v1/${name}.js`), 'utf8'), { filename: `${name}.js` })]));
const clients = ['Surge', 'Loon', 'Shadowrocket', 'Stash', 'Egern', 'Quantumult X'];
const key = 'wloc_settings';
const initial = { longitude: 20, latitude: 10, accuracy: 25, randomRadius: 0 };
// 合成 Wi-Fi WLOC：10 字节帧头，MAC aa:bb:cc:dd:ee:ff，lat=100、lon=200、acc=25。
const fixture = Buffer.from('0001000000010000001e121c0a1161613a62623a63633a64643a65653a66661207086410c8011819', 'hex');

function storage(value = null, mode = 'ok') {
  return { raw: JSON.stringify(value), mode, writes: [] };
}

function execute(name, options = {}) {
  const { client = 'Surge', store = storage(), query = '', argument,
    bytes = fixture, field = 'body', representation = 'view', headers = {} } = options;
  const done = [], logs = [];
  const read = () => { if (store.readError) throw Error('mock read failure'); return store.raw; };
  const write = (value, name) => {
    store.writes.push({ value, key: name });
    if (store.mode === 'throw') throw Error('mock write failure');
    if (store.mode === 'false') return false;
    store.raw = value;
    return true;
  };
  const globals = {
    console: { log: (...args) => logs.push(args.join(' ')) },
    $request: { url: `https://gs-loc.apple.com/${name === 'wloc' ? 'clls/wloc' : 'wloc-settings/save'}?${query}` },
    $script: { startTime: Date.now() }, $argument: argument,
    $persistentStore: { read, write },
    $done: value => done.push(value),
  };
  if (client === 'Quantumult X') {
    globals.$task = {};
    globals.$prefs = { valueForKey: read, setValueForKey: write };
    delete globals.$persistentStore;
  } else if (client === 'Loon') globals.$loon = {};
  else if (client === 'Shadowrocket') globals.$rocket = {};
  else if (client === 'Egern') globals.Egern = {};
  else globals.$environment = { [`${client.toLowerCase()}-version`]: 'mock' };
  const context = vm.createContext(globals, { microtaskMode: 'afterEvaluate' });
  // 输入字节在脚本所在 realm 构造，覆盖真实 ArrayBuffer 和带偏移量的视图。
  if (name === 'wloc') {
    const values = JSON.stringify([...bytes]);
    const forms = { array: values, buffer: `new Uint8Array(${values}).buffer`,
      view: `new Uint8Array([99,...${values},88]).subarray(1,${bytes.length + 1})`,
      string: `String.fromCharCode(...${values})` };
    vm.runInContext(`$response = { status: 200, headers: ${JSON.stringify(headers)},
      ${field}: ${forms[representation]} }; Math.random = () => 0.25;`, context);
  }
  scripts[name].runInContext(context, { timeout: 2000 });
  assert.equal(done.length, 1, `应恰好调用一次 $done；${logs.join('\n')}`);
  const output = done[0];
  const response = output.response || output;
  return { output, response, store, logs,
    originalResponse: globals.$response,
    json: name === 'wloc-settings' ? JSON.parse(response.body) : undefined };
}

function settings(query, store, client) {
  return execute('wloc-settings', { query, store, client });
}

function outputBytes(response) {
  const data = response.bodyBytes ?? response.body;
  if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  if (Object.prototype.toString.call(data) === '[object ArrayBuffer]') return Buffer.from(data);
  return Buffer.from(data || [], typeof data === 'string' ? 'latin1' : undefined);
}

function passthrough(result, bytes, headers) {
  if (Object.keys(result.output).length === 0) {
    // 空完成对象也不能掩盖对传入响应的原地破坏。
    const original = result.originalResponse;
    assert.deepEqual(outputBytes({ body: original.bodyBytes ?? original.rawBody ?? original.body }), bytes);
    assert.deepEqual(JSON.parse(JSON.stringify(original.headers)), headers);
    return;
  }
  assert.deepEqual(outputBytes(result.response), bytes);
  assert.deepEqual(JSON.parse(JSON.stringify(result.response.headers)), headers);
}

// 只读夹具解码器：核对输出 protobuf 的实际数值，不依赖生产内部符号。
function fields(bytes) {
  let cursor = 0;
  function varint() {
    let value = 0n, shift = 0n;
    for (;;) {
      assert.ok(cursor < bytes.length && shift < 70n, '完整 varint');
      const byte = bytes[cursor++];
      value |= BigInt(byte & 127) << shift;
      if (!(byte & 128)) return value;
      shift += 7n;
    }
  }
  const result = new Map();
  while (cursor < bytes.length) {
    const tag = Number(varint());
    if ((tag & 7) === 0) result.set(tag >> 3, Number(BigInt.asIntN(64, varint())));
    else {
      assert.equal(tag & 7, 2);
      const length = Number(varint());
      assert.ok(cursor + length <= bytes.length);
      result.set(tag >> 3, bytes.subarray(cursor, cursor + length));
      cursor += length;
    }
  }
  return result;
}

function patchedLocation(result) {
  assert.equal(result.output.response, undefined, '响应改写使用顶层 body/bodyBytes');
  const bytes = outputBytes(result.response);
  assert.equal(bytes.readUInt16BE(8), bytes.length - 10);
  return fields(fields(fields(bytes.subarray(10)).get(2)).get(2));
}

for (const client of clients) {
  test(`${client}: 正常保存、查询、清除与响应封装`, () => {
    const store = storage();
    const saved = settings('lon=20&lat=10&acc=25', store, client);
    assert.equal(saved.json.success, true);
    assert.equal(client === 'Quantumult X' ? saved.output.status : saved.output.response.status,
      client === 'Quantumult X' ? 'HTTP/1.1 200 OK' : 200);
    assert.equal(settings('action=query', store, client).json.longitude, 20);
    assert.equal(settings('action=clear', store, client).json.success, true);
    assert.match(settings('action=query', store, client).json.error, /无已保存/);
  });
  for (const mode of ['false', 'throw']) {
    test(`${client}: 保存／清除 ${mode} 不报成功、不丢旧值`, () => {
      for (const query of ['lon=30&lat=40', 'action=clear']) {
        const store = storage(initial, mode), before = store.raw;
        assert.equal(settings(query, store, client).json.success, false);
        assert.equal(store.raw, before);
        assert.equal(store.writes.length, 1);
        assert.equal(store.writes[0].key, key);
      }
    });
  }
  test(`${client}: gzip 透传与实际改写的二进制／响应头契约`, () => {
    const compressed = gzipSync(fixture);
    const headers = { 'cOnTeNt-EnCoDiNg': 'gzip', 'content-length': `${compressed.length}`,
      'CONTENT-LENGTH': `${compressed.length}`, 'tRaNsFeR-EnCoDiNg': 'chunked', 'X-Keep': 'yes' };
    const field = client === 'Quantumult X' ? 'bodyBytes' : 'body';
    const untouched = execute('wloc', { client, bytes: compressed, field, headers });
    passthrough(untouched, compressed, headers);
    assert.equal(untouched.store.writes.length, 0);
    const store = storage(initial);
    const result = execute('wloc', { client, bytes: compressed, field, headers, store });
    const location = patchedLocation(result);
    assert.equal(location.get(1), 10e8);
    assert.equal(location.get(2), 20e8);
    assert.equal(location.get(3), 25);
    assert.equal(result.response.headers['X-Keep'], 'yes');
    const keys = Object.keys(result.response.headers).map(key => key.toLowerCase());
    assert.ok(!keys.includes('content-encoding') && !keys.includes('transfer-encoding'));
    assert.equal(keys.filter(key => key === 'content-length').length, client === 'Quantumult X' ? 0 : 1);
    if (client === 'Quantumult X') {
      assert.equal(result.response.body, undefined);
      assert.equal(Object.prototype.toString.call(result.response.bodyBytes), '[object ArrayBuffer]');
    } else {
      assert.ok(ArrayBuffer.isView(result.response.body));
      assert.equal(result.response.bodyBytes, undefined);
      assert.equal(result.response.headers['Content-Length'], `${outputBytes(result.response).length}`);
    }
    assert.equal(store.writes.length, 1);
    const query = settings('action=query', store, client).json;
    assert.equal(query.appliedLatitude, 10);
    assert.equal(query.appliedLongitude, 20);
    assert.equal(query.appliedOffsetMeters, 0);
  });
}

for (const [lon, lat] of [[20, 0], [0, 20], [0, 0], [180, 90], [-180, -90]]) {
  test(`零值／边界 ${lon},${lat} 保存、查询、执行一致`, () => {
    const store = storage();
    assert.equal(settings(`lon=${lon}&lat=${lat}`, store).json.success, true);
    const query = settings('action=query', store).json;
    assert.equal(query.longitude, lon);
    assert.equal(query.latitude, lat);
    const loc = patchedLocation(execute('wloc', { store }));
    assert.equal(loc.get(1), lat * 1e8);
    assert.equal(loc.get(2), lon * 1e8);
  });
}

for (const [name, value] of [['缺失', undefined], ['null', null], ['空', ''], ['空白', '  '],
  ['非数字', 'abc'], ['尾缀', '20abc'], ['NaN', 'NaN'], ['Infinity', 'Infinity'],
  ['负无穷', '-Infinity'], ['溢出', '1e999'], ['布尔', true], ['数组', []], ['对象', {}]]) {
  test(`拒绝${name}坐标：保存、历史存储和参数执行`, () => {
    for (const axis of ['longitude', 'latitude']) {
      const coords = { ...initial, [axis]: value };
      const query = new URLSearchParams(Object.entries(coords).filter(([, v]) => v !== undefined)).toString();
      const store = storage(initial), before = store.raw;
      assert.equal(settings(query, store).json.success, false);
      assert.equal(store.raw, before);
      const legacy = storage(coords);
      assert.equal(settings('action=query', legacy).json.success, false);
      assert.equal(execute('wloc', { store: legacy, argument: initial }).store.writes.length, 0);
      const result = execute('wloc', { argument: coords });
      passthrough(result, fixture, {});
      assert.equal(result.store.writes.length, 0);
    }
  });
}

test('越界、别名与小数逗号／历史字符串兼容', () => {
  for (const query of ['lon=181&lat=0', 'lon=-181&lat=0', 'lon=0&lat=91', 'lon=0&lat=-91',
    'lon=&longitude=20&lat=10', 'lon=20&lat=&latitude=10']) {
    assert.equal(settings(query).json.success, false);
  }
  const store = storage();
  assert.equal(settings('longitude=20%2C5&latitude=0', store).json.longitude, 20.5);
  for (const argument of [{ longitude: '20,5', latitude: '0' }, { longitude: 0, latitude: 0 },
    'longitude=20.5&latitude=0']) {
    const loc = patchedLocation(execute('wloc', { argument }));
    assert.equal(loc.get(1), 0);
  }
  const legacy = storage({ ...initial, longitude: '20.5', latitude: '0' });
  assert.equal(settings('action=query', legacy).json.latitude, 0);
  assert.equal(settings('action=query', legacy).json.longitude, 20.5);
  assert.equal(patchedLocation(execute('wloc', { store: legacy })).get(2), 20.5e8);
  for (const coords of [{ longitude: 181, latitude: 0 }, { longitude: -181, latitude: 0 },
    { longitude: 0, latitude: 91 }, { longitude: 0, latitude: -91 }]) {
    const store = storage(coords);
    assert.equal(settings('action=query', store).json.success, false);
    passthrough(execute('wloc', { store, argument: initial }), fixture, {});
    passthrough(execute('wloc', { argument: coords }), fixture, {});
    assert.equal(store.writes.length, 0);
  }
});

test('Loon 模块实际位置参数格式支持零值并拒绝缺失／非法值', () => {
  for (const argument of ['[20,0,25,0,info]', '[0,20,25,0,info]', '[0,0,25,0,info]']) {
    const result = execute('wloc', { client: 'Loon', argument });
    const loc = patchedLocation(result);
    const [longitude, latitude] = argument.slice(1).split(',').map(Number);
    assert.equal(loc.get(1), latitude * 1e8);
    assert.equal(loc.get(2), longitude * 1e8);
  }
  for (const argument of ['[20,,25,0,info]', '[,20,25,0,info]', '[20,91,25,0,info]',
    '[20,NaN,25,0,info]', '[113.94114,22.544577,25,0,info]', '[20,10',
    '[20,5,0,25,0,info]', '[20,10,25,0,info', '[20,10,25,0,info,extra]']) {
    const result = execute('wloc', { client: 'Loon', argument });
    passthrough(result, fixture, {});
    assert.equal(result.store.writes.length, 0);
  }
});

test('非法百分号模块参数安全透传，恰好完成一次且不更新回读', () => {
  for (const client of clients) for (const argument of ['longitude=%&latitude=0',
    'longitude=0&latitude=%', 'longitude=%E0%A4&latitude=0']) {
    const result = execute('wloc', { client, argument });
    passthrough(result, fixture, {});
    assert.equal(result.store.writes.length, 0);
  }
});

test('QX ArrayBuffer bodyBytes 与各种编码头大小写', () => {
  for (const name of ['Content-Encoding', 'content-encoding', 'CONTENT-ENCODING']) {
    const bytes = gzipSync(fixture), headers = { [name]: 'gzip' };
    const options = { client: 'Quantumult X', field: 'bodyBytes', representation: 'buffer', bytes, headers };
    passthrough(execute('wloc', options), bytes, headers);
    assert.equal(patchedLocation(execute('wloc', { ...options, store: storage(initial) })).get(1), 10e8);
  }
});

test('存储读取异常不覆盖记录、不回退到另一坐标', () => {
  const store = storage(initial), before = store.raw;
  store.readError = true;
  assert.equal(settings('action=query', store).json.success, false);
  assert.equal(settings('lon=30&lat=40', store).json.success, false);
  passthrough(execute('wloc', { store, argument: initial }), fixture, {});
  assert.equal(store.raw, before);
  assert.equal(store.writes.length, 0);
});

test('默认模块坐标无持久化时仍透传；保存数据优先且不逐字段混用', () => {
  const defaults = 'longitude=113.94114&latitude=22.544577&accuracy=25';
  passthrough(execute('wloc', { argument: defaults }), fixture, {});
  const store = storage({ ...initial, latitude: 0 });
  assert.equal(patchedLocation(execute('wloc', { store, argument: defaults })).get(1), 0);
  const invalid = storage({ longitude: 20 });
  const result = execute('wloc', { store: invalid, argument: defaults });
  passthrough(result, fixture, {});
  assert.equal(invalid.writes.length, 0);
});

for (const representation of ['view', 'buffer', 'array', 'string']) {
  test(`输入 ${representation} 和 rawBody 保留二进制边界`, () => {
    assert.equal(patchedLocation(execute('wloc', {
      store: storage(initial), field: 'rawBody', representation })).get(2), 20e8);
  });
}

test('解析／解压／无可改写位置／空内容失败保留内容和响应头，不更新回读', () => {
  for (const client of clients) for (const bytes of [Buffer.alloc(0), Buffer.from([0xff]),
    gzipSync(Buffer.alloc(20, 0xff)), Buffer.from([31, 139, 0, 0]), Buffer.alloc(20)]) {
    const old = { ...initial, appliedLatitude: 1, appliedLongitude: 2, appliedOffsetMeters: 3 };
    const store = storage(old), before = store.raw;
    const headers = { 'Content-Encoding': 'gzip', 'CONTENT-length': String(bytes.length) };
    const result = execute('wloc', { client, bytes, headers, store });
    passthrough(result, bytes, headers);
    assert.equal(store.raw, before);
    assert.equal(store.writes.length, 0);
  }
});

test('随机扰动回读等于实际输出；再次保存使旧应用记录失效', () => {
  const store = storage({ ...initial, randomRadius: 100, custom: 'keep' });
  const loc = patchedLocation(execute('wloc', { store }));
  const query = settings('action=query', store).json;
  assert.equal(loc.get(1), Math.round(query.appliedLatitude * 1e8));
  assert.equal(loc.get(2), Math.round(query.appliedLongitude * 1e8));
  assert.equal(query.appliedOffsetMeters, 50);
  assert.equal(JSON.parse(store.raw).custom, 'keep');
  const saved = settings('lon=30&lat=40', store).json;
  for (const field of ['appliedOffsetMeters', 'appliedLatitude', 'appliedLongitude']) {
    assert.equal(saved[field], null);
    assert.equal(settings('action=query', store).json[field], null);
  }
});

test('回读写失败不撤销已改写的字节，不伪造存储成功，并留下日志', () => {
  for (const mode of ['false', 'throw']) {
    const store = storage(initial, mode), before = store.raw;
    const result = execute('wloc', { store });
    assert.equal(patchedLocation(result).get(2), 20e8);
    assert.equal(store.raw, before);
    assert.equal(store.writes.length, 1);
    assert.ok(result.logs.some(line => /回读.*失败/.test(line)));
  }
});
