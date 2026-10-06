using Gtk;

namespace Singularity.Apps.Notes {

    public class TableObject : NoteObject {
        public const string[] SHADES = { "#fff3bf", "#d3f9d8", "#d0ebff", "#ffe3e3", "#f3d9fa", "#e9ecef", "#ffd8a8" };

        public TableData data;
        public string anchor_id = "";
        private Grid grid;
        private Gee.ArrayList<Gee.ArrayList<Entry>> cells = new Gee.ArrayList<Gee.ArrayList<Entry>>();
        private bool rebuilding = false;
        private int focus_row = 0;
        private int focus_col = 0;

        public TableObject(TableData data) {
            base();
            this.data = data;
            data.normalize();
            add_css_class("notes-table-object");
            grid = new Grid();
            grid.add_css_class("notes-table");
            grid.column_homogeneous = false;
            append(grid);
            halign = Align.START;
            rebuild();
        }

        public void rebuild() {
            rebuilding = true;
            Widget? child;
            while ((child = grid.get_first_child()) != null) grid.remove(child);
            cells.clear();
            data.normalize();
            int cols = data.columns;
            int col_width = int.max(80, (available_width - 8) / int.max(1, cols));
            for (int r = 0; r < data.rows.size; r++) {
                var row_cells = new Gee.ArrayList<Entry>();
                for (int c = 0; c < cols; c++) {
                    var e = new Entry();
                    e.has_frame = false;
                    e.text = data.cell(r, c);
                    e.add_css_class("notes-cell");
                    if (r == 0) e.add_css_class("notes-cell-header");
                    e.set_size_request(col_width, -1);
                    string align = data.aligns[c];
                    e.xalign = align == "center" ? 0.5f : align == "right" ? 1.0f : 0.0f;
                    apply_shade(e, data.shade(r, c));
                    int rr = r;
                    int cc = c;
                    e.changed.connect(() => {
                        if (rebuilding) return;
                        data.rows[rr][cc] = e.text;
                        changed();
                    });
                    var focus = new EventControllerFocus();
                    focus.enter.connect(() => {
                        focus_row = rr;
                        focus_col = cc;
                    });
                    e.add_controller(focus);
                    var keys = new EventControllerKey();
                    keys.key_pressed.connect((kv, code, state) => on_cell_key(rr, cc, kv, state));
                    e.add_controller(keys);
                    Menus.on_secondary(e, (m) => build_menu(m, rr, cc));
                    grid.attach(e, c, r);
                    row_cells.add(e);
                }
                cells.add(row_cells);
            }
            rebuilding = false;
        }

        private void apply_shade(Entry e, string color) {
            for (int i = 0; i < SHADES.length; i++) {
                if (SHADES[i] == color) e.add_css_class("notes-shade-%d".printf(i));
                else e.remove_css_class("notes-shade-%d".printf(i));
            }
        }

        public override void set_available_width(int w) {
            int old = available_width;
            base.set_available_width(w);
            if (old != available_width) {
                int cols = int.max(1, data.columns);
                int col_width = int.max(80, (available_width - 8) / cols);
                foreach (var row in cells) foreach (var e in row) e.set_size_request(col_width, -1);
            }
        }

        public void focus_cell(int r, int c) {
            if (r < 0 || r >= cells.size) return;
            if (c < 0 || c >= cells[r].size) return;
            cells[r][c].grab_focus();
        }

        private bool on_cell_key(int r, int c, uint keyval, Gdk.ModifierType state) {
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            if (keyval == Gdk.Key.Tab || keyval == Gdk.Key.ISO_Left_Tab) {
                int cols = data.columns;
                int idx = r * cols + c + (shift ? -1 : 1);
                if (idx < 0) return true;
                if (idx >= data.rows.size * cols) {
                    insert_row(data.rows.size);
                    focus_cell(data.rows.size - 1, 0);
                    return true;
                }
                focus_cell(idx / cols, idx % cols);
                return true;
            }
            if (keyval == Gdk.Key.Down || ((keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) && !shift)) {
                if (r + 1 < data.rows.size) focus_cell(r + 1, c);
                else if (keyval != Gdk.Key.Down) {
                    insert_row(data.rows.size);
                    focus_cell(data.rows.size - 1, c);
                } else if (editor != null) {
                    editor.focus_after_object(this);
                }
                return true;
            }
            if (keyval == Gdk.Key.Up) {
                if (r > 0) focus_cell(r - 1, c);
                else if (editor != null) editor.focus_before_object(this);
                return true;
            }
            return false;
        }

        public void insert_row(int at) {
            var row = new Gee.ArrayList<string>();
            for (int i = 0; i < data.columns; i++) row.add("");
            data.rows.insert(at.clamp(0, data.rows.size), row);
            shift_shading(at, true, true);
            rebuild();
            changed();
        }

        public void insert_column(int at) {
            foreach (var r in data.rows) r.insert(at.clamp(0, r.size), "");
            data.aligns.insert(at.clamp(0, data.aligns.size), "");
            shift_shading(at, false, true);
            rebuild();
            changed();
        }

        public void delete_row(int r) {
            if (data.rows.size <= 1) {
                remove_requested();
                return;
            }
            data.rows.remove_at(r);
            shift_shading(r, true, false);
            rebuild();
            changed();
        }

