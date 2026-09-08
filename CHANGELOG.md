# Changelog / 更新记录

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
