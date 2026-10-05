import St from 'gi://St';
import GObject from 'gi://GObject';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import Clutter from 'gi://Clutter';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as WindowMenu from 'resource:///org/gnome/shell/ui/windowMenu.js';
import * as SwitcherPopup from 'resource:///org/gnome/shell/ui/switcherPopup.js';
import * as WindowPreview from 'resource:///org/gnome/shell/ui/windowPreview.js';
import * as WorkspaceThumbnail from 'resource:///org/gnome/shell/ui/workspaceThumbnail.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as BoxPointer from 'resource:///org/gnome/shell/ui/boxpointer.js';

const BORDER_WIDTH = 3;
const CORNER_RADIUS = 14;
const TINT_HEIGHT = 40;      // approximate CSD titlebar height
const TINT_OPACITY = 80;     // 0-255

const SWATCH_SIZE = 24;
const SWATCHES_PER_ROW = 8;

const APP_MENU_DOT_SIZE = 12;      // Dock 右クリックの窓一覧に付ける現在色ドット
const APP_MENU_TITLE_MAX = 40;     // 同上の窓タイトルの最大文字数 (超えたら … で切る)

// CSD 窓 (Chrome 等) のタイトルバー右クリックで開くアプリ自前のメニューに、色パレットを添える
const CSD_TITLEBAR_BAND = 40;      // 窓の上端からこの高さまでをタイトルバー (タブ列) とみなす
const POPUP_POINTER_SLOP = 4;      // メニュー窓の角がポインタからこの距離以内なら、右クリックで開いたとみなす
const CSD_PALETTE_GAP = 6;         // メニュー窓とパレットの間隔
const CSD_PALETTE_PADDING = 12;    // パレットの内側余白

const SWITCHER_BORDER_WIDTH = 3;   // Alt+Tab 項目の枠
const SWITCHER_RADIUS = 6;
const SWITCHER_DOT_SIZE = 8;       // 1 アプリに複数色の窓があるときの色ドット

const PREVIEW_BORDER_WIDTH = 4;    // オーバービューのウィンドウプレビューの枠
const PREVIEW_RADIUS = 6;

// ワークスペースサムネイル内の枠。中身は実ウィンドウの座標系のまま _viewport ごと
// 縮小されるので、画面上でこの太さに見えるようスケールで割った値を CSS に入れる
const WS_THUMB_BORDER_PX = 3;
const WS_THUMB_RADIUS_PX = 4;

// 組み込み既定パレット。shared/colors.json が読めない場合のみ使用する
// (内容は shared/colors.json と同一に保つ。Windows 版の DefaultPresets() と同じ)
const DEFAULT_PRESETS = [
    {name: 'red',         label: '赤',   hex: '#C42B1C', textHex: '#FFFFFF'},
    {name: 'darkred',     label: '深紅', hex: '#7E1416', textHex: '#FFFFFF'},
    {name: 'pink',        label: '桃',   hex: '#E3008C', textHex: '#FFFFFF'},
    {name: 'orange',      label: '橙',   hex: '#CA5010', textHex: '#FFFFFF'},
    {name: 'apricot',     label: '杏',   hex: '#E8A33D', textHex: '#000000'},
    {name: 'brown',       label: '茶',   hex: '#8E562E', textHex: '#FFFFFF'},
    {name: 'yellow',      label: '黄',   hex: '#C19C00', textHex: '#000000'},
    {name: 'lightyellow', label: '薄黄', hex: '#E8DB4F', textHex: '#000000'},
    {name: 'lime',        label: '黄緑', hex: '#7CB342', textHex: '#000000'},
    {name: 'green',       label: '緑',   hex: '#107C10', textHex: '#FFFFFF'},
    {name: 'darkgreen',   label: '深緑', hex: '#1B5E20', textHex: '#FFFFFF'},
    {name: 'teal',        label: '青緑', hex: '#00897B', textHex: '#FFFFFF'},
    {name: 'cyan',        label: '水',   hex: '#00B7C3', textHex: '#FFFFFF'},
    {name: 'blue',        label: '青',   hex: '#0F6CBD', textHex: '#FFFFFF'},
    {name: 'navy',        label: '紺',   hex: '#1F3864', textHex: '#FFFFFF'},
    {name: 'sky',         label: '空',   hex: '#5B9BD5', textHex: '#000000'},
    {name: 'purple',      label: '紫',   hex: '#7A34A3', textHex: '#FFFFFF'},
    {name: 'wisteria',    label: '藤',   hex: '#A78BDA', textHex: '#000000'},
    {name: 'magenta',     label: '紅紫', hex: '#B4009E', textHex: '#FFFFFF'},
    {name: 'gray',        label: '灰',   hex: '#5D5D5D', textHex: '#FFFFFF'},
    {name: 'lightgray',   label: '薄灰', hex: '#A6A6A6', textHex: '#000000'},
    {name: 'darkgray',    label: '暗灰', hex: '#333333', textHex: '#FFFFFF'},
];

const HEX_RE = /^#[0-9a-fA-F]{6}$/;
const RELOAD_DEBOUNCE_MS = 500;  // 設定ファイル変更 → 再読み込みまでの待ち
const LAUNCH_FALLBACK_GRACE_MS = 1500;  // PID 不一致の新規窓が出てから、PID 一致の窓をさらに待つ時間
const LAUNCH_MAX_TIMEOUT_MS = 120000;

const DBUS_PATH = '/tryandhappy/WindowColorTag';
const DBUS_IFACE = `
<node>
  <interface name="tryandhappy.WindowColorTag">
    <method name="Set">
      <arg type="s" name="target" direction="in"/>
      <arg type="s" name="color" direction="in"/>
      <arg type="s" name="result" direction="out"/>
    </method>
    <method name="Clear">
      <arg type="s" name="target" direction="in"/>
      <arg type="s" name="result" direction="out"/>
    </method>
    <method name="ClearAll">
      <arg type="s" name="result" direction="out"/>
    </method>
    <method name="List">
      <arg type="s" name="result" direction="out"/>
    </method>
    <method name="Palette">
      <arg type="s" name="result" direction="out"/>
    </method>
    <method name="Rules">
      <arg type="s" name="result" direction="out"/>
    </method>
    <method name="Reload">
      <arg type="s" name="result" direction="out"/>
    </method>
    <method name="TagPid">
      <arg type="i" name="pid" direction="in"/>
      <arg type="s" name="color" direction="in"/>
      <arg type="i" name="timeoutMs" direction="in"/>
      <arg type="s" name="result" direction="out"/>
    </method>
  </interface>
</node>`;

