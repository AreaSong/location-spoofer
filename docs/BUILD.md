# Build

## Requirements

- macOS with Xcode and Command Line Tools
- Go 1.23 or newer
- XcodeGen (`brew install xcodegen`)

## One-command build

```bash
./build.sh
```

该脚本会先检查 `xcrun`、`xcodebuild`、`xcodegen` 和 `go`，随后构建 iOS Go 静态库、重新生成 Xcode 工程、构建并输出未签名 IPA。

`Scripts/build-core.sh` 产出两份静态库：真机 `arm64`，以及模拟器通用库（`arm64` + `x86_64`，由 `lipo` 合并）。generic iOS Simulator 目标会同时链接这两个架构；只保留 `arm64` 时，链接阶段会因缺少 `_wloccore_*` 的 `x86_64` 符号失败。

如需在未签名 IPA 已生成后额外运行 `PaopaoLocationSpoofer` 的 iOS Simulator 单元测试：

```bash
./build.sh --test
```

`--test` 默认使用名为 `iPhone 16` 的 Simulator。若本机没有该设备，请传入已安装设备的 destination：

```bash
SIMULATOR_DESTINATION='platform=iOS Simulator,name=<你的模拟器名称>' ./build.sh --test
```

Output:

```text
dist/PaopaoLocationSpoofer-unsigned.ipa
```

IPA 始终保持未签名。用 [Impactor](https://github.com/claration/Impactor) 签名安装即可。

## 预编译依赖

开发者隧道模式链接 `Vendor/idevice/libidevice_ffi.a`（约 95 MB，MIT 许可）。该文件只在 iOS 真机目标下链接，模拟器构建和单元测试不需要它。来源、用到的接口和重新构建步骤见 [Vendor/idevice/README.md](../Vendor/idevice/README.md)。

## 发布验收

1. `./build.sh` 通过并输出未签名 IPA
2. 用 Impactor 签名后安装到设备
3. 真机安装后，先配置 WiFi HTTP 代理 `127.0.0.1:8888`，再按检测结果完成 CA 下载、安装和信任
4. 环境检测通过后，选点开启虚拟定位
5. 打开 Apple 地图验证定位是否变为虚拟位置
6. 切换到开发者隧道模式：连上 LocalDevVPN、导入配对文件，验证定点推送和路线播放，并确认停止后真实位置立即恢复
7. 若失败，查看诊断页的日志信息

## 发布版本

发布前先生成版本归档并提交：

```bash
./Scripts/generate-release-notes.sh v1.1.0
git add docs/releases/v1.1.0.md
git commit -m "docs: archive v1.1.0 release notes"
git tag v1.1.0
git push origin main v1.1.0
```

归档文件根据“上一个版本标签到当前提交”的 commit subject 生成。GitHub Actions 会校验归档存在，并将文件正文直接作为 GitHub Release 内容；不会发布文档链接或缺失说明的占位 Release。
