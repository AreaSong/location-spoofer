# Build

## Requirements

- macOS、完整 Xcode 和 Command Line Tools；`project.yml` 声明 Swift 5.9、App 最低 iOS 15.0、实时活动扩展最低 iOS 16.2。这些目标声明不是旧系统运行验收结果。
- Go 模块声明下限为 `1.23.0`，不表示所有更高版本已兼容。构建脚本和 Make 测试入口固定 `GOTOOLCHAIN=local`，版本不足直接失败，不自动下载新编译器；显式将已安装的合适 Go 的 `bin` 放到 `PATH` 前端。
- XcodeGen；本机需预先准备，CI 从上游固定版本 ZIP 恢复至 runner 临时目录，不运行 Homebrew 安装。
- Python 3（只使用标准库）、系统 `ditto` / `zip`；第三方脚本测试还需 Node.js 的 `node:test`。

| 工具 | CI 选择 | 本阶段本机实际环境 |
|---|---|---|
| macOS / Xcode | `macos-26` arm64，显式 `DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer` | macOS 26.6.2 arm64；Xcode 26.6 (17F113)，iPhoneOS26.5 SDK |
| Go | `1.23.12`，沿用模块的 1.23 系列并固定补丁版本 | 显式使用已缓存 Go 1.23.0；默认 PATH 的 1.22.12 不满足模块要求 |
| XcodeGen | `2.46.0`，验证 ZIP SHA-256 后解压 | 2.46.0 |
| Node.js | `22` 系列，由 setup-node 选择该系列补丁版本 | 25.1.0 |
| Python | `3.12` 系列，由 setup-python 选择该系列补丁版本 | 3.9.6 |

CI 选择尚未在远端运行；本机版本不同的工具不能视为已验证 CI 对应版本。上述配置也不是工具最低版本的完整兼容矩阵。Node/Python 不新增项目包依赖或锁文件，具体补丁版本输出到 job 日志。runner 标签固定 OS 系列，托管镜像自身仍会更新；指定 Xcode 路径不存在时应失败，不回退到 latest。

