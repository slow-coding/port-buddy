# PortBuddy

macOS 菜单栏小工具：列出**你自己的进程**在监听哪些 TCP 端口、每个端口背后是哪个工程或应用，点两下就把进程终止。不用再敲 `lsof -i :3000` 再 `kill`。

**[English README](README.md)**

<p>
  <img src="docs/panel-dark.png" width="330" alt="深色外观下的面板">
  <img src="docs/panel-confirm.png" width="330" alt="筛选到某一个工程，终止按钮等待第二次点击">
</p>

<p>
  <img src="docs/settings.png" width="330" alt="设置：全局快捷键与开机自启">
</p>

界面跟随系统语言（中文 / 英文）。

## 它做什么

- **运行最久的排最上面。** 列表按进程已运行时长排序，不按端口号：三天前起的那个服务在最上面一眼能看到，一分钟前刚起的最下面。
- **列出你自己的进程在监听的所有端口**，名字取「哪个工程 / 哪个应用」（`shop-web`、`api`、`Docker`），不是干巴巴的 `python3.14`。取名顺序：进程所在的 `.app` 包名 → 启动时的工作目录最后一段 → 可执行文件名。
- **按类筛选**。一个工程往往占好几个端口（同一类会重复出现）。点某一行的名字就把列表筛成那个工程 / 应用，再点一次那个名字（或在下拉里选**全部**）就取消。下拉里带着每一组有几个。筛选状态在应用运行期间一直保留，重启后回到全部。
- **系统进程完全不列**。ControlCenter、rapportd 这些不提权杀不掉，就不占位置了。
- **终止**：第一次点击把胶囊点亮成红色「确认」，第二次点击发 `SIGTERM`；第二次点击时按住 ⌥ 发 `SIGKILL`。没有弹窗，3 秒不动自己恢复。
- **全部终止**：同样两段式，作用于**当前列表里**的每一行 —— 筛了某个工程，就是终止那个工程。
- **每行末尾有已运行时长**（`1h2m`、`4m`）。
- **全局快捷键**（齿轮图标，或右键 → 设置）在任何地方都能唤出面板。面板**不抢键盘焦点**：不会把你从正在打字的地方拽出来。设置里还有外观（跟随系统 / 浅色 / 深色）与开机自启。
- **点端口号**复制 `http://localhost:端口`。
- 菜单栏徽标 = 你自己在监听的端口数。

不需要 sudo、没有常驻后台、没有依赖、不联网。

## 安装

需要 macOS 13 以上，以及 Xcode 命令行工具（`xcode-select --install`）。

```sh
git clone https://github.com/slow-coding/port-buddy.git
cd port-buddy
make            # 编译成通用二进制（arm64 + x86_64），落在 build/PortBuddy.app
make install    # 复制到 /Applications 并向 LaunchServices 注册
```

Release 页里的安装包一样用：双击 `PortBuddy-<版本>.dmg`，把 `PortBuddy` 拖进 `/Applications`（也有 `PortBuddy-<版本>.zip`，想解压也行）。应用只做了 ad-hoc 签名、没有公证，从网上下载的副本第一次打开要右键 → 打开。

开机自启：系统设置 → 通用 → 登录项 → 把 PortBuddy 加进去。

## 怎么用

| 操作 | 结果 |
| --- | --- |
| 点菜单栏图标 | 打开面板 |
| 设置里绑的快捷键 | 在 macOS 任意位置唤出同一个面板 |
| 面板顶部的下拉 | 只看某一个工程 / 应用 |
| 点某一行的名字 | 同样筛选到它；再点一下取消 |
| **终止** | 点亮，第二次点击发 `SIGTERM` |
| 第二次点击时按 ⌥ | 改发 `SIGKILL` |
| **全部终止** | 点亮，第二次点击终止列表里全部 |
| 点端口号 | 复制 `http://localhost:端口` |
| 齿轮图标 / 右键 → 设置 | 外观、快捷键、开机自启 |
| 右键图标 | 刷新 / 设置 / 退出 |
| 面板打开时按 ⌘Q | 退出 |

