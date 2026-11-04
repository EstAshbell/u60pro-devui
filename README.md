# Ashbell · U60 Pro 桌面

为 U60 Pro 320×480 触摸屏整合的个人桌面。以三页总览、信号和控制中心为入口，保留双卡、按卡流量、CPU、时区、短信、连接设备及可选网络工具，并加入 ShellCrash 启停和代理模式控制。来源和许可见 [NOTICE.md](NOTICE.md)。

界面是 HTML/CSS，由静态 AArch64 程序通过 litehtml、FreeType、DRM/KMS 和 evdev 绘制；不是浏览器，没有 JavaScript。运行目录为 `/data/plugins/u60pro-devui`，状态后端只监听 `127.0.0.1:9460`。

## 安装、更新与恢复

完整离线包 `ashbell-devui.tar.gz` 同时包含桌面、页面、管理器和匹配的 datad，支持从零安装。UFI-TOOLS 导入 `ashbell-desktop-manager.js`（或 `.txt` 副本）后，打开「Ashbell 桌面管理」即可直接上传离线包、安装、更新、回滚、卸载和控制自启动。具体步骤见 [安装说明](docs/ASHBELL-INSTALL.md)。

ADB 安装：

```sh
adb shell 'mkdir -p /data/plugins/.ashbell-devui'
adb push ashbell-devui.tar.gz /data/plugins/.ashbell-devui/ashbell-devui.tar.gz
adb push scripts/ashbell-devui.sh /tmp/ashbell-devui.sh
adb shell 'sh /tmp/ashbell-devui.sh validate /data/plugins/.ashbell-devui/ashbell-devui.tar.gz'
adb shell 'sh /tmp/ashbell-devui.sh install /data/plugins/.ashbell-devui/ashbell-devui.tar.gz'
```

管理器先校验 SHA-256、架构和完整页面，再备份桌面与启动链。只有桌面和后端持续运行且 `/state` 可访问才报告成功；失败会恢复备份。个人配置、锁屏 PIN、自定义函数和后端流量状态会保留。旧桌面包装器和页面改写脚本归档到管理器备份目录。

默认离线包长期保存在 `/data/plugins/.ashbell-devui/ashbell-devui.tar.gz`，卸载后仍可重装。只有个人 GitHub Release 已发布完整包时，才可将在线源填写为：

```text
https://github.com/EstAshbell/u60pro-devui/releases/latest/download
```

旧版 `install-autostart.sh` 是历史开发工具；本发行版请使用 `ashbell-devui.sh`，避免多套启动器并存。

## 控制边界

- Wi-Fi 信息优先显示 5 GHz，另列 2.4 GHz；各自读取名称、密码和加密方式。名称和展开后的密码完整换行，默认隐藏密码。
- Wi-Fi 开关读取实际接口状态，等待终态并显示失败；绕过第三方 `ifconfig` 包装器。频段开关控制本次运行，重启后跟随固件无线配置。
- ShellCrash 与 Mihomo 分开检测；设备装了对应服务时才有实际控制能力。TS、WG、锁运营商等页面也依赖对应插件，桌面不会代装或自动启用它们。
- CPU 模式只在用户选择时修改，最高频率使用硬件上限。
- 本包固定 `scoltzero/zwrt-datad-remix v0.6.7-remix.5`，其 SIM 流量、时区和邻区接口与界面匹配。升级到其他后端需先验证接口兼容。

## 构建与打包

使用 Linux/WSL 和 AArch64 musl 工具链。macOS 可用 Linux 容器执行相同脚本。工具链和静态库准备方式见 `scripts/_setup_toolchain.sh`、`scripts/_build_freetype.sh`、`scripts/_build_litehtml.sh`。

```sh
bash scripts/build.sh
python3 scripts/build-ufi-plugin.py
python3 scripts/package-ashbell-release.py \
  --devui ./u60pro-devui.stripped \
  --datad /path/to/zwrt-datad-aarch64 \
  --datad-version /path/to/datad-version.json \
  --output /path/to/release
```

后端固定版本二进制 SHA-256：`4ea3fdf921c077e077ce820669339f3844101415512775bf42e497c0471e7d0d`。UI 归档递归包含 `subpages/`、`functions/` 和辅助脚本；不要只打包顶层 HTML/CSS。

GitHub workflow 在 `main` 上构建完整包和源码包，先保存 Actions artifact，再发布。默认不自动合并上游；手动选择同步时若有冲突，保留当前 Ashbell 源码并在 Job Summary 列出冲突文件。

## 验证

```sh
sh tests/test_shellcrash_mode.sh
sh tests/test_wifi_control.sh
python3 tests/test_data_transport.py
python3 tests/test_ui_contract.py
python3 tests/test_pinned_header.py
python3 tests/test_cpuctl.py
python3 tests/test_ashbell_installer.py
python3 tests/test_ufi_upload.py
python3 tests/test_runtime_controls.py
python3 tests/test_wifi_profiles.py
```

本机测试覆盖控制失败、状态回读、HTTP/SSE 回退、UI 动作与令牌、CPU 边界、安装/更新/卸载/回滚及异常包。硬件交互仍需实机验证。

历史架构和界面作者文档见 [UI-GUIDE](docs/UI-GUIDE.md)、[DEVELOPMENT](docs/DEVELOPMENT.md)、[HARDWARE](docs/HARDWARE.md)。仓库不包含设备备份、厂商字体或任何网络凭据。
