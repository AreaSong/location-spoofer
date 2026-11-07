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

`wloc.module` names a local SOCKS5 node `环回 = socks5, 127.0.0.1, 18767`,
appends `skip-proxy` for localhost, and adds loopback CIDR `DIRECT` rules.
The App serves that SOCKS5 forwarder in third-party mode. Import
`socks5://127.0.0.1:18767#环回` into Shadowrocket’s home node list, select
it, and use Configuration routing so loopback script downloads use DIRECT
rules. Global Proxy routing with a remote node can send localhost requests to
that remote node and cause timeouts. Keep this App open while that node is selected. The module does not
add `FINAL,DIRECT`, so an existing proxy profile keeps its own default
policy.

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

## 独立坐标控制接口（模块 1.2.0）

新版 App 的查询、保存、清除统一使用
`https://location-spoofer.invalid/wloc-settings/save`，仍使用原有 GET 参数及
`wloc_settings` 存储，不迁移、清除或复制用户已保存的坐标。控制脚本与 WLOC
响应脚本继续读写同一个键。新版控制响应必须携带 `X-Wloc-Control: 1`，这是兼容性
标识而非认证凭据；缺失或版本不匹配会要求更新模块，不能被当作清除/保存成功。
所有响应（包括无坐标和错误）回报 `moduleVersion: 1.2.0`。

请先安装新版 App，再从 App 的本机来源更新正式定位模块和两份脚本。
小火箭全局路由选择「配置」，保持 App 运行以提供本机脚本；仅导入独立探测模块
不能使坐标控制接口可用。开发中的未推送修改只能从本机来源获取；使用远端来源时，
需确认仓库已有对应模块和脚本，且客户端已更新缓存。为兼容旧 App，模块仍保留旧 Apple 控制地址入口；
新版 App 不自动回退旧地址或 HTTP，且拒绝全部重定向。旧 App 在受证书固定限制
的设备上仍可能失败，保留兼容入口不表示已解除系统限制。

各模块新增专用域名的解密、`192.0.2.1` 映射与直连规则；普通公网服务不承担坐标存储。
2026-11-07 在 iOS 26.7.2 / Shadowrocket 2.2.93 上完成真机对照：独立探测、历史坐标
查询、测试点保存、独立回读与清除后查询为空均通过；Apple 地图位置未跟随测试点。
VPN 日志中的 `gs-loc-cn.apple.com` 在读取 MITM 证书后立即关闭，未看到 `/clls/wloc`
处理记录。此前 App 对 Apple 控制域名的详细诊断明确报告证书固定校验失败 `-67880`；
不能把这条具体错误码直接当作上述 VPN 连接关闭的已证实原因。
后续在 WLOC 模块已停用、VPN 仍开启的状态下，观察到 Apple 地图恢复显示定位蓝点。
因此本设备的 WLOC 实际定位未通过验收，保持模块停用；这些结果不代表其他设备全部失效。
清除坐标不会关闭模块的 HTTPS 拦截，遇到正常定位受影响时需单独检查模块启用状态。
Surge/Egern、Loon、Stash、Quantumult X 仅提供候选配置与模拟脚本测试，尚未真机验证。
Quantumult X 若以 rewrite 资源方式导入，需同时将模块中的 `[dns]` 和
`[filter_local]` 项合并进主配置，不能假定 rewrite 导入会应用 DNS/分流设置。
映射语法参考 [Surge](https://manual.nssurge.com/dns/local-dns-mapping.html)、
[Stash](https://stash.wiki/features/hosts)、
[Quantumult X 官方示例](https://github.com/crossutility/Quantumult-X/blob/master/sample.conf)。

验收分为：查询历史坐标 → 保存合成测试点 → 独立查询回读 → 检查实际定位请求和地图
位置 → 清除并确认查询为空及实际位置恢复。配置响应成功不等于系统定位被改写。
如需回滚代码，应同时使用匹配的 App/模块，存储键及值格式未改变；本次不自动回滚手机配置，
也不自动关闭或清除已有虚拟定位。正式坐标迁移不改 `/clls/wloc` 的匹配与改写逻辑。

## HTTPS 证书失败诊断

连接检测报告「HTTPS 证书校验失败」不等于未开启完全信任。请求失败日志之后，
App 会在后台追加「证书校验诊断」，通过相同的「诊断ID」关联。复制这两条日志，
重点查看 `trust.error.*` 的系统错误域、代码和描述，以及证书链摘要与 SHA-256 指纹；
iOS 18 及以上还会记录各证书的有效期。新增诊断不包含证书原文或私钥。
控制传输失败日志只记录错误域和代码，避免将带坐标的 URL userInfo 写入日志。
旧版本已保存的日志可能仍包含坐标，分享旧日志时需检查。

诊断在后台评估失败请求携带的原 SecTrust，不设置信任锚点、例外或策略，
不放行失败请求、不重试定位写入。系统可能重新评估并联网检查证书，诊断结果单独标记，
不作为原请求时刻的结果。未携带信任对象时明确记录缺口。
后台诊断可能稍晚于错误提示出现；若诊断时校验已通过，也不会将原请求改为成功。
普通 TLS 握手失败保留网络错误，不再仅凭 TLS/SSL 字样断言证书失败。

本地合成证书测试不能替代实际代理客户端的真机校验。安装包含本次代码的新版本后，
保持原代理配置，点击一次「检测连接」，再复制对应日志以定位实际失败原因。

## 独立 HTTPS 探测（实验，仅小火箭）

运行日志 →「独立 HTTPS 探测（实验）」→ 复制模块地址，在小火箭导入并启用后回到 App 执行探测。
该模块通过本机 `http://127.0.0.1:18766/modules/wloc-probe.module` 提供，脚本同样来自本机；
导入或更新时须保持 App 的本机服务可用，不依赖尚未发布的 GitHub 文件。它是独立模块，
不替换现有定位模块；退出实验可禁用该探测模块。

请求固定为 `GET https://location-spoofer.invalid/probe`，没有查询参数、坐标或请求体。
成功必须收到 HTTP 200 及精确标识 `{"protocol":"location-spoofer-probe","version":"1","mode":"no-storage"}`。
脚本不访问持久存储或网络，拒绝非 GET、额外参数和其他路径；App 禁用缓存、拒绝重定向，
保留系统默认 TLS 校验，不降级 HTTP，也不改变定位管理器的连接状态。

模块把专用 `.invalid` 域名映射到文档保留地址 `192.0.2.1` 并设置精确 DIRECT 规则，
目的是让代理在请求阶段本地返回响应，而不是连接真实外部服务。规则解析、DNS、MITM 与脚本
执行顺序仍须用 Shadowrocket 真机验证；未接管时可能表现为 DNS 失败或超时，不代表证书固定校验。
此地址设计不是其他客户端的兼容承诺。探测通过也只证明控制链路候选可用，
不证明 `/clls/wloc` 拦截或系统定位修改成功。此探测模块不能替代下文的新版定位控制模块。

本地验证：`node --test Tests/https_probe_behavior_test.cjs`，Swift 的 `IndependentHTTPSProbeTests`
和 `ThirdPartyModuleCatalogTests`。这些检查不代表真机导入或 HTTPS 探测已通过。

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
