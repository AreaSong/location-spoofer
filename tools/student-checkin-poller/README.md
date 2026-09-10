# 学生待签到轮询（红方监控）

Mac 常驻脚本：用**学生身份**请求和小程序相同的「待签到列表」接口，发现新签到后通过 **Bark** 推到 iPhone。

微信小程序关掉后进程会停，所以轮询不写在小程序里。本工具也不改 Location Spoofer 的 WLOC 模块。

只用于你拥有或已获授权的后端。把学生 token 和 Bark key 放在环境变量或未提交的 `config.json` 里。

## 接口约定

脚本不写死业务 URL。用 `config.json` 把你的学生列表接口适配成下面这份结构。

示例响应：

```json
{
  "code": 0,
  "data": {
    "list": [
      {
        "id": "chk_1001",
        "title": "高等数学 第3节",
        "deadline": "2026-09-10 12:40:00",
        "signed": false
      }
    ]
  }
}
```

对应字段（可改）：

- `fields.listPath`：列表路径，默认 `data.list`
- `fields.idPath`：签到 id，去重键
- `fields.titlePath`：通知标题
- `fields.deadlinePath`：截止时间
- `fields.signedPath`：已签则跳过；列表本身已是待签到时可留空 `""`

鉴权：

- 请求头里用 `${STUDENT_TOKEN}` 注入学生 session
- HTTP `401` / `403`，或 JSON `code` 为未授权值时，Bark 提示 token 过期（默认 30 分钟冷却）

把真实 URL、请求方法（GET/POST）、header、body 填进 `request`。字段对不上时用 `--dump` 打印原始 JSON 再改 path。

## 准备

1. iPhone 安装 [Bark](https://github.com/Finb/Bark)，复制设备 key。
2. 复制配置：

```bash
cd tools/student-checkin-poller
cp config.example.json config.json
```

3. 编辑 `config.json` 的 `request.url` 和 `fields`。
4. 导出密钥（不要写进已提交文件）：

```bash
export STUDENT_TOKEN='学生登录后的 token'
export BARK_DEVICE_KEY='Bark 设备 key'
```

## 运行

先拉一次原始 JSON，核对字段：

```bash
python3 poller.py --config ./config.json --dump
```

单次轮询（确认 Bark 能收到）：

```bash
python3 poller.py --config ./config.json --once
```

常驻（终端保持打开，或自己用 `tmux`/`launchd`）：

```bash
python3 poller.py --config ./config.json
```

默认每 15 秒请求一次，最短 5 秒。同一 `checkinId` 只推一次；从列表消失（已签或过期）后会从已告警集合删除，下一场相同 id 仍会提醒。

`config.json` 和 `state.json` 已加入本目录 `.gitignore`。

## 测试

```bash
python3 -m unittest test_poller.py
```
