using Gtk;

namespace Singularity.Apps.Notes {

    public class PageView : Box {
        public signal void edited(string body);
        public signal void status(string message);
        public signal void navigate(string uri);
        public signal void active_changed();
        public signal void page_link_requested(RichEditor editor);
        public signal void link_dialog_requested(RichEditor editor);
        public signal void date_changed(int64 created);

        public string notes_dir { get; set; default = ""; }
        public string note_id { get; private set; default = ""; }
        public RichEditor? active_editor { get; private set; default = null; }
        public PageDoc doc { get; private set; default = new PageDoc(); }
        public int64 created { get; private set; default = 0; }

        private Entry title_entry;
        private Button date_button;
        private Label date_label;
        private Label presence_label;
        private Stack mode_stack;
        private RichEditor flow_editor;
        private ScrolledWindow flow_scroll;
        private CanvasView canvas;
        private Singularity.Widgets.FindReplaceBar find_bar;
        private Revealer find_revealer;
        private Revealer record_revealer;
        private Label record_label;
        private Box header;
        private Box page_box;

        private bool loading = false;
        private uint emit_source = 0;
        private string last_body = "";
        private Gee.ArrayList<string> undo_stack = new Gee.ArrayList<string>();
        private Gee.ArrayList<string> redo_stack = new Gee.ArrayList<string>();

        private Recorder? recorder = null;
        private RecordingInfo? recording_info = null;
        private int recording_line = 0;
        private RichEditor? recording_editor = null;
        private uint record_tick = 0;

        public CollabClient? live { get; private set; default = null; }
        private string live_seen = "";
        private uint cursor_source = 0;
        private ulong live_remote_id = 0;
        private ulong live_peers_id = 0;
        private ulong live_closed_id = 0;
        public signal void live_ended(string reason);

        public PageView() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("notes-page");

            find_bar = new Singularity.Widgets.FindReplaceBar();
            find_bar.find_next.connect((q) => find_step(q, true));
            find_bar.find_prev.connect((q) => find_step(q, false));
            find_bar.replace_one.connect((q, r) => replace_one(q, r));
            find_bar.replace_all.connect((q, r) => replace_all(q, r));
            find_bar.closed.connect(() => close_find());
            find_revealer = new Revealer();
            find_revealer.child = find_bar;
            append(find_revealer);

            var record_box = new Box(Orientation.HORIZONTAL, 10);
            record_box.add_css_class("notes-record-bar");
            var dot = new Image.from_icon_name("media-record-symbolic");
            dot.add_css_class("notes-record-dot");
            record_box.append(dot);
            record_label = new Label("");
            record_label.add_css_class("numeric");
            record_label.hexpand = true;
            record_label.xalign = 0;
            record_box.append(record_label);
            var stop = new Button.with_label(_("Stop Recording"));
            stop.add_css_class("destructive-action");
            stop.clicked.connect(() => stop_recording());
            record_box.append(stop);
            record_revealer = new Revealer();
            record_revealer.child = record_box;
            append(record_revealer);

            header = new Box(Orientation.VERTICAL, 2);
            header.add_css_class("notes-page-header");
            title_entry = new Entry();
            title_entry.has_frame = false;
            title_entry.placeholder_text = _("Page Title");
            title_entry.add_css_class("notes-title-entry");
            title_entry.changed.connect(() => {
                if (!loading) schedule_emit();
            });
            title_entry.activate.connect(() => {
                if (active_editor != null) {
                    if (doc.meta.is_canvas) active_editor.view.grab_focus();
                    else flow_editor.focus_line(0);
                }
            });
            header.append(title_entry);
            date_button = new Button();
            date_button.add_css_class("flat");
            date_button.add_css_class("notes-date-button");
            date_button.halign = Align.START;
            date_label = new Label("");
            date_label.add_css_class("dim-label");
            date_button.child = date_label;
            date_button.tooltip_text = _("Change the date and time of this page");
            date_button.clicked.connect(() => edit_date());
            var meta_row = new Box(Orientation.HORIZONTAL, 12);
            meta_row.append(date_button);
            presence_label = new Label("");
            presence_label.add_css_class("notes-presence");
            presence_label.visible = false;
            presence_label.ellipsize = Pango.EllipsizeMode.END;
            meta_row.append(presence_label);
            header.append(meta_row);

