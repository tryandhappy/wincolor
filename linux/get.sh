#!/bin/bash
# wincolor (Linux版) ワンライナーインストーラ
#
# GitHub Releases から最新の Linux 版バンドル zip を取得して install.sh を実行する。
#
#   curl -fsSL https://raw.githubusercontent.com/tryandhappy/wincolor/main/linux/get.sh | bash
#
#   バージョン指定:   curl -fsSL .../get.sh | WINCOLOR_VERSION=0.2.2 bash
#   アンインストール: curl -fsSL .../get.sh | bash -s -- --uninstall
#   CLI の配置先変更: curl -fsSL .../get.sh | PREFIX=/usr/local/bin bash
#
# 必要なもの: curl (または wget)、unzip、GNOME Shell 50 / 51
set -euo pipefail

REPO=tryandhappy/wincolor
UUID=window-color-tag@smart2j.jp

msg()  { printf '\033[1m[wincolor]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[wincolor] error:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 依存確認 ----
if command -v curl >/dev/null; then
    fetch() { curl -fsSL "$1" -o "$2"; }
    fetch_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null; then
    fetch() { wget -qO "$2" "$1"; }
    fetch_stdout() { wget -qO- "$1"; }
else
    die "curl か wget が必要です"
fi
command -v unzip >/dev/null || die "unzip が必要です (例: sudo apt install unzip)"

if command -v gnome-shell >/dev/null; then
    shell_ver=$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
    case "$shell_ver" in
        50|51) ;;
        "") msg "警告: GNOME Shell のバージョンを判定できませんでした。対応は 50 / 51 です" ;;
        *)  msg "警告: GNOME Shell $shell_ver は未対応です (対応: 50 / 51)。インストールは続けますが拡張は有効になりません" ;;
    esac
else
    msg "警告: gnome-shell が見つかりません。この拡張は GNOME Shell 専用です (KDE / Xfce 等では動きません)"
fi

# ---- バージョン決定 ----
version=${WINCOLOR_VERSION:-}
if [ -z "$version" ]; then
    # Release は Windows 版と共用なので "latest" ではなく linux-v* の最新タグを探す
    releases=$(fetch_stdout "https://api.github.com/repos/$REPO/releases?per_page=50") \
        || die "GitHub API に接続できません。WINCOLOR_VERSION=X.Y.Z を指定して再実行してください"
    version=$(printf '%s' "$releases" | grep -oE '"tag_name": *"linux-v[0-9]+\.[0-9]+\.[0-9]+"' \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    [ -n "$version" ] || die "Linux 版のリリースが見つかりません"
fi
version=${version#linux-v}; version=${version#v}
zip_name="wincolor-linux-v$version.zip"
url="https://github.com/$REPO/releases/download/linux-v$version/$zip_name"

# ---- 取得と展開 ----
tmp=$(mktemp -d "${TMPDIR:-/tmp}/wincolor.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
msg "wincolor linux v$version を取得中: $url"
fetch "$url" "$tmp/$zip_name" || die "ダウンロードに失敗しました: $url"
unzip -q "$tmp/$zip_name" -d "$tmp"
[ -x "$tmp/wincolor/install.sh" ] || chmod +x "$tmp/wincolor/install.sh"

# ---- インストール (引数は install.sh にそのまま渡す: --uninstall など) ----
"$tmp/wincolor/install.sh" "$@"

if [ "${1:-}" != --uninstall ]; then
    msg "完了。使い方: wincolor --help / Super+C でメニュー / Super+X で色の順送り"
    case ":$PATH:" in *":${PREFIX:-$HOME/.local/bin}:"*) ;; *)
        msg "注意: ${PREFIX:-$HOME/.local/bin} が PATH に入っていません。~/.bashrc 等に追加してください" ;;
    esac
fi
