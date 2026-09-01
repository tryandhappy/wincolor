# wincolor

ウィンドウ単位で色を付けて見分けるクロスプラットフォームツール。
全体像は README.md、OS共通仕様は docs/spec.md を参照。

## 運用ルール

- **変更を加えたら、毎回自動的に git commit まで行うこと**(ユーザーへの確認は不要)。
  コミットメッセージは変更内容に合わせて Claude が適切に作成する。
- push は指示があったときのみ。

## バージョン管理とリリース

- **バージョンは OS ごとに独立**して管理する。タグは OS プレフィックス付き:
  `windows-v1.0.0` / `macos-v0.1.0` / `linux-v0.1.0`
- タグを push すると GitHub Actions (.github/workflows/release.yml) が Release を自動作成する。
  Windows は Ahk2Exe で単体 exe にコンパイルし **MSI (WiX) とポータブル zip** を添付、
  macOS/Linux は実装が入るまでソース zip のみ
- リリース手順(例: Windows 版):
  1. `windows/wincolor.ahk` の `WINCOLOR_VERSION` を更新してコミット
  2. `git tag windows-vX.Y.Z && git push origin main --tags`(push は指示があったときのみ)
- MSI の注意:
  - バージョンは数値3組 (X.Y.Z) のみ。`-rc1` 等のサフィックスは MSI では使えない
  - WiX は **5.0.2 に固定**(v6 以降は OSMF 同意が必要になったため)
  - wxs は windows/installer/wincolor.wxs。ユーザー単位インストール
    (%LocalAppData%\Programs\wincolor)、スタートメニューとスタートアップに
    ショートカット作成、UpgradeCode 固定でメジャーアップグレード対応
  - ローカル検証: `wix build windows/installer/wincolor.wxs -d ProductVersion=X.Y.Z -d SourceDir=<exeとcolors.jsonのある場所> -o out.msi`

## 構成

- `windows/` — AutoHotkey v2 実装(現在の主開発対象)
- `macos/` / `linux/` — 未着手(オーバーレイ枠方式の予定)
- `shared/colors.json` — 全OS共通の色プリセット
- `docs/spec.md` — OS共通仕様と、OSごとの制約・実測結果

## Windows版の開発メモ

- 構文チェック: `AutoHotkey64.exe /ErrorStdOut /validate windows\wincolor.ahk`(exit 0 で成功)
- 動作確認は実ウィンドウに適用し、境界ピクセルの実測(GetPixel)で検証してきた。
  勘に頼らず必ず実測すること(隙間問題は「影」「リージョン排他座標」「アプリの半透明1px境界」
  の3要因が重なっていた。詳細は docs/spec.md)
- 本体はタスクトレイ常駐。再起動は同スクリプトの再実行(`#SingleInstance Force` で置き換わる)。
  再起動するとオーバーレイ枠は消えるため、ユーザーに再着色を依頼する
