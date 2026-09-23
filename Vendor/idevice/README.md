# Vendor/idevice

开发者隧道模式链接的 idevice FFI 静态库。App 通过它建立 RemotePairing 隧道、完成 RSD 握手，并调用 iOS 的开发者定位模拟服务。

## 来源

- 上游项目：[jkcoxson/idevice](https://github.com/jkcoxson/idevice)（Rust 实现的 iOS 设备协议库，含 `idevice_ffi` C 绑定）
- 许可证：MIT，见 `LICENSE.txt`
- 头文件：`idevice_location.h` 只声明 App 用到的函数，是从上游 `idevice_ffi` 生成的完整头文件中裁剪出来的
- 链接方式：`project.yml` 只在 `sdk=iphoneos*` 下链接 `-lidevice_ffi -lc++ -lz`，模拟器构建不包含这个库，对应代码用 `#if !targetEnvironment(simulator)` 隔离

## App 使用的接口

| 函数 | 用途 |
|---|---|
| `rp_pairing_file_read` / `rp_pairing_file_free` | 读取导入的 RemotePairing 配对文件 |
| `tunnel_create_rppairing` | 经 LocalDevVPN 的本机隧道地址（10.7.0.1:49152）建立隧道 |
| `remote_server_connect_rsd` / `remote_server_free` | RSD 握手并连接 RemoteServer |
| `location_simulation_new` / `location_simulation_set` / `location_simulation_clear` / `location_simulation_free` | 开始、更新、清除定位模拟 |
| `adapter_free` / `rsd_handshake_free` / `idevice_error_free` | 释放句柄和错误对象 |

调用封装在 `App/IdeviceLocationClient.swift`，重试和就绪判断在 `App/RouteLocationSetupStore.swift`。

## 更新静态库

`libidevice_ffi.a` 约 95 MB，已直接提交到仓库。更新时请按下面步骤做，并把版本信息补到本文件末尾的记录里：

1. 检出上游对应 tag，在 macOS 上安装 Rust 工具链并添加目标：

   ```bash
   rustup target add aarch64-apple-ios
   ```

2. 在上游仓库的 `ffi` crate 目录构建 iOS 静态库（需要启用定位模拟和隧道相关 feature，以上游 README 为准）：

   ```bash
   cargo build --release --target aarch64-apple-ios
   ```

3. 把生成的 `target/aarch64-apple-ios/release/libidevice_ffi.a` 复制到本目录，覆盖旧文件；
4. 对照上游生成的头文件，同步 `idevice_location.h` 中用到的函数签名；
5. 运行 `./build.sh` 确认 iOS 真机目标能链接；
6. 在下方记录里追加一行。

仓库对单个大文件的承受能力有限（GitHub 单文件上限 100 MB），后续若继续更新，建议改用 Git LFS 或在构建脚本中按版本下载，避免每次更新都让仓库体积增加近 100 MB。

## 版本记录

| 日期 | 上游版本 | 说明 |
|---|---|---|
| 2026-09-22 | 未记录 | 首次引入，随开发者隧道模式提交。上游 tag 未记录，下次更新时请补齐。 |
