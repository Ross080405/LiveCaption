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

需要 macOS 14 或更新。用 Whisper 建议 Apple 芯片的 Mac。

从源码编译（需要 Xcode 16 或更新）：

```bash
./build.sh --install
```

之后在「应用程序」里打开 LiveCaption。第一次打开会有引导，带你允许权限、选识别引擎。

如果你会经常重新编译，先运行一次下面的脚本。它会建一个本机签名证书，这样每次编译后不用重新授权麦克风等权限：

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

## 打包给别人

```bash
./scripts/make-dmg.sh
```

会生成 `build/LiveCaption-版本号.dmg`。对方不需要 Xcode，拖进「应用程序」就能用。

目前的安装包没有经过 Apple 公证，所以：

- 对方第一次打开会被系统拦下，要到「系统设置 → 隐私与安全性」点一次「仍要打开」。安装包里附了说明。
- 只支持 Apple 芯片的 Mac。

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
