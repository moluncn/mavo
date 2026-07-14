<p align="center">
  <img src="Resources/MaVo-icon-image2.png" width="128" height="128" alt="MaVo 图标">
</p>

<h1 align="center">MaVo</h1>

<p align="center">
  在 Mac 上使用蜂窝网络、短信和电话。
</p>

MaVo 是一款原生 macOS 菜单栏应用，用于连接 QDC507 蜂窝模块。插入模块后，
你可以直接在 Mac 上联网、收发短信和拨打电话，无需浏览器服务或额外的通信软件。

## 主要功能

### 蜂窝网络

- 一键开启或关闭模块联网。
- 开启后自动让蜂窝网络优先于 Wi-Fi。
- 关闭后恢复原来的网络顺序，不影响短信和来电接收。
- 模块 ECM 链路没有响应时自动恢复，无需反复拔插。
- 实时显示运营商、网络制式和信号强度。

### 短信

- 后台接收短信并发送 macOS 通知。
- 查看完整短信，复制正文或直接回复。
- 发送中文短信和长短信。
- 自动识别验证码，点击即可复制并标记已读。
- 删除后不再出现在 MaVo；如果短信仍保存在模块中，MaVo 会同时尝试清理。
- 可选在验证码短信已读 30 分钟后自动删除。

### 电话

- 拨号、接听、拒接、静音和挂断。
- 来电时显示带“接听”和“拒接”按钮的通知与浮窗。
- 通话中提供数字拨号盘，可操作客服语音菜单。
- 使用 Mac 的麦克风和扬声器进行通话。

### 日常使用

- 支持模块热插拔，无需重启应用。
- 菜单栏图标显示当前信号与蜂窝网络状态。
- 可打开标准主窗口；关闭窗口后继续在菜单栏运行。
- 可选择模块未插入时隐藏菜单栏图标。
- 可选择登录 Mac 时自动启动，默认关闭。

## 系统要求

- Apple Silicon Mac
- macOS 14 或更高版本
- QDC507 蜂窝模块
- 可用的 SIM 卡和对应运营商服务

MaVo 针对 macOS 26 的 Liquid Glass 界面进行了优化，在较早的兼容系统上会自动
使用标准 macOS 材质。

## 安装

1. 从 [GitHub Releases](https://github.com/moluncn/mavo/releases/latest) 下载最新的
   `MaVo-版本号-arm64.zip` 并解压。
2. 将 `MaVo.app` 放入下面任一位置：

   ```text
   ~/Applications/MaVo.app
   /Applications/MaVo.app
   ```

3. 当前 Release 使用 ad-hoc 签名，未经过 Apple 公证。仅当安装包来自上面的官方
   Release 页面时，根据应用所在位置运行下面一条命令，移除 macOS 下载隔离属性：

   ```sh
   xattr -dr com.apple.quarantine "$HOME/Applications/MaVo.app"
   ```

   或：

   ```sh
   xattr -dr com.apple.quarantine "/Applications/MaVo.app"
   ```

4. 双击打开 MaVo。

如果仍被 macOS 阻止，可在 Finder 中右键 MaVo，然后选择“打开”。不要对来源不明的
应用执行 `xattr` 命令。

## 首次使用

1. 插入模块，等待菜单栏出现信号图标。
2. 如果 MaVo 显示初始化引导，按照页面提示完成初始化。
3. 打开“蜂窝网络”开关。
4. 第一次开启时，macOS 会要求一次管理员验证，用于安装 MaVo 网络组件。

网络组件安装完成后，以后切换蜂窝网络不再重复要求密码或 Touch ID，重新启动 Mac
后也仍然有效。

## 权限说明

MaVo 只会在需要时请求以下权限：

- **通知**：显示新短信和来电提醒。
- **麦克风**：进行语音通话。
- **管理员验证**：首次安装网络组件，用于切换蜂窝网络和调整网络顺序。

该组件只允许操作 MaVo 识别到的目标模块，不能执行任意系统命令。

## 菜单栏与完全退出

关闭 MaVo 的主窗口不会退出应用，短信、来电和模块监测仍会在后台继续运行。

如果需要停止 MaVo，请打开“设置”，然后点击 **完全退出**。

## SIM 信息

MaVo 会优先读取 SIM 中保存的手机号。如果运营商没有把手机号写入 SIM，界面会
显示卡号尾号。这不会影响联网、短信或电话功能。

## 数据与隐私

- 短信记录仅保存在当前 Mac：

  ```text
  ~/Library/Application Support/MaVo/messages.json
  ```

- 已删除短信的屏蔽记录保存在同一目录，用于防止模块重新同步后再次出现。
- MaVo 不提供云同步，也不会把短信、号码或通话内容上传到服务器。
- MaVo 不会自动修改 IMEI，也不会刷机。

## 常见问题

### 插入模块后没有反应

拔下模块后重新插入，并退出可能正在占用模块的串口、USB 或其他模块管理工具。如果仍未
识别，可在 MaVo 中点击刷新。

### 蜂窝网络已开启，但无法联网

确认 SIM 已开通数据服务并有可用流量，然后等待运营商分配网络地址。首次使用的
模块还需要完成 MaVo 初始化引导。

### 收不到短信或来电

确认 SIM 状态正常、运营商网络可用，并检查 macOS 通知权限。来电接收还需要在
MaVo 设置中开启“接收来电”。

### 为什么读不到手机号

很多运营商不会把本机号码写入 SIM。此时 MaVo 只能显示卡号尾号，但其他功能不受
影响。

### 如何回复短信

打开短信右侧菜单并选择“回复”，或在短信详情窗口点击“回复”。MaVo 会自动填入
收件号码，但不会自动发送。

<details>
<summary><strong>开发者：从源码构建</strong></summary>

项目使用 Swift Package Manager，需要 Apple Command Line Tools。

```sh
scripts/run_tests.sh
scripts/build_app.sh
```

构建完成后，经过签名和归档校验的应用位于：

```text
outputs/MaVo-<版本号>-arm64.zip
```

主要目录：

```text
Sources/MaVo/                 macOS 应用
Sources/CModemBridge/         USB AT 与语音桥
Sources/CUACProbe/            CoreAudio UAC 桥
Sources/MaVoNetworkIPC/       网络 helper XPC 协议
Sources/MaVoNetworkHelper/    受限网络 helper
Resources/ModuleVoice/        QDC507 通话运行资源
Tests/                        自测试
scripts/                      构建与诊断脚本
```

普通测试不会自动拨号、发送短信、重启模块或修改模块配置。

</details>

## 许可证

MaVo 应用代码使用 [MIT License](LICENSE)。第三方组件及其许可证说明见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
