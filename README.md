# CustomKeyMapper (KOReader plugin)

把「特定输入设备」的按键绑定到自定义 KOReader 功能——参考
[kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough) 的
「按下按钮 → 记录键码 → 绑定到 KOReader 动作」思路。
目前主要用于 Kindle(PW3)上的 Skycolor 翻页笔等外接 USB HID 设备(USB-A 接收器 +
Micro-USB OTG 转接)。

## 功能

一个**带设置面板**的键位绑定插件,参考 kindle-hid-passthrough 的交互,**不改 KOReader 源码**:

- **选设备**:从 `/proc/bus/input/devices` 列出的输入设备里挑一个。
- **Map a button…**:点一下后保持菜单打开,按一次设备按钮即可自动捕获键码;**若该键已有映射,会直接覆盖原映射**。
- **Choose a key…**:从**全量键名列表**里直接挑一个键(常用键 `UP/DOWN/PAGEUP/PAGEDOWN/...` 排在最前,其余所有键盘/媒体/按键也都列出),不用手动按。
- **动作选择器**:只用 KOReader **Dispatcher 动作**(翻页用 `page_jmp` ±1 等,`Paging / Display` 排最前),后面是 KOReader 的**全部无参 Dispatcher 动作**,按 `General / Reader / Screen & lights / Device / File browser` 分组。**不再使用直接 event 绑定**。
- **改动作 / 删除**:对已存在的映射项,点进去可 `Change action…` 或 `Delete mapping`。
- **持久化**:保存在 KOReader 设置里(`settings.reader.lua` 的 `custom_key_mapper`),重启/更新不丢。
- **吞掉重复/释放**,只在下按时触发一次,避免与 `externalkeyboard` 双触发。

> 不再需要手改 `keymap.lua`。它只在**首次运行**作为初始默认(`103→上一页`、`108→下一页`、`15→全屏刷新`)种到设置里。

## 仓库结构

```text
customkeymapper.koplugin/
├── main.lua                 # 插件入口:菜单、状态、按键回调
├── _meta.lua                # 插件元信息(KOReader 插件列表用)
├── keymap.lua               # 首次运行的默认键位(之后存进 KOReader 设置)
├── keynames.lua             # 键名表
├── koreader_actions.lua     # 由 KOReader dispatcher 生成的动作列表
├── ckm.map                  # .so 导出符号白名单(只导出 ckm_*)
├── lib/
│   ├── ckm_input.so         # 已提交的原生产物(加载内核模块 / 扫设备)
│   ├── ckm_h.lua            # 与 .so 对应的 FFI 声明
│   ├── ckm_hotplug.lua      # 热插拔与设备打开
│   ├── ckm_ui.lua           # 设置面板
│   ├── ckm_helpers.lua      # 不依赖 KOReader 的小工具
│   ├── customkeymapper_i18n.lua
│   └── modules/             # 已提交的 hid.ko / usbhid.ko / mousedev.ko(+来源说明)
├── src/ckm_input.c          # lib/ckm_input.so 的源码
├── scripts/                 # build-ckm.sh / check-artifacts.sh
├── locale/                  # en.po / zh_CN.po
└── librime_koreader/        # 构建期 submodule(交叉编译工具链,装机不用带)
```

## USB HID 自加载 + 热插拔

Kindle 内核不内置 USB HID 输入支持:KOReader 启动时扫一次输入设备,而 `/dev/input/eventN`
只有在 `hid`/`usbhid` 模块加载后才会出现。本插件把这两件事都接管了,不再依赖 KindleLazy
在开机时加载模块:

- **自加载内核模块**:插件 `init` 时,`lib/ckm_input.so` 依次 `insmod` 插件自带的
  `lib/modules/hid.ko → usbhid.ko → mousedev.ko`(幂等,已加载则跳过)。
- **补开机漏检**:加载模块后重新扫描输入设备,并额外打开 `/proc/bus/input/devices` 里
  列出的**按键类 USB 设备**(如翻页笔),以及设置里选中的 `device`。
- **热插拔**:监听 KOReader 的 `EvdevInputInsert/Remove` 事件,拔/插后自动开/关对应
  event fd;同时带一个轻量的 `/proc` 轮询兜底(每 2 秒),即使内核不掉
  USB HID 的 uevent 也能正常识别拔插。
- 仅 `Device:isKindle()` 下启用,不影响其它平台;与 `externalkeyboard` 并存时靠
  `Input.opened_devices` 去重,不改其行为。

### 编译 `lib/ckm_input.so`

交叉编译工具链(Zig 包装器 + 每个 target 的 ABI)来自随仓库固定的 `librime_koreader`
submodule(pin 见 `.gitmodules`),所以本插件与 rime 插件用**同一套 ABI**:
kindlepw2、softfp、cortex_a9、glibc 2.12、`-Wl,-z,lazy`。

