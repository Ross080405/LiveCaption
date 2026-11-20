# LiveCaption

macOS 上的实时字幕。把麦克风或电脑里正在播放的声音变成字幕，显示在屏幕上，同时存成 Markdown 文件。

识别全部在本机完成，音频不会上传。

## 能做什么

- **悬浮字幕条**：始终置顶，能盖在全屏视频上。可以拖动、调大小、锁定后让鼠标穿透。
- **两种声音来源**：麦克风（上课、开会、面对面），或系统声音（视频、网课、线上会议）。
- **两种识别引擎**：
  - 系统识别：macOS 自带，快、省电。
  - Whisper 高精度：对口音、中英混说明显更准，字幕大约晚 1 秒。
- **边说边存**：字幕实时写进 Markdown 文件，连还没说完的半句也会写进去。让桌面 AI 盯着这个文件，就能跟上正在进行的对话。
- **记录库**：之前的记录可以搜索、阅读（渲染 Markdown）、直接编辑、改名、接着写。
- **一键交给 AI**：按 ⌥⌘A 把当前字幕发给 Claude、ChatGPT、Grok 等桌面应用，不需要 API Key。

## 安装

**[下载最新版安装包 →](https://github.com/Ross080405/LiveCaption/releases/latest)**

需要 Apple 芯片的 Mac（M1 及以后），macOS 14 或更新。

1. 在上面的页面下载 `.dmg` 文件，打开后把 LiveCaption 拖进「应用程序」。
2. 在「应用程序」里双击打开。系统会提示无法打开，点「完成」。
3. 打开「系统设置 → 隐私与安全性」，往下翻，在 LiveCaption 那一行点「仍要打开」。只需要做一次。
4. 按窗口里的引导允许权限、选识别引擎。

需要第 2、3 步是因为安装包还没有经过 Apple 公证。

### 从源码编译

想自己改代码的话（本地增强版需要 Xcode 26 / Swift 6.2 或更新）：

```bash
./build.sh --install
```

如果会经常重新编译，先运行一次下面的脚本。它会建一个本机签名证书，这样每次编译后不用重新授权麦克风等权限：

```bash
./scripts/make-signing-cert.sh
```

## 使用

1. 打开应用，点中间的红色按钮，或在任何地方按 **⌥⌘P** 开始。
2. 字幕出现在屏幕下方的字幕条和主窗口里。
3. 再按 **⌥⌘P** 暂停或继续；点「结束」完成这次记录。

主窗口关掉后应用还在菜单栏里。点菜单栏图标可以重新打开窗口，也能直接开始、暂停、换设置。

### 起名字

新记录有两种起名方式，在设置里切换：

- **自动命名**：按规则起名，默认是 `字幕_{date}_{time}`。可以用 `{date}` `{time}` `{weekday}` `{source}` `{language}` 等。
- **开始前先起名**：先输入名字再开始。

不管哪种，之后点标题都可以改名。

### 选 Whisper 时

- 第一次用会下载模型（最大的那个 1 GB 多），之后就不用了。可以在设置里提前下好。
- 一场对话里中英文混着说，就打开「自动检测语言」。
- 模型存在 `~/Library/Application Support/LiveCaption/whisper`，不用了可以删。

## 文件在哪

所有记录都在 `~/Documents/LiveCaption/`。

其中 `最新字幕.md` 始终是当前正在记录的内容，路径固定，适合交给 AI 读。文件大约每半秒刷新一次；正在说的那一句行尾带 ` …（识别中）`，说完后会被定稿的句子替换。

## 快捷键

| 快捷键 | 作用 |
|---|---|
| ⌥⌘P | 开始 / 暂停 / 继续 |
| ⌥⌘A | 把当前字幕发给桌面 AI |
| `/` | 在主窗口里打开记录库并搜索 |
| ⌘S | 编辑记录时保存 |

## 自己打安装包

```bash
./scripts/make-dmg.sh
```

会生成 `build/LiveCaption-版本号.dmg`，和发布页上的是同一种：没有公证，只支持 Apple 芯片的 Mac，里面附了首次打开的说明。

有 Apple 开发者账号的话，可以正式签名并公证，对方双击就能打开（这条路径还没有实际跑过）：

```bash
xcrun notarytool store-credentials livecaption
SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" NOTARY_PROFILE=livecaption ./scripts/make-dmg.sh
```

## 常见问题

| 问题 | 怎么办 |
|---|---|
| 没有字幕出来 | 看主窗口顶部的音量条有没有动。不动就是没收到声音：检查音频来源和系统权限。 |
| 系统声音没反应 | 在「系统设置 → 隐私与安全性 → 屏幕与系统录音」里允许 LiveCaption，然后重新打开应用。 |
| Whisper 模型下载失败 | 检查能不能访问 huggingface.co，或者先用系统识别。 |
| 安静时冒出没说过的话 | Whisper 在长时间静音时偶尔会这样，常见的情况已经过滤。 |
| ⌥⌘A 或 ⌥⌘P 没反应 | 可能和别的软件的快捷键冲突，改用菜单栏图标。 |
| AI 读不到字幕文件 | 在「系统设置 → 隐私与安全性 → 文件与文件夹」里允许那个 AI 应用访问「文稿」。 |

出问题时可以看日志：`~/Library/Logs/LiveCaption.log`。

## 代码结构

```
Sources/
  AppDelegate.swift         菜单栏、设置、记录的开始和结束、给界面用的接口
  Transcriber.swift         采集声音、识别、断句
  WhisperEngine.swift       Whisper 模型的下载、加载和实时识别
  SystemAudioCapture.swift  采集系统声音
  RecordingFile.swift       记录文件：命名、实时写入、接着写、改名
  SubtitleWindow.swift      悬浮字幕条
  DashboardWindow.swift     主窗口
  DashboardPage.swift       主窗口里的界面（单文件 HTML）
  DashboardServer.swift     只对本机开放的 HTTP 服务，界面通过它和应用通信
  AgentBridge.swift         发送给桌面 AI
  HotKey.swift              全局快捷键
  Log.swift                 日志
scripts/                    签名证书、打包、图标
build.sh                    编译并安装
```


## 本地增强版：实时说话人 + 快速分享

- 开始页或「设置 → 识别」开启 **实时区分说话人**，录音时自动按声音分成 A/B/C/D，最多 4 人。
- 使用 FluidAudio 0.18.4 的 Sortformer 流式 CoreML 模型；首次从 Hugging Face 下载到 `~/Library/Application Support/LiveCaption/speakers`。分人在本机运行，不上传声音，不识别真实姓名。
- 标签通常稍晚于文字，随后会校正。`?` /「待识别」表示没有足够声学证据，`A+B` 表示重叠发言。噪声、短句、相似声音及四人以上场景可能分错。
- 结合系统识别和 Whisper 的词级时间戳，在一句话里发生换人时拆成多行；缺少可靠词级时间戳时，按整段的主要说话人标注。
- 暂停/继续保持同一组标签；每次新记录重新编号。接着写入旧记录会在新的「继续记录」段中重新编号。只能在结束记录后切换分人开关。
- 实时录音页与记录阅读页都提供 **复制全文 / 导出 Markdown / 导出 TXT**。导出弹出原生保存窗口；复制直接得到可粘贴的完整文本。
- 复制、导出和交给 AI 使用同一份完整快照，保留时间戳与说话人标签，也包含明确标注为「识别中」的半句话；不会只复制屏幕上最近 200 行。
- 结束时先等识别与说话人结果收尾，再写入记录与 `最新字幕.md`。历史记录可通过已有「编辑」功能修正误识别或标签。
- 原有 ⌥⌘A 是复制提示词与 transcript 并打开选定的桌面 AI，用户再按 ⌘V；不会自动发送消息。

分人关闭时可继续使用原有转写。系统语音识别原有的在线回退机制仍存在；若需要转写也始终本地处理，请选 Whisper。

### 验证

```sh
swift test
# 可选：使用合成的两种声音做真实 CoreML 流式推理与暂停/继续测试（首次下载模型）
LIVE_CAPTION_SPEAKER_FIXTURES=/path/to/fixtures swift test --filter SpeakerIntegrationTests
```

fixtures 目录应包含 16 kHz 单声道的 `a.wav`、`b.wav`（两个不同声音）；测试按 A → B → 暂停 → A 输入，不使用麦克风。

模型及 SDK 来源：[FluidAudio](https://github.com/FluidInference/FluidAudio)、[Sortformer 使用与限制](https://github.com/FluidInference/FluidAudio/blob/v0.18.4/Documentation/Diarization/Sortformer.md)。
