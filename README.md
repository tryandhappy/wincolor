# wincolor

ウィンドウ単位で色を付けて見分けるためのツール。
同じアプリの複数ウィンドウ(SSH端末、業務アプリの複数環境など)を、枠やタイトルバーの色で識別できるようにする。

## 構成

```
wincolor/
├── README.md
├── docs/
│   └── spec.md        # OS共通の仕様(機能・メニュー構成・挙動)
├── shared/
│   └── colors.json    # 色プリセット定義(全OS共通)
├── windows/           # Windows 実装 (AutoHotkey v2 / PowerShell)
├── macos/             # macOS 実装 (Swift / Hammerspoon)
└── linux/             # Linux 実装 (X11: wmctrl 等 / Wayland は要検討)
```

- OS 間でコードは共有せず、**仕様(docs/spec.md)と色定義(shared/colors.json)だけを共有**する。
- 各 OS ディレクトリは自己完結。ビルド方法・依存はそれぞれの README に書く。

## OS ごとの実現方式

| OS | 方式 | 変えられるもの |
|---|---|---|
| Windows | DWM API (`DwmSetWindowAttribute`) | 枠・タイトルバー背景・タイトル文字色 |
| macOS | オーバーレイ枠(公開APIでは他アプリのタイトルバー色変更不可) | ウィンドウ周囲の色枠 |
| Linux | WM 依存(X11 は装飾 or オーバーレイ枠、Wayland は制約大) | ウィンドウ周囲の色枠 |

## ステータス

- [ ] Windows 版(最初のターゲット)
- [ ] macOS 版
- [ ] Linux 版
