namespace Singularity.Apps.Notes {

    public class ExportPage : Object {
        public string id { get; construct; }
        public string title { get; construct; }
        public int64 created { get; construct; }
        public string body { get; construct; }

        public ExportPage(string id, string title, int64 created, string body) {
            Object(id: id, title: title, created: created, body: body);
        }

        public PageDoc doc() {
            return PageDoc.parse(body);
        }

        public Gee.List<Block> blocks() {
            var d = doc();
            var list = new Gee.ArrayList<Block>();
            list.add_all(RichText.parse(d.flow_markdown()));
            if (d.meta.ink != "") list.add(RichText.image_block(_("Drawing"), d.meta.ink, 0));
            return list;
        }

        public string display_title() {
            return title != "" ? title : _("Untitled Page");
        }
    }

    public class Inline {
        public static string pango(Gee.List<Span> spans, string? link_color = "#1c71d8") {
            var sb = new StringBuilder();
            foreach (var s in spans) {
                if (s.text == "") continue;
                string t = Markup.escape_text(s.text);
                string attrs = "";
                if (s.color != "") attrs += " foreground=\"%s\"".printf(s.color);
                if (s.highlight != "") attrs += " background=\"%s\"".printf(s.highlight == "yellow" ? "#ffe066" : s.highlight);
                if (s.font != "") attrs += " font_family=\"%s\"".printf(Markup.escape_text(s.font));
                if (s.size > 0) attrs += " size=\"%dpt\"".printf(s.size);
                if (s.href != "") attrs += " foreground=\"%s\" underline=\"single\"".printf(link_color);
                if (s.underline && s.href == "") attrs += " underline=\"single\"";
                if (s.strike) attrs += " strikethrough=\"true\"";
                if (s.bold) attrs += " weight=\"bold\"";
                if (s.italic) attrs += " style=\"italic\"";
                if (s.code) attrs += " font_family=\"Monospace\" background=\"#eeeeee\"";
                if (attrs != "") sb.append("<span%s>%s</span>".printf(attrs, t));
                else sb.append(t);
            }
            return sb.str;
        }

        public static string tag_labels(string[] tags) {
            var sb = new StringBuilder();
            foreach (string t in tags) sb.append("[%s] ".printf(TagCatalog.get_default().lookup(t).label));
            return sb.str;
        }
    }

    public class NoteRenderer : Object {
        private enum UnitKind {
            LINE,
            IMAGE,
            INK,
            ROW,
            RULE,
            BREAK,
            SPACE
        }

        private class Unit {
            public UnitKind kind;
            public double height;
            public double indent;
            public Pango.Layout? layout;
            public int line_index;
            public double line_y;
            public Pango.Layout? prefix;
            public string prefix_kind = "";
            public bool prefix_checked;
            public string image = "";
            public double image_w;
            public double image_h;
            public InkDoc? ink;
            public Gee.ArrayList<Pango.Layout>? cells;
            public double[]? col_x;
            public double[]? col_w;
            public Gee.ArrayList<string>? shades;
            public bool header;
            public bool quote;
            public bool code;
        }

        public string notes_dir { get; construct; }
        public double font_size { get; set; default = 11; }
        public Gee.ArrayList<ExportPage> pages = new Gee.ArrayList<ExportPage>();

        private Gee.ArrayList<Unit> units = new Gee.ArrayList<Unit>();
        private Gee.ArrayList<int> page_starts = new Gee.ArrayList<int>();
        private Gee.ArrayList<double?> unit_y = new Gee.ArrayList<double?>();
        private Pango.Context ctx;
        private double content_w;
        private double content_h;
        private double margin_left;
        private double margin_top;

        public NoteRenderer(string notes_dir) {
            Object(notes_dir: notes_dir);
            ctx = Pango.CairoFontMap.get_default().create_context();
            Pango.cairo_context_set_resolution(ctx, 72);
        }

        private Pango.Layout layout(string markup, double width, string font) {
            var l = new Pango.Layout(ctx);
            l.set_font_description(Pango.FontDescription.from_string(font));
            l.set_width((int) (width * Pango.SCALE));
            l.set_wrap(Pango.WrapMode.WORD_CHAR);
            l.set_markup(markup, -1);
            return l;
        }

        private string base_font(double scale = 1.0, string extra = "") {
            return "Sans %s%s".printf(extra, Stroke.num(font_size * scale));
        }

