# Vendor/idevice

开发者隧道模式链接的 idevice FFI（外部函数接口）静态库。App 通过它建立 RemotePairing 隧道、完成 RSD 握手，并调用开发者定位模拟服务。

## 来源与文件身份

上游项目为 [jkcoxson/idevice](https://github.com/jkcoxson/idevice)。**当前预编译库的精确上游 tag/commit、Cargo.lock、features 和完整构建配方均未核实**；不能从文件日期、符号或编译器字符串反推。

2026-10-02 对仓库文件的只读取证：

| 项目 | 结果 |
|---|---|
| 文件 | `libidevice_ffi.a`，95,405,912 字节 |
| SHA-256 | `05e6f58f082ee9f866a60763debe9b016e003005d424ac227b8d459686a2b575` |
| Git blob | `1ff0cf88fcd35ae2feee3882982c10015414b946` |
| 架构 | 普通 ar 归档；557 个 arm64 Mach-O 对象及 1 个归档符号表，无模拟器切片 |
| 首次引入 | [`f28564fcd81d1ee9053525ab531526c40e69ef3c`](https://github.com/AreaSong/location-spoofer/commit/f28564fcd81d1ee9053525ab531526c40e69ef3c)，2026-09-22；库、头文件、许可、modulemap 同次加入 |
| 历史一致性 | 当前库与首次引入的 Git blob 相同；README 后由 `f902295b65ee9617373998746d6d37242cc2d147` 加入，记录上游版本“未记录” |

校验和只标识当前文件，不证明能从某个上游提交重现构建。已检索的仓库历史和脚本没有恢复出 idevice 的构建清单或锁文件。库中可见 `rustc version 1.97.1 (8bab26f4f 2026-07-14)`，这是编译器标识，不是 idevice 的提交。

可复查的本地命令：

```bash
shasum -a 256 Vendor/idevice/libidevice_ffi.a
xcrun lipo -info Vendor/idevice/libidevice_ffi.a
xcrun otool -l Vendor/idevice/libidevice_ffi.a
git log --all -- Vendor/idevice
git rev-parse f28564f:Vendor/idevice/libidevice_ffi.a
git hash-object Vendor/idevice/libidevice_ffi.a
```

## 许可证与头文件

- 本地 [LICENSE.txt](LICENSE.txt) 为 MIT 文本，权利人为 `Copyright 2026 Jackson Coxson`；分发需保留版权与许可声明。
- 本次将公开上游固定到 [`d32c8189c51c2789496b0768039419c3705498c3`](https://github.com/jkcoxson/idevice/tree/d32c8189c51c2789496b0768039419c3705498c3) 作比对：其 `LICENSE.txt` 与本地字节一致，SHA-256 为 `131488ce7e302b9f62e3236793e57c86a208d3dfaf03e6d7d03ddc0fc82392ed`。**此比对提交不是已确认的二进制来源。**
- 仓库原有说明称 `idevice_location.h` 从上游完整头文件裁剪而来；上游 [`ffi/build.rs`](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/ffi/build.rs#L27) 确实使用 cbindgen 生成 `idevice.h`。主要函数签名与本次比对提交中的 `rp_pairing_file`、`tunnel_provider`、`dvt/remote_server`、`dvt/location_simulation` 实现一致，但原始生成头文件的版本和配置未知。
- 顶层 MIT 文本不能证明静态归档中全部传递依赖只受 MIT 约束；完整依赖许可及通知清单尚未恢复。

## App 使用的接口

| 函数 | 用途 |
|---|---|
| `rp_pairing_file_read` / `rp_pairing_file_free` | 读取、释放导入的 RemotePairing 配对文件 |
| `tunnel_create_rppairing` | 经 LocalDevVPN 的本机地址（10.7.0.1:49152）建立隧道 |
| `remote_server_connect_rsd` / `remote_server_free` | RSD 握手、连接和释放 RemoteServer |
| `location_simulation_new` / `location_simulation_set` / `location_simulation_clear` / `location_simulation_free` | 创建、更新、清除定位模拟及释放句柄 |
| `adapter_free` / `rsd_handshake_free` / `idevice_error_free` | 释放句柄和错误对象 |

上述 12 个函数均由 [App/IdeviceLocationClient.swift](../../App/IdeviceLocationClient.swift) 使用，并在归档符号表中找到外部定义。就绪判断在 `App/RouteLocationSetupStore.swift`。

[project.yml](../../project.yml) 仅在 `sdk=iphoneos*` 时链接 `-lidevice_ffi -lc++ -lz`；模块导入、真实句柄及调用受 `#if !targetEnvironment(simulator)` 隔离。模拟器不链接或运行此库，因此 Swift 模拟器测试无法验证这条设备路径。

## 最低系统版本冲突

App 声明最低 iOS 15.0；归档对象的 Mach-O 版本命令包含以下组合：

| 对象数 | 版本命令 | 最低 iOS | SDK 字段 |
|---:|---|---|---|
| 166 | `LC_BUILD_VERSION`，platform iOS | 18.0 | 0（otool 显示 n/a） |
| 1 | `LC_BUILD_VERSION`，platform iOS | 18.0 | 27.0 |
| 346 | `LC_VERSION_MIN_IPHONEOS` | 10.0 | 0（n/a） |
| 44 | `LC_VERSION_MIN_IPHONEOS` | 10.0 | 26.2 |

代表对象 `idevice_ffi.idevice_ffi.e75610fe4c48b73b-cgu.0.rcgu.o` 和 `idevice-86a3e6c6e3db19be.idevice.d3f6c0b11105fa27-cgu.0.rcgu.o` 声明 iOS 18.0、SDK n/a；`ea708c7824d36062-shims.o` 声明 iOS 18.0、SDK 27.0。n/a 不等于未使用 SDK，整个归档也不能统一称为 SDK 27 构建。

这解释了设备链接中的最低版本警告。构建通过不证明 iOS 15–17 能启动或运行；警告也不能证明所有旧系统必崩溃。即使应用界面将隧道能力限制为 iOS 18+，库仍链接进设备 App，不能仅凭功能入口限制排除加载或符号风险。

本机 `nm` 读取部分 Rust bitcode 时报告 LLVM 读取器不兼容（Producer LLVM22.1.6 / Rust1.97.1），其部分输出不能作为完整符号清单。直接读取对象的 Mach-O `LC_SYMTAB`，扣除归档内部定义后可见 202 个外部未定义符号名；这不是链接裁剪后的最终 App 导入表。有限核对本机 iPhoneOS26.5 SDK：`CommonCrypto/CommonRandom.h:56` 的 `CCRandomGenerateBytes` 标注 iOS 8.0，`sys/clonefile.h:49` 的 `fclonefileat` 标注 iOS 10.0，`unistd.h:762` 的 `fsetattrlist` 标注 iOS 3.0。这些例子未显示 iOS 18 专属要求，但未覆盖全部符号、ABI 和运行行为，且存在 `dlsym` 间接查找，不能据此宣布旧系统兼容。

## 待决选项与更新要求

本阶段只记录，未替换库、安装 Rust 或调整支持系统范围。

1. 向原提供者恢复精确源码提交、Cargo.lock、features、工具链、部署目标和构建日志；这是补齐来源及依赖许可的优先路径。
2. 来源明确后，可评估按原有最低目标重建兼容库；若上游代码本身依赖新系统，仅修改 deployment target 不足以修复，需核对 API 并做 iOS 15/16/17 设备启动及功能回归。
3. 可评估隔离新系统能力和链接依赖；涉及 App 结构及运行行为，需单独设计和验证。
4. 也可由用户决定调整支持范围；这会影响既有用户及产品声明，本阶段未执行。

原 README 的通用 `cargo build --release --target aarch64-apple-ios` 示例不构成当前库的可复现配方。本次比对的上游 [`justfile`](https://github.com/jkcoxson/idevice/blob/d32c8189c51c2789496b0768039419c3705498c3/justfile#L64) 设备 recipe 显式设置 iOS 17.0，与当前对象元数据不同，不能直接套用。

未来经授权更新时，应同时记录源码和依赖锁定信息、完整构建命令、目标、产物校验和与许可证；同步裁剪头文件，运行正式构建并完成所承诺系统的真机验证。约 95 MB 的库当前直接入 Git；更换存储或下载方案属于另行决定的工程变更。

## 版本记录

| 日期 | 上游版本 | 说明 |
|---|---|---|
| 2026-09-22 | 未记录 / 未核实 | 首次引入，当前文件仍与该次 blob 一致 |
| 2026-10-02 | 仍未核实 | 补充身份、历史、许可比对和最低版本证据；未更新二进制 |
