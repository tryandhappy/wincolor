# wincolor

ウィンドウ単位で色を付けて見分けるクロスプラットフォームツール。
全体像は README.md、OS共通仕様は docs/spec.md を参照。

## 運用ルール

- **変更を加えたら、毎回自動的に git commit まで行うこと**(ユーザーへの確認は不要)。
  コミットメッセージは変更内容に合わせて Claude が適切に作成する。
- push は指示があったときのみ。

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
