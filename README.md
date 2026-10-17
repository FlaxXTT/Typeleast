# dsh-voice

Mac 上的本地语音输入：按热键说话，本地 SenseVoice 转写，再由 DeepSeek 模型整理（去口水词、纠错、分点），最后自动粘贴到当前光标处。对标 Typeless。

## 组成

| 目录 | 是什么 |
|---|---|
| [`dsh-voice-polish/`](dsh-voice-polish/) | DeepSeek Harness（DSH）宿主插件：转写、整理、校验/回落、本机 HTTP 接口（`127.0.0.1:<端口>/api/voice-polish`，端口每次启动由 DSH 分配）和历史记录 |
| [`dsh-voice/native/macos/`](dsh-voice/native/macos/) | macOS 菜单栏 App（显示名 TypeLeast，bundle id `com.dsh.voice`）：全局热键、录音、录音条、粘贴 |
| [`dsh-voice-项目概述.md`](dsh-voice-项目概述.md) | 完整的项目说明：架构、接口契约、已知坑、路线图 |
| [`typeless-spec.md`](typeless-spec.md) | 对标产品 Typeless 的功能规格整理 |

## 前提条件

- macOS 13 或更新，Xcode 命令行工具（`swiftc`）。
- DeepSeek Harness 桌面版：已登录 DeepSeek 账号，并已准备好本地 SenseVoice 语音模型。
- 插件依赖 DSH 0.2.0-rc.2 的内部接口，DSH 升级后可能需要适配。

## 快速开始

1. 在 `~/.dsh/profiles/desktop/cordis.patch.yml` 里挂载插件（写法见 [`dsh-voice-polish/README.md`](dsh-voice-polish/README.md) 第 4 节），重启 DSH。
2. 编译并安装 App：

   ```bash
   cd dsh-voice/native/macos && ./build.sh
   ```

3. 首次打开时按引导授予麦克风和辅助功能权限。

## 测试

```bash
cd dsh-voice-polish && node --test test/*.test.js
```

```bash
cd dsh-voice/native/macos && ./test.sh
```

## 现状

- 只支持 macOS，并且必须运行 DSH。脱离 DSH 的独立后端（本地 SenseVoice + DeepSeek API）和 Windows / 移动端客户端在规划中，见项目概述的路线图。
- 音频只在本机处理；发给模型的只有转写文本和少量上下文，发送前会抹掉密钥形状的字符串。
