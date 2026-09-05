import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import Clutter from 'gi://Clutter';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as WindowMenu from 'resource:///org/gnome/shell/ui/windowMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const BORDER_WIDTH = 3;
const CORNER_RADIUS = 14;
const TINT_HEIGHT = 40;      // approximate CSD titlebar height
const TINT_OPACITY = 80;     // 0-255

const SWATCH_SIZE = 24;
const SWATCHES_PER_ROW = 8;

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

const DBUS_PATH = '/jp/smart2j/WindowColorTag';
const DBUS_IFACE = `
<node>
  <interface name="jp.smart2j.WindowColorTag">
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

        // CSD ウィンドウ (Chrome 等) はタイトルバー右クリックが効かないため、
        // mutter ネイティブのキーバインドでメニューを開けるようにする
        this._settings = this.getSettings();
        Main.wm.addKeybinding('open-window-menu', this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => this._openMenuForFocused());
        Main.wm.addKeybinding('cycle-color', this._settings,
            Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL,
            () => this.Set('focused', 'next'));

        this._startRules();
        this._startConfigMonitors();
    }

    disable() {
        this._stopConfigMonitors();
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

    // ---- auto rules ----

    // 新規ウィンドウとタイトル/クラス変化を監視してルールを照合する。
    // 一度色を確定した窓 (ルール適用済み / 手動で色を付けた・消した窓) には再適用しない
    _startRules() {
        this._ruleDone = new WeakSet();  // MetaWindow。unmanaged 後は GC に任せる
        this._watched = new Map();       // MetaWindow -> signal ids
        this._windowCreatedId = global.display.connect('window-created',
            (_display, win) => this._watchWindow(win));
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

        const item = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
        });
        const rows = new St.BoxLayout({
            orientation: Clutter.Orientation.VERTICAL,
            style: 'spacing: 6px;',
        });
        item.add_child(rows);

        const current = this._tags.get(window)?.hex;

        // プリセット + 「消す」ボタンを SWATCHES_PER_ROW 個ずつ折り返して並べる
        let box = null;
        const addSwatch = btn => {
            if (!box || box.get_n_children() >= SWATCHES_PER_ROW) {
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
                can_focus: true,
                track_hover: true,
                accessible_name: `${p.label} (${p.name})`,
                style: `background-color: ${p.hex}; ` +
                       `border-radius: ${SWATCH_SIZE / 2}px; ` +
                       `border: 2px solid ${selected ? 'white' : 'transparent'};`,
            });
            btn.connect('clicked', () => {
                this._markManual(window);
                this._addTag(window, {name: p.name, hex: p.hex});
                menu.close();
            });
            addSwatch(btn);
        }

        const offBtn = new St.Button({
            width: SWATCH_SIZE,
            height: SWATCH_SIZE,
            can_focus: true,
            track_hover: true,
            accessible_name: '色を消す',
            style: `border-radius: ${SWATCH_SIZE / 2}px; border: 2px solid #888;`,
            child: new St.Icon({icon_name: 'edit-clear-symbolic', icon_size: 12}),
        });
        offBtn.connect('clicked', () => {
            this._markManual(window);
            this._removeTag(window);
            menu.close();
        });
        addSwatch(offBtn);

        menu.addMenuItem(item);
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