            flow_editor = new_editor(32);
            page_box = new Box(Orientation.VERTICAL, 0);
            page_box.append(header);
            flow_editor.view.vexpand = true;
            flow_scroll = new ScrolledWindow();
            flow_scroll.hscrollbar_policy = PolicyType.NEVER;
            flow_scroll.vexpand = true;
            flow_scroll.child = flow_editor.view;
            page_box.append(flow_scroll);

            canvas = new CanvasView();
            canvas.editor_created.connect((ed) => wire_editor(ed));
            canvas.changed.connect(() => {
                if (!loading) schedule_emit();
            });
            var canvas_scroll = new ScrolledWindow();
            canvas_scroll.vexpand = true;
            var canvas_port = new Viewport(null, null);
            canvas_port.scroll_to_focus = false;
            canvas_port.child = canvas;
            canvas_scroll.child = canvas_port;

            mode_stack = new Stack();
            mode_stack.vexpand = true;
            mode_stack.add_named(page_box, "flow");
            mode_stack.add_named(canvas_scroll, "canvas");
            append(mode_stack);
            active_editor = flow_editor;

            var keys = new EventControllerKey();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect((kv, code, state) => {
                bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
                bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                uint k = Gdk.keyval_to_lower(kv);
                if (ctrl && k == Gdk.Key.z && !shift) {
                    undo();
                    return true;
                }
                if (ctrl && (k == Gdk.Key.y || (k == Gdk.Key.z && shift))) {
                    redo();
                    return true;
                }
                if (ctrl && k == Gdk.Key.f && !shift && focus_inside()) {
                    open_find(false);
                    return true;
                }
                if (ctrl && k == Gdk.Key.h && !shift && focus_inside()) {
                    open_find(true);
                    return true;
                }
                return false;
            });
            add_controller(keys);
        }

        private bool focus_inside() {
            var root = get_root() as Gtk.Window;
            if (root == null) return false;
            var f = root.get_focus();
            while (f != null) {
                if (f == this) return true;
                f = f.get_parent();
            }
            return false;
        }

        private RichEditor new_editor(int margin) {
            var ed = new RichEditor(margin);
            wire_editor(ed);
            return ed;
        }

        private void wire_editor(RichEditor ed) {
            ed.notes_dir = notes_dir;
            ed.note_id = note_id;
            ed.changed.connect(() => {
                if (loading) return;
                if (recorder != null && recorder.running && recording_info != null) {
                    string t = ed.line_text(ed.current_line());
                    if (t != "") recording_info.mark(recorder.elapsed, t);
                }
                schedule_emit();
            });
            ed.status.connect((m) => status(m));
            ed.navigate.connect((u) => navigate(u));
            ed.activated.connect(() => {
                if (active_editor != ed) {
                    active_editor = ed;
                    active_changed();
                }
            });
            ed.cursor_moved.connect(() => {
                if (active_editor == ed) active_changed();
                if (live != null) schedule_cursor();
            });
            ed.page_link_requested.connect(() => page_link_requested(ed));
            ed.link_dialog_requested.connect(() => link_dialog_requested(ed));
            ed.task_requested.connect(() => {
                active_editor = ed;
                add_task();
            });
            ed.translate_requested.connect(() => {
                active_editor = ed;
                translate();
            });
            ed.play_here_requested.connect(() => {
                active_editor = ed;
                play_from_current_line();
            });
            ed.printout_requested.connect((path, line) => insert_printout(ed, path, line));
            ed.attach_requested.connect((file, line) => attach_pdf(ed, file, line));
        }

        public bool is_canvas {
            get { return doc.meta.is_canvas; }
        }

        public Gee.List<RichEditor> editors() {
            if (doc.meta.is_canvas) return canvas.editors();
            var l = new Gee.ArrayList<RichEditor>();
            l.add(flow_editor);
            return l;
        }

        public void load(string id, string body, int64 created_time) {
            bool same = id == note_id;
            note_id = id;
            created = created_time;
            if (!same) {
                undo_stack.clear();
                redo_stack.clear();
                stop_recording();
                close_find();
            }
            load_body(body);
            last_body = serialize();
        }