        public void delete_column(int c) {
            if (data.columns <= 1) {
                remove_requested();
                return;
            }
            foreach (var r in data.rows) if (c < r.size) r.remove_at(c);
            if (c < data.aligns.size) data.aligns.remove_at(c);
            shift_shading(c, false, false);
            rebuild();
            changed();
        }

        private void shift_shading(int at, bool rows, bool insert) {
            var fresh = new Gee.HashMap<string, string>();
            foreach (var e in data.shading.entries) {
                string[] p = e.key.split(":");
                int r = int.parse(p[0]);
                int c = int.parse(p[1]);
                int v = rows ? r : c;
                if (insert && v >= at) v++;
                else if (!insert && v == at) continue;
                else if (!insert && v > at) v--;
                if (rows) r = v;
                else c = v;
                fresh["%d:%d".printf(r, c)] = e.value;
            }
            data.shading = fresh;
        }

        private void build_menu(Singularity.Widgets.ContextMenu m, int r, int c) {
            m.add_item(_("Insert Row Above"), null, () => insert_row(r));
            m.add_item(_("Insert Row Below"), null, () => insert_row(r + 1));
            m.add_item(_("Insert Column Left"), null, () => insert_column(c));
            m.add_item(_("Insert Column Right"), null, () => insert_column(c + 1));
            m.add_separator();
            m.add_item(_("Sort Ascending"), "view-sort-ascending-symbolic", () => sort(c, false));
            m.add_item(_("Sort Descending"), "view-sort-descending-symbolic", () => sort(c, true));
            var align = m.add_submenu(_("Align Column"), "format-justify-left-symbolic");
            align.add_item(_("Left"), "format-justify-left-symbolic", () => set_align(c, "left"));
            align.add_item(_("Center"), "format-justify-center-symbolic", () => set_align(c, "center"));
            align.add_item(_("Right"), "format-justify-right-symbolic", () => set_align(c, "right"));
            var shade = m.add_submenu(_("Shading"), "color-select-symbolic");
            string[] names = { _("Yellow"), _("Green"), _("Blue"), _("Red"), _("Purple"), _("Grey"), _("Orange") };
            for (int i = 0; i < SHADES.length; i++) {
                string color = SHADES[i];
                shade.add_item(names[i], null, () => set_shade(r, c, color));
            }
            shade.add_item(_("Shade the Whole Row"), null, () => {
                string color = data.shade(r, c) != "" ? data.shade(r, c) : SHADES[0];
                for (int k = 0; k < data.columns; k++) data.set_shade(r, k, color);
                rebuild();
                changed();
            });
            shade.add_item(_("No Shading"), null, () => set_shade(r, c, ""));
            m.add_separator();
            m.add_item(_("Copy as Spreadsheet Data"), "edit-copy-symbolic", () => {
                get_clipboard().set_text(data.to_csv());
                status(_("Table copied"));
            });
            m.add_item(_("Open in Spreadsheet"), "x-office-spreadsheet-symbolic", () => open_in_spreadsheet());
            m.add_separator();
            m.add_item(_("Delete Row"), null, () => delete_row(r));
            m.add_item(_("Delete Column"), null, () => delete_column(c));
            m.add_item(_("Delete Table"), "edit-delete-symbolic", () => remove_requested());
        }

        private void set_shade(int r, int c, string color) {
            data.set_shade(r, c, color);
            rebuild();
            changed();
        }

        private void set_align(int c, string a) {
            data.normalize();
            data.aligns[c] = a;
            rebuild();
            changed();
        }

        public void sort(int c, bool descending) {
            bool header = data.rows.size > 1;
            data.sort_by(c, descending, header);
            rebuild();
            changed();
        }

        private void open_in_spreadsheet() {
            if (editor == null || editor.note_id == "") return;
            string dir = Path.build_filename(notes_dir(), "attachments", editor.note_id);
            string path = Path.build_filename(dir, "table-%s.csv".printf(Uuid.string_random().substring(0, 8)));
            try {
                DirUtils.create_with_parents(dir, 0700);
                FileUtils.set_contents(path, data.to_csv());
            } catch (Error e) {
                status(_("The table could not be exported"));
                return;
            }
            AppInfo? app = null;
            foreach (var info in AppInfo.get_all_for_type("text/csv")) {
                if (info.get_id() == "dev.sinty.spreadsheet.desktop" || info.get_id() == "dev.sinty.Spreadsheet.desktop") app = info;
            }
            if (app == null) app = AppInfo.get_default_for_type("text/csv", false);
            try {
                if (app != null) {
                    var files = new GLib.List<File>();
                    files.append(File.new_for_path(path));
                    app.launch(files, null);
                } else {
                    ImageObject.open_external(path, window());
                }
            } catch (Error e) {
                status(_("No spreadsheet app is available"));
            }
        }

        public override Block to_block() {
            var b = new Block(BlockKind.TABLE);
            b.table = data.copy();
            b.anchor = anchor_id;
            return b;
        }

        public override string search_text() {
            var sb = new StringBuilder();
            foreach (var r in data.rows) sb.append(string.joinv(" ", r.to_array()) + "\n");
            return sb.str;
        }

        public static TableData empty(int rows, int cols) {
            var t = new TableData();
            for (int r = 0; r < rows; r++) {
                var row = new Gee.ArrayList<string>();
                for (int c = 0; c < cols; c++) row.add("");
                t.rows.add(row);
            }
            t.normalize();
            return t;
        }
    }
}
