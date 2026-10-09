using Gtk;

namespace Singularity.Apps.Notes {

    public class NotesTextView : TextView {
        public signal void resized(int width);
        public string page_color { get; set; default = ""; }
        public string rule { get; set; default = ""; }
        private int last_width = -1;

        public override void size_allocate(int width, int height, int baseline) {
            base.size_allocate(width, height, baseline);
            if (width != last_width) {
                last_width = width;
                Idle.add(() => {
                    resized(last_width);
                    return Source.REMOVE;
                });
            }
        }

        public Gee.ArrayList<RemoteCaret> carets = new Gee.ArrayList<RemoteCaret>();

        public override void snapshot_layer(TextViewLayer layer, Snapshot snapshot) {
            if (layer == TextViewLayer.ABOVE_TEXT) {
                draw_carets(snapshot);
                return;
            }
            if (rule == "") return;
            Gdk.Rectangle vis;
            get_visible_rect(out vis);
            PageBackground.draw_rules(snapshot, rule, vis.x, vis.y, vis.width, vis.height, 0);
        }

        private void draw_carets(Snapshot snapshot) {
            foreach (var c in carets) {
                if (c.line < 0 || c.line >= buffer.get_line_count()) continue;
                TextIter it;
                buffer.get_iter_at_line(out it, c.line);
                int max = it.get_chars_in_line() - (c.line < buffer.get_line_count() - 1 ? 1 : 0);
                buffer.get_iter_at_line_offset(out it, c.line, int.max(0, int.min(c.column, max)));
                Gdk.Rectangle r;
                get_iter_location(it, out r);
                var rgba = Gdk.RGBA();
                if (!rgba.parse(c.color)) rgba.parse("#1c71d8");
                snapshot.append_color(rgba, Graphene.Rect().init(r.x - 1, r.y, 2, int.max(r.height, 16)));
                var layout = create_pango_layout(c.name);
                var fd = new Pango.FontDescription();
                fd.set_size(8 * Pango.SCALE);
                fd.set_weight(Pango.Weight.BOLD);
                layout.set_font_description(fd);
                int lw, lh;
                layout.get_pixel_size(out lw, out lh);
                float ly = r.y - lh - 2;
                if (ly < 0) ly = r.y + int.max(r.height, 16);
                var bg = Graphene.Rect().init(r.x - 1, ly, lw + 8, lh + 2);
                var rr = Gsk.RoundedRect();
                rr.init_from_rect(bg, 4);
                snapshot.push_rounded_clip(rr);
                snapshot.append_color(rgba, bg);
                snapshot.pop();
                snapshot.save();
                snapshot.translate(Graphene.Point().init(r.x + 3, ly + 1));
                var white = Gdk.RGBA();
                white.parse("#ffffff");
                snapshot.append_layout(layout, white);
                snapshot.restore();
            }
        }
    }

    public class RemoteCaret : Object {
        public string name { get; set; default = ""; }
        public string color { get; set; default = "#1c71d8"; }
        public int line { get; set; default = 0; }
        public int column { get; set; default = 0; }
    }

    public class PageBackground {
        public const int SPACING = 28;

        public static Gdk.RGBA? color_of(string name) {
            string spec;
            switch (name) {
                case "yellow": spec = "#fff9db"; break;
                case "green": spec = "#ebfbee"; break;
                case "blue": spec = "#e7f5ff"; break;
                case "pink": spec = "#fff0f6"; break;
                case "purple": spec = "#f3f0ff"; break;
                case "grey": spec = "#f1f3f5"; break;
                case "orange": spec = "#fff4e6"; break;
                default: return null;
            }
            var c = Gdk.RGBA();
            c.parse(spec);
            return c;
        }

        public static void draw_rules(Snapshot snapshot, string rule, int x, int y, int w, int h, int offset) {
            var c = Gdk.RGBA();
            c.parse("#7aa7d9");
            c.alpha = 0.35f;
            int first = ((y - offset) / SPACING) * SPACING + offset;
            for (int ly = first; ly < y + h; ly += SPACING) {
                if (ly < y) continue;
                snapshot.append_color(c, Graphene.Rect().init(x, ly, w, 1));
            }
            if (rule == "grid") {
                int fx = (x / SPACING) * SPACING;
                for (int lx = fx; lx < x + w; lx += SPACING) {
                    if (lx < x) continue;
                    snapshot.append_color(c, Graphene.Rect().init(lx, y, 1, h));
                }
            }
        }
    }

    public class LineStyle {
        public int heading = 0;
        public bool quote = false;
        public bool code = false;
        public int indent = 0;

        public LineStyle copy() {
            var s = new LineStyle();
            s.heading = heading;
            s.quote = quote;
            s.code = code;
            s.indent = indent;
            return s;
        }
    }

    public class RichEditor : Object {
        public const int MAX_INDENT = 8;
        public const string[] FONTS = { "Sans", "Serif", "Monospace", "Cantarell", "Inter", "Noto Sans", "Noto Serif", "DejaVu Sans", "Liberation Serif", "Comic Neue" };
        public const int[] SIZES = { 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48, 72 };

        public signal void changed();
        public signal void status(string message);
        public signal void navigate(string uri);
        public signal void activated();
        public signal void cursor_moved();
        public signal void page_link_requested();
        public signal void printout_requested(string pdf_path, int line);
        public signal void attach_requested(File file, int line);
        public signal void link_dialog_requested();
        public signal void play_here_requested();
        public signal void task_requested();
        public signal void translate_requested();

        public delegate NoteClip? ClipSource();
        public signal void select_page_requested();
        public signal void page_cut_requested();
        public ClipSource? page_clip = null;

        public delegate string LinkTitle(string href);
        public static LinkTitle? link_title = null;
        public static string? copied_link = null;

        public NotesTextView view { get; private set; }
        public TextBuffer buffer { get; private set; }
        public string notes_dir { get; set; default = ""; }
        public string note_id { get; set; default = ""; }
        public int base_margin { get; private set; }

        private TextTag[] tag_h = new TextTag[7];
        private TextTag tag_quote;
        private TextTag tag_code;
        private TextTag[] tag_indent = new TextTag[MAX_INDENT + 1];
        public TextTag tag_bold;
        public TextTag tag_italic;
        public TextTag tag_underline;
        public TextTag tag_strike;
        public TextTag tag_mono;
        private TextTag tag_done;
        private TextTag tag_bullet;
        private TextTag tag_number;
        private TextTag tag_find;
        private TextTag tag_find_current;
        private TextTag tag_play;

        private Gee.HashMap<TextTag, string> link_tags = new Gee.HashMap<TextTag, string>();
        private Gee.HashMap<TextChildAnchor, CheckButton> checks = new Gee.HashMap<TextChildAnchor, CheckButton>();
        private Gee.HashMap<TextChildAnchor, string> chips = new Gee.HashMap<TextChildAnchor, string>();
        private Gee.HashMap<TextChildAnchor, NoteObject> objects = new Gee.HashMap<TextChildAnchor, NoteObject>();
        private Gee.HashMap<TextMark, string> anchor_marks = new Gee.HashMap<TextMark, string>();
        private Gee.HashMap<TextMark, string> lang_marks = new Gee.HashMap<TextMark, string>();

        private bool loading = false;
        private bool internal_edit = false;
        private LineStyle? pending_style = null;
        public Gee.HashSet<string> typing = new Gee.HashSet<string>();
        private uint renumber_source = 0;
        private Gee.ArrayList<int> find_starts = new Gee.ArrayList<int>();
        private Gee.ArrayList<int> find_ends = new Gee.ArrayList<int>();
        private int find_index = -1;
        public bool trailing_newline = false;

