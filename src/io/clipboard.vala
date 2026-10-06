namespace Singularity.Apps.Notes {

    public class NoteClip : Object {
        public const string MIME = "application/x-singularity-notes";
        public const int MAX_SIDE = 1600;
        public const int MAX_BYTES = 1536 * 1024;
        public const int MAX_DISPLAY = 680;
        public const string UNCHECKED = "☐";
        public const string CHECKED = "☑";
        public const string CHECK_STYLE = "<style>input[type=checkbox] + .sx-check-fallback { display: none }</style>";

        public string notes_dir { get; construct; }
        public string note_id { get; construct; }
        public bool inline { get; set; default = false; }
        public Gee.ArrayList<Block> blocks = new Gee.ArrayList<Block>();

        public NoteClip(string notes_dir, string note_id) {
            Object(notes_dir: notes_dir, note_id: note_id);
        }

        public static NoteClip from_markdown(string notes_dir, string note_id, string markdown) {
            var c = new NoteClip(notes_dir, note_id);
            c.blocks.add_all(RichText.parse(markdown));
            return c;
        }

        public string resolve(string p) {
            if (Path.is_absolute(p)) return p;
            if (p.has_prefix("file://")) return File.new_for_uri(p).get_path() ?? p;
            return Path.build_filename(notes_dir, Uri.unescape_string(p) ?? p);
        }

        private static string esc(string s) {
            return Markup.escape_text(s);
        }

        private static string attr(string s) {
            return Markup.escape_text(s).replace("\"", "&quot;");
        }

        public string native() {
            var sb = new StringBuilder("<!-- singularity-notes-clip");
            sb.append(" dir=" + Uri.escape_string(notes_dir, "/", false));
            sb.append(" note=" + Uri.escape_string(note_id, null, false));
            if (inline) sb.append(" inline=1");
            sb.append(" -->\n");
            sb.append(RichText.render(blocks));
            return sb.str;
        }

        public static NoteClip? parse_native(string text) {
            if (!text.has_prefix("<!-- singularity-notes-clip")) return null;
            int nl = text.index_of("\n");
            string head = nl >= 0 ? text.substring(0, nl) : text;
            string body = nl >= 0 ? text.substring(nl + 1) : "";
            string dir = "", note = "";
            bool is_inline = false;
            foreach (string part in head.replace("-->", "").split(" ")) {
                int eq = part.index_of("=");
                if (eq <= 0) continue;
                string v = Uri.unescape_string(part.substring(eq + 1)) ?? "";
                switch (part.substring(0, eq)) {
                    case "dir": dir = v; break;
                    case "note": note = v; break;
                    case "inline": is_inline = v == "1"; break;
                }
            }
            var c = from_markdown(dir, note, body);
            c.inline = is_inline;
            return c;
        }

        public string plain() {
            var sb = new StringBuilder();
            int[] numbers = RichText.numbering(blocks);
            for (int i = 0; i < blocks.size; i++) {
                var b = blocks[i];
                if (i > 0) sb.append("\n");
                if (inline) {
                    sb.append(b.plain_text());
                    continue;
                }
                string pad = string.nfill(b.indent * 4, ' ');
                string tags = b.tags.length > 0 ? Inline.tag_labels(b.tags) : "";
                switch (b.kind) {
                    case BlockKind.CHECK:
                        sb.append(pad + (b.checked ? "- [x] " : "- [ ] ") + tags + b.plain_text());
                        break;
                    case BlockKind.BULLET:
                        sb.append(pad + "- " + tags + b.plain_text());
                        break;
                    case BlockKind.NUMBERED:
                        sb.append(pad + RichText.number_label(numbers[i], b.indent) + " " + tags + b.plain_text());
                        break;
                    case BlockKind.QUOTE:
                        sb.append("> " + tags + b.plain_text());
                        break;
                    case BlockKind.CODE:
                        sb.append(b.raw);
                        break;
                    case BlockKind.IMAGE:
                    case BlockKind.INK:
                    case BlockKind.EQUATION:
                        sb.append("![%s]".printf(b.alt != "" ? b.alt : _("Picture")));
                        break;
                    case BlockKind.FILE:
                    case BlockKind.RECORDING:
                        sb.append("[%s]".printf(b.alt != "" ? b.alt : Path.get_basename(b.image)));
                        break;
                    case BlockKind.TABLE:
                        var rows = new StringBuilder();
                        foreach (string row in RichText.render_table(b.table).split("\n")) {
                            if (row.has_prefix("<!--")) continue;
                            if (rows.len > 0) rows.append("\n");
                            rows.append(row);
                        }
                        sb.append(rows.str);
                        break;
                    case BlockKind.RULE:
                        sb.append("---");
                        break;
                    default:
                        int level = b.kind.heading_level();
                        if (level > 0) sb.append(string.nfill(level, '#') + " ");
                        else sb.append(pad);
                        sb.append(tags + b.plain_text());
                        break;
                }
            }
            return sb.str;
        }

        private string link_target(string href) {
            if (href.has_prefix("note:") || href.has_prefix("section:")) return "";
            if (href.has_prefix("attachments/")) {
                try {
                    return Filename.to_uri(resolve(href));
                } catch (ConvertError e) {
                    return "";
                }
            }
            return href;
        }

        private static string highlight_color(string h) {
            return h == "yellow" ? "#ffe066" : h;
        }

        public string inline_html(Gee.List<Span> spans) {
            var sb = new StringBuilder();
            foreach (var s in spans) {
                if (s.text == "") continue;
                string t = esc(s.text);
                if (s.code) t = "<code>%s</code>".printf(t);
                if (s.bold) t = "<b>%s</b>".printf(t);
                if (s.italic) t = "<i>%s</i>".printf(t);
                if (s.underline) t = "<u>%s</u>".printf(t);
                if (s.strike) t = "<s>%s</s>".printf(t);
                string style = "";
                if (s.color != "") style += "color:%s;".printf(s.color);
                if (s.highlight != "") style += "background-color:%s;".printf(highlight_color(s.highlight));
                if (s.font != "") style += "font-family:'%s';".printf(s.font.replace("'", ""));
                if (s.size > 0) style += "font-size:%dpt;".printf(s.size);
                if (style != "") t = "<span style=\"%s\">%s</span>".printf(attr(style), t);
                if (s.href != "") {
                    string h = link_target(s.href);
                    if (h != "") t = "<a href=\"%s\">%s</a>".printf(attr(h), t);
                }
                sb.append(t);
            }
            return sb.str;
        }

        private string tag_html(string[] tags) {
            if (tags.length == 0) return "";
            return "<span style=\"color:#9141ac;font-weight:bold\">%s</span>".printf(esc(Inline.tag_labels(tags)));
        }

        private static string list_tag(Block b) {
            return b.kind == BlockKind.NUMBERED ? "ol" : "ul";
        }

        private static string list_style(Block b) {
            if (b.kind == BlockKind.CHECK) return " style=\"list-style-type:none\"";
            if (b.kind == BlockKind.NUMBERED) {
                switch (b.indent % 3) {
                    case 1: return " type=\"a\"";
                    case 2: return " type=\"i\"";
                    default: return "";
                }
            }
            return "";
        }

        private static bool same_list(Block a, Block b) {
            if (list_tag(a) != list_tag(b)) return false;
            return (a.kind == BlockKind.CHECK) == (b.kind == BlockKind.CHECK);
        }

        private string list_item(Block b) {
            string inner = tag_html(b.tags) + inline_html(b.spans);
            if (b.kind != BlockKind.CHECK) return inner;
            return "<input type=\"checkbox\" disabled%s><span class=\"sx-check-fallback\" style=\"display:none\">%s </span>%s".printf(b.checked ? " checked" : "", b.checked ? CHECKED : UNCHECKED, inner);
        }

        private void list_html(StringBuilder sb, ref int i, int level) {
            var head = blocks[i];
            string tag = list_tag(head);
            sb.append("<%s%s>".printf(tag, list_style(head)));
            bool open = false;
            while (i < blocks.size && blocks[i].kind.is_list() && blocks[i].indent >= level) {
                var b = blocks[i];
                if (b.indent > level) {
                    if (!open) {
                        sb.append("<li style=\"list-style-type:none\">");
                        open = true;
                    }
                    list_html(sb, ref i, b.indent);
                    continue;
                }
                if (!same_list(head, b)) break;
                if (open) sb.append("</li>");
                string anchor = b.anchor != "" ? " id=\"%s\"".printf(attr(b.anchor)) : "";
                sb.append("<li%s>%s".printf(anchor, list_item(b)));
                open = true;
                i++;
            }
            if (open) sb.append("</li>");
            sb.append("</%s>\n".printf(tag));
        }

        private string table_html(TableData t) {
            t.normalize();
            var sb = new StringBuilder("<table style=\"border-collapse:collapse\">\n");
            for (int r = 0; r < t.rows.size; r++) {
                sb.append("<tr>");
                for (int c = 0; c < t.columns; c++) {
                    string cell = r == 0 ? "th" : "td";
                    string style = "border:1px solid #c0bfbc;padding:4px 8px;";
                    if (t.shade(r, c) != "") style += "background-color:%s;".printf(t.shade(r, c));
                    if (c < t.aligns.size && t.aligns[c] != "") style += "text-align:%s;".printf(t.aligns[c]);
                    var cb = new Block(BlockKind.PARAGRAPH);
                    RichText.parse_inline(t.cell(r, c), cb);
                    sb.append("<%s style=\"%s\">%s</%s>".printf(cell, style, inline_html(cb.spans).replace("\n", "<br>"), cell));
                }
                sb.append("</tr>\n");
            }
            sb.append("</table>\n");
            return sb.str;
        }

        public string html_fragment() {
            var sb = new StringBuilder();
            if (inline) {
                foreach (var b in blocks) sb.append(inline_html(b.spans));
                return sb.str;
            }
            foreach (var b in blocks) {
                if (b.kind == BlockKind.CHECK) {
                    sb.append(CHECK_STYLE + "\n");
                    break;
                }
            }
            int i = 0;
            while (i < blocks.size) {
                var b = blocks[i];
                string anchor = b.anchor != "" ? " id=\"%s\"".printf(attr(b.anchor)) : "";
                if (b.kind.is_list()) {
                    list_html(sb, ref i, b.indent);
                    continue;
                }
                int level = b.kind.heading_level();
                switch (b.kind) {
                    case BlockKind.CODE:
                        sb.append("<pre><code>");
                        while (i < blocks.size && blocks[i].kind == BlockKind.CODE) {
                            sb.append(esc(blocks[i].raw) + "\n");
                            i++;
                        }
                        sb.append("</code></pre>\n");
                        continue;
                    case BlockKind.QUOTE:
                        sb.append("<blockquote%s>%s%s</blockquote>\n".printf(anchor, tag_html(b.tags), inline_html(b.spans)));
                        break;
                    case BlockKind.RULE:
                        sb.append("<hr>\n");
                        break;
                    case BlockKind.TABLE:
                        if (b.table != null) sb.append(table_html(b.table));
                        break;
                    case BlockKind.IMAGE:
                    case BlockKind.INK:
                    case BlockKind.EQUATION:
                        sb.append("<p%s>%s</p>\n".printf(anchor, image_html(b)));
                        break;
                    case BlockKind.FILE:
                    case BlockKind.RECORDING:
                        sb.append("<p%s>%s</p>\n".printf(anchor, file_html(b)));
                        var info = RecordingInfo.load(resolve(b.image));
                        if (info.transcript != null && info.transcript != "") sb.append("<blockquote>%s</blockquote>\n".printf(esc(info.transcript)));
                        break;
                    default:
                        if (level > 0) {
                            sb.append("<h%d%s>%s%s</h%d>\n".printf(level, anchor, tag_html(b.tags), inline_html(b.spans), level));
                        } else if (b.plain_text() == "" && b.tags.length == 0) {
                            sb.append("<p><br></p>\n");
                        } else {
                            string style = b.indent > 0 ? " style=\"margin-left:%dem\"".printf(b.indent * 2) : "";
                            sb.append("<p%s%s>%s%s</p>\n".printf(anchor, style, tag_html(b.tags), inline_html(b.spans)));
                        }
                        break;
                }
                i++;
            }
            return sb.str;
        }

        public string html() {
            string fragment = html_fragment();
            string style = fragment.has_prefix(CHECK_STYLE) ? CHECK_STYLE : "";
            return "<html><head><meta http-equiv=\"content-type\" content=\"text/html; charset=utf-8\"><meta name=\"generator\" content=\"Singularity Notes\">" + style + "</head><body>\n<!--StartFragment-->" + fragment + "<!--EndFragment-->\n</body></html>\n";
        }

        private string file_html(Block b) {
            string name = b.alt != "" ? b.alt : Path.get_basename(b.image);
            string uri;
            try {
                uri = Filename.to_uri(resolve(b.image));
            } catch (ConvertError e) {
                return esc(name);
            }
            return "<a href=\"%s\">%s</a>".printf(attr(uri), esc(name));
        }

        private string image_html(Block b) {
            int w, h;
            string? mime;
            var data = block_image(b, out w, out h, out mime);
            if (data == null) return "<i>%s</i>".printf(esc("[%s]".printf(b.alt != "" ? b.alt : _("Picture"))));
            int dw = w, dh = h;
            if (b.kind == BlockKind.IMAGE && b.width > 0 && w > 0) {
                dw = b.width;
                dh = (int) Math.round((double) h * b.width / w);
            }
            if (dw > MAX_DISPLAY) {
                dh = (int) Math.round((double) dh * MAX_DISPLAY / dw);
                dw = MAX_DISPLAY;
            }
            string size = dw > 0 && dh > 0 ? " width=\"%d\" height=\"%d\"".printf(dw, dh) : "";
            return "<img src=\"data:%s;base64,%s\" alt=\"%s\"%s>".printf(mime, Base64.encode(data.get_data()), attr(b.alt), size);
        }

        public Bytes? single_png() {
            if (inline || blocks.size != 1) return null;
            var b = blocks[0];
            if (b.kind != BlockKind.IMAGE && b.kind != BlockKind.INK && b.kind != BlockKind.EQUATION) return null;
            int w, h;
            string? mime;
            var data = block_image(b, out w, out h, out mime);
            if (data == null) return null;
            if (mime == "image/png") return data;
            try {
                var loader = new Gdk.PixbufLoader();
                loader.write(data.get_data());
                loader.close();
                uint8[] buf;
                loader.get_pixbuf().save_to_buffer(out buf, "png");
                return new Bytes(buf);
            } catch (Error e) {
                return null;
            }
        }

        public Bytes? block_image(Block b, out int width, out int height, out string? mime) {
            width = 0;
            height = 0;
            mime = null;
            string file = resolve(b.image);
            if (!FileUtils.test(file, FileTest.IS_REGULAR)) return null;
            if (b.kind == BlockKind.INK) {
                mime = "image/png";
                return ink_png(InkDoc.load(file), 2.0, out width, out height);
            }
            var data = encode_image(file, out width, out height, out mime);
            if (b.kind == BlockKind.EQUATION) {
                width /= 2;
                height /= 2;
            }
            return data;
        }

        public static Bytes? encode_image(string file, out int width, out int height, out string? mime) {
            width = 0;
            height = 0;
            mime = null;
            uint8[] data;
            try {
                FileUtils.get_data(file, out data);
            } catch (FileError e) {
                return null;
            }
            int iw = 0, ih = 0;
            var format = Gdk.Pixbuf.get_file_info(file, out iw, out ih);
            width = iw;
            height = ih;
            string fname = format != null ? format.get_name() : "";
            if ((fname == "png" || fname == "jpeg") && data.length <= MAX_BYTES && int.max(iw, ih) <= MAX_SIDE) {
                mime = fname == "png" ? "image/png" : "image/jpeg";
                return new Bytes(data);
            }
            try {
                var pb = new Gdk.Pixbuf.from_file(file);
                int pw = pb.width, ph = pb.height;
                if (int.max(pw, ph) > MAX_SIDE) {
                    double s = (double) MAX_SIDE / int.max(pw, ph);
                    pw = int.max(1, (int) Math.round(pw * s));
                    ph = int.max(1, (int) Math.round(ph * s));
                    pb = pb.scale_simple(pw, ph, Gdk.InterpType.BILINEAR);
                }
                if (width <= 0 || height <= 0) {
                    width = pw;
                    height = ph;
                }
                uint8[] buf;
                if (!pb.has_alpha && (fname == "jpeg" || data.length > MAX_BYTES)) {
                    pb.save_to_buffer(out buf, "jpeg", "quality", "88");
                    mime = "image/jpeg";
                } else {
                    pb.save_to_buffer(out buf, "png");
                    mime = "image/png";
                }
                return new Bytes(buf);
            } catch (Error e) {
                if (file.down().has_suffix(".svg")) {
                    mime = "image/svg+xml";
                    return new Bytes(data);
                }
                return null;
            }
        }

        public static Bytes? ink_png(InkDoc doc, double scale, out int width, out int height) {
            width = 0;
            height = 0;
            if (doc.strokes.size == 0) return null;
            double x0 = double.MAX, y0 = double.MAX, x1 = -double.MAX, y1 = -double.MAX;
            foreach (var s in doc.strokes) {
                double a, b, c, d;
                s.bounds(out a, out b, out c, out d);
                double half = s.width / 2;
                x0 = double.min(x0, a - half);
                y0 = double.min(y0, b - half);
                x1 = double.max(x1, c + half);
                y1 = double.max(y1, d + half);
            }
            double pad = 8;
            x0 -= pad;
            y0 -= pad;
            width = int.max(1, (int) Math.ceil(x1 - x0 + pad));
            height = int.max(1, (int) Math.ceil(y1 - y0 + pad));
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, (int) Math.ceil(width * scale), (int) Math.ceil(height * scale));
            var cr = new Cairo.Context(surface);
            cr.scale(scale, scale);
            cr.translate(-x0, -y0);
            foreach (var s in doc.strokes) s.draw(cr);
            surface.flush();
            var out_bytes = new ByteArray();
            surface.write_to_png_stream((data) => {
                out_bytes.append(data);
                return Cairo.Status.SUCCESS;
            });
            return ByteArray.free_to_bytes((owned) out_bytes);
        }

        public Gdk.ContentProvider provider() {
            Gdk.ContentProvider[] list = {};
            list += new Gdk.ContentProvider.for_bytes(MIME, new Bytes(native().data));
            list += new Gdk.ContentProvider.for_bytes("text/html", new Bytes(html().data));
            var png = single_png();
            if (png != null) list += new Gdk.ContentProvider.for_bytes("image/png", png);
            list += new Gdk.ContentProvider.for_value(plain());
            return new Gdk.ContentProvider.union(list);
        }

        private static Gee.List<string> attachment_refs(Block b) {
            var list = new Gee.ArrayList<string>();
            if (b.image.has_prefix("attachments/")) list.add(b.image);
            foreach (var s in b.spans) if (s.href.has_prefix("attachments/")) list.add(s.href);
            return list;
        }

        private static string copy_attachment(string src, string dir) throws Error {
            string name = Path.get_basename(src);
            int dot = name.last_index_of(".");
            string stem = dot > 0 ? name.substring(0, dot) : name;
            string prefix = "";
            int n = 2;
            while (FileUtils.test(Path.build_filename(dir, prefix + name), FileTest.EXISTS)) prefix = "%d-".printf(n++);
            string src_dir = Path.get_dirname(src);
            var dir_handle = Dir.open(src_dir);
            string? entry;
            while ((entry = dir_handle.read_name()) != null) {
                if (entry != name && !entry.has_prefix(stem + ".")) continue;
                string target = Path.build_filename(dir, prefix + entry);
                File.new_for_path(Path.build_filename(src_dir, entry)).copy(File.new_for_path(target), FileCopyFlags.NONE);
                FileUtils.chmod(target, 0600);
            }
            return prefix + name;
        }

        public void import_into(string dest_dir, string dest_note) {
            var moved = new Gee.HashMap<string, string>();
            string dir = Attachments.dir_for(dest_dir, dest_note);
            foreach (var b in blocks) {
                b.anchor = "";
                foreach (string rel in attachment_refs(b)) {
                    if (moved.has_key(rel)) continue;
                    string src = resolve(rel);
                    if (Path.get_dirname(src) == dir || !FileUtils.test(src, FileTest.IS_REGULAR)) continue;
                    try {
                        DirUtils.create_with_parents(dir, 0700);
                        string name = copy_attachment(src, dir);
                        moved[rel] = "attachments/%s/%s".printf(dest_note, name);
                    } catch (Error e) {
                    }
                }
                if (moved.has_key(b.image)) b.image = moved[b.image];
                foreach (var s in b.spans) if (moved.has_key(s.href)) s.href = moved[s.href];
            }
        }
    }
}