来源（2026-10-02 核对）：[官方 runner 标签映射](https://github.com/actions/runner-images/blob/6d942e630479cd99a93dadfc766af11242bfa402/README.md)、[macos-26 arm64 镜像清单](https://github.com/actions/runner-images/blob/6d942e630479cd99a93dadfc766af11242bfa402/images/macos/macos-26-arm64-Readme.md)（镜像 `20260907.0351.1`，列出 Xcode 26.6）、[Go 官方下载记录](https://go.dev/dl/)、[XcodeGen 2.46.0](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0)。本次下载核对的 `xcodegen.zip` SHA-256 为 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`，与上游 release asset digest 一致；ZIP 内路径为 `xcodegen/bin/xcodegen`。

Actions 的版本与已核实 commit SHA 以 [.github/workflows/release.yml](../.github/workflows/release.yml) 为准，SHA 旁保留版本注释。当前选择 checkout 7.0.1、setup-go/node/python 7.0.0、upload-artifact 7.0.1、download-artifact 8.0.1、action-gh-release 3.0.3；通过上游 Git refs 与各 SHA 的 `action.yml` 核对引用、输入及 Node 24 运行时。[GitHub 已移除 Actions Node 20](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/)，因此不沿用旧 Node 20 Actions；Actions 自身运行时与第三方脚本测试使用的 Node 22 是两件事。

## One-command build

```bash
./build.sh
```

该脚本会先检查 `xcrun`、`xcodebuild`、`xcodegen`、`go` 和 `python3`，调用 `Scripts/build-unsigned-ipa.sh`：构建 Core、重新生成 Xcode 工程、检查有效部署目标、编译 Release 主 App 与实时活动扩展，再打包并检查 IPA 结构及 Mach-O 最低系统版本。`make ipa-unsigned` 调用同一入口，Core 只构建一次；`make core` 可单独重建静态库。

`Scripts/build-core.sh` 产出两份静态库：真机 `arm64`，以及模拟器通用库（`arm64` + `x86_64`，由 `lipo` 合并）。generic iOS Simulator 目标会同时链接这两个架构；只保留 `arm64` 时，链接阶段会因缺少 `_wloccore_*` 的 `x86_64` 符号失败。

如需在未签名 IPA 已生成后额外运行 `PaopaoLocationSpoofer` 的 iOS Simulator 单元测试：

```bash
./build.sh --test
```

`--test` 完整读取 `xcrun simctl list --json`，按版本从高到低查找已安装且可用的 iOS 运行时，在该运行时的可用 iPhone 中按名称、UUID 排序，使用明确 UUID。设备类型取 `deviceTypeIdentifier`，改名设备也能识别；同名设备和多个运行时不会造成 destination 歧义。无可用运行时/设备、JSON 异常或 simctl 失败均终止，不跳过 Swift 测试。可显式覆盖 destination：

```bash
SIMULATOR_DESTINATION='platform=iOS Simulator,id=<设备 UUID>' ./build.sh --test
```

测试使用本次重建的 Core 模拟器库；派生数据位于 `build/SimulatorTests`，结果位于 `build/SimulatorTests.xcresult`（再次测试会重建这个结果包，拒绝符号链接路径）。即使 IPA 已生成，Swift 测试失败也会令整个命令失败。

Output:

```text
dist/PaopaoLocationSpoofer-unsigned.ipa
```

构建入口禁用代码签名。打包只使用本次 `build/UnsignedIPA/Payload`，在 `dist` 内创建临时 IPA，通过结构、plist 与 Mach-O 部署目标检查后原子替换正式目标；打包或检查失败保留上一份成功 IPA，临时产物随退出清理。脚本只重建自有的 `Core/build`、`build/DerivedData` 与 `build/UnsignedIPA`，拒绝符号链接形式的输出父目录。`dist` 中其他文件不清理。

本地产物名保持 `PaopaoLocationSpoofer-unsigned.ipa`；release 工作流另行重命名为 `Location-Spoofer-unsigned.ipa`。构建成功不表示已经签名、安装、发布或通过真机运行验收。

## 部署目标门禁

工程输入以 `project.yml` 为准：全局 `options.deploymentTarget.iOS: "15.0"` 供主 App 继承，单平台扩展使用 `deploymentTarget: "16.2"` 字符串。[XcodeGen 2.46.0 Target 规范](https://github.com/yonaskolb/XcodeGen/blob/2.46.0/Docs/ProjectSpec.md#target) 不接受此处的 `{iOS: "16.2"}` 字典写法；该错误曾使扩展静默继承 15.0。不要手改生成的 pbxproj。

检查的预期值统一维护在 `Scripts/deployment_targets.py` 的 `EXPECTED_TARGETS`，代表产品约定，独立于被检查的 YAML 和 IPA。变更支持范围时需同步审阅生成配置、此契约和独立的回归样本；测试不会读取 YAML 来计算预期值。

`Scripts/build-unsigned-ipa.sh` 在真实 `xcodegen generate` 后调用该检查器，逐 target 读取 `xcodebuild -showBuildSettings -json`，覆盖主 App/扩展 × Debug/Release × iphoneos/iphonesimulator 共八组，并校验返回的 target、配置和平台。不能用 scheme 的设置输出推定依赖扩展也已覆盖。正式构建及 CI 的 `./build.sh --test` 自然复用这两个门禁，不另写 CI 检查逻辑。

```bash
xcodegen generate
python3 -B Scripts/deployment_targets.py --project PaopaoLocationSpoofer.xcodeproj
```

IPA 中 `MinimumOSVersion` 和 Mach-O 的最低版本都必须符合该契约，按数值组件比较，`16.2` 与 `16.2.0` 等价。`--macho` 使用 Xcode 的 `xcrun lipo -archs` 枚举可执行文件切片，逐片运行 `vtool -show-build`：读取 `LC_BUILD_VERSION.minos`（并要求 IOS 平台），兼容旧 `LC_VERSION_MIN_IPHONEOS.version`。`sdk`（如 26.5）、链接器版本及营销版本都不是最低系统版本；版本信息缺失、非法、重复或工具无法读取均失败。此检查只覆盖 App/扩展可执行文件的部署元数据，不证明静态 Vendor 对象或旧系统运行兼容性，idevice 的 iOS 18 依赖问题仍见下文。

## IPA 检查

```bash
./Scripts/verify-ipa.sh --unsigned dist/PaopaoLocationSpoofer-unsigned.ipa
make verify-ipa IPA_MODE=unsigned IPA="/absolute/path/to/unsigned.ipa"

# macOS 正式产物门禁，构建入口已自动调用
./Scripts/verify-ipa.sh --unsigned --macho dist/PaopaoLocationSpoofer-unsigned.ipa

# 仅对已有签名样本做只读检查，不会签名或修改输入
./Scripts/verify-ipa.sh --signed "/absolute/path/to/signed.ipa"
make verify-ipa IPA="/absolute/path/to/signed.ipa"
```

`make verify-ipa` 保留原有默认 `signed` 模式；检查本地未签名包需显式传 `IPA_MODE=unsigned`。路径通过环境变量传入脚本，支持空格和 shell 引号。

两种模式均校验 ZIP 可读性与 CRC，按 ZIP 原始路径精确核对主 App/实时活动扩展、可解析的 Info.plist、非空且保有执行权限的可执行文件，并检查固定 Bundle ID、主 App 与扩展版本一致、各自 MinimumOSVersion，以及 WidgetKit/实时活动声明。解包前检查全部条目及隐式父目录，拒绝绝对路径、父目录跳转、重复/大小写或 Unicode 别名、链接及特殊文件；只在脚本自有隔离目录解包并清理，不修改输入。此项目 bundle 约定为普通文件和目录，不支持带符号链接的输入。

`--unsigned` 是结构检查模式，允许未签名产物，也不判断一个包是否已签名。`--signed` 额外要求 App 和扩展的签名资源存在，并对二者运行 `codesign --verify --deep --strict`。它不读取私钥、修改 Keychain 或信任；通过也不代表 provisioning profile 与 entitlements 一致、签名有效期/分发资格通过、设备可安装或权限已获系统接受。两种模式都可在路径前添加 `--macho`；不传时明确输出未检查 Mach-O，保留只用 Python 标准库的跨平台 ZIP/plist 测试。`--macho` 需要 macOS Xcode 工具，缺失时报错而非跳过。签名成功的合成工具测试不能替代真实签名样本。

脚本退出码：`2` 参数，`3` 输入缺失，`4` ZIP 损坏/不支持，`5` 不安全条目，`6` bundle 缺失，`7` plist，`8` 可执行文件，`9` 项目结构约束，`10` 签名资源缺失，`11` 签名无效，`12` 验证工具失败，`13` 文件/临时目录 IO 失败，`14` 部署目标/最低版本元数据不符合约定。`make` 会将子命令失败汇总为自身失败状态，原始类别仍见错误消息。

脚本回归检查：`bash Tests/build_script_test.sh`（包括真实脚本配合合成 bundle、编译器/签名工具替身的行为测试，以及有效设置与版本解析测试）。工具失败、旧 load command 和多切片分支采用 mock；真实 XcodeGen 生成、App/扩展编译和新 IPA 检查需另外执行正式构建，不能以合成通过替代。

## 测试入口与 CI 门禁

| 正式入口 | 覆盖范围 | 所需环境 |
|---|---|---|
| `make test-go` | `go mod download` / `verify`、全部单元测试及 race（同一轮）、`go vet`；测试禁用缓存并限制为 5 分钟 | Go ≥ 1.23.0、支持 race 的主机 C 编译器；CI 使用 Ubuntu 24.04 |
| `make test-scripts` | Shell 语法、全部 `Tests/*_test.sh` 文档/构建/产品契约，随后运行第三方 JS 行为测试 | macOS 的 Bash/ditto/zip/make、Python、Node；不调用真实 Xcode 编译器 |
| `./build.sh --test` | 当前 Core 设备和双架构模拟器库、八组有效部署设置、Release App/扩展、未签名 IPA 结构/plist/Mach-O 检查、Swift 模拟器测试 | 完整 macOS 构建环境及可用 iPhone 模拟器 |

`make test-scripts` 中的 `Tests/build_script_test.sh` 已调用构建行为与 IPA 验证 Python 测试，不再单独重复执行它们。Make 任一步失败都会失败退出；缺失测试文件或工具不作成功跳过。

事件以远端 `origin/HEAD → main`（本次 `git ls-remote --symref origin HEAD` 核实）和既有 `v*` tag 发布习惯为依据：

- PR 目标为 `main`、提交推送到 `main`：执行 `preflight → [go, scripts, apple]`。普通分支以 PR 检查接入；三个检查并行且不发布。
- 推送 `v*` tag：`preflight` 先核对归档文件非空及精确标题；失败不启动昂贵构建。随后三个检查全部成功，`release` 才能执行。
- `release` 显式依赖 `preflight/go/scripts/apple`，没有 `always()` 或 `continue-on-error` 放行。只此 job 获得 `contents: write`；其他 job 仅 `contents: read`、checkout 不保留凭据。无 `pull_request_target` 或发布 Secrets 注入 PR。
- `apple` 成功后才准备既有产物名和归档正文，上传本次 run/attempt 的 artifact；`release` 先要求有效 artifact ID，仅下载 `apple` 输出的同次运行产物并严格核验下载摘要，不检出/执行仓库代码。未通过检查或缺少输入时无法发布。
- 不使用依赖/产物缓存，setup-go 与 Node 包缓存显式关闭；每次从当前源码重建 Core，避免跨 PR/发布缓存混用。没有路径过滤。
- 同事件/ref 的普通检查可被新提交取消，tag 不作运行中取消，不同版本不共用取消组。各 job 设置 5–45 分钟超时；失败保留相应日志、Swift xcresult，tag 候选产物和诊断均只保留 5 天，不上传签名配置、私钥或整个工作区。

这是工作流内部发布门禁，不等于已配置 GitHub 分支保护或必需状态检查。第 8B 阶段不触发远端 workflow，CI 运行态、托管 runner 上的恢复/模拟器启动及 artifact 传递尚待验证。Go 模块与 `go.sum` 未改动；CI 使用 `-mod=readonly` 并检查构建/测试后依赖文件没有漂移。`go.sum` 和 `go mod verify` 核对模块内容身份，不代替兼容性或依赖安全审查。

## 预编译依赖

开发者隧道模式链接 `Vendor/idevice/libidevice_ffi.a`（约 95 MB，附 MIT 文本）。当前文件身份及首次引入记录已核实，但精确上游版本、完整构建配方和传递依赖许可清单未恢复；167 个对象声明最低 iOS 18，与 App 的 iOS 15 声明冲突。该库只在设备目标链接，模拟器通过不能证明 iOS 15–17 兼容，链接警告也不等于旧系统必崩溃。校验和、对象元数据、许可/头文件比对、有限符号证据和待决选项统一维护在 [Vendor/idevice/README.md](../Vendor/idevice/README.md)，本阶段不替换库或改变支持范围。

## 搜索界面隔离验收

Debug 模拟器产物可用 `xcrun simctl launch <当前设备 UUID> com.paopaolabs.location-spoofer -uiPreviewEnabled YES --search-fixtures` 启动搜索夹具。先用 `xcrun simctl list devices available` 选择设备，不使用真实定位或第三方配置。

仅该显式参数启用合成搜索：输入「加载」保持挂起直至取消，「空结果」返回空列表，「失败」返回网络错误，其余地点名称返回六条长结果。坐标和地图链接仍走正常本地解析。此夹具只替代地点搜索；页面仍使用原生地图，不代表真实搜索服务或定位验收。Release 和真机产物不包含夹具请求实现。

实时活动预算依据 [Apple ActivityKit 文档](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)：静态 attributes 与动态 ContentState（含更新）合计不超过 4 KB。`RouteActivityPayload` 对真实类型的完整 JSON 包装采用 3800 字节预算，并在接管已有活动后复核不可变 attributes。模拟器载荷测试与扩展编译不能替代 ActivityKit 真机显示验收。

## 发布验收

1. `./build.sh` 通过并输出未签名 IPA
2. 用 Impactor 签名后安装到设备
3. 真机安装后，先配置 WiFi HTTP 代理 `127.0.0.1:8888`，再按检测结果完成 CA 下载、安装和信任
4. 环境检测通过后，选点开启虚拟定位
5. 打开 Apple 地图验证定位是否变为虚拟位置
6. 切换到开发者隧道模式：连上 LocalDevVPN、导入配对文件，验证定点推送和路线播放；退出路线或走完应留在当前虚拟点，停止虚拟定位后真实位置立即恢复
7. 若失败，查看诊断页的日志信息

开发者隧道后台回归：定点成功后切到 Apple 地图并保持至少 2 分钟，再锁屏至少 2 分钟，检查位置是否保持、回前台是否无需手动补写。随后切换到另一个点、播放并暂停路线、停止定位，确认没有旧点写回或停止后重新开启。日志中的「定位会话已补写」及写入间隔用于区分自动维持仍在运行与后台调度中断；模拟器测试无法替代这一真机验收。

开发者隧道网络切换回归：蜂窝 → 无公网 Wi-Fi 热点 → 换点 → 停止，检查失败后的重试及停止后无旧点补写。默认 `NWPathMonitor` 只记录路径观察及时间，不据此断言 Wi-Fi 客户端未关联或公网可用，也不减少隧道恢复预算；接口/端口检测只说明环境可尝试，成功必须来自设备定位写入。Apple 对 [`usesInterfaceType`](https://developer.apple.com/documentation/network/nwpath/usesinterfacetype(_:)) 的定义是路径可能使用的接口，包含隧道下层接口，不能作为 Wi-Fi 关联证明。

连接失败沿用最多 3 次延迟重试（0.5、2、4 秒），每次重读既有隧道候选端点；旧句柄写入失败先在设备串行队列释放，再检查操作代次后重建。网络恢复只维持最后成功位置；停止/清理撤销维持资格。日志只需核对「阶段」「失败类别」「网络来源」「快照时机」「路径观察时间」「重连」「定位意图有效」；不需要配对文件、身份、密钥或坐标。现有 FFI 头文件未提供同步握手/定位调用的超时、取消或健康查询 API；重试次数有界不等于底层调用总耗时有硬上限，模拟器假设备通过不证明 iOS 26.7 真机通道已恢复。

真实走动与路线收尾回归：慢写入期间连续迈步，待写队列应只保留最新累计位置；关闭走动丢弃未提交采样，等待已发送写入收尾并保留定位。暂停路线保持可恢复状态；退出、停止路线或自然走完只接管最终成功坐标，不发送 clear。等待期间发起换点、新路线、走动或停止定位，旧生产者不得更新新追踪或接管。已发送成功收据仍记录为设备最终位置；若新生产者未写入就停止，应由最新停止意图按该坐标收尾。同步设备调用不能强制取消，界面取消不代表设备副作用已撤销。

## 发布版本

当前 `project.yml` 的 App/扩展共用 `MARKETING_VERSION=1.2.0.1`、`CURRENT_PROJECT_VERSION=18`；两个 Info.plist 均引用这些字段。`version.txt` 的 latestVersion、待发布 tag `v1.2.0.1` 和归档 `docs/releases/v1.2.0.1.md` 对应。`minimumSupportedVersion=1.0.0` 是 App 更新版本下限，不是 iOS 版本。

四段营销版本与 [Apple 对 CFBundleShortVersionString 的三段整数格式要求](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring) 存在差异。本阶段保留既有自签发布策略，不改版本号或历史归档；构建/IPA 结构检查通过不证明 App Store 等渠道接受此格式，后续需由用户决定版本映射及渠道策略。CI 归档检查也不代替版本策略核销。

后续经授权发布时，先选定尚未打 tag、与产品版本一致的版本，生成并审阅归档；以下是操作说明，本阶段未执行：

```bash
VERSION='v<待发布版本>'
./Scripts/generate-release-notes.sh "$VERSION"
git add "docs/releases/$VERSION.md"
git commit -m "docs: 归档 $VERSION 发布说明"
git tag "$VERSION"
git push origin main "$VERSION"
```

归档文件根据“上一个版本标签到当前提交”的 commit subject 生成。GitHub Actions 会校验归档存在，并将文件正文直接作为 GitHub Release 内容；不会发布文档链接或缺失说明的占位 Release。

仍未核销：第 7 阶段最大字号末项操作、VoiceOver 实际朗读和 ActivityKit 真机表现；真实已签名 IPA 正向检查；真机定位、后台与锁屏；iOS 15–17 的加载/运行；Go 依赖内部 WebSocket 复制任务是否全部等待结束。CI 配置、本地构建和模拟器通过均不能关闭这些项目。
