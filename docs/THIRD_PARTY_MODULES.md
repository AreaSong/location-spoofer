# Third-party proxy modules

Third-party proxy mode (Surge / Quantumult X / Loon / Shadowrocket / Stash /
Egern) uses modules and scripts hosted in this repository under
`ThirdParty/WlocScripts/`. The original WLOC intercept approach is based on
Yu9191/wloc; this project now vendors the adapted copies so subscriptions do
not depend on that upstream repository remaining public.

## Subscription addresses

The App copies the same module files into the application bundle and, by default,
serves them on the device:

- on-device (default):
  `http://127.0.0.1:18766/modules/<file>`
  Script paths inside the served module are rewritten to
  `http://127.0.0.1:18766/dist/v1/wloc.js` and `wloc-settings.js`.
- GitHub mirror:
  `https://gh-proxy.org/https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/<file>`
- GitHub direct:
  `https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/<file>`

Importing or refreshing an on-device subscription requires this App to stay
running so the loopback server can answer. After the client caches the scripts,
location rewriting no longer needs GitHub.

| Module file | Client |
|---|---|
| `wloc.module` | Shadowrocket |
| `wloc.sgmodule` | Surge and Egern |
| `wloc.conf` | Quantumult X |
| `wloc.lpx` | Loon |
| `wloc.stoverride` | Stash |

No `?v=` cache-bust is appended. Re-importing the subscription in the proxy
client re-fetches the module. Script files live at
`ThirdParty/WlocScripts/dist/v1/` and are referenced by each module's
`script-path`.

After changing these files, rebuild the App so the bundled copy updates. GitHub
URLs only matter when the user switches the module source away from on-device.

## Script protocol

`wloc.js` patches Apple WLOC responses and reads coordinates from the
`wloc_settings` persistent key or the module `argument` config.
`wloc-settings.js` implements `wloc-settings/save` (query/clear/save) using
`lon`/`lat`/`acc`/`randomRadius` parameters.

The App's third-party save sends `lon`/`lat`/`acc`, matching the vendored
settings script. Motion-state simulation (fields 11/12) is not implemented by
these scripts and is unavailable in third-party mode; it remains available in
APP mode (built-in proxy).

## 脚本维护与行为验证

仓库目前只保留 `dist/v1/` 中的独立脚本，没有对应的未压缩源工程、
source map、依赖清单或生成命令。文件头的 Build 时间标识原始打包版本，
不表示当前修订时间。维护时直接修改脚本中展开的业务段，保留打包依赖及
第三方声明；不要用缺少本地修复的上游产物覆盖。无需安装 esbuild 或新建打包系统。
App 仍按上文方式复制、提供这些文件，模块路径保持不变。

- 保存、查询、执行均接受有限数值和历史数值字符串，经度范围为
  `[-180, 180]`、纬度范围为 `[-90, 90]`，允许零值及原有小数逗号形式
  （Loon 位置数组以逗号分隔，必须使用小数点；缺少括号或项数不是五项时拒绝）。
  缺失、空白、非数值、非有限值、部分可解析字符串和越界值均无效。
  查询将合法历史字符串坐标返回为 JSON 数值，以兼容 Swift 的 `Double`。
- 保存值优先于模块参数，整组坐标校验，不能将无效保存值和模块参数混用。
  无保存数据且参数仍为模块默认坐标时保持透传；Loon 的位置数组参数也按相同规则处理。
- 保存与清除仅在客户端存储接口返回成功时报告 `success: true`；返回 false
  或抛异常均报告失败。继续使用 `wloc_settings` 和 JSON `null` 清除约定。
- `appliedLatitude`、`appliedLongitude` 是成功改写输出中的 WGS-84 坐标（精度为
  `1e-8` 度），`appliedOffsetMeters` 为本次扰动距离（米，保留一位小数）。
  保存配置会将三者重置为 null；此后它们表示该配置最近一次成功改写的记录。
  透传或改写失败不更新记录。回读存储失败会记日志，已改写响应继续返回，
  查询仍只能看到此前持久化的记录，不能用它推断每次请求都已应用。
- 透传以 `$done({})` 保留客户端的原始内容、编码头及状态。成功改写返回顶层
  二进制 `body`；Quantumult X 通过现有适配器转换为 `ArrayBuffer` 类型的
  `bodyBytes`。移除所有大小写形式的旧编码、传输编码和长度头；除 QX 交由客户端
  计算长度外，其余返回新长度。设置接口仍保留原有的请求阶段响应封装。

独立行为测试只需现有 Node 和标准库，使用 `vm` 执行真实交付脚本，模拟六种
客户端 API，以合成 WLOC 数据验证字节、响应头及存储副作用，无需代理、联网或凭据：

```bash
node --test Tests/wloc_scripts_behavior_test.cjs
bash Tests/third_party_mode_contract_test.sh
git diff --check
```

这些检查不代表第三方客户端真机验收。客户端自动解压、二进制回传和缓存刷新行为，
仍需在实际客户端及对应系统版本上验证。
