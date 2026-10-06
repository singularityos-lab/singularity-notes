using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Notes {

    public class TagSummary : Box {
        public signal void open_hit(TagHit hit);

        private Singularity.Notes.NoteStore store;
        private SectionLocks locks;
        private ListBox list;
        private Entry filter;
        private CheckButton open_only;
        private string grouping = "tag";

        public TagSummary(Singularity.Notes.NoteStore store, SectionLocks locks) {
            Object(orientation: Orientation.VERTICAL, spacing: 8);
            this.store = store;
            this.locks = locks;
            add_css_class("notes-tag-summary");
            margin_start = 24;
            margin_end = 24;
            margin_top = 16;
            var title = new Label(_("Tag Summary"));
            title.xalign = 0;
            title.add_css_class("title-2");
            append(title);
            var bar = new Box(Orientation.HORIZONTAL, 8);
            filter = new Entry();
            filter.placeholder_text = _("Filter tags and text");
            filter.hexpand = true;
            filter.changed.connect(() => reload());
            bar.append(filter);
            open_only = new CheckButton.with_label(_("Only open to-dos"));
            open_only.toggled.connect(() => reload());
            bar.append(open_only);
            var group = new BubbleSwitcher();
            group.add_option("tag", _("By Tag"));
            group.add_option("section", _("By Section"));
            group.add_option("page", _("By Page"));
            group.selected.connect((n) => {
                grouping = n;
                reload();
            });
            bar.append(group);
            append(bar);
            list = new ListBox();
            list.add_css_class("notes-list");
            list.selection_mode = SelectionMode.NONE;
            var scroll = new ScrolledWindow();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = list;
            append(scroll);
        }

        public void reload() {
            Widget? child;
            while ((child = list.get_first_child()) != null) list.remove(child);
            var groups = new Gee.TreeMap<string, Gee.ArrayList<TagHit>>();
            var titles = new Gee.HashMap<string, string>();
            string q = filter.text.strip().casefold();
            foreach (var n in store.all()) {
                string body = n.body;
                if (SectionLocks.is_locked_body(body)) {
                    string? plain = locks.decrypt(n.folder, body);
                    if (plain == null) continue;
                    body = plain;
                }
                titles[n.id] = PageDoc.title_of(body);
                foreach (var h in TagIndex.scan(n.id, body)) {
                    if (open_only.active && (!h.is_check || h.done)) continue;
                    var def = TagCatalog.get_default().lookup(h.tag);
                    string label = h.tag == "todo" ? _("To Do") : def.label;
                    if (q != "" && !h.text.casefold().contains(q) && !label.casefold().contains(q)) continue;
                    string key = grouping == "tag" ? label : grouping == "section" ? (n.folder != "" ? n.folder.replace("/", " › ") : _("Quick Notes")) : (titles[n.id] != "" ? titles[n.id] : _("Untitled Page"));
                    if (!groups.has_key(key)) groups[key] = new Gee.ArrayList<TagHit>();
                    groups[key].add(h);
                }
            }
            if (groups.size == 0) {
                var none = new Label(_("No tagged paragraphs. Tag a paragraph from the Home tab or with Ctrl+1 to Ctrl+9."));
                none.wrap = true;
                none.add_css_class("dim-label");
                none.margin_top = 24;
                var row = new ListBoxRow();
                row.child = none;
                row.activatable = false;
                list.append(row);
                return;
            }
            foreach (var e in groups.entries) {
                var head = new Label("%s  (%d)".printf(e.key, e.value.size));
                head.xalign = 0;
                head.add_css_class("heading");
                head.margin_top = 12;
                var hrow = new ListBoxRow();
                hrow.child = head;
                hrow.activatable = false;
                list.append(hrow);
                foreach (var h in e.value) {
                    var def = TagCatalog.get_default().lookup(h.tag);
                    var box = new Box(Orientation.HORIZONTAL, 10);
                    var icon = new Image.from_icon_name(h.tag == "todo" ? (h.done ? "checkbox-checked-symbolic" : "checkbox-symbolic") : def.icon);
                    icon.add_css_class("notes-tag-" + h.tag);
                    box.append(icon);
                    var text = new Label(h.text != "" ? h.text : _("(empty paragraph)"));
                    text.xalign = 0;
                    text.hexpand = true;
                    text.ellipsize = Pango.EllipsizeMode.END;
                    if (h.done) text.add_css_class("dim-label");
                    box.append(text);
                    var where = new Label(titles[h.note_id] != "" ? titles[h.note_id] : _("Untitled Page"));
                    where.add_css_class("dim-label");
                    where.add_css_class("caption");
                    where.ellipsize = Pango.EllipsizeMode.END;
                    where.max_width_chars = 30;
                    box.append(where);
                    var btn = new Button();
                    btn.add_css_class("flat");
                    btn.child = box;
                    var hit = h;
                    btn.clicked.connect(() => open_hit(hit));
                    var row = new ListBoxRow();
                    row.child = btn;
                    list.append(row);
                }
            }
        }
    }

    public class LinkPicker : AppDialog {
        public signal void chosen(string label, string href);

        private Singularity.Notes.NoteStore store;
        private Notebooks notebooks;
        private NotesWindow owner;
        private ListBox list;
        private Entry entry;

        public LinkPicker(Gtk.Application app, NotesWindow owner, Singularity.Notes.NoteStore store, Notebooks notebooks) {
            base(app, true);
            this.store = store;
            this.notebooks = notebooks;
            this.owner = owner;
            transient_for = owner;
            set_title(_("Link to a Page or Section"));
            set_default_size(520, 560);
            var box = new Box(Orientation.VERTICAL, 10);
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_bottom = 20;
            entry = new Entry();
            entry.placeholder_text = _("Search pages and sections");
            entry.changed.connect(() => fill());
            entry.activate.connect(() => {
                var row = list.get_row_at_index(0);
                if (row != null) row.activate();
            });
            box.append(entry);
            list = new ListBox();
            list.add_css_class("notes-list");
            list.row_activated.connect((row) => {
                chosen(row.get_data<string>("label"), row.get_data<string>("href"));
                close_dialog();
            });
            var scroll = new ScrolledWindow();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = list;
            box.append(scroll);
            var hint = new Label(_("To link a paragraph, right-click it and choose Copy Link to Paragraph, then paste the link."));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class("dim-label");
            hint.add_css_class("caption");
            box.append(hint);
            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            buttons.append(add_cancel_button());
            box.append(buttons);
            content_box.append(box);
            fill();
        }

        private void add(string icon, string title, string subtitle, string label, string href) {
            var row = new ListBoxRow();
            var b = new Box(Orientation.HORIZONTAL, 10);
            b.append(new Image.from_icon_name(icon));
            var labels = new Box(Orientation.VERTICAL, 0);
            var t = new Label(title);
            t.xalign = 0;
            t.ellipsize = Pango.EllipsizeMode.END;
            labels.append(t);
            if (subtitle != "") {
                var s = new Label(subtitle);
                s.xalign = 0;
                s.add_css_class("dim-label");
                s.add_css_class("caption");
                s.ellipsize = Pango.EllipsizeMode.END;
                labels.append(s);
            }
            b.append(labels);
            row.child = b;
            row.set_data<string>("label", label);
            row.set_data<string>("href", href);
            list.append(row);
        }

        private void fill() {
            Widget? child;
            while ((child = list.get_first_child()) != null) list.remove(child);
            string q = entry.text.strip().casefold();
            int n = 0;
            foreach (var s in owner.all_sections()) {
                if (q != "" && !s.path.casefold().contains(q)) continue;
                add("text-x-generic-symbolic", s.name, _("Section in %s").printf(Notebooks.parent_of(s.path) != "" ? Notebooks.parent_of(s.path).replace("/", " › ") : _("Notebooks")),
                    s.name, "section:" + Uri.escape_string(s.path, "/", false));
                if (++n > 30) break;
            }
            foreach (var note in store.all()) {
                string body = owner.plain_body(note);
                string title = PageDoc.title_of(body);
                if (title == "") title = _("Untitled Page");
                if (q != "" && !title.casefold().contains(q)) continue;
                add("x-office-document-symbolic", title, note.folder != "" ? note.folder.replace("/", " › ") : _("Quick Notes"), title, "note:" + note.id);
                if (++n > 120) break;
            }
        }
    }

    public class TemplatePicker : AppDialog {
        public signal void chosen(PageTemplate template);
        private Templates templates;
        private FlowBox grid;

        public TemplatePicker(Gtk.Application app, Gtk.Window owner, Templates templates) {
            base(app, true);
            this.templates = templates;
            transient_for = owner;
            set_title(_("New Page from a Template"));
            set_default_size(640, 560);
            var box = new Box(Orientation.VERTICAL, 10);
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_bottom = 20;
            grid = new FlowBox();
            grid.selection_mode = SelectionMode.NONE;
            grid.max_children_per_line = 3;
            grid.min_children_per_line = 2;
            grid.column_spacing = 10;
            grid.row_spacing = 10;
            grid.homogeneous = true;
            var scroll = new ScrolledWindow();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = grid;
            box.append(scroll);
            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            buttons.append(add_cancel_button());
            box.append(buttons);
            content_box.append(box);
            fill();
        }

        private void fill() {
            Widget? child;
            while ((child = grid.get_first_child()) != null) grid.remove(child);
            foreach (var t in templates.all()) {
                var b = new Button();
                b.add_css_class("notes-template");
                var v = new Box(Orientation.VERTICAL, 6);
                var icon = new Image.from_icon_name(t.icon);
                icon.pixel_size = 32;
                v.append(icon);
                var name = new Label(t.name);
                name.add_css_class("heading");
                name.wrap = true;
                name.justify = Justification.CENTER;
                v.append(name);
                var desc = new Label(t.description);
                desc.wrap = true;
                desc.justify = Justification.CENTER;
                desc.add_css_class("dim-label");
                desc.add_css_class("caption");
                v.append(desc);
                b.child = v;
                var tt = t;
                b.clicked.connect(() => {
                    chosen(tt);
                    close_dialog();
                });
                if (t.custom) Menus.on_secondary(b, (m) => m.add_item(_("Delete Template"), "edit-delete-symbolic", () => {
                    templates.remove(tt);
                    fill();
                }));
                grid.append(b);
            }
        }
    }

    public delegate string PlainFunc(string text);

    public class VersionsDialog : AppDialog {
        public signal void restore(string text);
        private ListBox list;
        private Label preview;
        private Button restore_button;
        private PageVersion? selected = null;
        private PlainFunc plain;

        public VersionsDialog(Gtk.Application app, Gtk.Window owner, History history, string id, owned PlainFunc plain) {
            base(app, true);
            this.plain = (owned) plain;
            transient_for = owner;
            set_title(_("Page Versions"));
            set_default_size(820, 580);
            var outer = new Box(Orientation.VERTICAL, 10);
            outer.margin_start = 20;
            outer.margin_end = 20;
            outer.margin_bottom = 20;
            var pane = new Box(Orientation.HORIZONTAL, 12);
            pane.vexpand = true;
            list = new ListBox();
            list.add_css_class("notes-list");
            var ls = new ScrolledWindow();
            ls.set_size_request(260, -1);
            ls.hscrollbar_policy = PolicyType.NEVER;
            ls.child = list;
            pane.append(ls);
            preview = new Label("");
            preview.xalign = 0;
            preview.yalign = 0;
            preview.wrap = true;
            preview.selectable = true;
            preview.add_css_class("notes-trash-preview");
            var ps = new ScrolledWindow();
            ps.hexpand = true;
            ps.child = preview;
            pane.append(ps);
            outer.append(pane);
            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            buttons.append(add_cancel_button(_("Close")));
            restore_button = new Button.with_label(_("Restore This Version"));
            restore_button.add_css_class("suggested-action");
            restore_button.sensitive = false;
            restore_button.clicked.connect(() => {
                if (selected == null) return;
                restore(selected.text());
                close_dialog();
            });
            buttons.append(restore_button);
            outer.append(buttons);
            content_box.append(outer);
            var versions = history.list(id);
            bool first = true;
            foreach (var v in versions) {
                var row = new ListBoxRow();
                var b = new Box(Orientation.VERTICAL, 2);
                var t = new Label(new DateTime.from_unix_local(v.time).format("%x %H:%M"));
                t.xalign = 0;
                t.add_css_class("heading");
                b.append(t);
                var who = new Label(first ? _("Current version, %s").printf(v.author) : v.author);
                who.xalign = 0;
                who.add_css_class("dim-label");
                who.add_css_class("caption");
                b.append(who);
                row.child = b;
                var vv = v;
                row.set_data<PageVersion>("version", vv);
                list.append(row);
                first = false;
            }
            list.row_selected.connect((row) => {
                if (row == null) return;
                selected = row.get_data<PageVersion>("version");
                preview.label = PageDoc.parse(this.plain(selected.text())).plain_text();
                restore_button.sensitive = list.get_row_at_index(0) != row;
            });
            if (versions.size == 0) preview.label = _("No earlier versions yet. Versions are kept while you edit, every few minutes.");
            else list.select_row(list.get_row_at_index(0));
        }
    }

    public class ExportDialog : AppDialog {
        public signal void chosen(ExportFormat format);

        public ExportDialog(Gtk.Application app, Gtk.Window owner, string what) {
            base(app, true);
            transient_for = owner;
            set_title(_("Export “%s”").printf(what));
            set_default_size(420, -1);
            var box = new Box(Orientation.VERTICAL, 8);
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_bottom = 20;
            var group = new PreferencesGroup(_("Format"));
            ExportFormat[] formats = { ExportFormat.PDF, ExportFormat.DOCX, ExportFormat.ODT, ExportFormat.HTML, ExportFormat.MARKDOWN, ExportFormat.PNG };
            string[] notes = { _("Pages as they print"), _("Opens in Word and Write"), _("Opens in Write and LibreOffice"), _("One file with the pictures inside"), _("Plain text with a folder of attachments"), _("One picture for each printed page") };
            for (int i = 0; i < formats.length; i++) {
                var row = new ActionRow(formats[i].label(), notes[i]);
                row.activatable = true;
                var f = formats[i];
                row.activated.connect(() => {
                    chosen(f);
                    close_dialog();
                });
                group.add_row(row);
            }
            box.append(group);
            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            buttons.append(add_cancel_button());
            box.append(buttons);
            content_box.append(box);
        }
    }
}
