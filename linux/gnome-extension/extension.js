import St from 'gi://St';
import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as WindowMenu from 'resource:///org/gnome/shell/ui/windowMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const BORDER_WIDTH = 3;
const CORNER_RADIUS = 14;
const TINT_HEIGHT = 40;      // approximate CSD titlebar height
const TINT_OPACITY = 80;     // 0-255

// タイトルバー右クリック / Alt+Space メニューに出す色候補
const PALETTE = [
    '#e01b24', // red
    '#ff7800', // orange
    '#f5c211', // yellow
    '#33d17a', // green
    '#00bcd4', // cyan
    '#3584e4', // blue
    '#9141ac', // purple
    '#ff5c9e', // pink
];
const SWATCH_SIZE = 24;

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
  </interface>
</node>`;

export default class WindowColorTagExtension extends Extension {
    enable() {
        this._tags = new Map(); // MetaWindow -> {color, border, tint, winIds, actorIds}

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

    // ---- D-Bus methods ----

    Set(target, color) {
        if (!/^(#[0-9a-fA-F]{3,8}|[a-zA-Z]+)$/.test(color))
            return `invalid color: ${color}`;
        const win = this._resolve(target);
        if (!win)
            return `no window for target: ${target}`;
        if (color === 'next' || color === 'prev') {
            color = this._cycleColor(win, color === 'next' ? 1 : -1);
            if (!color) {
                this._removeTag(win);
                return `cleared: [${win.get_id()}]`;
            }
        }
        this._addTag(win, color);
        return `ok: [${win.get_id()}] ${win.get_wm_class() ?? '?'} "${win.get_title() ?? ''}" -> ${color}`;
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
            lines.push(`${w.get_id()}\t${w.get_wm_class() ?? '?'}\t${tag ? tag.color : '-'}\t${w.get_title() ?? ''}`);
        }
        return lines.join('\n');
    }

    // ---- window menu ----

    _appendColorRow(menu, window) {
        menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem('色タグ'));

        const item = new PopupMenu.PopupBaseMenuItem({
            reactive: false,
            can_focus: false,
        });
        const box = new St.BoxLayout({style: 'spacing: 8px;'});
        item.add_child(box);

        const current = this._tags.get(window)?.color;

        for (const color of PALETTE) {
            const selected = color === current;
            const btn = new St.Button({
                width: SWATCH_SIZE,
                height: SWATCH_SIZE,
                can_focus: true,
                track_hover: true,
                style: `background-color: ${color}; ` +
                       `border-radius: ${SWATCH_SIZE / 2}px; ` +
                       `border: 2px solid ${selected ? 'white' : 'transparent'};`,
            });
            btn.connect('clicked', () => {
                this._addTag(window, color);
                menu.close();
            });
            box.add_child(btn);
        }

        const offBtn = new St.Button({
            width: SWATCH_SIZE,
            height: SWATCH_SIZE,
            can_focus: true,
            track_hover: true,
            style: `border-radius: ${SWATCH_SIZE / 2}px; border: 2px solid #888;`,
            child: new St.Icon({icon_name: 'edit-clear-symbolic', icon_size: 12}),
        });
        offBtn.connect('clicked', () => {
            this._removeTag(window);
            menu.close();
        });
        box.add_child(offBtn);

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
        const cur = this._tags.get(win)?.color;
        let idx = PALETTE.indexOf(cur) + dir; // 無タグは -1 扱い
        if (idx < -1)
            idx = PALETTE.length - 1;
        else if (idx >= PALETTE.length)
            idx = -1;
        return idx < 0 ? null : PALETTE[idx];
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

    _addTag(win, color) {
        const existing = this._tags.get(win);
        if (existing) {
            existing.color = color;
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

        const tag = {color, border, tint, actor, winIds: [], actorIds: []};
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
            `border: ${BORDER_WIDTH}px solid ${tag.color}; ` +
            `border-radius: ${CORNER_RADIUS}px;`);
        tag.tint.set_style(
            `background-color: ${tag.color}; ` +
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
