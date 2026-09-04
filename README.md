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
└── linux/             # Linux 実装 (GNOME Shell 拡張 + D-Bus CLI)
```

- OS 間でコードは共有せず、**仕様(docs/spec.md)と色定義(shared/colors.json)だけを共有**する。
- 各 OS ディレクトリは自己完結。ビルド方法・依存はそれぞれの README に書く。

## OS ごとの実現方式

| OS | 方式 | 変えられるもの |
|---|---|---|
| Windows | DWM API (`DwmSetWindowAttribute`) | 枠・タイトルバー背景・タイトル文字色 |
| macOS | オーバーレイ枠(公開APIでは他アプリのタイトルバー色変更不可) | ウィンドウ周囲の色枠 |
| Linux | GNOME Shell 拡張(mutter の `window_group` にオーバーレイ枠+タイトルタイントを重畳、D-Bus 経由で CLI から操作) | 枠・タイトルバー相当の色タイント |

## 対応環境 (Linux 版)

Linux 版は GNOME Shell 拡張として実装しているため、**対応可否はディストリビューションではなく
GNOME Shell のバージョンで決まる**。GNOME Shell 50 が入っていればディストリを問わず動作する。

| 区分 | GNOME Shell | ディストリビューション例 | 状態 |
|---|---|---|---|
| 対応 | 50 | Ubuntu 26.04 LTS、Fedora 44、Debian 14、Arch Linux / openSUSE Tumbleweed (GNOME 50 系) | 動作確認済み (Ubuntu 26.04 / GNOME Shell 50.1 / Wayland) |
| 未確認 | 45〜49 | Ubuntu 24.04 LTS (46)、Fedora 42/43、Debian 13 (48) | コードは動く見込みだが `linux/gnome-extension/metadata.json` の `shell-version` が `50` 固定のため無効化される。追記して実機確認すれば対応可 |
| 非対応 | 44 以前 | Ubuntu 22.04 LTS (42)、Debian 12 (43)、RHEL 9 系 (40) | 拡張が ESM 形式 (GNOME 45 で導入) のため読み込み不可 |
| 非対応 | 51 以降 | (今後のリリース) | `shell-version` 不一致で無効化。非公開 API (`Main.wm._windowMenuManager` 等) に依存しているため要追従 |

- セッションは **Wayland / X11 の両方に対応**。mutter 内部に描画するため、Wayland ネイティブ窓
  (Chrome 等の CSD アプリ) にも枠が付く。
- 追加の依存は `gdbus` (glib2 系) のみ。GNOME 環境なら標準で入っている。
- **GNOME Shell 以外のデスクトップは非対応**: KDE Plasma (KWin)、Xfce、Cinnamon、MATE、Budgie、
  COSMIC、Sway、Hyprland、i3、LXQt など。GNOME 派生でも GNOME Shell の拡張 API を持たない環境では動かない。
- インストール手順と使い方は `linux/README.md` を参照。

## リリース

バージョンは OS ごとに独立して管理する。OS プレフィックス付きタグ
(`windows-v1.0.0` / `linux-v0.1.0` など)を push すると、GitHub Actions が該当 OS の
成果物を添付した Release を自動作成する。

| OS | 添付物 |
|---|---|
| Windows | MSI インストーラ、ポータブル zip (exe + colors.json + ソース) |
| Linux | `wincolor-linux-vX.Y.Z.zip` (install.sh + 拡張 + CLI + shared)、`wincolor-linux-vX.Y.Z-extension.zip` (`gnome-extensions install` 用) |
| macOS | ソース zip (実装待ち) |

```sh
git tag linux-v0.1.0
git push origin main --tags
```

## ステータス

- [x] Windows 版 v1.0.0(AutoHotkey v2 / DWM + オーバーレイ枠)
- [ ] macOS 版
- [x] Linux 版(GNOME Shell 拡張、詳細は linux/README.md)