export default class WindowColorTagExtension extends Extension {
    enable() {
        this._tags = new Map(); // MetaWindow -> {name, hex, border, tint, winIds, actorIds}
        this._presets = this._loadPresets();
        this._rules = this._loadRules();

        this._dbus = Gio.DBusExportedObject.wrapJSObject(DBUS_IFACE, this);
        this._dbus.export(Gio.DBus.session, DBUS_PATH);

        this._restackedId = global.display.connect('restacked',
            () => this._restackAll());

        // ウィンドウメニュー (タイトルバー右クリック / Alt+Space) に色スウォッチ行を追加
        const ext = this;
        this._origBuildMenu = WindowMenu.WindowMenu.prototype._buildMenu;
        const origBuildMenu = this._origBuildMenu;
        WindowMenu.WindowMenu.prototype._buildMenu = function (window) {
            origBuildMenu.call(this, window);
            ext._appendColorRow(this, window);
        };

        // Dock (ubuntu-dock / dash-to-dock) と GNOME 標準 Dash のアイコン右クリックメニューにも
        // 色タグ欄を足す。ubuntu-dock のメニュークラスは export されていないので、
        // PopupMenu.open を包み、開く直前に 'app-menu' クラスのメニューかどうかで判定する。
        // Dock は開いたままのメニューに再度 popup() すると中身を作り直す (色タグ欄も消える) ので、
        // 開いていても欄が無くなっていれば足し直す
        this._appMenuSections = new Set();
        this._origMenuOpen = PopupMenu.PopupMenu.prototype.open;
        const origMenuOpen = this._origMenuOpen;
        PopupMenu.PopupMenu.prototype.open = function (...args) {
            if (!this.isOpen || !this._wincolorSection) {
                try {
                    ext._prepareAppMenu(this);
                } catch (e) {
                    console.error(e, 'wincolor: failed to add color section to app menu');
                }
            }
            return origMenuOpen.apply(this, args);
        };

        // Alt+Tab (アプリ切り替え / ウィンドウ切り替え / サムネイル一覧) の各項目にも色を反映する
        this._origAddItem = SwitcherPopup.SwitcherList.prototype.addItem;
        const origAddItem = this._origAddItem;
        SwitcherPopup.SwitcherList.prototype.addItem = function (item, label) {
            const bbox = origAddItem.call(this, item, label);
            try {
                ext._decorateSwitcherItem(this, item);
            } catch (e) {
                console.error(e, 'wincolor: failed to decorate switcher item');
            }
            return bbox;
        };

        // オーバービューのウィンドウプレビューにも色枠を重ねる
        this._previews = new Set();
        this._origPreviewInit = WindowPreview.WindowPreview.prototype._init;
        const origPreviewInit = this._origPreviewInit;
        WindowPreview.WindowPreview.prototype._init = function (...args) {
            origPreviewInit.apply(this, args);
            try {
                ext._decorateWindowPreview(this);
            } catch (e) {
                console.error(e, 'wincolor: failed to decorate window preview');
            }
        };

        // ワークスペースサムネイル内の小さなウィンドウにも色枠を重ねる。
        // 枠の太さはサムネイルの縮小率に依存するので、setScale も包んで追従させる
        this._wsClones = new Set();
        this._origCloneInit = WorkspaceThumbnail.WindowClone.prototype._init;
        const origCloneInit = this._origCloneInit;
        WorkspaceThumbnail.WindowClone.prototype._init = function (...args) {
            origCloneInit.apply(this, args);
            try {
                ext._decorateWorkspaceClone(this);
            } catch (e) {
                console.error(e, 'wincolor: failed to decorate workspace clone');
            }
        };

        this._origSetScale = WorkspaceThumbnail.WorkspaceThumbnail.prototype.setScale;
        const origSetScale = this._origSetScale;
        WorkspaceThumbnail.WorkspaceThumbnail.prototype.setScale = function (scaleX, scaleY) {
            origSetScale.call(this, scaleX, scaleY);
            try {
                for (const clone of this._windows ?? [])
                    ext._syncWorkspaceClone(clone, scaleX);
            } catch (e) {
                console.error(e, 'wincolor: failed to rescale workspace clone border');
            }
        };

        // CSD ウィンドウ (Chrome 等) はタイトルバー右クリックが効かないため、
        // mutter ネイティブのキーバインドでメニューを開けるようにする
        this._settings = this.getSettings();
        Main.wm.addKeybinding('open-window-menu', this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => this._openMenuForFocused());
        Main.wm.addKeybinding('cycle-color', this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => this.Set('focused', 'next'));

        this._pendingLaunches = [];  // TagPid の待ち行列
        this._startRules();
        this._startConfigMonitors();
        this._startCsdMenuWatch();
    }

    disable() {
        this._stopCsdMenuWatch();
        this._stopConfigMonitors();
        this._cancelLaunches('extension disabled');
        this._stopRules();
        Main.wm.removeKeybinding('open-window-menu');
        Main.wm.removeKeybinding('cycle-color');
        this._settings = null;
        this.ClearAll();
        this._tags = null;
        this._presets = null;
        this._rules = null;
        if (this._restackedId) {
            global.display.disconnect(this._restackedId);
            this._restackedId = null;
        }
        if (this._dbus) {
            this._dbus.unexport();
            this._dbus = null;
        }
        if (this._origBuildMenu) {
            WindowMenu.WindowMenu.prototype._buildMenu = this._origBuildMenu;
            this._origBuildMenu = null;
        }
        if (this._origMenuOpen) {
            PopupMenu.PopupMenu.prototype.open = this._origMenuOpen;
            this._origMenuOpen = null;
        }
        // 標準 AppMenu は開くたびに作り直さないので、足した色タグ欄をここで外しておく
        for (const section of [...(this._appMenuSections ?? [])])
            section.destroy();
        this._appMenuSections = null;
        if (this._origAddItem) {
            SwitcherPopup.SwitcherList.prototype.addItem = this._origAddItem;
            this._origAddItem = null;
        }
        if (this._origPreviewInit) {
            WindowPreview.WindowPreview.prototype._init = this._origPreviewInit;
            this._origPreviewInit = null;
        }
        this._previews = null;
        if (this._origCloneInit) {
            WorkspaceThumbnail.WindowClone.prototype._init = this._origCloneInit;
            this._origCloneInit = null;
        }
        if (this._origSetScale) {
            WorkspaceThumbnail.WorkspaceThumbnail.prototype.setScale = this._origSetScale;
            this._origSetScale = null;
        }
        this._wsClones = null;
    }

    // ---- palette ----

    // 設定ファイルの探索順 (colors.json / rules.json 共通):
    //   1. ユーザー設定 ~/.config/wincolor/<name> (install.sh が rules.json の雛形を置く。upgrade で消えない)
    //   2. 拡張ディレクトリ直下 (install.sh / リリース zip が colors.json を同梱する)
    //   3. リポジトリ構成 (linux/gnome-extension/ から見た ../../shared/)
    _configCandidates(name) {
        return [
            GLib.build_filenamev([GLib.get_user_config_dir(), 'wincolor', name]),
            GLib.build_filenamev([this.path, name]),
            GLib.build_filenamev([this.path, '..', '..', 'shared', name]),
        ];
    }

