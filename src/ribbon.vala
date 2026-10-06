using Gtk;

namespace Singularity.Apps.Notes {

    public class Ribbon : Singularity.Widgets.ContextRibbon {
        public signal void tag_summary_requested();
        public signal void versions_requested();
        public signal void page_link_requested();

        public PageView page { get; construct; }
        private bool syncing = false;
        private Singularity.Widgets.RibbonSelector style_selector;
        private Singularity.Widgets.RibbonSelector font_selector;
        private Singularity.Widgets.RibbonSelector size_selector;
        private Gee.HashMap<string, Singularity.Widgets.RibbonToggle> toggles = new Gee.HashMap<string, Singularity.Widgets.RibbonToggle>();
        private Gee.HashMap<InkTool, Singularity.Widgets.RibbonToggle> tool_buttons = new Gee.HashMap<InkTool, Singularity.Widgets.RibbonToggle>();
        private Singularity.Widgets.RibbonToggle canvas_toggle;
        private Singularity.Widgets.RibbonButton record_audio;
        private Singularity.Widgets.RibbonButton record_video;

        public Ribbon(PageView page) {
            Object(page: page, orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("notes-format-bar");
            build_home(add_context("home", _("Home"), "format-text-bold-symbolic"));
            build_insert(add_context("insert", _("Insert"), "list-add-symbolic"));
            build_draw(add_context("draw", _("Draw"), "notes-pen-symbolic"));
            build_view(add_context("view", _("View"), "view-reveal-symbolic"));
            page.active_changed.connect(sync);
            context_changed.connect((id) => {
                if (id != "draw" && InkTools.get_default().drawing) InkTools.get_default().tool = InkTool.NONE;
            });
            InkTools.get_default().notify["tool"].connect(sync_tools);
            sync();
        }

        private RichEditor? ed() {
            return page.active_editor;
        }

        private delegate void Act();

        private void act(Singularity.Widgets.RibbonContext c, string icon, string label, string? shortcut, owned Act cb) {
            var b = c.add_button(icon, label);
            b.shortcut = shortcut;
            b.activated.connect(() => cb());
        }

        private Singularity.Widgets.RibbonButton labeled_button(Singularity.Widgets.RibbonContext c, string icon, string label, string tip, owned Act cb) {
            var b = c.add_button(icon, label, tip);
            b.label_in_compact = true;
            b.activated.connect(() => cb());
            return b;
        }

        private void style_toggle(Singularity.Widgets.RibbonContext c, string key, string icon, string label, string? shortcut) {
            var t = c.add_toggle(icon, label);
            t.shortcut = shortcut;
            t.toggled.connect((active) => {
                if (syncing || ed() == null) return;
                ed().apply_inline(key, active);
            });
            toggles[key] = t;
        }

        private Singularity.Widgets.RibbonMenu menu(Singularity.Widgets.RibbonContext c, string icon, string label, string? tip, bool with_label, owned Singularity.Widgets.RibbonMenuBuilder build) {
            var m = c.add_menu(icon, label, tip);
            m.label_in_compact = with_label;
            m.set_builder((owned) build);
            return m;
        }

        private void build_home(Singularity.Widgets.RibbonContext c) {
            style_selector = c.add_selector(_("Paragraph Style"), 9);
            style_selector.add_option("0", _("Body"));
            style_selector.add_option("1", _("Title"));
            for (int i = 2; i <= 6; i++) style_selector.add_option(i.to_string(), _("Heading %d").printf(i - 1));
            style_selector.add_separator();
            style_selector.add_option("quote", _("Quote"));
            style_selector.add_option("code", _("Code"));
            style_selector.text = _("Body");
            style_selector.changed.connect((id) => {
                if (ed() == null) return;
                if (id == "quote" || id == "code") ed().set_block_style(id);
                else ed().set_heading(int.parse(id));
                sync();
            });
            font_selector = c.add_selector(_("Font"), 8);
            font_selector.add_option("", _("Default Font"));
            foreach (string f in RichEditor.FONTS) font_selector.add_option(f, f);
            font_selector.add_extra((m) => m.add_item(_("Other Font…"), null, () => choose_font()));
            font_selector.text = _("Font");
            font_selector.changed.connect((id) => {
                if (ed() == null) return;
                ed().set_font(id == "" ? null : id);
                sync();
            });
            size_selector = c.add_selector(_("Font Size"), 3);
            size_selector.add_option("0", _("Default Size"));
            foreach (int s in RichEditor.SIZES) size_selector.add_option(s.to_string(), s.to_string());
            size_selector.text = "11";
            size_selector.changed.connect((id) => {
                if (ed() == null) return;
                ed().set_size(int.parse(id));
                sync();
            });
            c.add_separator();
            style_toggle(c, "bold", "format-text-bold-symbolic", _("Bold"), "Ctrl+B");
            style_toggle(c, "italic", "format-text-italic-symbolic", _("Italic"), "Ctrl+I");
            style_toggle(c, "underline", "format-text-underline-symbolic", _("Underline"), "Ctrl+U");
            style_toggle(c, "strike", "format-text-strikethrough-symbolic", _("Strikethrough"), "Ctrl+-");
            style_toggle(c, "mono", "notes-code-symbolic", _("Inline Code"), null);
            menu(c, "notes-text-color-symbolic", _("Text Color"), null, false, (m) => {
                m.add_item(_("Automatic"), null, () => ed().set_color(null));
                foreach (string col in TEXT_COLORS) {
                    string cc = col;
                    m.add_widget(swatch_row(color_name(col), col, () => ed().set_color(cc)));
                }
                m.add_item(_("Other Color…"), null, () => choose_color((col) => ed().set_color(col)));
            });
            menu(c, "notes-marker-symbolic", _("Highlight"), _("Highlight (Ctrl+Shift+H)"), false, (m) => {
                m.add_item(_("No Highlight"), null, () => ed().set_highlight(null));
                foreach (string col in HIGHLIGHTS) {
                    string cc = col;
                    m.add_widget(swatch_row(color_name(col), col == "yellow" ? "#ffe066" : col, () => ed().set_highlight(cc)));
                }
            });
            act(c, "edit-clear-all-symbolic", _("Clear Formatting"), null, () => ed().clear_formatting());
            c.add_separator();
            act(c, "view-list-bullet-symbolic", _("Bulleted List"), "Ctrl+.", () => ed().toggle_list(BlockKind.BULLET));
            act(c, "notes-list-numbered-symbolic", _("Numbered List"), "Ctrl+/", () => ed().toggle_list(BlockKind.NUMBERED));
            act(c, "checkbox-checked-symbolic", _("To Do"), "Ctrl+1", () => ed().toggle_list(BlockKind.CHECK));
            act(c, "notes-outdent-symbolic", _("Decrease Indent"), "Shift+Tab", () => ed().change_indent(-1));
            act(c, "notes-indent-symbolic", _("Increase Indent"), "Tab", () => ed().change_indent(1));
            c.add_separator();
            menu(c, "notes-tag-symbolic", _("Tag"), _("Tag the paragraph"), true, (m) => {
                var current = ed() != null ? ed().current_tags() : new Gee.ArrayList<string>();
                foreach (var t in TagCatalog.get_default().all()) {
                    string id = t.id;
                    string label = t.label + (t.shortcut != "" ? "   Ctrl+%s".printf(t.shortcut) : "");
                    if (current.contains(id)) label = _("Remove %s").printf(t.label);
                    m.add_item(label, t.icon, () => ed().toggle_tag(id));
                }
                m.add_separator();
                m.add_item(_("New Tag…"), "list-add-symbolic", () => new_custom_tag());
                m.add_item(_("Remove All Tags (Ctrl+0)"), "edit-clear-symbolic", () => ed().clear_tags());
                m.add_item(_("Find Tags…"), "system-search-symbolic", () => tag_summary_requested());
            });
            act(c, "insert-link-symbolic", _("Add Link"), "Ctrl+K", () => ed().request_link());
            var link = c.add_button("notes-link-page-symbolic", _("Link to a Page"), _("Link to a Page, Section or Paragraph ([[)"));
            link.activated.connect(() => page_link_requested());
            act(c, "notes-task-symbolic", _("Add to Tasks"), null, () => page.add_task());
        }

        private delegate void ColorChosen(string c);

        private void choose_color(owned ColorChosen cb) {
            var d = new ColorDialog();
            d.with_alpha = false;
            d.choose_rgba.begin(get_root() as Gtk.Window, null, null, (o, r) => {
                try {
                    var c = d.choose_rgba.end(r);
                    cb("#%02x%02x%02x".printf((int) (c.red * 255), (int) (c.green * 255), (int) (c.blue * 255)));
                } catch (Error e) {
                }
            });
        }

        private void choose_font() {
            var d = new FontDialog();
            d.choose_family.begin(get_root() as Gtk.Window, null, null, (o, r) => {
                try {
                    var fam = d.choose_family.end(r);
                    if (fam != null && ed() != null) ed().set_font(fam.get_name());
                } catch (Error e) {
                }
            });
        }

        private void new_custom_tag() {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new Singularity.Widgets.ConfirmDialog(app, _("New Tag"), "notes-tag",
                _("Give the tag a name. It is available in every page."), _("Create"), Singularity.Widgets.ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = get_root() as Gtk.Window;
            var entry = new Entry();
            entry.placeholder_text = _("Tag Name");
            dialog.custom_area.append(entry);
            entry.activate.connect(() => dialog.response(Singularity.Widgets.ConfirmDialog.Response.PRIMARY));
            dialog.response.connect((r) => {
                if (r == Singularity.Widgets.ConfirmDialog.Response.PRIMARY && entry.text.strip() != "" && ed() != null) {
                    ed().toggle_tag(TagCatalog.get_default().add_custom(entry.text.strip()));
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        public const string[] TEXT_COLORS = { "#000000", "#5e5c64", "#e01b24", "#ff7800", "#e5a50a", "#2ec27e", "#1c71d8", "#9141ac", "#986a44" };
        public const string[] HIGHLIGHTS = { "yellow", "#8ff0a4", "#99c1f1", "#f66151", "#ffbe6f", "#dc8add", "#deddda" };

        private static string color_name(string c) {
            switch (c) {
                case "#000000": return _("Black");
                case "#5e5c64": return _("Grey");
                case "#e01b24": return _("Red");
                case "#ff7800": return _("Orange");
                case "#e5a50a": return _("Gold");
                case "#2ec27e": return _("Green");
                case "#1c71d8": return _("Blue");
                case "#9141ac": return _("Purple");
                case "#986a44": return _("Brown");
                case "yellow": return _("Yellow");
                case "#8ff0a4": return _("Green");
                case "#99c1f1": return _("Blue");
                case "#f66151": return _("Red");
                case "#ffbe6f": return _("Orange");
                case "#dc8add": return _("Purple");
                case "#deddda": return _("Grey");
                default: return c;
            }
        }

        private Widget swatch_row(string label, string color, owned Act cb) {
            var btn = new Button();
            btn.add_css_class("flat");
            btn.add_css_class("menu-row");
            var box = new Box(Orientation.HORIZONTAL, 10);
            var sw = new DrawingArea();
            sw.set_size_request(16, 16);
            sw.valign = Align.CENTER;
            string cc = color;
            sw.set_draw_func((a, cr, w, h) => {
                var c = Gdk.RGBA();
                c.parse(cc);
                cr.arc(w / 2.0, h / 2.0, 7, 0, 2 * Math.PI);
                cr.set_source_rgba(c.red, c.green, c.blue, 1);
                cr.fill_preserve();
                cr.set_source_rgba(0, 0, 0, 0.25);
                cr.set_line_width(1);
                cr.stroke();
            });
            box.append(sw);
            box.append(new Label(label));
            btn.child = box;
            btn.clicked.connect(() => cb());
            return btn;
        }

        private void build_insert(Singularity.Widgets.RibbonContext c) {
            menu(c, "notes-table-symbolic", _("Table"), _("Insert Table"), true, (m) => {
                int[,] sizes = { { 2, 2 }, { 2, 3 }, { 3, 3 }, { 3, 4 }, { 4, 4 }, { 5, 3 }, { 6, 4 } };
                for (int i = 0; i < sizes.length[0]; i++) {
                    int r = sizes[i, 0];
                    int col = sizes[i, 1];
                    m.add_item(_("%d × %d").printf(col, r), null, () => page.insert_table(r, col));
                }
            });
            labeled_button(c, "insert-image-symbolic", _("Picture"), _("Insert a picture"), () => page.insert_picture());
            labeled_button(c, "mail-attachment-symbolic", _("File"), _("Attach a file"), () => page.insert_attachment());
            labeled_button(c, "document-print-symbolic", _("Printout"), _("Insert the pages of a PDF"), () => page.insert_printout_file());
            c.add_separator();
            labeled_button(c, "notes-pen-symbolic", _("Drawing"), _("Insert a drawing space"), () => page.insert_drawing());
            labeled_button(c, "notes-equation-symbolic", _("Equation"), _("Write an equation with Formula"), () => page.insert_equation());
            labeled_button(c, "applications-science-symbolic", _("Math"), _("Math Assistant: solve and graph"), () => page.open_math_assistant());
            c.add_separator();
            record_audio = labeled_button(c, "audio-input-microphone-symbolic", _("Audio"), _("Record audio linked to your notes"), () => {
                if (page.recording) page.stop_recording();
                else page.start_recording(false);
            });
            record_video = labeled_button(c, "camera-web-symbolic", _("Video"), _("Record video linked to your notes"), () => {
                if (page.recording) page.stop_recording();
                else page.start_recording(true);
            });
            c.add_separator();
            act(c, "notes-rule-symbolic", _("Horizontal Line"), null, () => page.insert_rule());
            menu(c, "x-office-calendar-symbolic", _("Date and Time"), null, false, (m) => {
                m.add_item(_("Date"), null, () => page.insert_date_time(false));
                m.add_item(_("Date and Time"), null, () => page.insert_date_time(true));
            });
        }

        private void tool_toggle(Singularity.Widgets.RibbonContext c, InkTool tool, string icon, string label) {
            var t = c.add_toggle(icon, label);
            t.toggled.connect((active) => {
                if (syncing) return;
                if (active) InkTools.get_default().tool = tool;
                else if (InkTools.get_default().tool == tool) InkTools.get_default().tool = InkTool.NONE;
            });
            tool_buttons[tool] = t;
        }

        private void build_draw(Singularity.Widgets.RibbonContext c) {
            tool_toggle(c, InkTool.NONE, "insert-text-symbolic", _("Type"));
            tool_toggle(c, InkTool.PEN, "notes-pen-symbolic", _("Pen"));
            tool_toggle(c, InkTool.HIGHLIGHTER, "notes-marker-symbolic", _("Highlighter"));
            tool_toggle(c, InkTool.ERASER, "notes-eraser-symbolic", _("Eraser"));
            tool_toggle(c, InkTool.LASSO, "notes-lasso-symbolic", _("Lasso Select"));
            var ruler = c.add_toggle("notes-ruler-symbolic", _("Ruler"), _("Ruler: draw straight lines along its edge; drag it to move, right-click to rotate"));
            InkTools.get_default().bind_property("ruler", ruler.button, "active", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);
            c.add_separator();
            tool_toggle(c, InkTool.LINE, "notes-line-symbolic", _("Line"));
            tool_toggle(c, InkTool.ARROW, "notes-arrow-symbolic", _("Arrow"));
            tool_toggle(c, InkTool.RECTANGLE, "notes-rect-symbolic", _("Rectangle"));
            tool_toggle(c, InkTool.ELLIPSE, "notes-ellipse-symbolic", _("Ellipse"));
            tool_toggle(c, InkTool.TRIANGLE, "notes-triangle-symbolic", _("Triangle"));
            c.add_separator();
            foreach (string col in InkPalette.COLORS) {
                if (col == "#ffffff") continue;
                string cc = col;
                var sw = new Button();
                sw.add_css_class("flat");
                sw.add_css_class("notes-ink-swatch");
                sw.focus_on_click = false;
                sw.tooltip_text = InkPalette.name_of(col);
                var da = new DrawingArea();
                da.set_size_request(16, 16);
                da.set_draw_func((a, cr, w, h) => {
                    var rgba = Gdk.RGBA();
                    rgba.parse(cc);
                    cr.arc(w / 2.0, h / 2.0, 7, 0, 2 * Math.PI);
                    cr.set_source_rgba(rgba.red, rgba.green, rgba.blue, 1);
                    cr.fill();
                    if (InkTools.get_default().color == cc || InkTools.get_default().highlighter_color == cc) {
                        cr.arc(w / 2.0, h / 2.0, 7.5, 0, 2 * Math.PI);
                        cr.set_source_rgba(0.5, 0.5, 0.5, 1);
                        cr.set_line_width(1.5);
                        cr.stroke();
                    }
                });
                InkTools.get_default().notify.connect(() => da.queue_draw());
                sw.child = da;
                sw.clicked.connect(() => {
                    var tools = InkTools.get_default();
                    if (tools.tool == InkTool.HIGHLIGHTER) tools.highlighter_color = cc;
                    else {
                        tools.color = cc;
                        if (!tools.drawing) tools.tool = InkTool.PEN;
                    }
                });
                c.add_widget(sw, InkPalette.name_of(col));
            }
            menu(c, "notes-width-symbolic", _("Thickness"), null, false, (m) => {
                double[] widths = { 1.5, 3, 5, 8, 12 };
                string[] names = { _("Extra Fine"), _("Fine"), _("Medium"), _("Thick"), _("Extra Thick") };
                for (int i = 0; i < widths.length; i++) {
                    double w = widths[i];
                    m.add_item(names[i], null, () => {
                        var tools = InkTools.get_default();
                        if (tools.tool == InkTool.HIGHLIGHTER) tools.highlighter_width = w * 4;
                        else tools.width = w;
                    });
                }
            });
            c.add_separator();
            labeled_button(c, "notes-pen-symbolic", _("Drawing Space"), _("Insert a drawing space in the page"), () => page.insert_drawing());
        }

        private void build_view(Singularity.Widgets.RibbonContext c) {
            canvas_toggle = c.add_toggle("notes-canvas-symbolic", _("Free-Form Page"), _("Place note containers anywhere on the page instead of one flowing column"));
            canvas_toggle.label_in_compact = true;
            canvas_toggle.toggled.connect((active) => {
                if (syncing) return;
                page.set_layout(active);
            });
            labeled_button(c, "list-add-symbolic", _("Container"), _("Add a note container to the free-form page"), () => page.add_canvas_container());
            c.add_separator();
            menu(c, "color-select-symbolic", _("Page Color"), null, true, (m) => {
                m.add_item(_("None"), null, () => page.set_background(""));
                string[] ids = { "yellow", "green", "blue", "pink", "purple", "orange", "grey" };
                string[] names = { _("Yellow"), _("Green"), _("Blue"), _("Pink"), _("Purple"), _("Orange"), _("Grey") };
                for (int i = 0; i < ids.length; i++) {
                    string id = ids[i];
                    var col = PageBackground.color_of(id);
                    m.add_widget(swatch_row(names[i], col.to_string(), () => page.set_background(id)));
                }
            });
            menu(c, "notes-rule-lines-symbolic", _("Rule Lines"), null, true, (m) => {
                m.add_item(_("None"), null, () => page.set_rule(""));
                m.add_item(_("Ruled Lines"), null, () => page.set_rule("lines"));
                m.add_item(_("Grid"), null, () => page.set_rule("grid"));
            });
            c.add_separator();
            labeled_button(c, "system-search-symbolic", _("Find"), _("Find in Page (Ctrl+F)"), () => page.open_find(false));
            labeled_button(c, "document-open-recent-symbolic", _("Versions"), _("Page Versions"), () => versions_requested());
            labeled_button(c, "audio-input-microphone-symbolic", _("Transcribe"), _("Turn the recordings of this page into text"), () => page.transcribe_all());
            labeled_button(c, "media-playback-start-symbolic", _("Play Here"), _("Play the recording from the moment this line was written"), () => page.play_from_current_line());
            c.add_separator();
            labeled_button(c, "notes-reader-symbolic", _("Immersive Reader"), _("Read the page in a large, calm view and have it read aloud"), () => page.open_reader());
            labeled_button(c, "notes-translate-symbolic", _("Translate"), _("Translate the selection or the page"), () => page.translate());
        }

        public void sync() {
            var e = ed();
            syncing = true;
            if (e != null) {
                foreach (var entry in toggles.entries) entry.value.active = e.has_typing(entry.key);
                string st = e.current_block_style();
                if (st == "body") style_selector.text = _("Body");
                else if (st == "quote") style_selector.text = _("Quote");
                else if (st == "code") style_selector.text = _("Code");
                else if (st == "h1") style_selector.text = _("Title");
                else style_selector.text = _("Heading %d").printf(int.parse(st.substring(1)) - 1);
                string f = e.typing_value("font");
                font_selector.text = f != "" ? f : _("Font");
                string sz = e.typing_value("size");
                size_selector.text = sz != "" ? sz : "11";
            }
            canvas_toggle.active = page.is_canvas;
            record_audio.label = page.recording ? _("Stop") : _("Audio");
            record_video.label = page.recording ? _("Stop") : _("Video");
            syncing = false;
            sync_tools();
        }

        private void sync_tools() {
            syncing = true;
            var t = InkTools.get_default().tool;
            foreach (var e in tool_buttons.entries) e.value.active = e.key == t;
            syncing = false;
        }
    }
}
