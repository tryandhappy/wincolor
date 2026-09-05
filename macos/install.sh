#!/bin/bash
# wincolor (macOS版) インストーラ
#
# リリース zip を展開したディレクトリ (wincolor バイナリと shared/ がある) から実行する。
#   ./install.sh              インストールして常駐を起動 (ログイン時に自動起動する LaunchAgent も登録)
#   ./install.sh --uninstall  アンインストール (~/.config/wincolor のユーザー設定は残す)
#
# 環境変数:
#   PREFIX      CLI の配置先 (既定: ~/.local/bin)
#   NO_AGENT=1  LaunchAgent の登録 / 常駐の起動をしない (CI 等)
set -eu

LABEL=jp.smart2j.wincolor
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
BIN_DST="${PREFIX:-$HOME/.local/bin}"
DATA_DIR="$HOME/.local/share/wincolor"
CONF_DIR="$HOME/.config/wincolor"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = --uninstall ]; then
    if [ -z "${NO_AGENT:-}" ] && [ -f "$AGENT" ]; then
        launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl unload "$AGENT" 2>/dev/null || true
    fi
    pkill -x wincolor 2>/dev/null || true
    rm -f "$AGENT" "$BIN_DST/wincolor"
    rm -rf "$DATA_DIR"
    echo "removed: $BIN_DST/wincolor, $DATA_DIR, $AGENT"
    [ -d "$CONF_DIR" ] && echo "kept: $CONF_DIR (ユーザー設定。不要なら手で削除)"
    exit 0
fi

# バイナリの場所: zip 展開直下、または SwiftPM のビルド出力
bin=""
for cand in "$SRC_DIR/wincolor" "$SRC_DIR/.build/release/wincolor"; do
    [ -x "$cand" ] && { bin=$cand; break; }
done
[ -n "$bin" ] || { echo "error: wincolor バイナリが見つかりません (swift build -c release でビルドしてください)" >&2; exit 1; }

# CLI (兼 常駐本体) を配置。ブラウザ経由で落とした zip の隔離属性は外す
mkdir -p "$BIN_DST"
install -m 0755 "$bin" "$BIN_DST/wincolor"
xattr -d com.apple.quarantine "$BIN_DST/wincolor" 2>/dev/null || true
echo "installed: $BIN_DST/wincolor"

# 色プリセット (upgrade で上書き) と自動ルールの雛形 (既存は保護)
shared=""
for cand in "$SRC_DIR/shared" "$SRC_DIR/../shared"; do
    [ -f "$cand/colors.json" ] && { shared=$cand; break; }
done
if [ -n "$shared" ]; then
    mkdir -p "$DATA_DIR"
    install -m 0644 "$shared/colors.json" "$DATA_DIR/colors.json"
    echo "installed: $DATA_DIR/colors.json"
    if [ -f "$CONF_DIR/rules.json" ]; then
        echo "kept: $CONF_DIR/rules.json (既存の自動ルール)"
    elif [ -f "$shared/rules.json" ]; then
        mkdir -p "$CONF_DIR"
        install -m 0644 "$shared/rules.json" "$CONF_DIR/rules.json"
        echo "installed: $CONF_DIR/rules.json (自動ルールの雛形。編集後は wincolor reload)"
    fi
else
    echo "note: shared/colors.json が見つからないため、組み込み既定パレットを使用します"
fi

case ":$PATH:" in *":$BIN_DST:"*) ;; *) echo "note: $BIN_DST が PATH に入っていません" ;; esac

if [ -z "${NO_AGENT:-}" ]; then
    mkdir -p "$(dirname "$AGENT")"
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN_DST/wincolor</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardErrorPath</key><string>/tmp/wincolor.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
    pkill -x wincolor 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || launchctl load "$AGENT" 2>/dev/null; then
        echo "started: $LABEL (ログイン時に自動起動。ログ: /tmp/wincolor.log)"
    else
        echo "note: LaunchAgent の登録に失敗しました。手で 'wincolor' を起動してください"
    fi
    echo "初回はシステム設定 → プライバシーとセキュリティ → アクセシビリティ で wincolor を許可してください"
fi