        private void add_text(string markup, double indent, string font, string prefix_kind = "", string prefix_text = "", bool checked = false, bool quote = false, bool code = false) {
            double width = content_w - indent - (prefix_kind != "" ? 18 : 0) - (quote ? 12 : 0);
            var l = layout(markup != "" ? markup : " ", width, font);
            Pango.Layout? prefix = null;
            if (prefix_kind == "text") prefix = layout(Markup.escape_text(prefix_text), 40, font);
            var iter = l.get_iter();
            int index = 0;
            do {
                Pango.Rectangle ink_r, log_r;
                iter.get_line_extents(out ink_r, out log_r);
                var u = new Unit();
                u.kind = UnitKind.LINE;
                u.layout = l;
                u.line_index = index;
                u.line_y = (double) log_r.y / Pango.SCALE;
                u.height = (double) log_r.height / Pango.SCALE;
                u.indent = indent + (prefix_kind != "" ? 18 : 0) + (quote ? 12 : 0);
                u.quote = quote;
                u.code = code;
                if (index == 0) {
                    u.prefix = prefix;
                    u.prefix_kind = prefix_kind;
                    u.prefix_checked = checked;
                }
                units.add(u);
                index++;
            } while (iter.next_line());
        }

        private void space(double h) {
            var u = new Unit();
            u.kind = UnitKind.SPACE;
            u.height = h;
            units.add(u);
        }

        private string resolve(string path) {
            if (Path.is_absolute(path)) return path;
            return Path.build_filename(notes_dir, Uri.unescape_string(path) ?? path);
        }

        private void add_image(Block b) {
            string file = resolve(b.image);
            if (Path.get_basename(file).has_prefix("ink-") && file.has_suffix(".svg")) {
                var doc = InkDoc.load(file);
                int w, h;
                doc.extent(out w, out h);
                if (w <= 0 || h <= 0) return;
                double scale = double.min(1.0, content_w / (w + 8));
                var u = new Unit();
                u.kind = UnitKind.INK;
                u.ink = doc;
                u.image_w = w * scale;
                u.image_h = h * scale;
                u.height = u.image_h + 6;
                units.add(u);
                return;
            }
            int iw = 0, ih = 0;
            var fmt = Gdk.Pixbuf.get_file_info(file, out iw, out ih);
            if (fmt == null || iw <= 0) {
                add_text("<i>%s</i>".printf(Markup.escape_text(b.alt != "" ? b.alt : Path.get_basename(file))), 0, base_font());
                return;
            }
            double w = b.width > 0 ? b.width * 0.75 : iw * 0.75;
            if (b.kind == BlockKind.EQUATION) w = iw * 0.375;
            w = double.min(w, content_w);
            double h = ih * w / iw;
            if (h > content_h * 0.9) {
                h = content_h * 0.9;
                w = iw * h / ih;
            }
            var u = new Unit();
            u.kind = UnitKind.IMAGE;
            u.image = file;
            u.image_w = w;
            u.image_h = h;
            u.height = h + 6;
            units.add(u);
        }

        private void add_table(TableData t) {
            t.normalize();
            int cols = t.columns;
            double cw = content_w / cols;
            for (int r = 0; r < t.rows.size; r++) {
                var u = new Unit();
                u.kind = UnitKind.ROW;
                u.cells = new Gee.ArrayList<Pango.Layout>();
                u.col_x = new double[cols];
                u.col_w = new double[cols];
                u.shades = new Gee.ArrayList<string>();
                u.header = r == 0;
                double h = 0;
                for (int c = 0; c < cols; c++) {
                    u.col_x[c] = c * cw;
                    u.col_w[c] = cw;
                    string text = Markup.escape_text(t.cell(r, c));
                    if (r == 0) text = "<b>%s</b>".printf(text);
                    var l = layout(text, cw - 8, base_font(0.95));
                    string a = t.aligns[c];
                    l.set_alignment(a == "center" ? Pango.Alignment.CENTER : a == "right" ? Pango.Alignment.RIGHT : Pango.Alignment.LEFT);
                    int lw, lh;
                    l.get_pixel_size(out lw, out lh);
                    h = double.max(h, lh + 8);
                    u.cells.add(l);
                    u.shades.add(t.shade(r, c));
                }
                u.height = h;
                units.add(u);
            }
            space(6);
        }

