# Ashbell U60 Pro 桌面安装与维护

个人桌面把渲染器、配套后端、界面、启动脚本和管理器放在同一个离线包中。安装器核对包内 SHA256、AArch64 ELF、版本清单、必需页面和脚本语法，完成备份后才切换进程；桌面和后端状态接口连续通过检查才报告成功。失败会恢复操作前的快照。

本版保留 `zwrt-datad 0.6.7-remix.5` 的流量与邻区能力。不要单独用其他分支的 datad 替换它：不同版本的启动参数、状态字段和持久化格式可能不同。

## 在 ufi-tools 中使用

在 ufi-tools 的插件编辑入口导入 `integrations/ufi-tools/Ashbell桌面管理.txt`（当前原生上传入口接受 `.txt`），也提供 `ashbell-desktop-manager.js` 供支持该扩展名的版本使用，或者把 `Ashbell桌面管理.html` 的完整内容添加到自定义头部。这些文件内容相同，包含 `KANO_PLUGIN_START/END` 标记。保存并刷新后，功能列表中出现「Ashbell 桌面管理」。不要删除其他插件的内容。

管理插件使用 UFI-TOOLS-U60Pro 的 `/api/run_shell` 接口和当前登录认证头。收到 API 请求成功还不能认定安装完成；插件必须读到管理器的终态退出标记才显示结果。接口超时会显示状态未知，需要先检查状态。

默认安装包路径为：

```text
/data/plugins/.ashbell-devui/ashbell-devui.tar.gz
```

可以直接通过面板的 **上传离线包** 选择电脑上的本次 `ashbell-devui.tar.gz`，不需要 ADB、图片上传接口或新增端口。只接受不超过 20 MiB 的 `.tar.gz`，按 48 KiB 分块传输并显示字节进度。上传结束后，管理器检查 SHA256、gzip、架构与必需资源，通过后才原子替换默认安装包；此前保留旧包。上传不会自动安装，成功后再点击「安装 / 接管」或「更新」。传输中面板会暂时禁用其他操作，设备上传会话也会防止并发覆盖。

已有安装包也可以用 ADB 传到默认路径，或者填写设备上的另一条包路径。面板提供：

- **检查状态 / 残留**：读取已安装版本、进程、自启位置、旧脚本/进程位置、暂存状态和最近备份名。
- **安装 / 接管**：从原厂桌面或已有第三方桌面切换到 Ashbell 桌面，自动安装配套 datad。
- **更新**：仅更新已标记为 Ashbell 的安装，保留个人配置、数据和已选择的自启开关。
- **开启自启动 / 关闭自启动**：去重或移除本桌面启动钩子，不停止当前桌面，设备下次重启时生效。关闭时保留原厂早期初始化和共用 datad 的启动方式。
- **归档旧版残留**：停止已知旧界面刷新脚本，把明确旧文件和已中断的管理器暂存移到私有归档，保留个人设置和流量数据。
- **重启桌面**：只重启屏幕渲染器，不重启设备、不清零后端数据，也不改变自启选择。
- **诊断日志**：显示二进制就绪、本机接口与日志大小/异常行数摘要，不输出密码、令牌或完整设备状态。
- **回退上一版**：恢复最近一次操作之前的桌面和启动设置。
- **卸载回原厂**：关闭个人桌面并恢复原厂桌面，保留可回退的备份。

安装包输入框也接受 HTTPS release 下载目录。该目录必须真实包含本版 `ashbell-devui.tar.gz`。尚未发布的新构建应使用离线包，不能把旧 release 当作本次更新。

旧屏幕管理插件的安装、更新或恢复操作仍可能覆盖当前桌面。完成迁移后应在 ufi-tools 插件管理中停用旧屏幕管理入口，保留其代码和备份供需要时恢复，不影响其他插件。

旧「u60屏幕管理插件」把 `/data/plugins/u60pro-devui/start.sh` 固定判作旧版残留，而该路径正是 Ashbell 的正常启动器。不能为了消除旧提示而删除它。三屏插件的 `.screen-ui-backup-*` 是正常回退资料；只有 `ui.screen-new` / `ui.screen-old` 等未完成暂存才表示安装中断。新管理器按自己的归属标记检查，正常备份单独展示，不计入故障。

## 通过 ADB 离线安装

设备需已开启 ADB，并由 `adb devices -l` 确认识别。

```sh
adb shell 'mkdir -p /data/plugins/.ashbell-devui'
adb push /path/to/release/ashbell-devui.tar.gz /data/plugins/.ashbell-devui/
adb push scripts/ashbell-devui.sh /tmp/ashbell-devui.sh
adb shell 'sh /tmp/ashbell-devui.sh install /data/plugins/.ashbell-devui/ashbell-devui.tar.gz'
```

