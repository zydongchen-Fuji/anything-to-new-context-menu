# anything-to-new-context-menu

An agent skill (Claude Code / Agent Skills format) plus scripts that put **any** right-click item onto
the top level of the **Windows 11 context menu**, no more digging through *Show more options*.

- Legacy shell extensions (e.g. *Combine Files In Revu*, *在 Acrobat 中合并文件*): the new item forwards the click to the original extension, so it behaves identically.
- Plain commands (e.g. *Open in VS Code*): the new item launches a program with the selected paths.
- Native C++ handler (~5 ms load), one signed sparse MSIX per item, pinned to the main menu (not the *App extensions* submenu).

**Why:** on newer Windows 11 builds (26220+, 26H2 Insider) the well-known `{86ca1aa0-…}` registry tweak that restored the classic menu no longer works
([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/6052587/registry-to-restore-the-old-right-click-context-me)),
and legacy entries stay buried under *Show more options*. Instead of fighting the new menu, this puts the entries you actually use into it.

## Use as a skill

Copy this folder to `~/.claude/skills/anything-to-new-context-menu/` (or your agent's skills directory) and ask, e.g.
"put *Convert Files In Revu* on the new right-click menu". The agent follows [SKILL.md](SKILL.md).

## Use by hand (PowerShell, Windows 11 x64)

```powershell
# 1. find what you want to bring over
powershell -ExecutionPolicy Bypass -File scripts\probe.ps1 -Path C:\some\file.pdf -Filter Revu

# 2. describe it (see examples\), then build (downloads llvm-mingw + SDK BuildTools on first run)
powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Config examples\bluebeam-revu.json

# 3. trust <installDir>\ContextMenuBridge.cer: Local Machine > Trusted People (manual, admin)

# 4. install and pin to the main menu
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -InstallDir $env:USERPROFILE\NewContextMenu
```

Uninstall: `scripts\uninstall.ps1 -InstallDir <dir> -RemoveFiles`, then delete the certificate in `certlm.msc` > Trusted People.

## 中文说明

把任何只在“显示更多选项”里的右键菜单项（或任意命令）放到 Windows 11 新右键菜单的首页。
流程：`probe.ps1` 找到菜单项 → 写 JSON 配置 → `build.ps1` 编译并签名 → 手动把证书导入“本地计算机 › 受信任的人” → `install.ps1` 安装并置顶。
详细原理和踩过的坑见 [SKILL.md](SKILL.md)。

## License

MIT