        private void build(double width, double height) {
            units.clear();
            content_w = width;
            content_h = height;
            bool first = true;
            foreach (var p in pages) {
                if (!first) {
                    var br = new Unit();
                    br.kind = UnitKind.BREAK;
                    br.height = 0;
                    units.add(br);
                }
                first = false;
                add_text("<b>%s</b>".printf(Markup.escape_text(p.display_title())), 0, base_font(1.9));
                if (p.created > 0) add_text("<span foreground=\"#77767b\">%s</span>".printf(Markup.escape_text(new DateTime.from_unix_local(p.created).format("%A %e %B %Y, %H:%M"))), 0, base_font(0.85));
                var rule = new Unit();
                rule.kind = UnitKind.RULE;
                rule.height = 14;
                units.add(rule);
                var blocks = p.blocks();
                int[] numbers = RichText.numbering(blocks);
                for (int i = 0; i < blocks.size; i++) {
                    var b = blocks[i];
                    double indent = b.indent * 20;
                    string tags = b.tags.length > 0 ? "<span foreground=\"#9141ac\" weight=\"bold\">%s</span>".printf(Markup.escape_text(Inline.tag_labels(b.tags))) : "";
                    switch (b.kind) {
                        case BlockKind.IMAGE:
                        case BlockKind.INK:
                        case BlockKind.EQUATION:
                            add_image(b);
                            break;
                        case BlockKind.TABLE:
                            add_table(b.table);
                            break;
                        case BlockKind.RULE:
                            var u = new Unit();
                            u.kind = UnitKind.RULE;
                            u.height = 14;
                            units.add(u);
                            break;
                        case BlockKind.FILE:
                            add_text("<span foreground=\"#1c71d8\">%s</span>".printf(Markup.escape_text(_("Attachment: %s").printf(b.alt))), 0, base_font());
                            break;
                        case BlockKind.RECORDING:
                            add_text("<span foreground=\"#1c71d8\">%s</span>".printf(Markup.escape_text(b.alt)), 0, base_font());
                            var info = RecordingInfo.load(resolve(b.image));
                            if (info.transcript != null && info.transcript != "") add_text("<i>%s</i>".printf(Markup.escape_text(info.transcript)), 12, base_font(0.95));
                            break;
                        case BlockKind.CODE:
                            add_text(Markup.escape_text(b.raw), 8, "Monospace %s".printf(Stroke.num(font_size * 0.9)), "", "", false, false, true);
                            break;
                        case BlockKind.QUOTE:
                            add_text(tags + Inline.pango(b.spans), 0, base_font(1.0, "Italic "), "", "", false, true);
                            break;
                        case BlockKind.CHECK:
                            add_text(tags + (b.checked ? "<s>%s</s>".printf(Inline.pango(b.spans)) : Inline.pango(b.spans)), indent, base_font(), "check", "", b.checked);
                            break;
                        case BlockKind.BULLET:
                            add_text(tags + Inline.pango(b.spans), indent, base_font(), "text", "•");
                            break;
                        case BlockKind.NUMBERED:
                            add_text(tags + Inline.pango(b.spans), indent, base_font(), "text", RichText.number_label(numbers[i], b.indent));
                            break;
                        default:
                            int level = b.kind.heading_level();
                            if (level > 0) {
                                double[] scales = { 1, 1.6, 1.4, 1.2, 1.1, 1.0, 1.0 };
                                space(level <= 2 ? 6 : 3);
                                add_text("<b>%s</b>".printf(tags + Inline.pango(b.spans)), 0, base_font(scales[level]));
                            } else {
                                add_text(tags + Inline.pango(b.spans), indent, base_font());
                            }
                            break;
                    }
                    space(3);
                }
            }
        }

        public int paginate(double page_w, double page_h, double ml, double mt, double mr, double mb) {
            margin_left = ml;
            margin_top = mt;
            build(page_w - ml - mr, page_h - mt - mb);
            page_starts.clear();
            unit_y.clear();
            double y = 0;
            page_starts.add(0);
            for (int i = 0; i < units.size; i++) {
                var u = units[i];
                if (u.kind == UnitKind.BREAK) {
                    if (y > 0) {
                        page_starts.add(i);
                        y = 0;
                    }
                    unit_y.add(0);
                    continue;
                }
                if (y > 0 && y + u.height > content_h) {
                    page_starts.add(i);
                    y = 0;
                    if (u.kind == UnitKind.SPACE) {
                        unit_y.add(0);
                        continue;
                    }
                }
                unit_y.add(y);
                y += u.height;
            }
            return page_starts.size;
        }

        public void render_page(Cairo.Context cr, int index) {
            if (index < 0 || index >= page_starts.size) return;
            int start = page_starts[index];
            int end = index + 1 < page_starts.size ? page_starts[index + 1] : units.size;
            cr.save();
            cr.translate(margin_left, margin_top);
            for (int i = start; i < end; i++) draw_unit(cr, units[i], unit_y[i]);
            cr.restore();
        }

