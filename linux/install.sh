#!/bin/bash
# wincolor (Linux版) インストーラ
#
# リリース zip を展開したディレクトリ、またはリポジトリの linux/ から実行する。
#   ./install.sh            インストール (拡張 + CLI) して拡張を有効化
#   ./install.sh --uninstall  アンインストール
#
# 環境変数:
#   PREFIX   CLI の配置先 (既定: ~/.local/bin)
#   NO_ENABLE=1  gnome-extensions enable を実行しない (CI 等)
set -eu

UUID=window-color-tag@smart2j.jp
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
EXT_SRC="$SRC_DIR/gnome-extension"
EXT_DST="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$UUID"
BIN_DST="${PREFIX:-$HOME/.local/bin}"

if [ "${1:-}" = --uninstall ]; then
    command -v gnome-extensions >/dev/null && gnome-extensions disable "$UUID" 2>/dev/null || true
    rm -rf "$EXT_DST"
    rm -f "$BIN_DST/wincolor"
    echo "removed: $EXT_DST, $BIN_DST/wincolor"
    exit 0
fi

for cmd in glib-compile-schemas gdbus; do
    command -v "$cmd" >/dev/null || { echo "error: '$cmd' が見つかりません (glib2 系パッケージを入れてください)" >&2; exit 1; }
done
[ -f "$EXT_SRC/metadata.json" ] || { echo "error: $EXT_SRC/metadata.json がありません" >&2; exit 1; }

# 拡張を配置し gschema をコンパイル
rm -rf "$EXT_DST"
mkdir -p "$EXT_DST"
cp -r "$EXT_SRC"/. "$EXT_DST"/
glib-compile-schemas "$EXT_DST/schemas/"

# 色プリセット (shared/colors.json) を拡張ディレクトリに同梱する
# 探索順: バンドル zip 構成 (./shared/) → リポジトリ構成 (../shared/)
colors=""
for cand in "$SRC_DIR/shared/colors.json" "$SRC_DIR/../shared/colors.json"; do
    [ -f "$cand" ] && { colors=$cand; break; }
done
if [ -n "$colors" ]; then
    install -m 0644 "$colors" "$EXT_DST/colors.json"
else
    echo "note: shared/colors.json が見つからないため、拡張の組み込み既定パレットを使用します"
fi

# CLI を配置
mkdir -p "$BIN_DST"
install -m 0755 "$SRC_DIR/bin/wincolor" "$BIN_DST/wincolor"

echo "installed: $EXT_DST${colors:+ (colors.json 同梱)}"
echo "installed: $BIN_DST/wincolor"
case ":$PATH:" in *":$BIN_DST:"*) ;; *) echo "note: $BIN_DST が PATH に入っていません" ;; esac

if [ -z "${NO_ENABLE:-}" ] && command -v gnome-extensions >/dev/null; then
    if gnome-extensions enable "$UUID" 2>/dev/null; then
        echo "enabled: $UUID"
    else
        echo "note: 有効化に失敗しました。ログイン後に 'gnome-extensions enable $UUID' を実行してください"
    fi
fi
echo "GNOME Shell を再起動してください (X11: Alt+F2 → r / Wayland: ログアウト → ログイン)"