submodule 不会随普通 `git clone` 自动下载,先初始化:

```sh
git clone --recurse-submodules <repo>     # 新 clone
git submodule update --init --recursive   # 已经 clone 过(或忘了加参数)
```

(`librime_koreader/` 里只有 `.git` 占位、没有 `targets/` 就是没初始化;构建脚本会直接
把这行命令提示出来。)

然后构建:

```sh
./scripts/build-ckm.sh    # 产物 lib/ckm_input.so
```

只支持 **PW3(kindlepw2)** 一种目标:插件自带的内核模块是 `3.0.35-lab126` 的,换机型
`.ko` 根本加载不了,所以不提供 kindlehf 之类的构建——传别的 target 会被直接拒绝。

需要 zig(实测 0.16.0)与 `llvm-readelf`/`llvm-strip`(`brew install zig llvm`;脚本也会
自己找 `/opt/homebrew/opt/llvm/bin`)。若你有别处的 checkout,用
`RIME_PROJ=/path/to/librime_koreader` 覆盖;默认查找顺序是 `RIME_PROJ` →
`./librime_koreader` → `../../rime/librime_koreader`。

产物 `lib/ckm_input.so` 只依赖 libc,只导出 `ckm_*` 符号(见 `ckm.map`),并由
`librime_koreader/scripts/verify-elf.sh` 校验 ABI 与 GLIBC 上限。插件自带的
`lib/ckm_h.lua` 是 FFI 声明,必须与 C 保持一致。

### `.so` / `.ko` 产物随仓库提交

`lib/ckm_input.so` 和 `lib/modules/*.ko` **都在仓库里**,clone 下来直接可用:不用先编译,
也不用再去别的项目捞内核模块。

```sh
./scripts/check-artifacts.sh             # 校验 .ko 哈希 / .so ABI / FFI 与 C 是否同步
./scripts/check-artifacts.sh --rebuild   # 再就地重编一次,逐字节比对(需要 zig)
```

改了 `src/ckm_input.c`(或 `lib/ckm_h.lua` 的 FFI 声明)之后,必须重跑
`./scripts/build-ckm.sh kindlepw2` 并把新的 `lib/ckm_input.so` 一起提交——否则仓库里的
产物就是过期的。

`.ko` 的来源、vermagic 与替换步骤见 `lib/modules/README.md`:它们匹配 PW3 内核
`3.0.35-lab126`,换机型/换内核必须换成该内核的模块,否则 KOReader 只会记录
`insmod ... failed`,设备不会出现。

## 安装

```sh
cp -r customkeymapper.koplugin /mnt/us/koreader/plugins/
```

`librime_koreader/` 只是构建期工具链,装机时不必带上
(`rsync -a --exclude librime_koreader customkeymapper.koplugin /mnt/us/koreader/plugins/`)。

重启 KOReader 后,打开 **⚙ 设置 → Custom key mapper**,即可用面板:选设备、`Map a button…` 按键捕获、选动作、改/删映射。

## 发布(release)

```sh
./scripts/package-release.sh    # PW3/kindlepw2;版本号取自 _meta.lua
```

产物在 `dist/release/`:`customkeymapper-<target>-v<version>.tar.gz` 与同名 `.sha256`。
包内顶层就是 `customkeymapper.koplugin/`,直接解压进 `/mnt/us/koreader/plugins/` 即可。

- 打包前会跑 `scripts/check-artifacts.sh`(`.ko` 哈希、`.so` ABI、导出符号与 FFI 是否一致),
  产物漂移就直接失败,不会出包;
- 包内含 `MANIFEST.sha256`,在插件目录里 `shasum -a 256 -c MANIFEST.sha256` 可整体校验;
- `librime_koreader/`、`.git`/`.gitmodules`、`dist/` 都不会进包;
- `CKM_LIBRARY=/path/to/xxx.so` 可指定别的构建产物(仍须是 kindlepw2 ABI),包内一律落在
  `lib/ckm_input.so`(插件固定按这个路径加载);`CKM_VERSION` 可覆盖版本号。

## 国际化

- `lib/customkeymapper_i18n.lua`:解析插件自带 `locale/<lang>.po`,检测语言(用
  `settings.reader.lua` 的 `language`)。**msgid 用 `group.key` 分组**;
  释义顺序 = 当前语言 `.po` → `en.po`(英文回退)→ KOReader `gettext`(核心动作标题)。
  **不改 KOReader 源码、不动全局 gettext**。
- `locale/en.po`:英文源串(回退语言);`locale/zh_CN.po`:中文翻译。
  **新增语言**:复制 `locale/en.po` → `locale/<lang>.po`,填 `msgstr` 即可,无需改代码。
- 核心动作标题(`Full screen refresh`、`Toggle night mode`…)来自 KOReader 自身翻译,自动跟随界面语言。

