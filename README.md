# ClipDeck

> macOS 原生、简洁、高效的会话级剪贴板历史工具。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple) ![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white) [![CI](https://github.com/ifonly3/ClipDeck/actions/workflows/ci.yml/badge.svg)](https://github.com/ifonly3/ClipDeck/actions/workflows/ci.yml) ![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)

ClipDeck 是一款 **macOS 原生、简洁、高效** 的剪贴板历史小程序。它使用 SwiftUI 与 AppKit 构建，没有 Electron、没有第三方运行时依赖，专注于快速找回刚刚复制过的文字和图片。

<p align="center">
  <img src="docs/screenshots/history-text.jpg" alt="ClipDeck 主窗口展示文字历史、搜索、单击选择和内容预览" width="760">
</p>

<p align="center">
  <strong>复制 → ⌃⌥V → 单击或 ↑ / ↓ → Return</strong><br>
  <sub>鼠标和键盘都能完成选择；复制后可自动回到之前的应用。</sub>
</p>

## 为什么选择 ClipDeck

- **原生轻量**：SwiftUI + AppKit，空闲时几乎不占用 CPU。
- **文字与图片**：支持文字以及 PNG、JPEG、HEIC、GIF、TIFF 等 macOS 可识别的图片格式。
- **鼠标与键盘都顺手**：按 `⌃⌥V` 随时唤起，既可单击条目，也可使用 `↑` / `↓` 选择并按 `Return` 复制。
- **菜单栏常驻**：无需打开主窗口即可快速恢复最近内容。
- **会话级隐私**：历史只保存在内存中，退出 ClipDeck 后自动清空，不写入磁盘、不上传。
- **行为可控**：支持暂停记录、搜索、单条删除与撤销、清空确认、复制后返回原应用。
- **系统级启动**：使用 macOS 原生登录项，不依赖常驻 LaunchAgent。

## 界面一览

<table>
  <tr>
    <td width="60%" valign="top">
      <img src="docs/screenshots/history-image.jpg" alt="ClipDeck 图片历史和大图预览">
      <br><sub><strong>图片历史</strong>：识别常见图片格式，并在详情区展示预览与尺寸。</sub>
    </td>
    <td width="40%" valign="top">
      <img src="docs/screenshots/settings.jpg" alt="ClipDeck 原生设置窗口">
      <br><sub><strong>原生设置</strong>：控制记录、复制后关闭和登录时启动。</sub>
    </td>
  </tr>
</table>

## 常见使用场景

| 场景 | 你刚刚复制过的内容 | ClipDeck 能做什么 |
| --- | --- | --- |
| 开发调试 | 命令、报错、代码片段、配置值 | 不必反复切回终端或文档，唤起后直接选中再粘贴。 |
| 写作整理 | 标题、链接、引用、几段候选文案 | 保留最近上下文，随时找回前一版表述。 |
| 图片工作 | 截图、图标、设计参考图 | 在历史里看预览和尺寸，再选择需要的图片。 |
| 跨应用办公 | 浏览器中的资料、聊天内容、表格字段 | 在不同应用间连续复制，再按需要逐条取用。 |

例如，你可能先后复制了测试命令、分支名和一段配置：

```text
swift test -Xswiftc -warnings-as-errors
codex/clipboard-shortcuts
{"environment":"staging","region":"ap-east-1"}
```

按 `⌃⌥V` 后，直接单击目标条目或用方向键选择，再按 `Return`，无需重新寻找来源。

> ClipDeck 适合把最近复制的内容当作当前工作会话的短期记忆；它不是密码管理器、长期资料库或跨设备同步工具。

## 快速安装

要求：macOS 13 或更高版本，以及 Xcode Command Line Tools / Swift 6。

```bash
git clone https://github.com/ifonly3/ClipDeck.git
cd ClipDeck
./script/install_release.sh
```

脚本会构建 Release 版本、生成应用图标、进行 ad-hoc 签名和严格校验，然后安装到 `/Applications/ClipDeck.app` 并启动。

> 当前源码安装采用 ad-hoc 签名，适合本机使用。面向其他用户分发时，应改用 Developer ID 签名、Hardened Runtime 与 Apple notarization。

## 使用方式

1. 启动 ClipDeck 后，正常复制文字或图片。
2. 按 `⌃⌥V`，或点击菜单栏中的 ClipDeck 图标。
3. 搜索后单击目标条目，或使用方向键选择历史记录。
4. 按 `Return` 将内容复制回系统剪贴板。

主窗口快捷操作：

| 操作 | 快捷键 |
| --- | --- |
| 全局唤起 | `⌃⌥V` |
| 搜索 | `⌘F` |
| 鼠标选择 | 单击任意历史条目 |
| 选择上一条 / 下一条 | `↑` / `↓` |
| 复制所选内容 | `Return` |
| 删除所选内容 | `Delete` |
| 撤销删除 | `⌘Z` |
| 关闭窗口 | `Esc` 或 `⌘W` |

设置可从主窗口顶部的齿轮按钮进入，也可通过菜单栏菜单打开。

## 隐私与数据范围

剪贴板历史只保存在当前进程内存中。退出、注销、关机或重启后历史会清空，不会序列化到磁盘，也不会上传。清空 ClipDeck 历史不会清空当前系统剪贴板。

ClipDeck 不判断内容是否敏感；凡是可读取且未超过容量限制的文字和图片，都会按相同规则记录。窗口位置、“复制后关闭”等普通设置由 macOS `UserDefaults` 持久化，其中不包含剪贴板正文或图片。

默认保护限制：

- 最多保留 40 条历史。
- 单条文字最多 50 KB。
- 单张图片最多 32 MB、20 MP，单边不超过 12,000 像素。
- 图片历史总量最多 128 MB。

## 性能设计

- 以低频定时器观察系统剪贴板变化，避免忙轮询。
- 图片读取、格式识别、哈希和缩略图生成在后台 actor 中串行执行。
- 优先保留原始压缩图片数据，并缓存 320 px 预览图，避免列表重复解码大图。
- 对连续图片复制使用有界队列，防止大图阻塞后续文字或占满内存。
- 缓存搜索文本、菜单标题和时间文本，减少 SwiftUI 重绘与空闲唤醒。

## 本地开发

Debug 构建并运行：

```bash
./script/build_and_run.sh
```

构建与测试：

```bash
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
```

可选调试模式：

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --debug
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

Debug 脚本会停止已运行的 ClipDeck、构建并验证临时 `.app`，再使用普通 LaunchServices 打开它。项目明确禁止多实例；请勿使用 `open -n` 启动，否则多个应用进程的窗口可能重叠。

## 项目结构

```text
Sources/ClipDeck/
├── App/          # SwiftUI scenes 与应用入口
├── Models/       # 剪贴板内容模型
├── Services/     # 图片处理、热键、登录项与窗口协调
├── Stores/       # 剪贴板采集、历史与内存预算
├── Support/      # 通用辅助代码
└── Views/        # 主窗口、详情、菜单栏与设置界面

Tests/            # Swift Testing 回归测试
script/           # 构建、打包、签名和安装脚本
```

## 参与贡献

欢迎提交 Issue、功能建议和 Pull Request。提交代码前请运行完整测试，并尽量保持 ClipDeck 原生、克制、快速的产品方向。

## License

ClipDeck 使用 [MIT License](LICENSE) 开源。
