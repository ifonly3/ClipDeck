# Changelog / 更新记录

## 1.5.0 (build 11) — 2026-10-09

- Skip content that apps mark as concealed, transient, or auto-generated (nspasteboard.org), and let users ignore apps; Passwords and Keychain Access are ignored by default. Skipped content is never read. / 遵守 nspasteboard.org 约定，跳过标记为机密、临时或自动生成的内容，并支持按应用忽略（默认忽略“密码”和“钥匙串访问”）；被跳过的内容不会被读取。
- Restore formats in their original order and stop adding plain text that copied images never had. / 按原顺序恢复各格式，不再给复制的图片添加原本没有的纯文本。
- Release rebuildable PNG/TIFF compatibility data from older images before evicting them, and rebuild it on copy, so more images fit in history. / 历史预算紧张时先释放较早图片可重建的 PNG/TIFF 兼容数据，复制时再重建，能保留更多图片。
- Make the global shortcut customizable, register it at launch, and let it toggle the history window. / 全局快捷键可自定义、启动即生效，再按一次可关闭历史窗口。
- Launch at login is now opt-in for new installs; existing setups are kept. / 新安装默认不开启登录时启动，已有设置保持不变。
- Faster multi-word search, linear HTML text extraction, double-click to copy, dates for older items, correct ordering after undo, and bounded file availability checks. / 搜索更快并支持多关键词，HTML 文字提取改为线性算法，双击即可复制，较早条目显示日期，撤销后按时间顺序恢复，文件可用性检查不再无限阻塞。
- Support newer SwiftPM resource bundle layouts in packaging, localization lookup, and CI. / 打包、本地化查找和 CI 兼容新版 SwiftPM 的资源包结构。

## 1.4.1 (build 10) — 2026-09-08

- Show the installed version beside the history heading and in Settings, including the build number. / 在历史标题旁和设置底部显示真实安装版本及构建号。
- Publish the bilingual website and a new immutable download filename. / 同步发布双语官网，使用独立版本文件名保留旧安装包。

## 1.4.0 (build 9) — 2026-09-08

- Fix the collapsed menu-bar history and add direct detail navigation. / 修复菜单栏历史折叠空白，并增加对应详情入口。
- Capture and restore grouped text, URL, rich text, image, PDF, and Finder file-reference content. Preserve whitespace and available original formats. / 按组记录和恢复文字、链接、富文本、图片、PDF 与 Finder 文件引用，保留空白和可用原格式。
- Correct image orientation and add a separate high-resolution detail preview. / 修正图片方向，增加独立高清详情预览。
- Bound history/undo memory, clear related undo when clearing history, and prevent delayed images from resurrecting deleted entries. / 限制历史与撤销容量，清空时移除相关撤销，防止延迟图片复活已删除记录。
- Preserve app focus and report unsupported or partial captures. Keep AppKit pasteboard access on the main thread for correctness; expensive image processing remains in the background. / 修复焦点交互，明确不支持或部分捕获的情况；原生剪贴板访问保持主线程安全，图片重处理继续在后台执行。

Known limitation / 已知限制：a slow synchronous clipboard provider can still delay raw-data reads / 同步剪贴板来源响应很慢时，原始数据读取仍可能短暂阻塞界面。