    // 探索順に JSON を読み、最初に読めたものを {path, data} で返す。無ければ null
    _readFirstJson(name) {
        for (const path of this._configCandidates(name)) {
            const file = Gio.File.new_for_path(path);
            if (!file.query_exists(null))
                continue;
            try {
                const [, bytes] = file.load_contents(null);
                return {path, data: JSON.parse(new TextDecoder().decode(bytes))};
            } catch (e) {
                console.warn(`[window-color-tag] failed to load ${path}: ${e.message}`);
            }
        }
        return null;
    }

    // shared/colors.json を読む。読めなければ組み込み既定 (DEFAULT_PRESETS) を使う
    _loadPresets() {
        const found = this._readFirstJson('colors.json');
        if (found) {
            const presets = (Array.isArray(found.data.presets) ? found.data.presets : [])
                .filter(p => typeof p.name === 'string' && p.name !== '' &&
                             HEX_RE.test(p.hex ?? ''))
                .map(p => ({
                    name: p.name,
                    label: typeof p.label === 'string' ? p.label : p.name,
                    hex: p.hex.toUpperCase(),
                    textHex: p.textHex ?? '',
                }));
            if (presets.length > 0) {
                this._presetsPath = found.path;
                return presets;
            }
            console.warn(`[window-color-tag] ${found.path}: no valid presets, using built-in defaults`);
        }
        this._presetsPath = null;
        return DEFAULT_PRESETS;
    }

    // shared/rules.json を読む。形式は Windows 版と同じ:
    //   { "rules": [ { "title": "正規表現", "exe": "正規表現", "color": "プリセット名 or #RRGGBB" } ] }
    // title / exe は片方だけでも可 (大文字小文字無視)。Linux では exe をプロセス名と
    // WM_CLASS (Wayland の app-id) の両方に対して照合する。上のルールが優先
    _loadRules() {
        const found = this._readFirstJson('rules.json');
        this._rulesPath = found?.path ?? null;
        if (!found)
            return [];
        const rules = [];
        const list = Array.isArray(found.data.rules) ? found.data.rules : [];
        list.forEach((r, i) => {
            const title = typeof r.title === 'string' && r.title !== '' ? r.title : null;
            const exe = typeof r.exe === 'string' && r.exe !== '' ? r.exe : null;
            const color = typeof r.color === 'string' ? r.color : '';
            if ((!title && !exe) || !color) {
                console.warn(`[window-color-tag] rules[${i}]: needs title and/or exe, and color; skipped`);
                return;
            }
            if (!this._resolveColor(color)) {
                console.warn(`[window-color-tag] rules[${i}]: unknown color "${color}"; skipped`);
                return;
            }
            try {
                rules.push({
                    title: title ? new RegExp(title, 'i') : null,
                    exe: exe ? new RegExp(exe, 'i') : null,
                    titleSrc: title ?? '',
                    exeSrc: exe ?? '',
                    color,
                });
            } catch (e) {
                console.warn(`[window-color-tag] rules[${i}]: invalid regex (${e.message}); skipped`);
            }
        });
        return rules;
    }

    // プリセット名 (大文字小文字無視) / ラベル / #RRGGBB を {name, hex} に解決する。
    // #RRGGBB がプリセットと一致すればその名前を付ける。解決できなければ null
    _resolveColor(spec) {
        const s = spec.trim();
        const lower = s.toLowerCase();
        let preset = this._presets.find(p => p.name.toLowerCase() === lower || p.label === s);
        if (!preset && HEX_RE.test(s))
            preset = this._presets.find(p => p.hex === s.toUpperCase());
        if (preset)
            return {name: preset.name, hex: preset.hex};
        if (HEX_RE.test(s))
            return {name: null, hex: s.toUpperCase()};
        return null;
    }

    _describe(tag) {
        return tag.name ? `${tag.name} (${tag.hex})` : tag.hex;
    }

    // ---- D-Bus methods ----

    Set(target, color) {
        const win = this._resolve(target);
        if (!win)
            return `no window for target: ${target}`;
        let resolved;
        if (color === 'next' || color === 'prev') {
            resolved = this._cycleColor(win, color === 'next' ? 1 : -1);
            if (!resolved) {
                this._removeTag(win);
                return `cleared: [${win.get_id()}]`;
            }
        } else {
            resolved = this._resolveColor(color);
            if (!resolved) {
                const names = this._presets.map(p => p.name).join(', ');
                return `invalid color: ${color} (use #RRGGBB or one of: ${names})`;
            }
        }
        this._markManual(win);
        this._addTag(win, resolved);
        return `ok: [${win.get_id()}] ${win.get_wm_class() ?? '?'} "${win.get_title() ?? ''}" -> ${this._describe(resolved)}`;
    }

    Clear(target) {
        const win = this._resolve(target);
        if (!win)
            return `no window for target: ${target}`;
        this._markManual(win);   // ユーザーが消した窓を自動ルールで塗り直さない
        if (!this._tags.has(win))
            return 'not tagged';
        this._removeTag(win);
        return `cleared: [${win.get_id()}]`;
    }

    ClearAll() {
        if (!this._tags)
            return 'ok';
        for (const win of [...this._tags.keys()]) {
            this._markManual(win);
            this._removeTag(win);
        }
        return 'ok';
    }

    List() {
        const lines = [];
        for (const actor of global.get_window_actors()) {
            const w = actor.meta_window;
            if (!w || w.is_skip_taskbar())
                continue;
            const tag = this._tags.get(w);
            const color = tag ? (tag.name ?? tag.hex) : '-';
            lines.push(`${w.get_id()}\t${w.get_wm_class() ?? '?'}\t${color}\t${w.get_title() ?? ''}`);
        }
        return lines.join('\n');
    }

    // 利用可能なプリセット一覧 (name / label / hex)。先頭行に読み込み元を出す
    Palette() {
        const lines = [`# source: ${this._presetsPath ?? 'built-in defaults'}`];
        for (const p of this._presets)
            lines.push(`${p.name}\t${p.label}\t${p.hex}`);
        return lines.join('\n');
    }

    // 読み込み済みの自動ルール一覧 (title / exe / color)。先頭行に読み込み元を出す
    Rules() {
        const lines = [`# source: ${this._rulesPath ?? 'none'}`];
        for (const r of this._rules)
            lines.push(`${r.titleSrc || '-'}\t${r.exeSrc || '-'}\t${r.color}`);
        return lines.join('\n');
    }