        private void load_body(string body) {
            loading = true;
            if (emit_source != 0) {
                Source.remove(emit_source);
                emit_source = 0;
            }
            doc = PageDoc.parse(body);
            title_entry.text = doc.title;
            update_date_label();
            flow_editor.notes_dir = notes_dir;
            flow_editor.note_id = note_id;
            canvas.notes_dir = notes_dir;
            canvas.note_id = note_id;
            if (doc.meta.is_canvas) {
                if (header.get_parent() != null) ((Box) header.get_parent()).remove(header);
                canvas.prepend(header);
                canvas.load(doc);
                mode_stack.visible_child_name = "canvas";
                var eds = canvas.editors();
                active_editor = eds.size > 0 ? eds[0] : null;
            } else {
                if (header.get_parent() != page_box) {
                    if (header.get_parent() != null) ((Box) header.get_parent()).remove(header);
                    page_box.prepend(header);
                }
                flow_editor.load(doc.body);
                flow_editor.trailing_newline = false;
                mode_stack.visible_child_name = "flow";
                active_editor = flow_editor;
            }
            apply_background();
            loading = false;
            active_changed();
        }

        private void apply_background() {
            foreach (string c in new string[] { "yellow", "green", "blue", "pink", "purple", "grey", "orange" }) remove_css_class("notes-bg-" + c);
            if (doc.meta.background != "") add_css_class("notes-bg-" + doc.meta.background);
            flow_editor.view.rule = doc.meta.rule;
            flow_editor.view.queue_draw();
            canvas.rule = doc.meta.rule;
            canvas.queue_draw();
        }

        private void update_date_label() {
            if (created <= 0) {
                date_label.label = "";
                return;
            }
            var t = new DateTime.from_unix_local(created);
            date_label.label = t.format(_("%A, %e %B %Y   %H:%M"));
        }

        public string serialize() {
            doc.title = title_entry.text.strip();
            if (doc.meta.is_canvas) canvas.fill(doc);
            else doc.body = flow_editor.serialize();
            doc.trailing_newline = false;
            return doc.serialize();
        }

        private void schedule_emit() {
            if (emit_source != 0) Source.remove(emit_source);
            emit_source = Timeout.add(live != null ? 120 : 500, () => {
                emit_source = 0;
                flush();
                return Source.REMOVE;
            });
        }

        public bool pending {
            get { return emit_source != 0; }
        }

        public void flush() {
            if (emit_source != 0) {
                Source.remove(emit_source);
                emit_source = 0;
            }
            if (note_id == "" || loading) return;
            foreach (var ed in editors()) foreach (var o in ed.all_objects()) if (o is InkObject) ((InkObject) o).commit();
            string body = serialize();
            if (body == last_body) return;
            undo_stack.add(last_body);
            if (undo_stack.size > 200) undo_stack.remove_at(0);
            redo_stack.clear();
            last_body = body;
            edited(body);
            if (live != null && live.connected) {
                live.local_change(body);
                live_seen = live.text;
            }
        }

        public void attach_live(CollabClient client) {
            detach_live();
            live = client;
            live_remote_id = client.remote_text.connect((text, op) => apply_remote(op));
            live_peers_id = client.peers_changed.connect(() => update_live_peers());
            live_closed_id = client.closed.connect((reason) => {
                detach_live();
                live_ended(reason);
            });
            if (client.connected) {
                string current = serialize();
                if (current != client.text) {
                    reload(client.text);
                    string normalized = serialize();
                    last_body = normalized;
                    if (normalized != client.text) client.local_change(normalized);
                }
                live_seen = client.text;
                update_live_peers();
                schedule_cursor();
            }
        }

        public void detach_live() {
            if (live == null) return;
            var c = live;
            live = null;
            if (live_remote_id != 0) c.disconnect(live_remote_id);
            if (live_peers_id != 0) c.disconnect(live_peers_id);
            if (live_closed_id != 0) c.disconnect(live_closed_id);
            live_remote_id = live_peers_id = live_closed_id = 0;
            if (cursor_source != 0) {
                Source.remove(cursor_source);
                cursor_source = 0;
            }
            foreach (var ed in editors()) ed.set_carets(new Gee.ArrayList<RemoteCaret>());
            presence_label.visible = false;
        }

