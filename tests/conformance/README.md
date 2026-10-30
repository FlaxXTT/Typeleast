# 跨语言验收：契约 v2

这套用例只给开发者运行。它保存在源码仓库的 `tests/conformance/`，不复制进 Mac 或 Windows 安装包，也不在应用界面中提供入口。发布包只包含应用与本地服务运行文件。

这组测试从进程外检查 TypeLeast 本地服务。运行器不导入服务源码。重写者可以用任何语言实现服务，再用同一批 JSON 用例验收。`v2.json` 定义 HTTP 行为；`client-v2.json` 由 Mac 和 Windows 测试共同读取。这些文件不进入安装包。

## 运行

先在 `service/` 安装项目依赖。回到仓库根目录后运行：

```bash
node tests/conformance/run.mjs -- node service/bin/typeleast-service.mjs
node tests/conformance/run.mjs --group translation --json -- node service/bin/typeleast-service.mjs
node tests/conformance/run.mjs --fixture tests/conformance/v3-asr.json -- node tests/conformance/fake-asr-service.mjs
```

另一个实现把 `--` 后的命令换成自己的服务命令。例如 `-- ./my-service`。运行器不使用 shell 执行这个命令。被测程序须接受 `--state-dir DIR --models-dir DIR --port 0`，在标准输出第一行给出 `{"event":"ready","port":数字,"pid":数字,"version":"..."}`，并把令牌写入状态目录的 `api-token`。测试只连接该端口的 `127.0.0.1`。其他日志应写到标准错误。

每个用例使用新的临时状态目录和本机假整理模型，结束后删除。被测程序只收到临时的 HOME/AppData 路径及必要的运行环境；运行器不会把调用者的 Key 或代理变量传进去。用例不下载语音模型、不读取日常设置，也不使用真实 Key。只有 `--group` 指定的组会运行。`--json` 以机器可读格式报告每组的通过、失败和跳过数量。退出码 `0` 表示全过，`1` 表示用例失败，`2` 表示命令用法错误。

## 契约范围

`v2.json` 中每条用例有 `id`、`group` 和有序 `steps`。`preloadFiles` 在服务启动前写入隔离状态目录。请求步骤使用 `method`、`path`、`headers`、`body` 或 `rawBody`；`$FAKE_LLM` 代表本机假模型地址与假凭据。`expect.fields` 按点分路径比较稳定字段，`present` 检查字段存在，`contains` 和 `excludes` 检查文本，`modelCalls` 与 `modelUsers` 检查模型调用次数和输入。`restart` 保留该用例的隔离状态目录后重启服务。测试不要求生成结果的措辞完全相同。

主用例覆盖启动、鉴权、输入限制、音频拒绝路径、三种整理档位、两步翻译及回退、Beta 会话错误、旧词库字段忽略、模型状态、插件数据和持久化、语言变体、设置迁移及故障恢复。`v2-asr.json` 使用单独的**测试适配器**，离线检查听写成功、逐请求语言选择及 Beta 三轮补充、生成和取消。适配器把 WAV 第一个 PCM16 样本值 1–4 映射成文件内列出的虚构口述；重写者可以用同一规则制作自己的测试适配器。它不进入安装包，也不能证明真实模型识别质量。`client-v2.json` 规定两端共同使用的请求编码、旧档位迁移、响应解码和可插入文本行为。增加公开行为时，应增补新用例；改动已有契约时，应增加契约版本并写明迁移方法。

## 完整产品验收

两端自动测试还要分别运行 `apps/macos/test.sh` 与 `dotnet run --project apps/windows/TypeLeast.Core.Tests -c Release`。它们检查请求编码、响应兼容、设置、录音状态、粘贴目标、历史、更新提示及插件操作。自动测试无法证明系统权限和真实桌面交互正常；按[双端操作验收表](manual-checklist.md)在 Mac 和 Windows 上各做一次。

真实模型、外部整理服务和下载是单独的可选验收。只用公开或合成语音与假文本。运行模型下载脚本会执行文件完整性校验；按维护者规则，执行前先征得许可。测试完成后记录所用平台、模型、版本、通过项、失败项和未执行项，不把可选测试写成默认测试已通过。


## 客户端契约 v2

v2 将 `concise` 的界面名称改为 AI 整理，并增加待确认名称的响应样例：存在 `clarification` 时，即使有草稿 `text` 也不能插入。v1 保留给旧版本，HTTP 主契约现为 v2。默认档位的一次性迁移由两端隔离设置测试覆盖；完成迁移后不得在后续启动重置用户选择。

## 个性化契约


## 服务契约 v2 的变化

v2 将自然整理与 AI 整理的失败交付改为 `text: ""` 和 `clarification.kind: "quality"`，候选只能供用户审阅；插件仅接受风格类型。`v1.json` 与 `v1-asr.json` 保留作旧版行为记录，不作为当前验收要求。新实现须运行 v2 两套用例。

## 当前契约 v3：统一听写

v3 增加 `task`（dictation / translation / assistant）；录音头为 `x-voice-task`。缺少任务字段时，旧普通档位均映射听写，旧 promptbeta 映射需求助手。旧客户端契约文件仍检验历史字段的兼容读取，不代表当前存在档位选择。

默认运行器使用 v3.json；假识别链路使用 v3-asr.json。翻译的第一步不再绕过失败；所有失败交付为空正文及 quality 恢复资料。助手按需每轮最多 3 问，生成一次，不再执行审查修补循环。v1、v2 文件只保留作旧版本记录。

十分钟音频、分段边界、名称依据及预算回归位于 service/test/long-dictation.test.js。它们使用假识别器及假模型，只验证流程，不证明真实语音准确率。