        private void draw_unit(Cairo.Context cr, Unit u, double y) {
            switch (u.kind) {
                case UnitKind.LINE:
                    var line = u.layout.get_line_readonly(u.line_index);
                    Pango.Rectangle ink_r, log_r;
                    line.get_extents(out ink_r, out log_r);
                    double baseline = -(double) log_r.y / Pango.SCALE;
                    if (u.code) {
                        cr.set_source_rgb(0.95, 0.95, 0.95);
                        cr.rectangle(u.indent - 4, y, content_w - u.indent + 4, u.height);
                        cr.fill();
                    }
                    if (u.quote) {
                        cr.set_source_rgb(0.7, 0.7, 0.72);
                        cr.rectangle(u.indent - 10, y, 3, u.height);
                        cr.fill();
                    }
                    cr.set_source_rgb(0.1, 0.1, 0.12);
                    if (u.prefix_kind == "text" && u.prefix != null) {
                        cr.move_to(u.indent - 16, y);
                        Pango.cairo_show_layout(cr, u.prefix);
                    } else if (u.prefix_kind == "check") {
                        double s = 9;
                        double bx = u.indent - 16;
                        double by = y + (u.height - s) / 2;
                        cr.set_line_width(1);
                        cr.rectangle(bx, by, s, s);
                        cr.stroke();
                        if (u.prefix_checked) {
                            cr.move_to(bx + 2, by + 4.5);
                            cr.line_to(bx + 4, by + 7);
                            cr.line_to(bx + 7.5, by + 2);
                            cr.stroke();
                        }
                    }
                    cr.set_source_rgb(0.1, 0.1, 0.12);
                    cr.move_to(u.indent, y + baseline);
                    Pango.cairo_show_layout_line(cr, line);
                    break;
                case UnitKind.IMAGE:
                    try {
                        var pix = new Gdk.Pixbuf.from_file_at_scale(u.image, (int) (u.image_w * 3), (int) (u.image_h * 3), true);
                        cr.save();
                        cr.translate(0, y + 3);
                        cr.scale(u.image_w / pix.width, u.image_h / pix.height);
                        Gdk.cairo_set_source_pixbuf(cr, pix, 0, 0);
                        cr.paint();
                        cr.restore();
                    } catch (Error e) {
                    }
                    break;
                case UnitKind.INK:
                    int w, h;
                    u.ink.extent(out w, out h);
                    cr.save();
                    cr.translate(0, y + 3);
                    double sc = w > 0 ? u.image_w / w : 1;
                    cr.scale(sc, sc);
                    foreach (var s in u.ink.strokes) s.draw(cr);
                    cr.restore();
                    break;
                case UnitKind.ROW:
                    for (int c = 0; c < u.cells.size; c++) {
                        string shade = u.shades[c];
                        if (shade != "" || u.header) {
                            var col = Gdk.RGBA();
                            col.parse(shade != "" ? shade : "#f1f1f3");
                            cr.set_source_rgb(col.red, col.green, col.blue);
                            cr.rectangle(u.col_x[c], y, u.col_w[c], u.height);
                            cr.fill();
                        }
                        cr.set_source_rgb(0.7, 0.7, 0.72);
                        cr.set_line_width(0.6);
                        cr.rectangle(u.col_x[c], y, u.col_w[c], u.height);
                        cr.stroke();
                        cr.set_source_rgb(0.1, 0.1, 0.12);
                        cr.move_to(u.col_x[c] + 4, y + 4);
                        Pango.cairo_show_layout(cr, u.cells[c]);
                    }
                    break;
                case UnitKind.RULE:
                    cr.set_source_rgb(0.8, 0.8, 0.82);
                    cr.rectangle(0, y + u.height / 2, content_w, 0.8);
                    cr.fill();
                    break;
                default:
                    break;
            }
        }

        public Gee.List<string> write_png(string path, double scale = 2.0, double page_w = 595.28, double page_h = 841.89) throws Error {
            int n = paginate(page_w, page_h, 40, 40, 40, 40);
            var files = new Gee.ArrayList<string>();
            string stem = path.has_suffix(".png") ? path.substring(0, path.length - 4) : path;
            for (int i = 0; i < n; i++) {
                var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, (int) (page_w * scale), (int) (page_h * scale));
                var cr = new Cairo.Context(surface);
                cr.set_source_rgb(1, 1, 1);
                cr.paint();
                cr.scale(scale, scale);
                render_page(cr, i);
                string target = n == 1 ? stem + ".png" : "%s-%d.png".printf(stem, i + 1);
                if (surface.write_to_png(target) != Cairo.Status.SUCCESS) throw new IOError.FAILED(_("The picture could not be written"));
                files.add(target);
            }
            return files;
        }

        public void write_pdf(string path, double page_w = 595.28, double page_h = 841.89) throws Error {
            int n = paginate(page_w, page_h, 56, 56, 56, 56);
            var surface = new Cairo.PdfSurface(path, page_w, page_h);
            var cr = new Cairo.Context(surface);
            for (int i = 0; i < n; i++) {
                render_page(cr, i);
                cr.show_page();
            }
            surface.finish();
            if (surface.status() != Cairo.Status.SUCCESS) throw new IOError.FAILED(surface.status().to_string());
        }
    }
}
