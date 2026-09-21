# DeepSeekStats

DeepSeekStats 是一个 macOS 菜单栏应用，用于查看 DeepSeek API 余额及最近的余额变化。它会定时获取官方余额接口，并在本机保存最多 30 天的历史记录。

## 系统要求

- macOS 14 或更高版本
- Swift 6.3 工具链（从源码构建时）
- 有权访问余额接口的 DeepSeek API Key

## 使用

启动应用后，点击菜单栏中的 `DS` 图标打开余额弹窗。弹窗右上角可以立即刷新或打开设置；右键点击菜单栏图标可刷新、打开设置、切换登录启动或退出应用。

首次使用时，在设置窗口输入 API Key 并点击“验证并保存”。Key 验证成功后保存在 macOS 系统钥匙串，不会写入历史文件或日志。

应用仍兼容以下开发/旧配置来源，读取顺序为：

1. 系统钥匙串
2. `DEEPSEEK_API_KEY` 环境变量
3. `~/.hermes/.env` 中的 `DEEPSEEK_API_KEY`

检测到旧 `.env` Key 时，应用会将它复制到钥匙串，但不会自动删除原文件。确认设置页显示“已保存在系统钥匙串”后，可自行删除旧明文配置。

## 状态含义

- 灰色圆点：正在刷新
- 绿色圆点：显示最新余额
- 黄色圆点：网络异常，当前显示本地缓存
- 红色圆点：未配置 Key 或刷新失败且没有缓存

缓存状态会显示最后成功更新时间。刷新失败不会把余额重置为零，也不会产生虚假的消费记录。

## 本地数据

余额历史保存在：

```text
~/Library/Application Support/DeepSeekStats/history.json
```

历史按币种隔离，同一币种每分钟最多保存一个样本，自动删除 30 天前的数据。旧版 UserDefaults 历史会在首次成功读取时迁移。可在设置窗口中清除历史。

刷新间隔支持 1、5、15 和 30 分钟，默认 5 分钟。

## 构建与测试

运行测试：

```bash
swift test --disable-sandbox
```

仓库已配置 GitHub Actions（`.github/workflows/ci.yml`），推送或提交 PR 时会自动执行同一套测试。

生成本地签名的 Release 应用和 zip：

```bash
./build.sh
```

产物位于 `dist/`。将 `DeepSeekStats.app` 复制到 `/Applications` 后启动。登录启动使用 macOS `SMAppService`，建议从 `/Applications` 中运行应用后再开启。

当前打包采用 ad-hoc 签名，适合个人本机使用，不包含 Developer ID、公证或自动更新。

## 故障排查

- “API Key 无效”：在设置中重新验证并保存 Key。
- 显示黄色状态：应用正在使用最近一次成功余额；检查网络后手动刷新。
- 登录启动无法开启：确认应用位于 `/Applications`，并检查“系统设置 → 通用 → 登录项”。
- 历史文件损坏：应用会将其重命名为 `history.corrupt-<时间戳>.json`，然后从下一次成功刷新重新记录。
- 仅安装 Command Line Tools 时，首次测试会下载固定版本的 `swift-testing` 与 `swift-syntax`，耗时可能较长。
