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
  </interface>
</node>`;

export default class WindowColorTagExtension extends Extension {
    enable() {
        this._tags = new Map(); // MetaWindow -> {name, hex, border, tint, winIds, actorIds}
        this._presets = this._loadPresets();

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
    }

    disable() {
        Main.wm.removeKeybinding('open-window-menu');
        Main.wm.removeKeybinding('cycle-color');
        this._settings = null;
        this.ClearAll();
        this._tags = null;
        this._presets = null;
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

    // shared/colors.json を読む。探索順:
    //   1. 拡張ディレクトリ直下 (install.sh / リリース zip が同梱する)
    //   2. リポジトリ構成 (linux/gnome-extension/ から見た ../../shared/)
    // どちらも読めなければ組み込み既定 (DEFAULT_PRESETS) を使う
    _loadPresets() {
        const candidates = [
            GLib.build_filenamev([this.path, 'colors.json']),
            GLib.build_filenamev([this.path, '..', '..', 'shared', 'colors.json']),
        ];
        for (const path of candidates) {
            const file = Gio.File.new_for_path(path);
            if (!file.query_exists(null))
                continue;
            try {
                const [, bytes] = file.load_contents(null);
                const data = JSON.parse(new TextDecoder().decode(bytes));
                const presets = (Array.isArray(data.presets) ? data.presets : [])
                    .filter(p => typeof p.name === 'string' && p.name !== '' &&
                                 HEX_RE.test(p.hex ?? ''))
                    .map(p => ({
                        name: p.name,
                        label: typeof p.label === 'string' ? p.label : p.name,
                        hex: p.hex.toUpperCase(),
                        textHex: p.textHex ?? '',
                    }));
                if (presets.length > 0) {
                    this._presetsPath = path;
                    return presets;
                }
                console.warn(`[window-color-tag] ${path}: no valid presets, using built-in defaults`);
            } catch (e) {
                console.warn(`[window-color-tag] failed to load ${path}: ${e.message}`);
            }
        }
        this._presetsPath = null;
        return DEFAULT_PRESETS;
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
        this._addTag(win, resolved);
        return `ok: [${win.get_id()}] ${win.get_wm_class() ?? '?'} "${win.get_title() ?? ''}" -> ${this._describe(resolved)}`;
    }

    Clear(target) {
        const win = this._resolve(target);
        if (!win)
            return `no window for target: ${target}`;
        if (!this._tags.has(win))
            return 'not tagged';
        this._removeTag(win);
        return `cleared: [${win.get_id()}]`;
    }

    ClearAll() {
        if (!this._tags)
            return 'ok';
        for (const win of [...this._tags.keys()])
            this._removeTag(win);
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