        public RichEditor(int margin = 32) {
            base_margin = margin;
            buffer = new TextBuffer(null);
            buffer.enable_undo = false;
            double[] scales = { 1.0, 1.9, 1.55, 1.3, 1.15, 1.05, 1.0 };
            for (int i = 1; i <= 6; i++) {
                tag_h[i] = buffer.create_tag("h%d".printf(i), "scale", scales[i], "weight", i >= 5 ? 600 : 700,
                                             "pixels-above-lines", i <= 2 ? 10 : 6, "pixels-below-lines", 4);
                if (i == 6) tag_h[i].style = Pango.Style.ITALIC;
            }
            tag_quote = buffer.create_tag("quote", "left-margin", margin + 18, "style", Pango.Style.ITALIC, "foreground-rgba", rgba("#6b6b73"));
            tag_code = buffer.create_tag("code", "family", "Monospace", "paragraph-background-rgba", rgba("rgba(127,127,127,0.12)"), "left-margin", margin + 8);
            for (int i = 1; i <= MAX_INDENT; i++) tag_indent[i] = buffer.create_tag("indent%d".printf(i), "left-margin", margin + 28 * i);
            tag_bold = buffer.create_tag("bold", "weight", 700);
            tag_italic = buffer.create_tag("italic", "style", Pango.Style.ITALIC);
            tag_underline = buffer.create_tag("underline", "underline", Pango.Underline.SINGLE);
            tag_strike = buffer.create_tag("strike", "strikethrough", true);
            tag_mono = buffer.create_tag("mono", "family", "Monospace", "background-rgba", rgba("rgba(127,127,127,0.16)"));
            tag_done = buffer.create_tag("done", "strikethrough", true, "foreground-rgba", rgba("#808080"));
            tag_bullet = buffer.create_tag("bullet", "weight", 700);
            tag_number = buffer.create_tag("number", "foreground-rgba", rgba("#6b6b73"));
            tag_find = buffer.create_tag("find", "background-rgba", rgba("rgba(255,214,0,0.55)"));
            tag_find_current = buffer.create_tag("find-current", "background-rgba", rgba("rgba(255,120,0,0.75)"));
            tag_play = buffer.create_tag("play", "paragraph-background-rgba", rgba("rgba(53,132,228,0.18)"));

            view = new NotesTextView();
            view.buffer = buffer;
            view.wrap_mode = WrapMode.WORD_CHAR;
            view.left_margin = margin;
            view.right_margin = margin;
            view.top_margin = margin > 16 ? 8 : 4;
            view.bottom_margin = margin > 16 ? 40 : 6;
            view.pixels_below_lines = 4;
            view.add_css_class("notes-text");
            view.hexpand = true;
            view.resized.connect(on_resized);
            Menus.route_secondary(view);

            buffer.insert_text.connect_after(on_inserted);
            buffer.changed.connect(on_changed);
            buffer.mark_set.connect((loc, mark) => {
                if (mark == buffer.get_insert()) {
                    view.cursor_visible = true;
                }
                if (mark == buffer.get_insert() && !loading) {
                    sync_typing();
                    cursor_moved();
                }
            });

            var keys = new EventControllerKey();
            keys.key_pressed.connect(on_key);
            view.add_controller(keys);

            var focus = new EventControllerFocus();
            focus.enter.connect(() => activated());
            view.add_controller(focus);

            var click = new GestureClick();
            click.released.connect((n, x, y) => {
                if ((click.get_current_event_state() & Gdk.ModifierType.CONTROL_MASK) != 0) on_click(x, y);
            });
            view.add_controller(click);
            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => {
                int bx, by;
                view.window_to_buffer_coords(TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
                TextIter it;
                string? href = view.get_iter_at_location(out it, bx, by) ? link_at(it) : null;
                bool ctrl = (motion.get_current_event_state() & Gdk.ModifierType.CONTROL_MASK) != 0;
                view.set_cursor_from_name(href != null && ctrl ? "pointer" : "text");
                view.tooltip_text = href != null ? _("Ctrl+click to open %s").printf(describe_link(href)) : null;
            });
            view.add_controller(motion);

            view.paste_clipboard.connect(on_paste);
            view.copy_clipboard.connect(() => {
                if (copy_rich(false)) GLib.Signal.stop_emission_by_name(view, "copy-clipboard");
            });
            view.cut_clipboard.connect(() => {
                if (copy_rich(true)) GLib.Signal.stop_emission_by_name(view, "cut-clipboard");
            });
            view.select_all.connect((select) => {
                if (!select || !whole_selected()) return;
                GLib.Signal.stop_emission_by_name(view, "select-all");
                select_page_requested();
            });
            var group = new SimpleActionGroup();
            var copy_link = new SimpleAction("copy-paragraph-link", null);
            copy_link.activate.connect(() => copy_paragraph_link());
            group.add_action(copy_link);
            var link_page = new SimpleAction("link-page", null);
            link_page.activate.connect(() => link_dialog_requested());
            group.add_action(link_page);
            var add_task = new SimpleAction("add-task", null);
            add_task.activate.connect(() => task_requested());
            group.add_action(add_task);
            var translate = new SimpleAction("translate", null);
            translate.activate.connect(() => translate_requested());
            group.add_action(translate);
            var play_here = new SimpleAction("play-here", null);
            play_here.activate.connect(() => play_here_requested());
            group.add_action(play_here);
            view.insert_action_group("note", group);
            var extra = new GLib.Menu();
            var links = new GLib.Menu();
            links.append(_("Copy Link to Paragraph"), "note.copy-paragraph-link");
            links.append(_("Link to a Page or Section…"), "note.link-page");
            extra.append_section(null, links);
            var tools = new GLib.Menu();
            tools.append(_("Add to Tasks…"), "note.add-task");
            tools.append(_("Translate…"), "note.translate");
            extra.append_section(null, tools);
            var media = new GLib.Menu();
            media.append(_("Play Recording from Here"), "note.play-here");
            extra.append_section(null, media);
            view.extra_menu = extra;
            var drop = new DropTarget(typeof(Gdk.FileList), Gdk.DragAction.COPY);
            drop.drop.connect((value, x, y) => {
                var list = (Gdk.FileList) value.get_boxed();
                int bx, by;
                view.window_to_buffer_coords(TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
                TextIter it;
                view.get_iter_at_location(out it, bx, by);
                buffer.place_cursor(it);
                foreach (var f in list.get_files()) insert_file(f);
                return true;
            });
            view.add_controller(drop);
        }

        private static Gdk.RGBA rgba(string spec) {
            var c = Gdk.RGBA();
            c.parse(spec);
            return c;
        }

        public static string describe_link(string href) {
            if (href.has_prefix("note:")) return _("the linked page");
            if (href.has_prefix("section:")) return _("the linked section");
            return href;
        }

        private void on_resized(int width) {
            int avail = width - view.left_margin - view.right_margin - 12;
            foreach (var o in objects.values) o.set_available_width(avail);
        }

        public int available_width() {
            int w = view.get_width();
            if (w <= 0) w = 640;
            return w - view.left_margin - view.right_margin - 12;
        }

        private void detach_children() {
            var root = view.get_root() as Gtk.Window;
            if (root != null) {
                var f = root.get_focus();
                if (f != null && f != view && f.is_ancestor(view)) view.grab_focus();
            }
            var anchors = new Gee.ArrayList<TextChildAnchor>();
            anchors.add_all(objects.keys);
            anchors.add_all(checks.keys);
            anchors.add_all(chips.keys);
            foreach (var a in anchors) {
                if (a.get_deleted()) continue;
                foreach (var w in a.get_widgets()) {
                    if (w.get_parent() == view) view.remove(w);
                }
            }
        }

        public void load(string markdown) {
            loading = true;
            internal_edit = true;
            detach_children();
            checks.clear();
            chips.clear();
            objects.clear();
            foreach (var t in link_tags.keys) buffer.tag_table.remove(t);
            link_tags.clear();
            foreach (var m in anchor_marks.keys) buffer.delete_mark(m);
            foreach (var m in lang_marks.keys) buffer.delete_mark(m);
            anchor_marks.clear();
            lang_marks.clear();
            clear_find();
            buffer.set_text("", 0);
            trailing_newline = markdown.has_suffix("\n");
            var blocks = RichText.parse(markdown);
            int[] numbers = RichText.numbering(blocks);
            for (int i = 0; i < blocks.size; i++) {
                if (i > 0) {
                    TextIter end;
                    buffer.get_end_iter(out end);
                    buffer.insert(ref end, "\n", 1);
                }
                insert_block(blocks[i], numbers[i]);
            }
            TextIter start;
            buffer.get_start_iter(out start);
            buffer.place_cursor(start);
            pending_style = null;
            typing.clear();
            internal_edit = false;
            loading = false;
        }

        private void insert_block(Block b, int number) {
            TextIter end;
            buffer.get_end_iter(out end);
            int line = end.get_line();
            if (b.kind.is_object()) {
                var obj = create_object(b);
                insert_object_anchor(ref end, obj);
                if (b.anchor != "") set_line_anchor(line, b.anchor);
                return;
            }
            foreach (string t in b.tags) {
                buffer.get_end_iter(out end);
                insert_chip(ref end, t);
            }
            buffer.get_end_iter(out end);
            if (b.kind == BlockKind.CHECK) insert_check_anchor(ref end, b.checked);
            else if (b.kind == BlockKind.BULLET) buffer.insert_with_tags(ref end, "• ", -1, tag_bullet);
            else if (b.kind == BlockKind.NUMBERED) buffer.insert_with_tags(ref end, RichText.number_label(number, b.indent) + " ", -1, tag_number);
            if (b.kind == BlockKind.CODE) {
                buffer.get_end_iter(out end);
                buffer.insert(ref end, b.raw, -1);
            } else {
                foreach (var s in b.spans) {
                    buffer.get_end_iter(out end);
                    int offset = end.get_offset();
                    buffer.insert(ref end, s.text, -1);
                    TextIter from;
                    buffer.get_iter_at_offset(out from, offset);
                    foreach (var t in span_tags(s)) buffer.apply_tag(t, from, end);
                    if (b.kind == BlockKind.CHECK && b.checked) buffer.apply_tag(tag_done, from, end);
                }
            }
            var st = new LineStyle();
            st.heading = b.kind.heading_level();
            st.quote = b.kind == BlockKind.QUOTE;
            st.code = b.kind == BlockKind.CODE;
            st.indent = b.indent;
            apply_line_style(line, st);
            if (b.anchor != "") set_line_anchor(line, b.anchor);
            if (b.kind == BlockKind.CODE && b.lang != "") {
                TextIter ls;
                buffer.get_iter_at_line(out ls, line);
                lang_marks[buffer.create_mark(null, ls, true)] = b.lang;
            }
        }

        private Gee.List<TextTag> span_tags(Span s) {
            var list = new Gee.ArrayList<TextTag>();
            if (s.bold) list.add(tag_bold);
            if (s.italic) list.add(tag_italic);
            if (s.underline) list.add(tag_underline);
            if (s.strike) list.add(tag_strike);
            if (s.code) list.add(tag_mono);
            if (s.color != "") list.add(style_tag("fg", s.color));
            if (s.highlight != "") list.add(style_tag("bg", s.highlight));
            if (s.font != "") list.add(style_tag("font", s.font));
            if (s.size > 0) list.add(style_tag("size", s.size.to_string()));
            if (s.href != "") list.add(link_tag(s.href));
            return list;
        }

        public TextTag style_tag(string kind, string value) {
            string name = "%s:%s".printf(kind, value);
            var existing = buffer.tag_table.lookup(name);
            if (existing != null) return existing;
            var tag = new TextTag(name);
            switch (kind) {
                case "fg":
                    tag.foreground_rgba = rgba(value);
                    break;
                case "bg":
                    var c = rgba(value == "yellow" ? "#ffe066" : value);
                    c.alpha = 0.75f;
                    tag.background_rgba = c;
                    break;
                case "font":
                    tag.family = value;
                    break;
                case "size":
                    tag.size_points = double.parse(value);
                    break;
                default:
                    break;
            }
            buffer.tag_table.add(tag);
            return tag;
        }

        private static bool is_style_tag(TextTag t) {
            string? n = t.name;
            return n != null && (n.has_prefix("fg:") || n.has_prefix("bg:") || n.has_prefix("font:") || n.has_prefix("size:"));
        }

        private TextTag link_tag(string href) {
            string color = href.has_prefix("note:") || href.has_prefix("section:") ? "#9141ac" : "#3584e4";
            var tag = buffer.create_tag(null, "underline", Pango.Underline.SINGLE, "foreground-rgba", rgba(color));
            link_tags[tag] = href;
            return tag;
        }

        private void insert_check_anchor(ref TextIter at, bool active) {
            var anchor = buffer.create_child_anchor(at);
            var check = new CheckButton();
            check.active = active;
            check.margin_end = 6;
            check.valign = Align.CENTER;
            check.add_css_class("notes-check");
            check.toggled.connect(() => on_check_toggled(anchor, check));
            view.add_child_at_anchor(check, anchor);
            checks[anchor] = check;
            buffer.get_iter_at_child_anchor(out at, anchor);
            at.forward_char();
        }

        private void insert_chip(ref TextIter at, string tag_id) {
            var anchor = buffer.create_child_anchor(at);
            var def = TagCatalog.get_default().lookup(tag_id);
            var img = new Image.from_icon_name(def.icon);
            img.pixel_size = 16;
            img.margin_end = 6;
            img.valign = Align.CENTER;
            img.add_css_class("notes-tag-chip");
            img.add_css_class("notes-tag-" + tag_id);
            img.tooltip_text = def.label;
            view.add_child_at_anchor(img, anchor);
            chips[anchor] = tag_id;
            Menus.on_secondary(img, (m) => {
                m.add_item(_("Remove Tag “%s”").printf(def.label), "edit-delete-symbolic", () => remove_chip(anchor));
            });
            var click = new GestureClick();
            click.pressed.connect(() => {
                TextIter it;
                buffer.get_iter_at_child_anchor(out it, anchor);
                buffer.place_cursor(it);
            });
            img.add_controller(click);
            buffer.get_iter_at_child_anchor(out at, anchor);
            at.forward_char();
        }

        private void remove_chip(TextChildAnchor anchor) {
            if (anchor.get_deleted()) return;
            TextIter a;
            buffer.get_iter_at_child_anchor(out a, anchor);
            TextIter b = a;
            b.forward_char();
            chips.unset(anchor);
            buffer.delete(ref a, ref b);
        }

        private NoteObject create_object(Block b) {
            NoteObject.building = this;
            NoteObject obj;
            switch (b.kind) {
                case BlockKind.TABLE:
                    var t = new TableObject(b.table ?? TableObject.empty(2, 2));
                    t.anchor_id = b.anchor;
                    obj = t;
                    break;
                case BlockKind.FILE:
                    obj = new FileObject(b);
                    break;
                case BlockKind.RECORDING:
                    obj = new RecordingObject(b);
                    break;
                case BlockKind.INK:
                    obj = new InkObject(b);
                    break;
                case BlockKind.EQUATION:
                    obj = new EquationObject(b);
                    break;
                case BlockKind.RULE:
                    obj = new RuleObject();
                    break;
                default:
                    obj = new ImageObject(b);
                    break;
            }
            obj.editor = this;
            NoteObject.building = null;
            obj.set_available_width(available_width());
            obj.changed.connect(() => changed());
            obj.status.connect((m) => status(m));
            return obj;
        }

        private void insert_object_anchor(ref TextIter at, NoteObject obj) {
            var anchor = buffer.create_child_anchor(at);
            view.add_child_at_anchor(obj, anchor);
            objects[anchor] = obj;
            obj.remove_requested.connect(() => remove_object(anchor));
            buffer.get_iter_at_child_anchor(out at, anchor);
            at.forward_char();
        }

        private void remove_object(TextChildAnchor anchor) {
            if (anchor.get_deleted()) return;
            TextIter a;
            buffer.get_iter_at_child_anchor(out a, anchor);
            TextIter b = a;
            b.forward_char();
            if (!b.is_end() && b.get_char() == '\n') b.forward_char();
            else if (a.get_line() > 0) {
                a.backward_char();
            }
            objects.unset(anchor);
            buffer.delete(ref a, ref b);
            changed();
        }

        public Gee.Collection<NoteObject> all_objects() {
            return objects.values;
        }

        private TextIter line_iter(int line) {
            TextIter it;
            buffer.get_iter_at_line(out it, line);
            return it;
        }

        private void line_range(int line, out TextIter start, out TextIter end) {
            start = line_iter(line);
            end = start;
            if (!end.ends_line()) end.forward_to_line_end();
            if (!end.is_end()) end.forward_char();
        }

        public LineStyle read_line_style(int line) {
            var st = new LineStyle();
            var it = line_iter(line);
            if (it.is_end()) return pending_style != null ? pending_style.copy() : st;
            for (int i = 1; i <= 6; i++) if (it.has_tag(tag_h[i])) st.heading = i;
            st.quote = it.has_tag(tag_quote);
            st.code = it.has_tag(tag_code);
            for (int i = 1; i <= MAX_INDENT; i++) if (it.has_tag(tag_indent[i])) st.indent = i;
            return st;
        }

        public void apply_line_style(int line, LineStyle st) {
            TextIter start, end;
            line_range(line, out start, out end);
            for (int i = 1; i <= 6; i++) buffer.remove_tag(tag_h[i], start, end);
            buffer.remove_tag(tag_quote, start, end);
            buffer.remove_tag(tag_code, start, end);
            for (int i = 1; i <= MAX_INDENT; i++) buffer.remove_tag(tag_indent[i], start, end);
            if (st.heading > 0 && st.heading <= 6) buffer.apply_tag(tag_h[st.heading], start, end);
            if (st.quote) buffer.apply_tag(tag_quote, start, end);
            if (st.code) buffer.apply_tag(tag_code, start, end);
            int ind = st.indent.clamp(0, MAX_INDENT);
            if (ind > 0) buffer.apply_tag(tag_indent[ind], start, end);
            if (start.equal(end)) pending_style = st.copy();
        }

        public int chip_count(int line) {
            var it = line_iter(line);
            int n = 0;
            while (!it.ends_line()) {
                var a = it.get_child_anchor();
                if (a == null || !chips.has_key(a)) break;
                n++;
                it.forward_char();
            }
            return n;
        }

        public Gee.List<string> line_tags(int line) {
            var list = new Gee.ArrayList<string>();
            var it = line_iter(line);
            while (!it.ends_line()) {
                var a = it.get_child_anchor();
                if (a == null || !chips.has_key(a)) break;
                list.add(chips[a]);
                it.forward_char();
            }
            return list;
        }

        public BlockKind list_kind(int line, out int prefix_len) {
            int chipn = chip_count(line);
            var it = line_iter(line);
            it.forward_chars(chipn);
            prefix_len = chipn;
            if (it.ends_line()) return BlockKind.PARAGRAPH;
            var a = it.get_child_anchor();
            if (a != null && checks.has_key(a)) {
                prefix_len = chipn + 1;
                return BlockKind.CHECK;
            }
            if (it.get_char() == 0x2022 && it.has_tag(tag_bullet)) {
                prefix_len = chipn + 2;
                return BlockKind.BULLET;
            }
            if (it.has_tag(tag_number)) {
                int n = 0;
                while (!it.ends_line() && it.has_tag(tag_number)) {
                    n++;
                    it.forward_char();
                }
                prefix_len = chipn + n;
                return BlockKind.NUMBERED;
            }
            return BlockKind.PARAGRAPH;
        }

        public int prefix_length(int line) {
            int n;
            list_kind(line, out n);
            return n;
        }

        public NoteObject? object_at_line(int line) {
            var it = line_iter(line);
            var a = it.get_child_anchor();
            if (a != null && objects.has_key(a)) return objects[a];
            return null;
        }

        private void on_inserted(ref TextIter pos, string text, int length) {
            if (loading || internal_edit) return;
            TextIter start = pos;
            start.backward_chars(text.char_count());
            int first = start.get_line();
            int last = pos.get_line();
            int pos_offset = pos.get_offset();
            int start_offset = start.get_offset();
            TextIter before = start;
            bool has_before = before.backward_char() && before.get_line() == first;
            LineStyle st;
            if (has_before) {
                st = style_at(before);
            } else {
                TextIter after = pos;
                if (!after.is_end() && after.get_line() == last && !after.ends_line()) st = style_at(after);
                else st = pending_style != null ? pending_style.copy() : style_at(pos);
            }
            foreach (var t in all_inline_tags()) buffer.remove_tag(t, start, pos);
            if (text != "\n") {
                foreach (string key in typing) {
                    var t = typing_tag(key);
                    if (t != null) buffer.apply_tag(t, start, pos);
                }
                if (in_done_line(first)) buffer.apply_tag(tag_done, start, pos);
            }
            apply_line_style(first, st);
            var rest = st.copy();
            rest.heading = 0;
            for (int l = first + 1; l <= last; l++) apply_line_style(l, rest);
            if (last > first) pending_style = null;
            buffer.get_iter_at_offset(out pos, pos_offset);
            if (text == "[" && start_offset > 0) {
                TextIter prev;
                buffer.get_iter_at_offset(out prev, start_offset - 1);
                if (prev.get_char() == '[') Idle.add(() => {
                    page_link_requested();
                    return Source.REMOVE;
                });
            }
            schedule_renumber();
        }

        private bool in_done_line(int line) {
            int n;
            if (list_kind(line, out n) != BlockKind.CHECK) return false;
            var it = line_iter(line);
            it.forward_chars(chip_count(line));
            var a = it.get_child_anchor();
            return a != null && checks.has_key(a) && checks[a].active;
        }

        private LineStyle style_at(TextIter it) {
            var st = new LineStyle();
            for (int i = 1; i <= 6; i++) if (it.has_tag(tag_h[i])) st.heading = i;
            st.quote = it.has_tag(tag_quote);
            st.code = it.has_tag(tag_code);
            for (int i = 1; i <= MAX_INDENT; i++) if (it.has_tag(tag_indent[i])) st.indent = i;
            return st;
        }

        private Gee.List<TextTag> all_inline_tags() {
            var list = new Gee.ArrayList<TextTag>();
            list.add(tag_bold);
            list.add(tag_italic);
            list.add(tag_underline);
            list.add(tag_strike);
            list.add(tag_mono);
            list.add(tag_done);
            list.add(tag_find);
            list.add(tag_find_current);
            buffer.tag_table.foreach((t) => {
                if (is_style_tag(t)) list.add(t);
            });
            list.add_all(link_tags.keys);
            return list;
        }

        private TextTag? typing_tag(string key) {
            switch (key) {
                case "bold": return tag_bold;
                case "italic": return tag_italic;
                case "underline": return tag_underline;
                case "strike": return tag_strike;
                case "mono": return tag_mono;
                default:
                    int colon = key.index_of(":");
                    if (colon > 0) return style_tag(key.substring(0, colon), key.substring(colon + 1));
                    return null;
            }
        }

        private string? tag_key(TextTag t) {
            if (t == tag_bold) return "bold";
            if (t == tag_italic) return "italic";
            if (t == tag_underline) return "underline";
            if (t == tag_strike) return "strike";
            if (t == tag_mono) return "mono";
            if (is_style_tag(t)) return t.name;
            return null;
        }

        private void sync_typing() {
            TextIter cursor;
            buffer.get_iter_at_mark(out cursor, buffer.get_insert());
            TextIter probe = cursor;
            if (!(probe.backward_char() && probe.get_line() == cursor.get_line() && probe.get_char() != 0xFFFC)) {
                if (!cursor.ends_line() && cursor.get_char() != 0xFFFC) probe = cursor;
                else return;
            }
            typing.clear();
            foreach (var t in probe.get_tags()) {
                string? k = tag_key(t);
                if (k != null) typing.add(k);
            }
        }

        public bool has_typing(string key) {
            TextIter a, b;
            if (buffer.get_selection_bounds(out a, out b)) {
                var t = typing_tag(key);
                return t != null && a.has_tag(t);
            }
            return key in typing;
        }

        public string typing_value(string kind) {
            TextIter a, b;
            if (buffer.get_selection_bounds(out a, out b)) {
                foreach (var t in a.get_tags()) if (t.name != null && t.name.has_prefix(kind + ":")) return t.name.substring(kind.length + 1);
                return "";
            }
            foreach (string k in typing) if (k.has_prefix(kind + ":")) return k.substring(kind.length + 1);
            return "";
        }

        private void on_changed() {
            if (loading || internal_edit) return;
            clear_find();
            changed();
        }

        private void schedule_renumber() {
            if (renumber_source != 0) return;
            renumber_source = Idle.add(() => {
                renumber_source = 0;
                renumber();
                return Source.REMOVE;
            });
        }

        public void renumber() {
            var counters = new int[MAX_INDENT + 2];
            int lines = buffer.get_line_count();
            TextIter cursor;
            buffer.get_iter_at_mark(out cursor, buffer.get_insert());
            int cursor_offset = cursor.get_offset();
            bool touched = false;
            internal_edit = true;
            for (int l = 0; l < lines; l++) {
                int plen;
                var kind = list_kind(l, out plen);
                int level = read_line_style(l).indent.clamp(0, MAX_INDENT);
                if (kind == BlockKind.NUMBERED) {
                    counters[level]++;
                    for (int k = level + 1; k < counters.length; k++) counters[k] = 0;
                    string want = RichText.number_label(counters[level], level) + " ";
                    int chipn = chip_count(l);
                    TextIter s = line_iter(l);
                    s.forward_chars(chipn);
                    TextIter e = s;
                    e.forward_chars(plen - chipn);
                    if (s.get_text(e) != want) {
                        int delta = want.char_count() - (plen - chipn);
                        int soff = s.get_offset();
                        buffer.delete(ref s, ref e);
                        buffer.get_iter_at_offset(out s, soff);
                        buffer.insert_with_tags(ref s, want, -1, tag_number);
                        var st = read_line_style(l);
                        apply_line_style(l, st);
                        if (cursor_offset > soff) cursor_offset += delta;
                        touched = true;
                    }
                } else if (kind == BlockKind.BULLET || kind == BlockKind.CHECK) {
                    for (int k = level; k < counters.length; k++) counters[k] = 0;
                } else if (object_at_line(l) == null) {
                    for (int k = 0; k < counters.length; k++) counters[k] = 0;
                }
            }
            internal_edit = false;
            if (touched) {
                buffer.get_iter_at_offset(out cursor, cursor_offset);
                buffer.place_cursor(cursor);
            }
        }

        public string serialize() {
            var blocks = new Gee.ArrayList<Block>();
            int lines = buffer.get_line_count();
            for (int line = 0; line < lines; line++) blocks.add(line_block(line));
            string md = RichText.render(blocks);
            return trailing_newline ? md + "\n" : md;
        }

        private string? mark_value(Gee.HashMap<TextMark, string> map, int line) {
            TextIter s, e;
            line_range(line, out s, out e);
            string? found = null;
            int best = int.MAX;
            foreach (var entry in map.entries) {
                if (entry.key.get_deleted()) continue;
                TextIter mi;
                buffer.get_iter_at_mark(out mi, entry.key);
                if (mi.get_line() != line) continue;
                if (mi.get_offset() < best) {
                    best = mi.get_offset();
                    found = entry.value;
                }
            }
            return found;
        }

        public void set_line_anchor(int line, string id) {
            var it = line_iter(line);
            anchor_marks[buffer.create_mark(null, it, true)] = id;
        }

        public string ensure_line_anchor(int line) {
            string? existing = mark_value(anchor_marks, line);
            if (existing != null) return existing;
            string id = "p-" + Uuid.string_random().substring(0, 8);
            set_line_anchor(line, id);
            var obj = object_at_line(line);
            if (obj is TableObject) ((TableObject) obj).anchor_id = id;
            else if (obj is ImageObject) ((ImageObject) obj).block.anchor = id;
            else if (obj is FileObject) ((FileObject) obj).block.anchor = id;
            changed();
            return id;
        }

        public int line_of_anchor(string id) {
            foreach (var e in anchor_marks.entries) {
                if (e.value != id || e.key.get_deleted()) continue;
                TextIter it;
                buffer.get_iter_at_mark(out it, e.key);
                return it.get_line();
            }
            return -1;
        }

        public Block line_block(int line) {
            var obj = object_at_line(line);
            string? anchor = mark_value(anchor_marks, line);
            if (obj != null) {
                var ob = obj.to_block();
                if (anchor != null) ob.anchor = anchor;
                return ob;
            }
            int plen;
            var kind = list_kind(line, out plen);
            var st = read_line_style(line);
            Block b;
            if (kind != BlockKind.PARAGRAPH) {
                b = new Block(kind);
                b.indent = st.indent;
                if (kind == BlockKind.CHECK) {
                    var it = line_iter(line);
                    it.forward_chars(chip_count(line));
                    var a = it.get_child_anchor();
                    b.checked = a != null && checks.has_key(a) && checks[a].active;
                }
            } else if (st.code) {
                b = new Block(BlockKind.CODE);
            } else if (st.heading > 0) {
                b = new Block(BlockKind.heading(st.heading));
            } else if (st.quote) {
                b = new Block(BlockKind.QUOTE);
            } else {
                b = new Block(BlockKind.PARAGRAPH);
                b.indent = st.indent;
            }
            var tags = line_tags(line);
            b.tags = tags.to_array();
            if (anchor != null) b.anchor = anchor;
            var it = line_iter(line);
            it.forward_chars(plen);
            if (b.kind == BlockKind.CODE) {
                TextIter e = it;
                if (!e.ends_line()) e.forward_to_line_end();
                b.raw = it.get_text(e).replace("￼", "");
                b.lang = mark_value(lang_marks, line) ?? "";
                if (line > 0 && read_line_style(line - 1).code && list_kind(line - 1, out plen) == BlockKind.PARAGRAPH) b.lang = "";
                return b;
            }
            collect_spans(b, it, -1);
            return b;
        }

        private void collect_spans(Block b, TextIter from, int stop) {
            TextIter it = from;
            var sb = new StringBuilder();
            Span? cur = null;
            while (!it.ends_line() && !it.is_end() && (stop < 0 || it.get_line_offset() < stop)) {
                unichar c = it.get_char();
                if (c == 0xFFFC) {
                    it.forward_char();
                    continue;
                }
                var s = span_at(it);
                if (cur != null && !cur.same_style(s)) {
                    b.add(cur.with_text(sb.str));
                    sb.truncate(0);
                }
                cur = s;
                sb.append_unichar(c);
                it.forward_char();
            }
            if (cur != null && sb.len > 0) b.add(cur.with_text(sb.str));
        }

        public Block block_range(int line, int from, int to) {
            var b = line_block(line);
            if (b.kind.is_object()) return b;
            int plen;
            list_kind(line, out plen);
            var start = line_iter(line);
            var end = start;
            if (!end.ends_line()) end.forward_to_line_end();
            int line_end = end.get_line_offset();
            if (from <= plen && (to < 0 || to >= line_end)) return b;
            var it = line_iter(line);
            it.forward_chars(int.max(plen, from));
            if (b.kind == BlockKind.CODE) {
                TextIter e = it;
                if (to >= 0 && to < line_end) e.set_line_offset(to);
                else if (!e.ends_line()) e.forward_to_line_end();
                b.raw = it.get_text(e).replace("￼", "");
                return b;
            }
            b.spans.clear();
            collect_spans(b, it, to);
            return b;
        }

        private bool whole_selected() {
            TextIter a, b;
            if (!buffer.get_selection_bounds(out a, out b)) return false;
            return a.is_start() && b.is_end();
        }

        public void select_everything() {
            TextIter a, b;
            buffer.get_bounds(out a, out b);
            buffer.select_range(a, b);
        }

        public NoteClip? selection_clip() {
            TextIter a, b;
            if (!buffer.get_selection_bounds(out a, out b)) return null;
            var clip = new NoteClip(notes_dir, note_id);
            int first = a.get_line();
            int last = b.get_line();
            if (last > first && b.get_line_offset() == 0) last--;
            if (first == last && object_at_line(first) == null) {
                int plen;
                list_kind(first, out plen);
                bool to_end = b.get_line() > first || b.ends_line();
                if (a.get_line_offset() > plen || !to_end) {
                    clip.inline = true;
                    clip.blocks.add(block_range(first, a.get_line_offset(), b.get_line() > first ? -1 : b.get_line_offset()));
                    return clip;
                }
            }
            for (int l = first; l <= last; l++) {
                int from = l == first ? a.get_line_offset() : 0;
                int to = l == b.get_line() ? b.get_line_offset() : -1;
                clip.blocks.add(block_range(l, from, to));
            }
            return clip;
        }

        private bool copy_rich(bool cut) {
            NoteClip? clip = page_clip != null ? page_clip() : null;
            bool page = clip != null;
            if (clip == null) clip = selection_clip();
            if (clip == null || clip.blocks.size == 0) return false;
            view.get_clipboard().set_content(clip.provider());
            if (cut && view.editable) {
                if (page) page_cut_requested();
                else {
                    buffer.delete_selection(true, true);
                    changed();
                }
            }
            return true;
        }

        public void insert_clip(NoteClip clip) {
            if (clip.notes_dir != "" && note_id != "") clip.import_into(notes_dir, note_id);
            if (clip.blocks.size == 0) return;
            if (clip.inline || (clip.blocks.size == 1 && clip.blocks[0].kind == BlockKind.PARAGRAPH && clip.blocks[0].tags.length == 0)) {
                insert_spans(clip.blocks[0].spans);
                return;
            }
            insert_blocks(clip.blocks);
        }

        public void insert_spans(Gee.List<Span> spans) {
            buffer.begin_user_action();
            buffer.delete_selection(true, true);
            foreach (var s in spans) {
                if (s.text == "") continue;
                TextIter c;
                buffer.get_iter_at_mark(out c, buffer.get_insert());
                int offset = c.get_offset();
                internal_edit = true;
                buffer.insert(ref c, s.text, -1);
                internal_edit = false;
                TextIter from;
                buffer.get_iter_at_offset(out from, offset);
                foreach (var t in all_inline_tags()) buffer.remove_tag(t, from, c);
                foreach (var t in span_tags(s)) buffer.apply_tag(t, from, c);
            }
            buffer.end_user_action();
            view.grab_focus();
            changed();
        }

        public void insert_blocks(Gee.List<Block> pasted) {
            buffer.delete_selection(true, true);
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            int line = c.get_line();
            int col = c.get_line_offset();
            bool at_end = c.ends_line();
            var all = new Gee.ArrayList<Block>();
            int cursor_block = -1;
            int lines = buffer.get_line_count();
            for (int l = 0; l < lines; l++) {
                if (l != line) {
                    all.add(line_block(l));
                    continue;
                }
                var cur = line_block(l);
                int plen;
                list_kind(l, out plen);
                bool empty = !cur.kind.is_object() && cur.kind == BlockKind.PARAGRAPH && cur.plain_text() == "" && cur.tags.length == 0;
                if (empty) {
                    all.add_all(pasted);
                    cursor_block = all.size - 1;
                } else if (cur.kind.is_object()) {
                    if (col == 0) {
                        all.add_all(pasted);
                        cursor_block = all.size - 1;
                        all.add(cur);
                    } else {
                        all.add(cur);
                        all.add_all(pasted);
                        cursor_block = all.size - 1;
                    }
                } else if (col <= plen) {
                    all.add_all(pasted);
                    cursor_block = all.size - 1;
                    all.add(cur);
                } else if (at_end) {
                    all.add(cur);
                    all.add_all(pasted);
                    cursor_block = all.size - 1;
                } else {
                    all.add(block_range(l, 0, col));
                    all.add_all(pasted);
                    cursor_block = all.size - 1;
                    all.add(block_range(l, col, -1));
                }
            }
            bool tn = trailing_newline;
            load(RichText.render(all));
            trailing_newline = tn;
            if (cursor_block >= 0 && cursor_block < buffer.get_line_count()) {
                var it = line_iter(cursor_block);
                if (!it.ends_line()) it.forward_to_line_end();
                buffer.place_cursor(it);
            }
            view.grab_focus();
            changed();
        }

        private void paste_html(string html) {
            var conv = new HtmlConverter();
            conv.heading_shift = 0;
            conv.convert(html, false);
            if (conv.blocks.size == 0) return;
            Clipper.fetch_images.begin(conv, notes_dir, note_id, null, null, (o, r) => {
                Clipper.fetch_images.end(r);
                var clip = new NoteClip("", note_id);
                clip.blocks.add_all(conv.blocks);
                insert_clip(clip);
            });
        }

        private void read_clipboard_text(string mime, owned TextHandler handler) {
            var clipboard = view.get_clipboard();
            clipboard.read_async.begin({ mime }, Priority.DEFAULT, null, (o, r) => {
                try {
                    string out_mime;
                    var stream = clipboard.read_async.end(r, out out_mime);
                    var mem = new MemoryOutputStream.resizable();
                    mem.splice_async.begin(stream, OutputStreamSpliceFlags.CLOSE_SOURCE | OutputStreamSpliceFlags.CLOSE_TARGET, Priority.DEFAULT, null, (o2, r2) => {
                        try {
                            mem.splice_async.end(r2);
                            var data = mem.steal_as_bytes();
                            var sb = new StringBuilder();
                            sb.append_len((string) data.get_data(), (ssize_t) data.get_size());
                            handler(sb.str.make_valid());
                        } catch (Error e) {
                            status(_("The clipboard could not be read"));
                        }
                    });
                } catch (Error e) {
                    status(_("The clipboard could not be read"));
                }
            });
        }

        private delegate void TextHandler(string text);

        private Span span_at(TextIter it) {
            var s = new Span("");
            foreach (var t in it.get_tags()) {
                if (t == tag_bold) s.bold = true;
                else if (t == tag_italic) s.italic = true;
                else if (t == tag_underline) s.underline = true;
                else if (t == tag_strike) s.strike = true;
                else if (t == tag_mono) s.code = true;
                else if (link_tags.has_key(t)) s.href = link_tags[t];
                else if (t.name != null) {
                    string n = t.name;
                    if (n.has_prefix("fg:")) s.color = n.substring(3);
                    else if (n.has_prefix("bg:")) s.highlight = n.substring(3);
                    else if (n.has_prefix("font:")) s.font = n.substring(5);
                    else if (n.has_prefix("size:")) s.size = int.parse(n.substring(5));
                }
            }
            return s;
        }

        private string? link_at(TextIter it) {
            foreach (var t in it.get_tags()) {
                if (link_tags.has_key(t)) return link_tags[t];
            }
            return null;
        }

        private void on_click(double x, double y) {
            if (buffer.get_has_selection()) return;
            int bx, by;
            view.window_to_buffer_coords(TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
            TextIter it;
            if (!view.get_iter_at_location(out it, bx, by)) return;
            string? href = link_at(it);
            if (href == null) return;
            open_link(href);
        }

        public void open_link(string href) {
            if (href.has_prefix("note:") || href.has_prefix("section:")) {
                navigate(href);
                return;
            }
            if (href.has_prefix("attachments/")) {
                ImageObject.open_external(Path.build_filename(notes_dir, Uri.unescape_string(href) ?? href), view.get_root() as Gtk.Window);
                return;
            }
            var launcher = new UriLauncher(href);
            launcher.launch.begin(view.get_root() as Gtk.Window, null, (o, r) => {
                try {
                    launcher.launch.end(r);
                } catch (Error e) {
                    status(_("The link could not be opened"));
                }
            });
        }

        public void copy_paragraph_link() {
            if (note_id == "") return;
            string id = ensure_line_anchor(current_line());
            string href = "note:%s#%s".printf(note_id, id);
            view.get_clipboard().set_text(href);
            copied_link = href;
            status(_("Link copied. Paste it in any page."));
        }

        private void on_paste() {
            var clipboard = view.get_clipboard();
            var formats = clipboard.get_formats();
            if (note_id != "" && formats.contain_mime_type(NoteClip.MIME)) {
                GLib.Signal.stop_emission_by_name(view, "paste-clipboard");
                read_clipboard_text(NoteClip.MIME, (text) => {
                    var clip = NoteClip.parse_native(text);
                    if (clip != null) insert_clip(clip);
                });
                return;
            }
            if (note_id != "" && formats.contain_mime_type("text/html") && !(clipboard.is_local() && copied_link != null)) {
                GLib.Signal.stop_emission_by_name(view, "paste-clipboard");
                read_clipboard_text("text/html", (text) => paste_html(text));
                return;
            }
            if (clipboard.is_local() && copied_link != null && formats.contain_gtype(typeof(string))) {
                GLib.Signal.stop_emission_by_name(view, "paste-clipboard");
                string href = copied_link;
                clipboard.read_text_async.begin(null, (o, r) => {
                    try {
                        string? text = clipboard.read_text_async.end(r);
                        if (text == null) return;
                        if (text == href && (href.has_prefix("note:") || href.has_prefix("section:"))) {
                            string title = link_title != null ? link_title(href) : "";
                            if (href.contains("#")) {
                                string line_text = title;
                                title = title != "" ? _("%s (paragraph)").printf(title) : _("Linked paragraph");
                                if (line_text == "") title = _("Linked paragraph");
                            }
                            int s, e;
                            bool sel = selection_offsets(out s, out e);
                            insert_link(s, e, sel, title != "" ? title : href, href);
                        } else {
                            TextIter c;
                            buffer.delete_selection(true, true);
                            buffer.get_iter_at_mark(out c, buffer.get_insert());
                            buffer.insert(ref c, text, -1);
                        }
                    } catch (Error e) {
                    }
                });
                return;
            }
            if (formats.contain_gtype(typeof(Gdk.Texture)) && !formats.contain_gtype(typeof(string))) {
                GLib.Signal.stop_emission_by_name(view, "paste-clipboard");
                clipboard.read_texture_async.begin(null, (o, r) => {
                    try {
                        var tex = clipboard.read_texture_async.end(r);
                        if (tex != null) insert_texture(tex);
                    } catch (Error e) {
                        status(_("The picture could not be pasted"));
                    }
                });
                return;
            }
            if (formats.contain_gtype(typeof(Gdk.FileList)) && !formats.contain_gtype(typeof(string))) {
                GLib.Signal.stop_emission_by_name(view, "paste-clipboard");
                clipboard.read_value_async.begin(typeof(Gdk.FileList), Priority.DEFAULT, null, (o, r) => {
                    try {
                        var v = clipboard.read_value_async.end(r);
                        var list = (Gdk.FileList) v.get_boxed();
                        foreach (var f in list.get_files()) insert_file(f);
                    } catch (Error e) {
                    }
                });
                return;
            }
        }

        public void insert_texture(Gdk.Texture tex) {
            if (note_id == "") return;
            try {
                string rel = Attachments.save_texture(notes_dir, note_id, tex);
                insert_block_at_cursor(RichText.image_block(_("Pasted picture"), rel, 0));
            } catch (Error e) {
                status(_("The picture could not be pasted"));
            }
        }

        public void insert_file(File file) {
            if (note_id == "") return;
            string path = file.get_path() ?? "";
            if (path.down().has_suffix(".pdf")) {
                TextIter c;
                buffer.get_iter_at_mark(out c, buffer.get_insert());
                attach_requested(file, c.get_line());
                return;
            }
            try {
                string rel = Attachments.import_file(notes_dir, note_id, file);
                if (Attachments.is_image(path)) insert_block_at_cursor(RichText.image_block(file.get_basename() ?? "", rel, 0));
                else {
                    var b = new Block(BlockKind.FILE);
                    b.alt = file.get_basename() ?? Path.get_basename(rel);
                    b.image = rel;
                    insert_block_at_cursor(b);
                }
            } catch (Error e) {
                status(_("The file could not be added: %s").printf(e.message));
            }
        }

        public void insert_block_at_cursor(Block b) {
            TextIter at;
            buffer.get_iter_at_mark(out at, buffer.get_insert());
            insert_block_at_line_end(at.get_line(), b, at.get_line_offset() == 0 && at.ends_line());
        }

        public void insert_block_at_line_end(int line, Block b, bool replace_empty = false) {
            internal_edit = true;
            TextIter at = line_iter(line);
            if (!replace_empty || object_at_line(line) != null) {
                if (!at.ends_line()) at.forward_to_line_end();
                buffer.insert(ref at, "\n", 1);
            }
            int obj_line = at.get_line();
            apply_line_style(obj_line, new LineStyle());
            var obj = create_object(b);
            insert_object_anchor(ref at, obj);
            if (at.is_end() || at.ends_line() && at.get_line() == buffer.get_line_count() - 1) {
                buffer.insert(ref at, "\n", 1);
            } else {
                at.forward_char();
            }
            if (at.get_line() == obj_line) at.forward_line();
            internal_edit = false;
            buffer.place_cursor(at);
            view.grab_focus();
            changed();
        }

        public void insert_text_after_object(NoteObject obj, string text) {
            foreach (var e in objects.entries) {
                if (e.value != obj || e.key.get_deleted()) continue;
                TextIter it;
                buffer.get_iter_at_child_anchor(out it, e.key);
                if (!it.ends_line()) it.forward_to_line_end();
                buffer.insert(ref it, "\n" + text, -1);
                changed();
                return;
            }
        }

        public void insert_printout_after(NoteObject obj, string path) {
            foreach (var e in objects.entries) {
                if (e.value != obj || e.key.get_deleted()) continue;
                TextIter it;
                buffer.get_iter_at_child_anchor(out it, e.key);
                printout_requested(path, it.get_line());
                return;
            }
        }

        public int object_line(NoteObject obj) {
            foreach (var e in objects.entries) {
                if (e.value != obj || e.key.get_deleted()) continue;
                TextIter it;
                buffer.get_iter_at_child_anchor(out it, e.key);
                return it.get_line();
            }
            return -1;
        }

        public void focus_after_object(NoteObject obj) {
            int l = object_line(obj);
            if (l < 0) return;
            if (l + 1 >= buffer.get_line_count()) {
                TextIter end;
                buffer.get_end_iter(out end);
                internal_edit = true;
                buffer.insert(ref end, "\n", 1);
                internal_edit = false;
            }
            buffer.place_cursor(line_iter(l + 1));
            view.grab_focus();
        }

        public void focus_before_object(NoteObject obj) {
            int l = object_line(obj);
            if (l <= 0) return;
            var it = line_iter(l - 1);
            if (!it.ends_line()) it.forward_to_line_end();
            buffer.place_cursor(it);
            view.grab_focus();
        }

        private bool on_key(uint keyval, uint keycode, Gdk.ModifierType state) {
            bool ctrl = (state & Gdk.ModifierType.CONTROL_MASK) != 0;
            bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
            bool alt = (state & Gdk.ModifierType.ALT_MASK) != 0;
            uint k = Gdk.keyval_to_lower(keyval);
            if (ctrl && alt && k >= Gdk.Key.@1 && k <= Gdk.Key.@6) {
                set_heading((int) (k - Gdk.Key.@0));
                return true;
            }
            if (ctrl && shift && k == Gdk.Key.n) {
                set_heading(0);
                return true;
            }
            if (ctrl && !alt && k == Gdk.Key.b) {
                toggle_style("bold");
                return true;
            }
            if (ctrl && !alt && k == Gdk.Key.i) {
                toggle_style("italic");
                return true;
            }
            if (ctrl && !alt && k == Gdk.Key.u) {
                toggle_style("underline");
                return true;
            }
            if (ctrl && k == Gdk.Key.minus) {
                toggle_style("strike");
                return true;
            }
            if (ctrl && shift && k == Gdk.Key.h) {
                set_highlight("yellow");
                return true;
            }
            if (ctrl && k == Gdk.Key.l && !shift) {
                toggle_list(BlockKind.CHECK);
                return true;
            }
            if (ctrl && k == Gdk.Key.period) {
                toggle_list(BlockKind.BULLET);
                return true;
            }
            if (ctrl && k == Gdk.Key.slash) {
                toggle_list(BlockKind.NUMBERED);
                return true;
            }
            if (ctrl && k == Gdk.Key.k) {
                request_link();
                return true;
            }
            if (ctrl && !alt && !shift && k >= Gdk.Key.@0 && k <= Gdk.Key.@9) {
                if (k == Gdk.Key.@0) {
                    clear_tags();
                    return true;
                }
                if (k == Gdk.Key.@1) {
                    toggle_list(BlockKind.CHECK);
                    return true;
                }
                var def = TagCatalog.get_default().by_shortcut(((char) ('0' + (k - Gdk.Key.@0))).to_string());
                if (def != null) {
                    toggle_tag(def.id);
                    return true;
                }
            }
            if ((keyval == Gdk.Key.Tab || keyval == Gdk.Key.ISO_Left_Tab) && !ctrl) {
                TextIter c;
                buffer.get_iter_at_mark(out c, buffer.get_insert());
                int l = c.get_line();
                int plen;
                bool list = list_kind(l, out plen) != BlockKind.PARAGRAPH;
                if (list || c.get_line_offset() <= plen || buffer.get_has_selection() || shift) {
                    change_indent(shift ? -1 : 1);
                    return true;
                }
                return false;
            }
            if (alt && shift && (keyval == Gdk.Key.Right || keyval == Gdk.Key.Left)) {
                change_indent(keyval == Gdk.Key.Right ? 1 : -1);
                return true;
            }
            if ((keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) && !shift && !ctrl) {
                return continue_list();
            }
            if (keyval == Gdk.Key.BackSpace && !buffer.get_has_selection()) {
                TextIter cursor;
                buffer.get_iter_at_mark(out cursor, buffer.get_insert());
                int line = cursor.get_line();
                int prefix = prefix_length(line);
                if (prefix > 0 && cursor.get_line_offset() == prefix) {
                    int plen;
                    if (list_kind(line, out plen) != BlockKind.PARAGRAPH) remove_list_prefix(line);
                    else {
                        TextIter a = line_iter(line);
                        a.forward_chars(prefix - 1);
                        var anchor = a.get_child_anchor();
                        if (anchor != null) remove_chip(anchor);
                    }
                    changed();
                    return true;
                }
                if (cursor.get_line_offset() == 0 && line > 0) {
                    var obj = object_at_line(line - 1);
                    if (obj != null) {
                        focus_before_object(obj);
                        return true;
                    }
                    var st = read_line_style(line);
                    if (st.indent > 0 && prefix == 0) {
                        change_indent(-1);
                        return true;
                    }
                }
            }
            if (keyval == Gdk.Key.Delete && !buffer.get_has_selection()) {
                TextIter cursor;
                buffer.get_iter_at_mark(out cursor, buffer.get_insert());
                if (cursor.ends_line() && cursor.get_line() + 1 < buffer.get_line_count() && object_at_line(cursor.get_line() + 1) != null) return true;
            }
            return false;
        }

        private bool continue_list() {
            TextIter cursor;
            buffer.get_iter_at_mark(out cursor, buffer.get_insert());
            int line = cursor.get_line();
            if (object_at_line(line) != null) {
                focus_after_object(object_at_line(line));
                return true;
            }
            int prefix;
            var kind = list_kind(line, out prefix);
            var st = read_line_style(line);
            if (kind == BlockKind.PARAGRAPH) {
                if (st.code) return false;
                if (st.heading > 0 && cursor.ends_line()) {
                    buffer.begin_user_action();
                    buffer.insert(ref cursor, "\n", 1);
                    var ns = st.copy();
                    ns.heading = 0;
                    apply_line_style(cursor.get_line(), ns);
                    buffer.end_user_action();
                    return true;
                }
                return false;
            }
            TextIter line_end = cursor;
            if (!line_end.ends_line()) line_end.forward_to_line_end();
            TextIter start = line_iter(line);
            start.forward_chars(prefix);
            if (start.get_text(line_end).strip() == "" && start.get_offset() >= cursor.get_offset() - 0) {
                if (st.indent > 0) change_indent(-1);
                else remove_list_prefix(line);
                changed();
                return true;
            }
            buffer.begin_user_action();
            buffer.insert(ref cursor, "\n", 1);
            int nl = cursor.get_line();
            internal_edit = true;
            if (kind == BlockKind.CHECK) insert_check_anchor(ref cursor, false);
            else if (kind == BlockKind.BULLET) buffer.insert_with_tags(ref cursor, "• ", -1, tag_bullet);
            else buffer.insert_with_tags(ref cursor, "1. ", -1, tag_number);
            TextIter rs = line_iter(nl);
            TextIter re = rs;
            if (!re.ends_line()) re.forward_to_line_end();
            buffer.remove_tag(tag_done, rs, re);
            var ns = st.copy();
            ns.heading = 0;
            apply_line_style(nl, ns);
            internal_edit = false;
            buffer.place_cursor(cursor);
            buffer.end_user_action();
            view.scroll_mark_onscreen(buffer.get_insert());
            renumber();
            changed();
            return true;
        }

        private void remove_list_prefix(int line) {
            int plen;
            var kind = list_kind(line, out plen);
            if (kind == BlockKind.PARAGRAPH) return;
            int chipn = chip_count(line);
            internal_edit = true;
            TextIter start = line_iter(line);
            start.forward_chars(chipn);
            TextIter end = start;
            end.forward_chars(plen - chipn);
            var a = start.get_child_anchor();
            if (a != null) checks.unset(a);
            var st = read_line_style(line);
            buffer.delete(ref start, ref end);
            TextIter ls, le;
            line_range(line, out ls, out le);
            buffer.remove_tag(tag_done, ls, le);
            apply_line_style(line, st);
            internal_edit = false;
            schedule_renumber();
        }

        private void selected_lines(out int first, out int last) {
            TextIter a, b;
            if (!buffer.get_selection_bounds(out a, out b)) {
                buffer.get_iter_at_mark(out a, buffer.get_insert());
                b = a;
            }
            first = a.get_line();
            last = b.get_line();
            if (last > first && b.starts_line()) last--;
        }

        public void toggle_list(BlockKind kind) {
            int first, last;
            selected_lines(out first, out last);
            int plen;
            bool remove = list_kind(first, out plen) == kind;
            buffer.begin_user_action();
            internal_edit = true;
            for (int l = first; l <= last; l++) {
                if (object_at_line(l) != null) continue;
                var current = list_kind(l, out plen);
                if (current != BlockKind.PARAGRAPH) {
                    internal_edit = false;
                    remove_list_prefix(l);
                    internal_edit = true;
                }
                if (remove) continue;
                var st = read_line_style(l);
                st.heading = 0;
                st.quote = false;
                st.code = false;
                TextIter at = line_iter(l);
                at.forward_chars(chip_count(l));
                if (kind == BlockKind.CHECK) insert_check_anchor(ref at, false);
                else if (kind == BlockKind.BULLET) buffer.insert_with_tags(ref at, "• ", -1, tag_bullet);
                else buffer.insert_with_tags(ref at, "1. ", -1, tag_number);
                apply_line_style(l, st);
            }
            internal_edit = false;
            buffer.end_user_action();
            renumber();
            changed();
            view.grab_focus();
        }

        public void change_indent(int delta) {
            int first, last;
            selected_lines(out first, out last);
            for (int l = first; l <= last; l++) {
                if (object_at_line(l) != null) continue;
                var st = read_line_style(l);
                if (st.heading > 0 || st.code) continue;
                st.indent = (st.indent + delta).clamp(0, MAX_INDENT);
                apply_line_style(l, st);
            }
            renumber();
            changed();
            view.grab_focus();
        }

        public void set_heading(int level) {
            int first, last;
            selected_lines(out first, out last);
            buffer.begin_user_action();
            for (int l = first; l <= last; l++) {
                if (object_at_line(l) != null) continue;
                if (level > 0 && list_kind(l, null) != BlockKind.PARAGRAPH) remove_list_prefix(l);
                var st = new LineStyle();
                st.heading = level;
                if (level == 0) st.indent = read_line_style(l).indent;
                apply_line_style(l, st);
            }
            buffer.end_user_action();
            changed();
            cursor_moved();
            view.grab_focus();
        }

        public void set_block_style(string style) {
            int first, last;
            selected_lines(out first, out last);
            buffer.begin_user_action();
            for (int l = first; l <= last; l++) {
                if (object_at_line(l) != null) continue;
                var st = new LineStyle();
                if (style == "quote") st.quote = true;
                else if (style == "code") {
                    if (list_kind(l, null) != BlockKind.PARAGRAPH) remove_list_prefix(l);
                    st.code = true;
                }
                apply_line_style(l, st);
            }
            buffer.end_user_action();
            changed();
            cursor_moved();
            view.grab_focus();
        }

        public int current_heading() {
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            return read_line_style(c.get_line()).heading;
        }

        public string current_block_style() {
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            var st = read_line_style(c.get_line());
            if (st.code) return "code";
            if (st.quote) return "quote";
            if (st.heading > 0) return "h%d".printf(st.heading);
            return "body";
        }

        public BlockKind current_list() {
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            return list_kind(c.get_line(), null);
        }

        public void toggle_style(string key) {
            bool on = !has_typing(key);
            apply_inline(key, on);
        }

        public void apply_inline(string key, bool on) {
            var tag = typing_tag(key);
            if (tag == null) return;
            TextIter a, b;
            if (buffer.get_selection_bounds(out a, out b)) {
                if (on) buffer.apply_tag(tag, a, b);
                else buffer.remove_tag(tag, a, b);
                changed();
            }
            if (on) typing.add(key);
            else typing.remove(key);
            cursor_moved();
            view.grab_focus();
        }

        private void replace_kind(string kind, string? value) {
            TextIter a, b;
            bool sel = buffer.get_selection_bounds(out a, out b);
            if (sel) {
                buffer.tag_table.foreach((t) => {
                    if (t.name != null && t.name.has_prefix(kind + ":")) buffer.remove_tag(t, a, b);
                });
                if (value != null && value != "") buffer.apply_tag(style_tag(kind, value), a, b);
                changed();
            }
            foreach (string k in typing.to_array()) if (k.has_prefix(kind + ":")) typing.remove(k);
            if (value != null && value != "") typing.add(kind + ":" + value);
            cursor_moved();
            view.grab_focus();
        }

        public void set_color(string? color) {
            replace_kind("fg", color);
        }

        public void set_highlight(string? color) {
            string current = typing_value("bg");
            replace_kind("bg", current == color ? null : color);
        }

        public void set_font(string? family) {
            replace_kind("font", family);
        }

        public void set_size(int points) {
            replace_kind("size", points > 0 ? points.to_string() : null);
        }

        public void clear_formatting() {
            TextIter a, b;
            if (buffer.get_selection_bounds(out a, out b)) {
                foreach (var t in all_inline_tags()) if (!link_tags.has_key(t) && t != tag_done) buffer.remove_tag(t, a, b);
                changed();
            }
            typing.clear();
            int first, last;
            selected_lines(out first, out last);
            for (int l = first; l <= last; l++) if (object_at_line(l) == null) apply_line_style(l, new LineStyle());
            cursor_moved();
            view.grab_focus();
        }

        public void toggle_tag(string tag_id) {
            int first, last;
            selected_lines(out first, out last);
            bool remove = line_tags(first).contains(tag_id);
            internal_edit = true;
            for (int l = first; l <= last; l++) {
                if (object_at_line(l) != null) continue;
                var tags = line_tags(l);
                if (remove) {
                    var it = line_iter(l);
                    for (int i = 0; i < tags.size; i++) {
                        var a = it.get_child_anchor();
                        if (a != null && chips[a] == tag_id) {
                            internal_edit = false;
                            remove_chip(a);
                            internal_edit = true;
                            break;
                        }
                        it.forward_char();
                    }
                } else if (!tags.contains(tag_id)) {
                    var st = read_line_style(l);
                    TextIter at = line_iter(l);
                    at.forward_chars(tags.size);
                    insert_chip(ref at, tag_id);
                    apply_line_style(l, st);
                }
            }
            internal_edit = false;
            changed();
            view.grab_focus();
        }

        public void clear_tags() {
            int first, last;
            selected_lines(out first, out last);
            for (int l = first; l <= last; l++) {
                int n = chip_count(l);
                if (n == 0) continue;
                TextIter a = line_iter(l);
                TextIter b = a;
                b.forward_chars(n);
                buffer.delete(ref a, ref b);
            }
            changed();
        }

        public Gee.List<string> current_tags() {
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            return line_tags(c.get_line());
        }

        private void on_check_toggled(TextChildAnchor anchor, CheckButton check) {
            if (anchor.get_deleted()) return;
            TextIter start;
            buffer.get_iter_at_child_anchor(out start, anchor);
            TextIter end = start;
            if (!end.ends_line()) end.forward_to_line_end();
            TextIter text_start = start;
            text_start.forward_char();
            if (check.active) buffer.apply_tag(tag_done, text_start, end);
            else buffer.remove_tag(tag_done, text_start, end);
            changed();
        }

        public void request_link() {
            TextIter a, b;
            bool selected = buffer.get_selection_bounds(out a, out b);
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new Singularity.Widgets.ConfirmDialog(app, _("Add Link"), "insert-link",
                selected ? _("Link the selected text to a web address.") : _("Insert a link to a web address."),
                _("Add Link"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = view.get_root() as Gtk.Window;
            var url = new Entry();
            url.placeholder_text = "https://";
            url.input_purpose = InputPurpose.URL;
            dialog.custom_area.append(url);
            Entry? label_entry = null;
            if (!selected) {
                label_entry = new Entry();
                label_entry.placeholder_text = _("Text to show");
                dialog.custom_area.append(label_entry);
            }
            int start_offset = a.get_offset();
            int end_offset = b.get_offset();
            url.activate.connect(() => {
                if (url.text.strip() != "") dialog.response(Singularity.Widgets.ConfirmDialog.Response.PRIMARY);
            });
            dialog.response.connect((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY) {
                    string href = url.text.strip();
                    if (href != "" && !href.contains(":") && !href.has_prefix("mailto:")) href = "https://" + href;
                    if (href != "") insert_link(start_offset, end_offset, selected, label_entry != null ? label_entry.text : href, href);
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        public bool selection_offsets(out int start, out int end) {
            TextIter a, b;
            bool sel = buffer.get_selection_bounds(out a, out b);
            start = a.get_offset();
            end = b.get_offset();
            return sel;
        }

        public void insert_link(int start_offset, int end_offset, bool selected, string label, string href) {
            string h = href.replace(" ", "%20").replace(")", "%29");
            TextIter a, b;
            buffer.begin_user_action();
            if (selected) {
                buffer.get_iter_at_offset(out a, start_offset);
                buffer.get_iter_at_offset(out b, end_offset);
                foreach (var t in link_tags.keys) buffer.remove_tag(t, a, b);
                buffer.apply_tag(link_tag(h), a, b);
            } else {
                buffer.get_iter_at_mark(out a, buffer.get_insert());
                int off = a.get_offset();
                string text = label.strip() != "" ? label.strip() : h;
                internal_edit = true;
                buffer.insert(ref a, text, -1);
                internal_edit = false;
                buffer.get_iter_at_offset(out b, off);
                buffer.apply_tag(link_tag(h), b, a);
                buffer.place_cursor(a);
            }
            buffer.end_user_action();
            changed();
        }

        public void replace_brackets_with_link(string label, string href) {
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            TextIter s = c;
            if (s.backward_chars(2) && s.get_text(c) == "[[") {
                internal_edit = true;
                buffer.delete(ref s, ref c);
                internal_edit = false;
            }
            insert_link(0, 0, false, label, href);
        }

        public void focus_end() {
            TextIter end;
            buffer.get_end_iter(out end);
            buffer.place_cursor(end);
            view.grab_focus();
        }

        public void focus_line(int line) {
            if (line < 0 || line >= buffer.get_line_count()) return;
            var it = line_iter(line);
            buffer.place_cursor(it);
            view.grab_focus();
            view.scroll_to_iter(it, 0.1, true, 0, 0.3);
        }

        public int current_line() {
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            return c.get_line();
        }

        public int current_column() {
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            return c.get_line_offset();
        }

        public void place_cursor_quiet(int line, int column) {
            if (line < 0 || line >= buffer.get_line_count()) return;
            TextIter it = line_iter(line);
            int max = it.get_chars_in_line() - (line < buffer.get_line_count() - 1 ? 1 : 0);
            buffer.get_iter_at_line_offset(out it, line, int.max(0, int.min(column, max)));
            buffer.place_cursor(it);
        }

        public void set_carets(Gee.List<RemoteCaret> list) {
            view.carets.clear();
            view.carets.add_all(list);
            view.queue_draw();
        }

        public void clear_find() {
            if (find_starts.size == 0) return;
            TextIter s, e;
            buffer.get_bounds(out s, out e);
            buffer.remove_tag(tag_find, s, e);
            buffer.remove_tag(tag_find_current, s, e);
            find_starts.clear();
            find_ends.clear();
            find_index = -1;
        }

        public int find(string query) {
            clear_find();
            if (query == "") return 0;
            TextIter it;
            buffer.get_start_iter(out it);
            TextIter ms, me;
            while (it.forward_search(query, TextSearchFlags.CASE_INSENSITIVE | TextSearchFlags.TEXT_ONLY, out ms, out me, null)) {
                buffer.apply_tag(tag_find, ms, me);
                find_starts.add(ms.get_offset());
                find_ends.add(me.get_offset());
                it = me;
            }
            return find_starts.size;
        }

        public int find_count {
            get { return find_starts.size; }
        }

        public int find_step(bool forward) {
            if (find_starts.size == 0) return -1;
            TextIter s, e;
            if (find_index >= 0) {
                buffer.get_iter_at_offset(out s, find_starts[find_index]);
                buffer.get_iter_at_offset(out e, find_ends[find_index]);
                buffer.remove_tag(tag_find_current, s, e);
            }
            if (find_index < 0) {
                TextIter c;
                buffer.get_iter_at_mark(out c, buffer.get_insert());
                find_index = 0;
                for (int i = 0; i < find_starts.size; i++) {
                    if (find_starts[i] >= c.get_offset()) {
                        find_index = i;
                        break;
                    }
                }
                if (!forward) find_index = (find_index - 1 + find_starts.size) % find_starts.size;
            } else {
                find_index = (find_index + (forward ? 1 : -1) + find_starts.size) % find_starts.size;
            }
            buffer.get_iter_at_offset(out s, find_starts[find_index]);
            buffer.get_iter_at_offset(out e, find_ends[find_index]);
            buffer.apply_tag(tag_find_current, s, e);
            buffer.select_range(s, e);
            view.scroll_to_iter(s, 0.1, true, 0, 0.3);
            return find_index;
        }

        public int replace_current(string replacement) {
            if (find_index < 0 || find_index >= find_starts.size) return 0;
            TextIter s, e;
            buffer.get_iter_at_offset(out s, find_starts[find_index]);
            buffer.get_iter_at_offset(out e, find_ends[find_index]);
            buffer.delete(ref s, ref e);
            buffer.insert(ref s, replacement, -1);
            return 1;
        }

        public int replace_all(string query, string replacement) {
            int n = find(query);
            for (int i = find_starts.size - 1; i >= 0; i--) {
                TextIter s, e;
                buffer.get_iter_at_offset(out s, find_starts[i]);
                buffer.get_iter_at_offset(out e, find_ends[i]);
                buffer.delete(ref s, ref e);
                buffer.insert(ref s, replacement, -1);
            }
            clear_find();
            changed();
            return n;
        }

        public void highlight_lines(Gee.Collection<int> lines) {
            TextIter s, e;
            buffer.get_bounds(out s, out e);
            buffer.remove_tag(tag_play, s, e);
            foreach (int l in lines) {
                if (l < 0 || l >= buffer.get_line_count()) continue;
                TextIter a, b;
                line_range(l, out a, out b);
                buffer.apply_tag(tag_play, a, b);
            }
        }

        public string line_text(int line) {
            if (line < 0 || line >= buffer.get_line_count()) return "";
            TextIter a = line_iter(line);
            a.forward_chars(prefix_length(line));
            TextIter b = a;
            if (!b.ends_line()) b.forward_to_line_end();
            return a.get_text(b).replace("￼", "").strip();
        }

        public int line_count() {
            return buffer.get_line_count();
        }

        public string selected_text() {
            TextIter a, b;
            if (!buffer.get_selection_bounds(out a, out b)) return "";
            return a.get_text(b).replace("￼", "");
        }

        public void insert_plain(string text) {
            TextIter c;
            buffer.get_iter_at_mark(out c, buffer.get_insert());
            buffer.insert(ref c, text, -1);
            view.grab_focus();
        }
    }
}