    // colors.json / rules.json を再読み込みし、まだ色を確定していない窓へルールを再適用
    Reload() {
        this._presets = this._loadPresets();
        this._rules = this._loadRules();
        this._startConfigMonitors();
        for (const actor of global.get_window_actors())
            this._watchWindow(actor.meta_window);
        return `presets: ${this._presets.length} (${this._presetsPath ?? 'built-in defaults'})\n` +
               `rules: ${this._rules.length} (${this._rulesPath ?? 'none'})`;
    }

    // ---- launcher (wincolor run) ----

    // CLI が起動したプロセス (pid) のウィンドウが現れたら色を付ける。結果が出るまで返さない
    // (GJS の DBusExportedObject は <name>Async があれば invocation 付きで呼ぶ)。
    // 判定: 窓の pid が一致、または pid の子孫プロセス。PID を引き継がないアプリ
    // (gnome-terminal のクライアント/サーバ型、既存インスタンスへ委譲するブラウザ等) のため、
    // 不一致の新規窓が出た場合も LAUNCH_FALLBACK_GRACE_MS だけ一致を待ってから、その窓に付ける
    TagPidAsync([pid, colorSpec, timeoutMs], invocation) {
        const reply = s => invocation.return_value(new GLib.Variant('(s)', [s]));
        const color = this._resolveColor(colorSpec);
        if (!color) {
            reply(`invalid color: ${colorSpec}`);
            return;
        }
        if (!Number.isInteger(pid) || pid <= 1) {
            reply(`invalid pid: ${pid}`);
            return;
        }
        const timeout = Math.min(Math.max(timeoutMs, 500), LAUNCH_MAX_TIMEOUT_MS);
        const p = {pid, color, reply, fallback: null, timeoutId: 0, graceId: 0};

        // すでに窓が出ている場合 (起動が速いアプリ)
        for (const actor of global.get_window_actors()) {
            const w = actor.meta_window;
            if (w && !w.is_skip_taskbar() && this._belongsToPid(w, pid)) {
                this._finishLaunch(p, w, 'pid');
                return;
            }
        }

        p.timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, timeout, () => {
            p.timeoutId = 0;
            this._finishLaunch(p, p.fallback, p.fallback ? 'fallback (timeout)' : null);
            return GLib.SOURCE_REMOVE;
        });
        this._pendingLaunches.push(p);
    }

    _onWindowCreatedForLaunch(win) {
        if (!this._pendingLaunches?.length || !win || win.is_skip_taskbar())
            return;
        for (const p of [...this._pendingLaunches]) {
            if (this._belongsToPid(win, p.pid)) {
                this._finishLaunch(p, win, 'pid');
            } else if (!p.fallback) {
                p.fallback = win;
                p.graceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, LAUNCH_FALLBACK_GRACE_MS, () => {
                    p.graceId = 0;
                    this._finishLaunch(p, p.fallback, 'fallback');
                    return GLib.SOURCE_REMOVE;
                });
            }
        }
    }

    _finishLaunch(p, win, how) {
        const i = this._pendingLaunches?.indexOf(p) ?? -1;
        if (i >= 0)
            this._pendingLaunches.splice(i, 1);
        if (p.timeoutId)
            GLib.source_remove(p.timeoutId);
        if (p.graceId)
            GLib.source_remove(p.graceId);
        p.timeoutId = p.graceId = 0;
        if (!win) {
            p.reply(`no window appeared for pid ${p.pid}`);
            return;
        }
        this._markManual(win);
        this._addTag(win, p.color);
        p.reply(`ok: [${win.get_id()}] ${win.get_wm_class() ?? '?'} "${win.get_title() ?? ''}" -> ${this._describe(p.color)} (matched by ${how}, pid ${win.get_pid()})`);
    }

    _cancelLaunches(reason) {
        for (const p of [...(this._pendingLaunches ?? [])]) {
            this._pendingLaunches.splice(this._pendingLaunches.indexOf(p), 1);
            if (p.timeoutId)
                GLib.source_remove(p.timeoutId);
            if (p.graceId)
                GLib.source_remove(p.graceId);
            p.reply(`cancelled: ${reason}`);
        }
        this._pendingLaunches = null;
    }

    // 窓の pid が pid と一致するか、pid の子孫プロセスか
    _belongsToPid(win, pid) {
        let cur = win.get_pid();
        for (let depth = 0; depth < 32 && cur > 1; depth++) {
            if (cur === pid)
                return true;
            cur = this._parentPid(cur);
        }
        return false;
    }

    // /proc/<pid>/stat から親 pid を読む。読めなければ 0
    _parentPid(pid) {
        try {
            const [ok, bytes] = GLib.file_get_contents(`/proc/${pid}/stat`);
            if (!ok)
                return 0;
            const stat = new TextDecoder().decode(bytes);
            // "pid (comm) S ppid ..." — comm に空白や括弧が入り得るので最後の ')' 以降を見る
            const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
            return Number(fields[1]) || 0;
        } catch {
            return 0;
        }
    }

    // ---- auto rules ----

    // 新規ウィンドウとタイトル/クラス変化を監視してルールを照合する。
    // 一度色を確定した窓 (ルール適用済み / 手動で色を付けた・消した窓) には再適用しない
    _startRules() {
        this._ruleDone = new WeakSet();  // MetaWindow。unmanaged 後は GC に任せる
        this._watched = new Map();       // MetaWindow -> signal ids
        this._windowCreatedId = global.display.connect('window-created', (_display, win) => {
            this._onWindowCreatedForLaunch(win);
            this._watchWindow(win);
        });
        for (const actor of global.get_window_actors())
            this._watchWindow(actor.meta_window);
    }

    _stopRules() {
        if (this._windowCreatedId) {
            global.display.disconnect(this._windowCreatedId);
            this._windowCreatedId = null;
        }
        if (this._watched) {
            for (const win of [...this._watched.keys()])
                this._unwatchWindow(win);
            this._watched = null;
        }
        this._ruleDone = null;
    }

    _watchWindow(win) {
        if (!win || !this._watched || this._ruleDone.has(win))
            return;
        if (this._watched.has(win)) {
            this._evaluateRules(win);
            return;
        }
        const ids = [
            win.connect('notify::title', () => this._evaluateRules(win)),
            win.connect('notify::wm-class', () => this._evaluateRules(win)),
            win.connect('unmanaged', () => this._unwatchWindow(win)),
        ];
        this._watched.set(win, ids);
        this._evaluateRules(win);
    }

    _unwatchWindow(win) {
        const ids = this._watched?.get(win);
        if (!ids)
            return;
        for (const id of ids)
            win.disconnect(id);
        this._watched.delete(win);
    }

    // 手動操作した窓: 以後ルールの対象外にする
    _markManual(win) {
        this._ruleDone?.add(win);
        this._unwatchWindow(win);
    }

    _evaluateRules(win) {
        if (!this._rules?.length || this._ruleDone.has(win) || win.is_skip_taskbar())
            return;
        const title = win.get_title() ?? '';
        if (title === '')
            return;  // Wayland ではタイトルが後から付くので、付いてから照合する
        const wmClass = win.get_wm_class() ?? '';
        let exe = null;  // 必要になった時だけ /proc を読む
        for (const r of this._rules) {
            if (r.title && !r.title.test(title))
                continue;
            if (r.exe) {
                exe ??= this._processName(win);
                if (!r.exe.test(exe) && !r.exe.test(wmClass))
                    continue;
            }
            const color = this._resolveColor(r.color);
            if (!color)
                continue;
            this._ruleDone.add(win);
            this._unwatchWindow(win);
            this._addTag(win, color);
            return;
        }
    }

    // ウィンドウの実行ファイル名 (/proc/<pid>/exe の basename、無理なら comm)。不明なら ''
    _processName(win) {
        const pid = win.get_pid();
        if (!pid || pid <= 0)
            return '';
        try {
            return GLib.path_get_basename(GLib.file_read_link(`/proc/${pid}/exe`));
        } catch {
            // Flatpak 等で exe が読めない場合は comm にフォールバック
        }
        try {
            const [ok, bytes] = GLib.file_get_contents(`/proc/${pid}/comm`);
            return ok ? new TextDecoder().decode(bytes).trim() : '';
        } catch {
            return '';
        }
    }

    // ---- config file monitors ----

    // colors.json / rules.json の読み込み元と、ユーザー設定ディレクトリの候補を監視し、
    // 変更があれば少し待ってから Reload する (エディタの保存は複数イベントになるため)
    _startConfigMonitors() {
        this._stopConfigMonitors();
        this._monitors = [];
        const paths = new Set();
        for (const name of ['colors.json', 'rules.json']) {
            paths.add(this._configCandidates(name)[0]);  // ユーザー設定 (未作成でも監視できる)
            const loaded = name === 'colors.json' ? this._presetsPath : this._rulesPath;
            if (loaded)
                paths.add(loaded);
        }
        for (const path of paths) {
            try {
                const mon = Gio.File.new_for_path(path).monitor_file(Gio.FileMonitorFlags.NONE, null);
                mon.connect('changed', () => this._scheduleReload());
                this._monitors.push(mon);
            } catch (e) {
                console.warn(`[window-color-tag] cannot monitor ${path}: ${e.message}`);
            }
        }
    }

    _stopConfigMonitors() {
        if (this._reloadTimeoutId) {
            GLib.source_remove(this._reloadTimeoutId);
            this._reloadTimeoutId = null;
        }
        for (const mon of this._monitors ?? [])
            mon.cancel();
        this._monitors = null;
    }

    _scheduleReload() {
        if (this._reloadTimeoutId)
            GLib.source_remove(this._reloadTimeoutId);
        this._reloadTimeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, RELOAD_DEBOUNCE_MS, () => {
            this._reloadTimeoutId = null;
            console.log(`[window-color-tag] config changed: ${this.Reload().replace('\n', ', ')}`);
            return GLib.SOURCE_REMOVE;
        });
    }

    // ---- window menu ----

    _appendColorRow(menu, window) {
        menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('色タグ'));
        menu.addMenuItem(this._buildSwatchItem(window, () => menu.close()));
    }

    // 色スウォッチ (プリセット + 「消す」) を並べたメニュー項目を作る。
    // 押すと window に色を付け (または消し)、onDone を呼ぶ (メニューを閉じる等)
    _buildSwatchItem(window, onDone) {
        const item = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
        });
        item.add_child(this._buildSwatchGrid(window, onDone));
        return item;
    }

    // スウォッチの格子 (St.BoxLayout) を作る。perRow 個ずつ折り返す。
    // canFocus: false にすると押してもキーフォーカスを Shell 側に取らない
    // (Chrome のメニュー窓にキーボードを残したまま Escape を届けるため)
    _buildSwatchGrid(window, onDone, {perRow = SWATCHES_PER_ROW, canFocus = true} = {}) {
        const rows = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style: 'spacing: 6px;',
        });

        const current = this._tags.get(window)?.hex;

        // プリセット + 「消す」ボタンを perRow 個ずつ折り返して並べる
        let box = null;
        const addSwatch = btn => {
            if (!box || box.get_n_children() >= perRow) {
                box = new St.BoxLayout({style: 'spacing: 8px;'});
                rows.add_child(box);
            }
            box.add_child(btn);
        };

        for (const p of this._presets) {
            const selected = p.hex === current;
            const btn = new St.Button({
                width: SWATCH_SIZE,
                height: SWATCH_SIZE,
                can_focus: canFocus,
                track_hover: true,
                accessible_name: `${p.label} (${p.name})`,
                style: `background-color: ${p.hex}; ` +
                       `border-radius: ${SWATCH_SIZE / 2}px; ` +
                       `border: 2px solid ${selected ? 'white' : 'transparent'};`,
            });
            btn.connect('clicked', () => {
                this._markManual(window);
                this._addTag(window, {name: p.name, hex: p.hex});
                onDone();
            });
            addSwatch(btn);
        }

        const offBtn = new St.Button({
            width: SWATCH_SIZE,
            height: SWATCH_SIZE,
            can_focus: canFocus,
            track_hover: true,
            accessible_name: '色を消す',
            style: `border-radius: ${SWATCH_SIZE / 2}px; border: 2px solid #888;`,
            child: new St.Icon({icon_name: 'edit-clear-symbolic', icon_size: 12}),
        });
        offBtn.connect('clicked', () => {
            this._markManual(window);
            this._removeTag(window);
            onDone();
        });
        addSwatch(offBtn);

        return rows;
    }

    // ---- dock / dash app menu ----

    // アプリアイコンの右クリックメニュー (ubuntu-dock の DockAppIconMenu、GNOME 標準の AppMenu)
    // を開く直前に呼ばれる。「終了」の上に色タグ欄を足す。
    //   窓が 1 つ   … スウォッチ行をそのまま並べる
    //   窓が複数    … 窓タイトルごとの折りたたみ項目 (現在色ドット付き)。開くとスウォッチ行
    _prepareAppMenu(menu) {
        // 前回足した欄を外す (Dock は開くたびに作り直すが、標準 AppMenu は作り直さない)
        menu._wincolorSection?.destroy();
        if (!this._tags || !menu.actor?.has_style_class_name?.('app-menu'))
            return;
        const app = menu.sourceActor?.app ?? menu._app;
        if (!app?.get_windows)
            return;
        // Dock はモニタ/ワークスペースの絞り込み設定を反映した窓一覧を持つので、あればそれに合わせる
        const all = menu.sourceActor?.getInterestingWindows?.() ?? app.get_windows();
        const windows = all.filter(w => w && !w.is_skip_taskbar());
        if (windows.length === 0)
            return;

        const done = () => menu.close(BoxPointer.PopupAnimation.FULL);
        const section = new PopupMenu.PopupMenuSection();
        section.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('色タグ'));
        if (windows.length === 1) {
            section.addMenuItem(this._buildSwatchItem(windows[0], done));
        } else {
            for (const win of windows)
                section.addMenuItem(this._buildWindowColorSubmenu(win, app, done));
        }

        // 「終了」とその直前の区切り線の上に入れる。見つからなければ末尾
        const items = menu._getMenuItems();
        let pos = items.indexOf(menu._quitMenuItem ?? menu._quitItem);
        if (pos > 0 && items[pos - 1] instanceof PopupMenu.PopupSeparatorMenuItem)
            pos--;
        menu.addMenuItem(section, pos >= 0 ? pos : undefined);

        menu._wincolorSection = section;
        this._appMenuSections.add(section);
        section.connect('destroy', () => {
            this._appMenuSections?.delete(section);
            if (menu._wincolorSection === section)
                menu._wincolorSection = null;
        });
    }

    // 窓 1 つ分の折りたたみ項目: 「● 窓タイトル ▸」、開くとその窓用のスウォッチ行
    _buildWindowColorSubmenu(win, app, onDone) {
        let title = win.get_title() || app.get_name() || '?';
        const chars = [...title];
        if (chars.length > APP_MENU_TITLE_MAX)
            title = `${chars.slice(0, APP_MENU_TITLE_MAX - 1).join('')}…`;

        const sub = new PopupMenu.PopupSubMenuMenuItem(title, false);
        const hex = this._tags.get(win)?.hex;
        sub.insert_child_at_index(new St.Widget({
            width: APP_MENU_DOT_SIZE,
            height: APP_MENU_DOT_SIZE,
            y_align: Clutter.ActorAlign.CENTER,
            style: `border-radius: ${APP_MENU_DOT_SIZE / 2}px; ` +
                   (hex ? `background-color: ${hex};` : 'border: 1px solid #888;'),
        }), 0);
        sub.menu.addMenuItem(this._buildSwatchItem(win, onDone));

        // メニューを開いている間に窓が閉じたら項目も消す
        const id = win.connect('unmanaged', () => sub.destroy());
        sub.connect('destroy', () => win.disconnect(id));
        return sub;
    }

    // ---- CSD titlebar menu (Chrome 等) ----

    // Chrome などの CSD 窓は、タイトルバー (タブ列) の右クリックでアプリ自前のメニューを出す。
    // そのメニューは他プロセスが描くので項目は足せない。そこで、タイトルバー帯で開いた
    // メニュー窓 (xdg_popup) を検知し、すぐ下 (上向きに開いたときは上、入らなければ横) に
    // 色パレットを添える。
    //   - フォーカス済みの Wayland 窓へのクリックは拡張から見えない (Clutter のイベントフィルタにも
    //     来ない。実測) ため、「ポインタが縁の上にある状態で開いたメニュー窓」を右クリックで開いたと
    //     みなす。ボタンに揃えて開くメニューやホバーカードはポインタから離れているので除外される
    //   - パレットは Shell の UI なので、Chrome のメニューを開いたまま押せる (実測)
    //   - 色を選んだら Escape を送って Chrome のメニューを閉じる。メニュー窓に
    //     MetaWindow.delete() を呼ぶと GNOME Shell 50.1 が落ちる (実測) ので使わない
    _startCsdMenuWatch() {
        this._csdPalette = null;   // {actor, popup, ids: [[obj, id], ...]}
        this._csdWindowCreatedId = global.display.connect('window-created',
            (_display, win) => {
                try {
                    this._onMenuWindowCreated(win);
                } catch (e) {
                    console.error(e, 'wincolor: failed to watch app menu window');
                }
            });
    }

    _stopCsdMenuWatch() {
        if (this._csdWindowCreatedId) {
            global.display.disconnect(this._csdWindowCreatedId);
            this._csdWindowCreatedId = null;
        }
        this._closeCsdPalette();
        this._virtualKeyboard = null;
    }

    _onMenuWindowCreated(popup) {
        const type = popup.get_window_type();
        if (type !== Meta.WindowType.DROPDOWN_MENU && type !== Meta.WindowType.POPUP_MENU)
            return;
        const parent = popup.get_transient_for();
        if (!parent || parent.decorated || parent.is_skip_taskbar() ||
            parent.get_window_type() !== Meta.WindowType.NORMAL)
            return;

        // 開いた瞬間のポインタがタイトルバー帯の中にあるか
        const [px, py] = global.get_pointer();
        const frame = parent.get_frame_rect();
        if (px < frame.x || px >= frame.x + frame.width ||
            py < frame.y || py >= frame.y + CSD_TITLEBAR_BAND)
            return;

        // xdg_popup は 0x0 で現れ、configure 後に位置と大きさが決まる
        const ids = [];
        const stop = () => {
            for (const id of ids.splice(0))
                popup.disconnect(id);
        };
        // 右クリックのメニューはポインタ位置を起点に開き、画面端では反転するか画面内へずらされる。
        // どの場合もポインタはメニュー窓の縁の上に残るので、それで判定する
        const check = () => {
            const r = popup.get_frame_rect();
            if (r.width <= 0 || r.height <= 0)
                return;
            stop();
            const s = POPUP_POINTER_SLOP;
            const near = (a, b) => Math.abs(a - b) <= s;
            const inX = px >= r.x - s && px <= r.x + r.width + s;
            const inY = py >= r.y - s && py <= r.y + r.height + s;
            const onEdge = (inY && (near(r.x, px) || near(r.x + r.width, px))) ||
                           (inX && (near(r.y, py) || near(r.y + r.height, py)));
            if (onEdge) {
                const openedUp = near(r.y + r.height, py) && !near(r.y, py);
                this._openCsdPalette(popup, parent, r, openedUp);
            }
        };
        ids.push(popup.connect('size-changed', check));
        ids.push(popup.connect('position-changed', check));
        ids.push(popup.connect('unmanaged', stop));
        check();
    }

    // メニュー窓 popup (矩形 r) の脇に、parent 用の色パレットを出す。
    // openedUp: メニューがポインタから上向きに開いた (パレットも上側に置き、クリック位置を隠さない)
    _openCsdPalette(popup, parent, r, openedUp) {
        this._closeCsdPalette();

        // メニュー窓の幅に収まる個数で折り返し、各行の個数をそろえる (12+11、8+8+7 など)
        const step = SWATCH_SIZE + 8;   // スウォッチ 1 個分の幅 (間隔込み)
        const total = this._presets.length + 1;   // + 「消す」
        const fit = Math.max(SWATCHES_PER_ROW,
            Math.floor((r.width - 2 * CSD_PALETTE_PADDING + 8) / step));
        const perRow = Math.ceil(total / Math.ceil(total / fit));
        // 見た目は Shell のポップアップメニューに合わせる (文字色は popup-menu、背景と角丸は -content)
        const actor = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style_class: 'popup-menu popup-menu-content',
            style: `padding: ${CSD_PALETTE_PADDING}px; spacing: 8px;`,
            reactive: true,
        });
        actor.add_child(new St.Label({
            text: '色タグ',
            style: 'font-size: 0.9em; font-weight: bold;',
        }));
        actor.add_child(this._buildSwatchGrid(parent, () => this._finishCsdPalette(),
            {perRow, canFocus: false}));

        Main.uiGroup.add_child(actor);
        Main.uiGroup.set_child_above_sibling(actor, null);

        // 置き場所: メニュー窓の下 (上向きに開いたときは上) → 反対側 → 右 → 左。
        // 作業領域からはみ出さないよう寄せる
        const [, natW] = actor.get_preferred_width(-1);
        const width = Math.max(natW, r.width);
        const [, natH] = actor.get_preferred_height(width);
        actor.set_size(width, natH);
        const monitor = popup.get_monitor() >= 0 ? popup.get_monitor() : parent.get_monitor();
        const area = Main.layoutManager.getWorkAreaForMonitor(monitor);
        const below = r.y + r.height + CSD_PALETTE_GAP;
        const above = r.y - natH - CSD_PALETTE_GAP;
        let x = r.x;
        let y = (openedUp ? [above, below] : [below, above])
            .find(cy => cy >= area.y && cy + natH <= area.y + area.height);
        if (y === undefined) {
            y = r.y;
            x = r.x + r.width + CSD_PALETTE_GAP;
            if (x + width > area.x + area.width)
                x = r.x - width - CSD_PALETTE_GAP;
        }
        x = Math.max(area.x, Math.min(x, area.x + area.width - width));
        y = Math.max(area.y, Math.min(y, area.y + area.height - natH));
        actor.set_position(Math.round(x), Math.round(y));

        // メニューが閉じた・窓が閉じたらパレットも消す
        const close = () => this._closeCsdPalette();
        this._csdPalette = {
            actor, popup,
            ids: [
                [popup, popup.connect('unmanaged', close)],
                [parent, parent.connect('unmanaged', close)],
            ],
        };
    }

    // パレットで色を選んだあと: パレットを消し、まだ開いている Chrome のメニューを Escape で閉じる
    _finishCsdPalette() {
        const popup = this._csdPalette?.popup;
        this._closeCsdPalette();
        if (!popup || !global.get_window_actors().some(a => a.meta_window === popup))
            return;
        if (!this._virtualKeyboard) {
            const seat = Clutter.get_default_backend().get_default_seat();
            this._virtualKeyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        }
        const t = GLib.get_monotonic_time();
        this._virtualKeyboard.notify_keyval(t, Clutter.KEY_Escape, Clutter.KeyState.PRESSED);
        this._virtualKeyboard.notify_keyval(t + 1, Clutter.KEY_Escape, Clutter.KeyState.RELEASED);
    }

    _closeCsdPalette() {
        const p = this._csdPalette;
        if (!p)
            return;
        this._csdPalette = null;
        for (const [obj, id] of p.ids)
            obj.disconnect(id);
        // スウォッチの clicked の最中に呼ばれることがあるので、隠すだけにして破棄は後に回す
        p.actor.hide();
        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            p.actor.destroy();
            return GLib.SOURCE_REMOVE;
        });
    }

    // Alt+Tab の一覧項目に色を反映する。項目ウィジェットの種類ごとに対応する窓を割り出し、
    // 単色なら枠、1 アプリに複数色の窓があるなら色ドットを足す
    //   altTab.WindowIcon      … ウィンドウ切り替え (Alt+` など) → item.window
    //   altTab.AppIcon         … アプリ切り替え (既定の Alt+Tab) → item.cachedWindows
    //   altTab.ThumbnailSwitcher … アプリ配下の窓サムネイル → list._windows[i]
    _decorateSwitcherItem(list, item) {
        if (!this._tags || !item)
            return;

        let windows = null;
        if (item.window)
            windows = [item.window];
        else if (item.cachedWindows)
            windows = item.cachedWindows;
        else if (list._windows && list._thumbnailBins)
            windows = [list._windows[list._items.length - 1]];

        const hexes = [];
        for (const win of windows ?? []) {
            const hex = win ? this._tags.get(win)?.hex : null;
            if (hex && !hexes.includes(hex))
                hexes.push(hex);
        }
        if (hexes.length === 0)
            return;

        if (hexes.length === 1) {
            item.set_style(
                `border: ${SWITCHER_BORDER_WIDTH}px solid ${hexes[0]}; ` +
                `border-radius: ${SWITCHER_RADIUS}px; padding: 2px;`);
            return;
        }

        const dots = new St.BoxLayout({
            style: 'spacing: 3px;',
            x_align: Clutter.ActorAlign.CENTER,
        });
        for (const hex of hexes) {
            dots.add_child(new St.Widget({
                width: SWITCHER_DOT_SIZE,
                height: SWITCHER_DOT_SIZE,
                style: `background-color: ${hex}; ` +
                       `border-radius: ${SWITCHER_DOT_SIZE / 2}px;`,
            }));
        }
        item.add_child(dots);
    }

    // オーバービューのウィンドウプレビューに色枠を重ねる。
    // 枠は WindowPreview の子として window_container の割り当てに追従させる
    // (window_container はオーバービューの出入りで拡大縮小するので、倍率も束縛する)
    _decorateWindowPreview(preview) {
        if (!this._previews)
            return;
        this._previews.add(preview);
        preview.connect('destroy', () => this._previews?.delete(preview));
        this._syncPreview(preview);
    }

    _syncPreview(preview) {
        const hex = this._tags?.get(preview.metaWindow)?.hex;
        if (!hex) {
            preview._wincolorBorder?.destroy();
            preview._wincolorBorder = null;
            return;
        }

        if (!preview._wincolorBorder) {
            const container = preview.window_container;
            const border = new St.Widget({reactive: false});
            border.set_pivot_point(0.5, 0.5);   // container と同じ拡大中心
            border.add_constraint(new Clutter.BindConstraint({
                source: container,
                coordinate: Clutter.BindCoordinate.ALL,
            }));
            container.bind_property('scale-x', border, 'scale-x',
                GObject.BindingFlags.SYNC_CREATE);
            container.bind_property('scale-y', border, 'scale-y',
                GObject.BindingFlags.SYNC_CREATE);
            preview.insert_child_above(border, container);
            preview._wincolorBorder = border;
        }

        preview._wincolorBorder.set_style(
            `border: ${PREVIEW_BORDER_WIDTH}px solid ${hex}; ` +
            `border-radius: ${PREVIEW_RADIUS}px;`);
    }

    // 表示中のプレビュー (オーバービューを開いている間だけ存在する) を色の変更に追従させる
    _syncPreviewsFor(win) {
        if (!this._previews)
            return;
        for (const preview of this._previews) {
            if (preview.metaWindow === win)
                this._syncPreview(preview);
        }
    }

    // ワークスペースサムネイル (オーバービュー上部) の小さなウィンドウに色枠を重ねる
    _decorateWorkspaceClone(clone) {
        if (!this._wsClones)
            return;
        this._wsClones.add(clone);
        clone.connect('destroy', () => this._wsClones?.delete(clone));
        this._syncWorkspaceClone(clone);
    }

    // scale 省略時は前回 setScale で渡された縮小率を使う (色だけ変わったとき)
    _syncWorkspaceClone(clone, scale) {
        if (scale > 0)
            clone._wincolorScale = scale;

        const hex = this._tags?.get(clone.metaWindow)?.hex;
        if (!hex) {
            clone._wincolorBorder?.destroy();
            clone._wincolorBorder = null;
            return;
        }

        if (!clone._wincolorBorder) {
            const border = new St.Widget({reactive: false});
            clone.add_child(border);
            clone._wincolorBorder = border;
        }

        // クローンの原点はウィンドウアクタ (影を含む) の原点なので、枠はフレーム矩形に合わせる
        const actor = clone.realWindow;
        const rect = clone.metaWindow.get_frame_rect();
        clone._wincolorBorder.set_position(rect.x - actor.x, rect.y - actor.y);
        clone._wincolorBorder.set_size(rect.width, rect.height);

        const s = clone._wincolorScale > 0 ? clone._wincolorScale : 1;
        clone._wincolorBorder.set_style(
            `border: ${Math.max(1, Math.round(WS_THUMB_BORDER_PX / s))}px solid ${hex}; ` +
            `border-radius: ${Math.round(WS_THUMB_RADIUS_PX / s)}px;`);
    }

    _syncWorkspaceClonesFor(win) {
        if (!this._wsClones)
            return;
        for (const clone of this._wsClones) {
            if (clone.metaWindow === win)
                this._syncWorkspaceClone(clone);
        }
    }

    _openMenuForFocused() {
        const win = global.display.focus_window;
        if (!win || win.is_skip_taskbar())
            return;
        const mgr = Main.wm._windowMenuManager;
        if (!mgr)
            return;
        const frame = win.get_frame_rect();
        mgr.showWindowMenuForWindow(win, Meta.WindowMenuType.WM,
            {x: frame.x + 8, y: frame.y + 8, width: 1, height: 1});
    }

    // ---- internals ----

    // 無タグ → 先頭色 → … → 末尾色 → 無タグ (null) の順で循環
    _cycleColor(win, dir) {
        const cur = this._tags.get(win)?.hex;
        let idx = this._presets.findIndex(p => p.hex === cur) + dir; // 無タグ・非プリセット色は -1 扱い
        if (idx < -1)
            idx = this._presets.length - 1;
        else if (idx >= this._presets.length)
            idx = -1;
        if (idx < 0)
            return null;
        const p = this._presets[idx];
        return {name: p.name, hex: p.hex};
    }

    _resolve(target) {
        if (target === 'focused')
            return global.display.focus_window;
        const id = Number(target);
        if (!Number.isFinite(id))
            return null;
        for (const actor of global.get_window_actors()) {
            if (actor.meta_window?.get_id() === id)
                return actor.meta_window;
        }
        return null;
    }

    // color: {name, hex}
    _addTag(win, color) {
        const existing = this._tags.get(win);
        if (existing) {
            existing.name = color.name;
            existing.hex = color.hex;
            this._applyStyle(existing);
            this._syncPreviewsFor(win);
            this._syncWorkspaceClonesFor(win);
            return;
        }

        const actor = win.get_compositor_private();
        if (!actor)
            return;

        const border = new St.Widget({reactive: false});
        const tint = new St.Widget({reactive: false, opacity: TINT_OPACITY});
        global.window_group.add_child(border);
        global.window_group.add_child(tint);

        const tag = {name: color.name, hex: color.hex, border, tint, actor, winIds: [], actorIds: []};
        this._tags.set(win, tag);
        this._applyStyle(tag);

        const sync = () => this._sync(win);
        tag.winIds.push(win.connect('position-changed', sync));
        tag.winIds.push(win.connect('size-changed', sync));
        tag.winIds.push(win.connect('unmanaged', () => this._removeTag(win)));
        tag.actorIds.push(actor.connect('notify::visible', sync));

        sync();
        this._restackAll();
        this._syncPreviewsFor(win);
        this._syncWorkspaceClonesFor(win);
    }

    _removeTag(win) {
        const tag = this._tags.get(win);
        if (!tag)
            return;
        for (const id of tag.winIds)
            win.disconnect(id);
        for (const id of tag.actorIds)
            tag.actor.disconnect(id);
        tag.border.destroy();
        tag.tint.destroy();
        this._tags.delete(win);
        this._syncPreviewsFor(win);
        this._syncWorkspaceClonesFor(win);
    }

    _applyStyle(tag) {
        tag.border.set_style(
            `border: ${BORDER_WIDTH}px solid ${tag.hex}; ` +
            `border-radius: ${CORNER_RADIUS}px;`);
        tag.tint.set_style(
            `background-color: ${tag.hex}; ` +
            `border-radius: ${CORNER_RADIUS - BORDER_WIDTH}px ${CORNER_RADIUS - BORDER_WIDTH}px 0 0;`);
    }

    _sync(win) {
        const tag = this._tags.get(win);
        if (!tag)
            return;
        const visible = tag.actor.visible;
        tag.border.visible = visible;
        tag.tint.visible = visible;
        if (!visible)
            return;
        const r = win.get_frame_rect();
        tag.border.set_position(r.x - BORDER_WIDTH, r.y - BORDER_WIDTH);
        tag.border.set_size(r.width + 2 * BORDER_WIDTH, r.height + 2 * BORDER_WIDTH);
        tag.tint.set_position(r.x, r.y);
        tag.tint.set_size(r.width, Math.min(TINT_HEIGHT, r.height));
    }

    _restackAll() {
        if (!this._tags)
            return;
        for (const tag of this._tags.values()) {
            if (tag.actor.get_parent() !== global.window_group)
                continue;
            global.window_group.set_child_above_sibling(tag.border, tag.actor);
            global.window_group.set_child_above_sibling(tag.tint, tag.border);
        }
    }
}