        private void schedule_cursor() {
            if (cursor_source != 0) return;
            cursor_source = Timeout.add(80, () => {
                cursor_source = 0;
                if (live == null || active_editor == null) return Source.REMOVE;
                int index = editors().index_of(active_editor);
                live.send_cursor(int.max(0, index), active_editor.current_line(), active_editor.current_column());
                return Source.REMOVE;
            });
        }

        private void update_live_peers() {
            if (live == null) return;
            var eds = editors();
            var per = new Gee.HashMap<int, Gee.ArrayList<RemoteCaret>>();
            string[] names = {};
            foreach (var p in live.peers.values) {
                names += p.name;
                if (p.line < 0) continue;
                var c = new RemoteCaret();
                c.name = p.name;
                c.color = p.color;
                c.line = p.line;
                c.column = p.column;
                if (!per.has_key(p.editor)) per[p.editor] = new Gee.ArrayList<RemoteCaret>();
                per[p.editor].add(c);
            }
            for (int i = 0; i < eds.size; i++) eds[i].set_carets(per.has_key(i) ? per[i] : new Gee.ArrayList<RemoteCaret>());
            if (names.length == 0) presence_label.label = _("Live session: waiting for others to join");
            else presence_label.label = _("Editing live with %s").printf(string.joinv(", ", names));
            presence_label.visible = true;
        }

        private void apply_remote(TextOperation op) {
            if (live == null) return;
            if (emit_source != 0) {
                Source.remove(emit_source);
                emit_source = 0;
            }
            string target = live.text;
            string mine = serialize();
            if (mine != live_seen) {
                try {
                    var local = TextOperation.diff(live_seen, mine);
                    TextOperation local2, remote2;
                    TextOperation.transform(local, op, out local2, out remote2);
                    target = local2.apply(live.text);
                } catch (Error e) {
                    target = live.text;
                }
            }
            var ed = active_editor;
            int index = ed != null ? editors().index_of(ed) : 0;
            int line = ed != null ? ed.current_line() : 0;
            int column = ed != null ? ed.current_column() : 0;
            string line_text = ed != null ? ed.line_text(line) : "";
            bool focused = ed != null && ed.view.has_focus;
            load_body(target);
            string normalized = serialize();
            last_body = normalized;
            if (normalized != live.text) live.local_change(normalized);
            live_seen = live.text;
            var eds = editors();
            if (index >= 0 && index < eds.size) {
                var ne = eds[index];
                active_editor = ne;
                int best = line;
                if (line_text != "" && ne.line_text(line) != line_text) {
                    for (int d = 1; d < 400; d++) {
                        if (line - d >= 0 && ne.line_text(line - d) == line_text) {
                            best = line - d;
                            break;
                        }
                        if (line + d < ne.line_count() && ne.line_text(line + d) == line_text) {
                            best = line + d;
                            break;
                        }
                        if (line - d < 0 && line + d >= ne.line_count()) break;
                    }
                }
                ne.place_cursor_quiet(int.min(best, ne.line_count() - 1), column);
                if (focused) ne.view.grab_focus();
            }
            edited(normalized);
            update_live_peers();
        }

        public void reload(string body) {
            int line = active_editor != null ? active_editor.current_line() : 0;
            bool focused = active_editor != null && active_editor.view.has_focus;
            load_body(body);
            last_body = serialize();
            if (live != null && live.connected) {
                live.local_change(last_body);
                live_seen = live.text;
            }
            if (active_editor != null && !doc.meta.is_canvas) {
                var ed = active_editor;
                if (focused) ed.focus_line(int.min(line, ed.line_count() - 1));
            }
        }

        public bool can_undo {
            get { return undo_stack.size > 0 || pending; }
        }

        public bool can_redo {
            get { return redo_stack.size > 0; }
        }

        public void undo() {
            flush();
            if (undo_stack.size == 0) return;
            redo_stack.add(last_body);
            string prev = undo_stack.remove_at(undo_stack.size - 1);
            restore(prev);
        }

        public void redo() {
            flush();
            if (redo_stack.size == 0) return;
            undo_stack.add(last_body);
            string next = redo_stack.remove_at(redo_stack.size - 1);
            restore(next);
        }

        private void restore(string body) {
            int line = active_editor != null ? active_editor.current_line() : 0;
            load_body(body);
            last_body = serialize();
            if (active_editor != null) active_editor.focus_line(int.min(line, active_editor.line_count() - 1));
            edited(last_body);
        }