安装过程中屏幕会短暂切换，不会重启设备或修改 WiFi、蜂窝、Clash 配置。安装结果以命令退出状态和终态输出为准。

已安装后的命令：

```sh
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh status'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh update /data/plugins/.ashbell-devui/ashbell-devui.tar.gz'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh autostart status'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh autostart off'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh autostart on'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh cleanup'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh diagnostics'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh restart'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh backups'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh rollback'
adb shell 'sh /data/plugins/u60pro-devui/ashbell-devui.sh uninstall'
```

卸载后，程序目录中的管理器也会删除。导入的 ufi-tools 插件内嵌管理器，仍然可以再次安装或回退；使用 ADB 时重新推送本仓库的管理脚本到 `/tmp` 即可。

## 保留的数据和启动链

更新会保留 `devui.conf`、`wifi-power-save.conf`、`flymodem-display.conf`、锁屏 PIN、datad 数据和不与本包重名的自定义功能文件。本包提供的同名受管理页面和脚本以新版本为准。原有完整目录保存在私有备份中。

新安装和更新会把根目录的旧 `screen-*.sh`、`start-devui.sh`、`cpuctl.sh`、`bin/ifconfig`、旧 `.screen-ui-backup-*` 与相关暂存移到 `/data/plugins/.ashbell-devui/backups/cleanup-*`。单独执行 `cleanup` 还会归档不属于当前任务的旧 `staging.*` 暂存。正常原始快照与卸载基线保留不动，清理不会替换「回退上一版」指针。归档目录不等于完整快照，不能传给 `rollback`。`plugin-detect.log` 和 `plugin-detect.log.old` 是当前渲染器正在使用和轮转的正常日志，不计为残留，也不会归档；诊断只报告其存在和字节数，不输出正文。

管理器会通过旧脚本的停止接口和 `/proc` 中精确脚本路径停止旧刷新进程与 `ifconfig` 包装器，并清理 `rc.local`、`/data/plugins/ufi_tools_boot.sh` 和 `/data/ufi-tools/sdcard/ufi_tools_boot.sh` 中已有的桌面启动行，保留其他插件命令。原厂 `zte_topsw_devui` 保持开机早期面板初始化，之后由一条 `rc.local` 钩子交给个人桌面。

备份位于 `/data/plugins/.ashbell-devui/backups/`，包含桌面目录、后端目录和相关启动设置。datad 停止时会刷新流量计数，管理器在此之后复制状态供新版读取。备份可能含设备配置和认证文件，不应作为公开发行资产。

如果 datad 在首次接管前已经存在，卸载桌面会保留其**当前**数据，恢复原有 datad 启动钩子并尝试按原方式启动，不会把流量计数替换成首次安装时的旧数据。如果是从零安装时由本管理器新增的后端，卸载时会一并移除该依赖。手动回退则按选定快照恢复目录和启动设置。

## 构建完整发行包

先完成渲染器构建，并准备所选 datad 的二进制及其对应 `version.json`。生成插件，再打包：

```sh
python3 scripts/build-ufi-plugin.py
python3 tests/test_ashbell_installer.py
python3 scripts/package-ashbell-release.py \
  --devui ./u60pro-devui.stripped \
  --datad /path/to/zwrt-datad-aarch64 \
  --datad-version /path/to/datad-version.json \
  --output /path/to/release
```

`--manifest` 可指定已合并的渲染器/UI 版本清单；默认读取仓库 `version.json`。脚本按目录递归打包 UI，包含 `subpages/`、`functions/` 和其中的 shell 脚本，排除点文件，不接受符号链接。

完整包顶层固定包含 `version.json`、两个 AArch64 二进制、`ui.tar.gz`、`start.sh`、`ashbell-devui.sh`、`LICENSE`、`NOTICE.md` 和 `SHA256SUMS`。发行目录另外提供完整包的 SHA256 和可导入的 ufi-tools 插件。

`tests/test_ufi_upload.py` 通过 Node 的浏览器接口模拟与真实本地 shell/冻结管理器校验上传，覆盖多块传输、损坏包、分块失败、扩展名/大小限制和并发隔离；运行 `python3 tests/test_ufi_upload.py`，需要 Node.js。

`tests/test_ashbell_installer.py` 在 `/tmp` 的独立文件系统中验证安装、更新、回退、卸载、自启开关与更新后保留、自启去重、旧启动链接管、残留归档、共用后端数据保留和失败恢复，不操作设备进程。硬件显示、触摸和无线控制需要另外在 U60 Pro 上验证。