面板打开时每 2 秒刷新一次，关着时每 5 秒刷新一次（徽标要跟着变）。

## 命令行

```
PortBuddy                        启动菜单栏应用
PortBuddy --json                 每个监听套接字一行 JSON
PortBuddy --kill 3000            终止监听 :3000 的进程
PortBuddy --kill 3000 --force    发 SIGKILL
PortBuddy --kill-all --dry-run   只列出「全部终止」会杀掉哪些
PortBuddy --kill-all             终止「我的」全部
PortBuddy --version
```

`--json` 每行一个对象，直接喂给 `jq`；与面板不同，它把系统进程也一并报出来：

```json
{"port":3000,"pid":40042,"name":"website","command":"python3.14","argv":"python3 -m http.server 3000","cwd":"/Users/me/demo/website","path":"/opt/homebrew/bin/python3.14","uid":501,"system":false,"hosts":["127.0.0.1"]}
```

## 它不做什么

- **不管 UDP**，只看 TCP 监听。
- **面板不列系统进程**。`--json` 里还有，但它们只能提权才能杀，面板就不显示了。
- **看不到别人的进程**，也不会提权；不属于你的进程列不出来也杀不掉。
- **没有常驻后台服务。** 快捷键走 Carbon 的 `RegisterEventHotKey`，不需要辅助功能权限。
- **没有历史、没有日志、没有统计、不联网。**

## 怎么实现的

- 套接字表来自 `lsof -nP -iTCP -sTCP:LISTEN -Fpcun`，命令行来自 `ps -o pid=,command=`，可执行文件路径与工作目录来自 `proc_pidpath()` / `proc_pidinfo(PROC_PIDVNODEPATHINFO)`。
- 行名取：`.app` 包名（`…/Google Chrome.app/…` → `Google Chrome`）→ 工作目录最后一段（`…/code/shop-web` → `shop-web`）→ 可执行文件名。说不出信息的工作目录（家目录、`/`、临时目录）直接跳过。
- 筛选按这个名字分组；运行时长来自 `proc_pidinfo(PROC_PIDTBSDINFO)`（进程启动时刻）。
- 终止就是 `kill(pid, SIGTERM)` 或 `SIGKILL`，只对你自己拥有的、且不在 `/System`、`/usr/libexec`、`/usr/sbin`、`/usr/bin` 下的进程生效。

## 开发

```
make bundle   编译出 build/PortBuddy.app
make run      编译并启动
make icon     从 Sources/PortGlyph.swift 重新生成 Resources/AppIcon.icns
make check    扫描器自检（JSON）
make zip      打 build/PortBuddy-<版本>.zip
make dmg      打 build/PortBuddy-<版本>.dmg（app + Applications 快捷方式）
make clean
```

文件：`Sources/PortScanner.swift`（套接字表 → 行）、`Sources/PortPanel.swift`（弹层内容、筛选、两段式终止按钮）、`Sources/PortGlyph.swift`（菜单栏与 App 图标共用的图形）、`Sources/AppDelegate.swift`（状态栏、刷新、动作）、`Sources/CLI.swift`、`Sources/L10n.swift`。

面板可以完全不用鼠标来验证，终止按钮就是这么测的：

```
# 打开弹层、真点两次终止按钮、检查套接字消失
python3 -m http.server 8611 &
./build/PortBuddy.app/Contents/MacOS/PortBuddy --selftest-click 8611
```

设置窗与快捷键同样可以无人值守地验：

```
./build/PortBuddy.app/Contents/MacOS/PortBuddy --settings    # 打开模态设置窗
./build/PortBuddy.app/Contents/MacOS/PortBuddy --hotkey      # 设成 ⌥⌘P 并打印 Carbon 是否接受
```

截图也走同一个门：

```
./build/PortBuddy.app/Contents/MacOS/PortBuddy --show --debug-frame /tmp/f.txt \
    --appearance dark --arm 3000 --filter website
# 把弹层窗口 id 写进 /tmp/f.txt
screencapture -x -l <窗口 id> panel.png
```

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。