        public void set_layout(bool canvas_mode) {
            if (canvas_mode == doc.meta.is_canvas) return;
            flush();
            string md = serialize();
            var d = PageDoc.parse(md);
            if (canvas_mode) {
                string flow = d.body;
                d.meta.layout = "canvas";
                d.containers.clear();
                if (flow.strip() != "") d.containers.add(new Container(40, 24, 640, flow));
                else d.containers.add(new Container(40, 24, 640, ""));
            } else {
                string flow = d.flow_markdown();
                if (d.meta.ink != "") {
                    flow = flow + (flow != "" ? "\n" : "") + "![%s](%s)".printf(_("Drawing"), d.meta.ink);
                    d.meta.ink = "";
                }
                d.meta.layout = "";
                d.containers.clear();
                d.body = flow;
            }
            load_body(d.serialize());
            schedule_emit();
        }

        public void set_background(string color) {
            doc.meta.background = color;
            apply_background();
            schedule_emit();
        }

        public void set_rule(string rule) {
            doc.meta.rule = rule;
            apply_background();
            schedule_emit();
        }

        public string background {
            owned get { return doc.meta.background; }
        }

        public string rule {
            owned get { return doc.meta.rule; }
        }

        private void edit_date() {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new Singularity.Widgets.ConfirmDialog(app, _("Page Date and Time"), "x-office-calendar",
                _("Choose when this page was written."), _("Change"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = get_root() as Gtk.Window;
            var cal = new Gtk.Calendar();
            var when = new DateTime.from_unix_local(created > 0 ? created : get_real_time() / 1000000);
            cal.select_day(when);
            dialog.custom_area.append(cal);
            var time_row = new Box(Orientation.HORIZONTAL, 6);
            time_row.halign = Align.CENTER;
            var hours = new SpinButton.with_range(0, 23, 1);
            hours.value = when.get_hour();
            var minutes = new SpinButton.with_range(0, 59, 1);
            minutes.value = when.get_minute();
            time_row.append(hours);
            time_row.append(new Label(":"));
            time_row.append(minutes);
            dialog.custom_area.append(time_row);
            dialog.response.connect((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) {
                    var d = cal.get_date();
                    var t = new DateTime.local(d.get_year(), d.get_month(), d.get_day_of_month(), (int) hours.value, (int) minutes.value, 0);
                    created = t.to_unix();
                    update_date_label();
                    date_changed(created);
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        public void open_find(bool replace) {
            find_revealer.reveal_child = true;
            string sel = active_editor != null ? active_editor.selected_text() : "";
            if (sel != "" && !sel.contains("\n")) find_bar.find_text = sel;
            if (replace) find_bar.open_replace();
            else find_bar.open_find();
        }

        public void close_find() {
            find_revealer.reveal_child = false;
            foreach (var ed in editors()) ed.clear_find();
        }

        private string last_query = "";

        private void find_step(string query, bool forward) {
            var eds = editors();
            if (query != last_query) {
                last_query = query;
                int total = 0;
                foreach (var ed in eds) total += ed.find(query);
                find_bar.set_match_info(total > 0 ? 1 : 0, total);
                foreach (var ed in eds) {
                    if (ed.find_count > 0) {
                        int idx = ed.find_step(true);
                        active_editor = ed;
                        find_bar.set_match_info(idx + 1, total);
                        break;
                    }
                }
                return;
            }
            var ed = active_editor;
            if (ed == null) return;
            int total = 0;
            foreach (var e in eds) total += e.find_count;
            if (ed.find_count == 0) {
                foreach (var e in eds) if (e.find_count > 0) ed = e;
            }
            int idx = ed.find_step(forward);
            int before = 0;
            foreach (var e in eds) {
                if (e == ed) break;
                before += e.find_count;
            }
            find_bar.set_match_info(idx >= 0 ? before + idx + 1 : 0, total);
        }

        private void replace_one(string query, string replacement) {
            if (active_editor == null) return;
            if (active_editor.replace_current(replacement) > 0) {
                last_query = "";
                find_step(query, true);
            }
        }

        private void replace_all(string query, string replacement) {
            int n = 0;
            foreach (var ed in editors()) n += ed.replace_all(query, replacement);
            last_query = "";
            find_bar.set_match_info(0, 0);
            status(ngettext("%d replacement", "%d replacements", n).printf(n));
        }

        public void insert_table(int rows, int cols) {
            if (active_editor == null) return;
            var b = new Block(BlockKind.TABLE);
            b.table = TableObject.empty(rows, cols);
            active_editor.insert_block_at_cursor(b);
        }

        public void insert_rule() {
            if (active_editor == null) return;
            active_editor.insert_block_at_cursor(new Block(BlockKind.RULE));
        }

        public void insert_drawing() {
            if (active_editor == null || note_id == "") return;
            if (doc.meta.is_canvas) {
                InkTools.get_default().tool = InkTool.PEN;
                return;
            }
            try {
                active_editor.insert_block_at_cursor(InkObject.create_new(notes_dir, note_id, active_editor.available_width()));
                InkTools.get_default().tool = InkTool.PEN;
            } catch (Error e) {
                status(_("The drawing space could not be added"));
            }
        }

        public void insert_date_time(bool with_time) {
            if (active_editor == null) return;
            var now = new DateTime.now_local();
            active_editor.insert_plain(with_time ? now.format("%x %H:%M") : now.format("%x"));
        }

        private delegate void FileChosen(File f);

        private void choose_file(string title, FileFilter? filter, owned FileChosen cb) {
            var dialog = new FileDialog();
            dialog.title = title;
            if (filter != null) {
                var filters = new GLib.ListStore(typeof(FileFilter));
                filters.append(filter);
                dialog.filters = filters;
            }
            dialog.open.begin(get_root() as Gtk.Window, null, (o, r) => {
                try {
                    var file = dialog.open.end(r);
                    if (file != null) cb(file);
                } catch (Error e) {
                }
            });
        }

        public void insert_picture() {
            var filter = new FileFilter();
            filter.name = _("Pictures");
            filter.add_mime_type("image/*");
            choose_file(_("Add Picture"), filter, (f) => {
                if (active_editor != null) active_editor.insert_file(f);
            });
        }

        public void insert_attachment() {
            choose_file(_("Attach File"), null, (f) => {
                if (active_editor == null || note_id == "") return;
                try {
                    string rel = Attachments.import_file(notes_dir, note_id, f);
                    var b = new Block(BlockKind.FILE);
                    b.alt = f.get_basename() ?? "";
                    b.image = rel;
                    active_editor.insert_block_at_cursor(b);
                } catch (Error e) {
                    status(_("The file could not be added: %s").printf(e.message));
                }
            });
        }

        public void insert_printout_file() {
            var filter = new FileFilter();
            filter.name = _("Documents");
            filter.add_mime_type("application/pdf");
            foreach (string pat in new string[] { "*.docx", "*.odt", "*.md", "*.txt", "*.html", "*.htm" }) filter.add_pattern(pat);
            choose_file(_("Insert Printout"), filter, (f) => {
                if (active_editor == null) return;
                attach_pdf(active_editor, f, active_editor.current_line(), true);
            });
        }

        private void attach_pdf(RichEditor ed, File file, int line, bool printout = true) {
            if (note_id == "") return;
            try {
                string rel = Attachments.import_file(notes_dir, note_id, file);
                var b = new Block(BlockKind.FILE);
                b.alt = file.get_basename() ?? "";
                b.image = rel;
                ed.insert_block_at_line_end(line, b);
                if (printout) insert_printout(ed, Path.build_filename(notes_dir, rel), ed.current_line() - 1);
            } catch (Error e) {
                status(_("The file could not be added: %s").printf(e.message));
            }
        }

        private void insert_printout(RichEditor ed, string pdf, int line) {
            try {
                var pages = Attachments.is_pdf(pdf) ? Attachments.pdf_printout(notes_dir, note_id, pdf) : Attachments.document_printout(notes_dir, note_id, pdf);
                int at = line;
                int n = 1;
                string name = Path.get_basename(pdf);
                foreach (string rel in pages) {
                    ed.insert_block_at_line_end(at, RichText.image_block(_("%s, page %d").printf(name, n++), rel, 0));
                    at = ed.current_line() - 1;
                }
                if (Attachments.is_pdf(pdf)) OcrIndex.store(pdf, Attachments.pdf_text(pdf));
                status(ngettext("%d page inserted", "%d pages inserted", pages.size).printf(pages.size));
            } catch (Error e) {
                status(_("The printout could not be made: %s").printf(e.message));
            }
        }

        public void insert_equation() {
            if (active_editor == null || note_id == "") return;
            var ed = active_editor;
            var eq = new Singularity.Equations.Equation.from_latex("");
            EquationFiles.edit_and_save.begin(eq, notes_dir, note_id, get_root() as Gtk.Window, (o, r) => {
                string? rel = EquationFiles.edit_and_save.end(r);
                if (rel == null) {
                    if (EquationFiles.last_error != "") status(EquationFiles.last_error);
                    return;
                }
                ed.insert_block_at_cursor(RichText.image_block(eq.latex != "" ? eq.latex : eq.speech, rel, 0));
            });
        }

        public void transcribe_all() {
            int n = 0;
            foreach (var ed in editors()) foreach (var o in ed.all_objects()) {
                var r = o as RecordingObject;
                if (r != null) {
                    r.transcribe();
                    n++;
                }
            }
            if (n == 0) status(_("This page has no recordings"));
        }

        public void add_task() {
            if (active_editor == null) return;
            var ed = active_editor;
            int line = ed.current_line();
            string text = ed.selected_text().strip();
            if (text == "") text = ed.line_text(line);
            string uid = Uuid.string_random();
            TaskBridge.ask(get_root() as Gtk.Window, text, title_entry.text.strip(), uid, () => {
                ed.focus_line(line);
                ed.toggle_tag(LinkedTasks.TAG_PREFIX + uid);
                status(_("Task added to Tasks"));
            });
        }

        public void translate() {
            if (active_editor == null) return;
            var ed = active_editor;
            string text = ed.selected_text().strip();
            bool whole = text == "";
            if (whole) text = plain_text().strip();
            int start, end;
            bool sel = ed.selection_offsets(out start, out end);
            TranslateBridge.open(get_root() as Gtk.Window, text, (result, replace) => {
                if (replace && sel) {
                    TextIter a, b;
                    ed.buffer.get_iter_at_offset(out a, start);
                    ed.buffer.get_iter_at_offset(out b, end);
                    ed.buffer.delete(ref a, ref b);
                    ed.buffer.insert(ref a, result, -1);
                } else {
                    ed.focus_end();
                    ed.insert_plain("\n" + result);
                }
                ed.changed();
            });
        }

        public void open_reader() {
            var app = (Gtk.Application) GLib.Application.get_default();
            string body = "";
            foreach (var ed in editors()) {
                for (int l = 0; l < ed.line_count(); l++) {
                    string t = ed.line_text(l);
                    if (t != "") body += t + "\n";
                }
            }
            var reader = new ImmersiveReader(app, get_root() as Gtk.Window, title_entry.text.strip() != "" ? title_entry.text.strip() : _("Untitled Page"), body);
            reader.open_dialog();
        }

        public void open_math_assistant() {
            if (active_editor == null) return;
            MathAssistant.open(active_editor, active_editor.selected_text());
        }

        public bool recording {
            get { return recorder != null && recorder.running; }
        }

        public void start_recording(bool video) {
            if (recording || note_id == "" || active_editor == null) return;
            string ext = video ? "webm" : Recorder.audio_extension();
            string stamp = new DateTime.now_local().format("%Y%m%d-%H%M%S");
            string dir = Attachments.dir_for(notes_dir, note_id);
            DirUtils.create_with_parents(dir, 0700);
            string path = Path.build_filename(dir, "recording-%s.%s".printf(stamp, ext));
            recorder = new Recorder(path, video);
            recording_info = new RecordingInfo();
            recording_info.path = path;
            recording_editor = active_editor;
            recording_line = active_editor.current_line();
            recorder.stopped.connect(on_recording_stopped);
            try {
                recorder.start();
            } catch (Error e) {
                recorder = null;
                status(e.message);
                return;
            }
            record_revealer.reveal_child = true;
            record_label.label = video ? _("Recording video 0:00") : _("Recording audio 0:00");
            record_tick = Timeout.add(500, () => {
                if (recorder == null || !recorder.running) {
                    record_tick = 0;
                    return Source.REMOVE;
                }
                string t = RecordingObject.format_time(recorder.elapsed);
                record_label.label = recorder.video ? _("Recording video %s").printf(t) : _("Recording audio %s").printf(t);
                return Source.CONTINUE;
            });
            active_changed();
        }

        public void stop_recording() {
            if (recorder == null) return;
            if (recording_info != null) recording_info.duration = recorder.elapsed;
            recorder.stop();
        }

        private void on_recording_stopped(string path, bool ok) {
            record_revealer.reveal_child = false;
            if (record_tick != 0) {
                Source.remove(record_tick);
                record_tick = 0;
            }
            var info = recording_info;
            var ed = recording_editor;
            recorder = null;
            recording_info = null;
            recording_editor = null;
            active_changed();
            if (!ok || info == null) {
                status(_("The recording failed"));
                return;
            }
            info.save();
            if (ed == null || !editors().contains(ed)) ed = active_editor;
            if (ed == null) return;
            var b = new Block(BlockKind.RECORDING);
            var when = new DateTime.now_local();
            b.alt = path.has_suffix(".webm") ? _("Video recording, %s").printf(when.format("%x %H:%M")) : _("Audio recording, %s").printf(when.format("%x %H:%M"));
            b.image = Attachments.relative(note_id, path);
            int line = int.min(recording_line, ed.line_count() - 1);
            ed.insert_block_at_line_end(int.max(0, line - 1), b, false);
            status(_("Recording added to the page"));
        }

        public RecordingObject? find_recording_for_line(RichEditor ed, int line) {
            string text = ed.line_text(line);
            foreach (var e in editors()) {
                foreach (var o in e.all_objects()) {
                    var r = o as RecordingObject;
                    if (r != null && r.time_for_text(text) != null) return r;
                }
            }
            return null;
        }

        public void play_from_current_line() {
            if (active_editor == null) return;
            int line = active_editor.current_line();
            var r = find_recording_for_line(active_editor, line);
            if (r == null) {
                status(_("Nothing was recorded while this line was written"));
                return;
            }
            r.play_from(double.max(0, r.time_for_text(active_editor.line_text(line)) - 2));
        }

        public string plain_text() {
            var sb = new StringBuilder();
            sb.append(title_entry.text + "\n");
            foreach (var ed in editors()) {
                for (int l = 0; l < ed.line_count(); l++) sb.append(ed.line_text(l) + "\n");
                foreach (var o in ed.all_objects()) sb.append(o.search_text() + "\n");
            }
            return sb.str;
        }

        public void set_presence(Gee.List<Presence>? people) {
            if (live != null) return;
            if (people == null || people.size == 0) {
                presence_label.visible = false;
                return;
            }
            string[] here = {};
            string[] around = {};
            foreach (var p in people) {
                if (p.page == note_id && note_id != "") here += p.name;
                else around += p.name;
            }
            if (here.length > 0) presence_label.label = _("Also on this page: %s").printf(string.joinv(", ", here));
            else presence_label.label = _("In this notebook now: %s").printf(string.joinv(", ", around));
            presence_label.visible = true;
        }

        public void focus_start() {
            if (active_editor == null) return;
            TextIter it;
            active_editor.buffer.get_start_iter(out it);
            active_editor.buffer.place_cursor(it);
            active_editor.view.grab_focus();
        }

        public void focus_title() {
            title_entry.grab_focus();
        }

        public void focus_body() {
            if (active_editor != null) active_editor.focus_end();
        }

        public void jump_to_anchor(string anchor) {
            foreach (var ed in editors()) {
                int l = ed.line_of_anchor(anchor);
                if (l >= 0) {
                    active_editor = ed;
                    ed.focus_line(l);
                    ed.highlight_lines(new Gee.ArrayList<int>.wrap({ l }));
                    Timeout.add(1600, () => {
                        ed.highlight_lines(new Gee.ArrayList<int>());
                        return Source.REMOVE;
                    });
                    return;
                }
            }
        }

        public void jump_to_block(int index) {
            int i = 0;
            foreach (var ed in editors()) {
                if (index < i + ed.line_count()) {
                    active_editor = ed;
                    ed.focus_line(index - i);
                    return;
                }
                i += ed.line_count();
            }
        }

        public void add_canvas_container() {
            if (!doc.meta.is_canvas) return;
            int y = 40;
            foreach (var ed in canvas.editors()) y = int.max(y, ed.view.get_height() + 80);
            active_editor = canvas.add_container_at(40, y);
        }
    }
}