## 依赖

- 越狱的 PW3 + KUAL + KOReader 2026.07+(PW3 上要装 `koreader-kindlepw2` 版,不要装
  `kindlehf` 版)。本插件**只支持 PW3/`kindlepw2`**,其它机型不适用。
- `lib/ckm_input.so` 与 `lib/modules/` 的三个 `.ko` 都已随仓库提供,匹配 PW3 内核
  `3.0.35-lab126`(来源与追踪方法见 `lib/modules/README.md`)。机型内核不同时插件会退化:
  仍需外部先加载模块,且只依赖 `/proc` 轮询识别已有设备。
- 音效/灯光等仅需 KOReader 自带动作,无需额外依赖。

> 若你之前手动改过 `externalkeyboard.koplugin/event_map_keyboard.lua` 和
> `readerui.lua`,可以把这些改动(和各自的 `.bak`)删掉,按键绑定统一由本插件管理。

## 真机回归测试要点(PW3)

1. 禁用 KindleLazy 开机加载;把激光笔插好再启动 KOReader → 能翻页(补开机漏检)。
2. 启动 KOReader → 拔出笔 → 插回 → 立即能翻页(热插拔回归点)。
3. 连续多次拔插、sleep 唤醒后再拔插 → 均正常。
4. 拔下后按键无动作、插回恢复,不误触发旧 fd。
5. 检查 `crash.log`:出现 `[CKM]` 的模块加载 / 设备打开日志,以及(若内核掉 uevent)
   `[FBInk]` hotplug 日志。

## 已知问题与恢复(TianCP LaserPen + PW3 OTG)

真机实测发现:这支「TianCP LaserPen」在**重新热插拔后,设备的 USB 可能枚举不回来**,
导致 KOReader 收不到任何按键。这是**硬件/主控兼容问题**,不是插件 bug:

- 现象:`dmesg` 出现 `input irq status -75 received`(EOVERFLOW,鼠标中断道上报溢出),
  随后 `USB disconnect`,再往后 `probe ... failed with error -110 / -71`、
  `can't set config #1, error -71`。此时 `/dev/input/event2` 不出现,插件无从打开。
- 插件行为:软件层面已修好——拔插乱序导致的旧 fd / `Input.opened_devices` 残留会被
  强制清理,**只要设备重新枚举出来,插件就会自动重新打开并与按键绑定恢复**。

### 恢复步骤(断电才有效)

软件上的 `usbhid` rebind、`authorized` 切 0/1、整体 unbind/bind 都**无法**救回,
因为 `-71` 是设备不给控制端点握手响应。**只有物理断电能复位**:

1. 把翻页笔整个从 OTG 口**拔下来,等约 10 秒**再插回去(给笔自己的 USB 芯片掉电);
2. 仍不行就**长按电源彻底关机再开机**(复位 eUSB/ehci 主控);
3. 恢复后重新进 KUAL → 打开 KOReader,即可再次翻页。

> 建议:**不要反复快速热插拔**。一旦把它弄到“枚举不回来”,只能断电恢复。

### 长期对策

- **硬件路线(最稳)**:换带供电的 USB OTG HUB、更稳的转接线,或换一个对 PW3 ehci
  主控更友好的 HID 翻页器。
- **软件实验**:`-75`(EOVERFLOW)几乎可以肯定是**鼠标接口**持续上报把中断道挤爆,
  进而引发整颗 USB 复位。可让插件在识别到笔时**解绑 HID 鼠标接口**(`1-1:1.1`),
  只保留稳定的键盘接口(`1-1:1.0`),从源头去掉 `-75`。目前尚未上线,待真机验证。

## 代码结构

`main.lua` 只保留插件类、共享状态、配置持久化与输入映射钩子;功能拆到 `lib/` 下:

- `main.lua` — 插件类、`shared` 状态、`loadCfg/saveCfg`、`trigger/register_hook`、`init`、
  组件装配(`ckm_ui.attach` / `ckm_hotplug.attach`)。
- `lib/ckm_ui.lua` — 设置界面(`addToMainMenu` / 各 `gen*` / 按键捕获 / 动作选择器)。
- `lib/ckm_hotplug.lua` — Kindle USB HID 自加载 + 热插拔(模块加载、设备扫描/接管、轮询、
  `EvdevInputInsert/Remove`、`setupUsbHidSupport`)。
- `lib/ckm_helpers.lua` — 纯工具(`list_input_devices`、`is_button_device`)。
- `lib/ckm_h.lua` — 原生 `lib/ckm_input.so` 的 FFI 声明(保持不变)。

各模块通过 `attach(plugin_class, shared, deps)` 注入共享状态并把自己的方法挂到插件类上,
因此 reader/filemanager 两个实例仍共享同一份 `shared` 状态。
