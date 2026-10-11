# 技能包

6 个面向 PYNQ / Zynq UltraScale+ 用户的通用技能，不依赖本作品的硬件设计（OFDM、AD9361、网络都不涉及）。
格式参照 AMD 官方的 [AMD Ross™ Agentic AI Assistant](https://github.com/xilinx/ross-ai-assistant) 中的技能：每个目录一个 `SKILL.md`（Agent Skills 格式，可放进
`.claude/skills/`、`.cursor/skills/` 或 Codex 的技能目录），正文是写给 AI 代理的英文操作手册，包括：

- 触发条件（frontmatter 的 `description`）、Purpose / Expected outcome / Prerequisites、When to Use / When NOT；
- DO's / DON'Ts，以及取自真实失败的反例（Anti-pattern）；
- 带检查点的分步流程，每步有 VERIFY；改系统、改用户代码之前有 USER GATE，代理必须停下来等用户确认；
- 参考数据（注明测试条件）、最后的汇总表、附带脚本。

| 技能 | 解决的问题 | 附带文件 |
|---|---|---|
| [`mali400-offscreen-gles`](mali400-offscreen-gles/SKILL.md) | ZU EG/EV 片上 Mali-400 GPU 在 PYNQ 下没有驱动，X 里只有软件渲染：判断能否用开源 lima 驱动，哪些渲染路径走不通，Python 下 GBM + EGL 离屏 GLES2 渲染与读回 | `probe.sh`、`gles_offscreen.py`、`prompts.md` |
| [`pynq-out-of-tree-kernel-module`](pynq-out-of-tree-kernel-module/SKILL.md) | 镜像内核没开的驱动（GPU、hid-multitouch、USB 网卡等）在板上补编成外部模块；内核 gcc 12 与板上 gcc 11 不一致时不破坏系统构建树 | `gen_arch_headers.sh`、`build_modpost.sh`、`gcc-wrap` |
| [`pynq-systemd-autostart`](pynq-systemd-autostart/SKILL.md) | 程序上电自启、脱离 Jupyter 和 PC：排在加载 base.bit 的 `bootpy.service` 之后、venv、等待 X / 外设、overlay 自检重载、SIGTERM 干净退出、断电重启验证 | `pynq-app.service`、`app_skeleton.py` |
| [`pynq-offline-packages`](pynq-offline-packages/SKILL.md) | 板子不能上网时装 apt 包 / pip wheel：在板上按自身索引解析文件清单，PC 下载并校验，离线安装，在 PYNQ venv 中验证 | `list_uris.sh`、`fetch_debs.py`、`install_debs.sh` |
| [`pynq-local-display-gui`](pynq-local-display-gui/SKILL.md) | 在板子自带的 DP/HDMI 屏（含 USB 触摸屏）上跑全屏 PyQt 界面：显示栈探测、板上离屏截图与文字溢出检测、A53 上的 CPU 预算、触摸长按 / 拖动 | `display_probe.sh`、`offscreen_shots.py`、`evdev_touch.py` |
| [`pynq-dma-stale-transfer`](pynq-dma-stale-transfer/SKILL.md) | AXI DMA 接收在超时、进程被杀后遗留传输，下一次 / 下一个进程卡在 `wait()`；pynq 的 `stop()` 撤不掉，用 DMACR 软复位 | — |

只适用于本系统的经验（AD9361 配置、杂散排查、时延测量等）和踩坑清单见 [`report/notes/project_skills/`](../report/notes/project_skills/)。

## 测试方法

为了排除开发会话上下文和模型的影响，每个技能都在**全新会话、全新工作区**里由另外的代理和模型执行，共两套环境：

| 环境 | 代理 | 模型 | 技能目录 |
|---|---|---|---|
| A | Cursor CLI（`cursor-agent -p`） | Grok 4.7 Extra High | `.cursor/skills/` |
| B | CodeBuddy CLI 2.164（`codebuddy -p`） | DeepSeek V4.1 Flash | `.codebuddy/skills/` |

1. 新建空工作区，只放该技能和用户场景所需的文件（如一段有问题的程序），不带本仓库任何内容；板卡登录用放在工作区里的
   一次性私钥副本（预先收紧权限），代理接触不到真正的 `~/.ssh` 私钥；
2. 提示词用普通用户口吻、不提技能名，同时检验能否自动触发；两套环境用同一组提示词；
3. 读取会话转写，逐项核对：是否读了技能、是否按步骤执行、VERIFY 是否做了、是否在 USER GATE 停下、结果是否正确、
   板上是否留下文件、系统文件是否被改动（如内核构建树 `.config` 的 SHA-256）、本机私钥是否完好。
   发现的问题改进技能后，在新会话里重跑，直到通过。最终版技能用环境 A 把 6 个场景完整重测了一遍。

被测板卡：PYNQ-ZU（xczu5eg），PynqLinux 3.0（Ubuntu 22.04），pynq 3.1.1。

| 技能 | 测试场景（用户提示词大意） | A：Grok 4.7（最终版技能） | B：DeepSeek V4.1 Flash |
|---|---|---|---|
| `mali400-offscreen-gles` | "板子上画 3D 曲面很卡，看看 GPU 能不能用，能用就跑个测试看效果和速度" | 通过：区分 lima / zocl 节点，冒烟测试 `Mali400`，940×430 读回 51 ms，未改系统，已清理 | 通过：同样结论，并自行做了网格密度扫描（读回约 49 ms，与几何量无关） |
| `pynq-out-of-tree-kernel-module` | "触摸屏只能点击，内核没开 CONFIG_HID_MULTITOUCH，能不能不重编内核单独编出 hid-multitouch"（技能里的例子是 lima，测试换了驱动以检验通用性） | 通过：编出 `hid-multitouch.ko`，vermagic 一致，`.config` 不变，核对了设备 modalias；在"是否加载"处停下并写明 103 MB 残留及删除命令 | 通过：同样结果 |
| `pynq-systemd-autostart` | "采集程序手动能跑，想上电自动运行" | 通过：识别 bootpy 加载 base.bit、pynq 只在 venv；程序加 SIGTERM / 自检 / DMA 复位；unit 通过 `systemd-analyze verify`；指出程序文件缺失、PL 被现有服务占用；在"是否安装启动"处停下 | 通过（第 1 轮发现阻塞后未产出 unit 就提问，补充规定后先做好本地修改再提问） |
| `pynq-offline-packages` | "板子不能上网，程序要用 paho-mqtt，帮我弄到板上" | 通过：apt 1.5.1 与 PyPI 2.1.0 API 不兼容，提问工具被跳过后仍停下请用户选择，未下载未安装，已清理 | 通过：首先发现两个版本 API 不兼容（已吸收进技能）；第 1 轮提问前未清理 |
| `pynq-local-display-gui` | "界面要放到板子的 1024×600 小屏上，我看不到屏幕，先检查排版" | 通过：板上离屏截图，报出 3 处问题（如按钮要 139 px 只有 112 px），测了 CPU，在"是否修改代码"处停下，未改用户文件 | 通过：同样结果，另指出触摸长按需 hid-multitouch |
| `pynq-dma-stale-transfer` | "Ctrl-C 后再运行就卡在 `wait()`，外部触发不是一直有" | 通过：超时轮询 + 超时 / 启动 / 退出三处 DMACR 软复位，mock 验证调用顺序 | 通过：同样实现，mock 验证 |

环境 B 的测试在技能最后两次修订（下述最后三条规则）之前进行。

测试中发现并已修正的问题：探测命令在 PowerShell 下引号失效（改为随技能附带脚本、`scp` 后执行）；临时文件残留在板上
（每个技能规定在汇报、GATE 和任何提问之前清理，截图脚本不再生成 `__pycache__`）；GATE 提问原样输出英文（改为用用户的语言提问）；
用户只要求检查时代理直接改了代码（加了 GATE）；引用其他技能时代理到处寻找（关键做法直接写进正文）；
删除了不是本次创建的目录、在 `/tmp` 中转、汇报漏掉板上残留（规定独立工作目录并把残留写进 GATE 提问）；在 Windows 上克隆内核仓库因保留文件名 `aux.c` 失败（改为按文件下载）；
搜索工作区之外的目录（限定在工作区和用户指定路径）；遇到阻塞就提前停下（规定先完成本地可做的步骤再提问）。
最终版测试前的一轮中还发现了更严重的问题，已在技能和测试方法中修正：代理把"提问被跳过"（非交互模式）当成同意，继续执行
（规定没有回答即为否定）；拼写 `scp` 命令时把私钥路径当作目的地，覆盖了本机私钥（规定拷贝命令必须明确写出远程一端、
不得读写 `~/.ssh`；测试改用工作区内的一次性私钥副本）；为结束卡住的 ssh 按名字杀掉了本机所有 ssh 进程（规定只能按精确 PID
结束自己启动的进程）。
