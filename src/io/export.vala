namespace Singularity.Apps.Notes {

    public enum ExportFormat {
        PDF,
        ODT,
        DOCX,
        HTML,
        MARKDOWN,
        PNG;

        public string extension() {
            switch (this) {
                case PDF: return "pdf";
                case ODT: return "odt";
                case DOCX: return "docx";
                case HTML: return "html";
                case PNG: return "png";
                default: return "md";
            }
        }

        public string label() {
            switch (this) {
                case PDF: return _("PDF Document");
                case ODT: return _("OpenDocument Text");
                case DOCX: return _("Word Document");
                case HTML: return _("Web Page");
                case PNG: return _("PNG Pictures");
                default: return _("Markdown");
            }
        }

        public string mime() {
            switch (this) {
                case PDF: return "application/pdf";
                case ODT: return "application/vnd.oasis.opendocument.text";
                case DOCX: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
                case HTML: return "text/html";
                case PNG: return "image/png";
                default: return "text/markdown";
            }
        }
    }

    public class Exporter : Object {
        public string notes_dir { get; construct; }
        public Gee.ArrayList<ExportPage> pages = new Gee.ArrayList<ExportPage>();

        public Exporter(string notes_dir) {
            Object(notes_dir: notes_dir);
        }

        public void write(ExportFormat fmt, string path) throws Error {
            switch (fmt) {
                case ExportFormat.PDF:
                    var r = new NoteRenderer(notes_dir);
                    r.pages.add_all(pages);
                    r.write_pdf(path);
                    break;
                case ExportFormat.HTML:
                    FileUtils.set_contents(path, html(true));
                    break;
                case ExportFormat.PNG:
                    var pr = new NoteRenderer(notes_dir);
                    pr.pages.add_all(pages);
                    pr.write_png(path);
                    break;
                case ExportFormat.MARKDOWN:
                    write_markdown(path);
                    break;
                case ExportFormat.ODT:
                    var data = odt();
                    FileUtils.set_data(path, data);
                    break;
                case ExportFormat.DOCX:
                    var data = docx();
                    FileUtils.set_data(path, data);
                    break;
            }
        }

        public string resolve(string p) {
            if (Path.is_absolute(p)) return p;
            return Path.build_filename(notes_dir, Uri.unescape_string(p) ?? p);
        }

        public Singularity.Equations.Equation? equation_of(Block b) {
            if (b.kind != BlockKind.EQUATION) return null;
            string png = resolve(b.image);
            if (!FileUtils.test(EquationFiles.stem(png) + ".mml", FileTest.EXISTS) && !FileUtils.test(EquationFiles.stem(png) + ".tex", FileTest.EXISTS)) return null;
            var eq = EquationFiles.load(png, b.alt);
            return eq.mathml.strip() != "" ? eq : null;
        }

        private static string esc(string s) {
            return Markup.escape_text(s);
        }

        private bool has_page(string id) {
            foreach (var p in pages) if (p.id == id) return true;
            return false;
        }

        private string href_for(string href) {
            if (href.has_prefix("note:")) {
                string id = href.substring(5);
                int hash = id.index_of("#");
                string anchor = hash >= 0 ? id.substring(hash + 1) : "";
                if (hash >= 0) id = id.substring(0, hash);
                if (has_page(id)) return "#" + (anchor != "" ? anchor : "page-" + id);
                return "";
            }
            if (href.has_prefix("section:")) return "";
            if (href.has_prefix("attachments/")) return "";
            return href;
        }

        public string html_inline(Gee.List<Span> spans) {
            var sb = new StringBuilder();
            foreach (var s in spans) {
                if (s.text == "") continue;
                string t = esc(s.text);
                if (s.code) t = "<code>%s</code>".printf(t);
                if (s.bold) t = "<strong>%s</strong>".printf(t);
                if (s.italic) t = "<em>%s</em>".printf(t);
                if (s.underline) t = "<u>%s</u>".printf(t);
                if (s.strike) t = "<s>%s</s>".printf(t);
                if (s.highlight != "") t = "<mark style=\"background:%s\">%s</mark>".printf(s.highlight == "yellow" ? "#ffe066" : s.highlight, t);
                string style = "";
                if (s.color != "") style += "color:%s;".printf(s.color);
                if (s.font != "") style += "font-family:'%s';".printf(esc(s.font));
                if (s.size > 0) style += "font-size:%dpt;".printf(s.size);
                if (style != "") t = "<span style=\"%s\">%s</span>".printf(style, t);
                if (s.href != "") {
                    string h = href_for(s.href);
                    if (h != "") t = "<a href=\"%s\">%s</a>".printf(esc(h), t);
                }
                sb.append(t);
            }
            return sb.str;
        }

        private string data_uri(string file) {
            uint8[] data;
            try {
                FileUtils.get_data(file, out data);
            } catch (FileError e) {
                return "";
            }
            bool uncertain;
            string mime = ContentType.get_mime_type(ContentType.guess(file, data, out uncertain)) ?? "application/octet-stream";
            if (file.has_suffix(".svg")) mime = "image/svg+xml";
            return "data:%s;base64,%s".printf(mime, Base64.encode(data));
        }

        public string html(bool embed) {
            var sb = new StringBuilder();
            string title = pages.size == 1 ? pages[0].display_title() : _("Notes");
            sb.append("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
            sb.append("<title>%s</title>\n".printf(esc(title)));
            sb.append("<style>\nbody{font-family:sans-serif;max-width:52em;margin:2em auto;padding:0 1em;line-height:1.5;color:#1e1e22}\n.date{color:#77767b;margin-top:-0.6em}\nblockquote{border-left:3px solid #c0bfbc;margin:0;padding-left:1em;color:#5e5c64;font-style:italic}\npre{background:#f3f3f5;padding:0.6em;border-radius:6px;overflow:auto}\ntable{border-collapse:collapse;margin:0.5em 0}\ntd,th{border:1px solid #c0bfbc;padding:0.3em 0.6em}\nth{background:#f1f1f3}\n.tag{color:#9141ac;font-weight:bold;font-size:0.85em}\n.done{text-decoration:line-through;color:#808080}\nimg{max-width:100%}\narticle{margin-bottom:3em}\n</style>\n</head>\n<body>\n");
            foreach (var p in pages) {
                sb.append("<article id=\"page-%s\">\n<h1>%s</h1>\n".printf(esc(p.id), esc(p.display_title())));
                if (p.created > 0) sb.append("<p class=\"date\">%s</p>\n".printf(esc(new DateTime.from_unix_local(p.created).format("%A %e %B %Y, %H:%M"))));
                sb.append(html_blocks(p.blocks(), embed));
                sb.append("</article>\n");
            }
            sb.append("</body>\n</html>\n");
            return sb.str;
        }

        private string tag_html(string[] tags) {
            if (tags.length == 0) return "";
            return "<span class=\"tag\">%s</span>".printf(esc(Inline.tag_labels(tags)));
        }

        public string html_blocks(Gee.List<Block> blocks, bool embed) {
            var sb = new StringBuilder();
            var stack = new Gee.ArrayList<string>();
            var levels = new Gee.ArrayList<int>();
            int i = 0;
            while (i < blocks.size) {
                var b = blocks[i];
                string anchor = b.anchor != "" ? " id=\"%s\"".printf(esc(b.anchor)) : "";
                if (b.kind.is_list()) {
                    string type = b.kind == BlockKind.NUMBERED ? "ol" : "ul";
                    while (stack.size > 0 && (levels[levels.size - 1] > b.indent || (levels[levels.size - 1] == b.indent && stack[stack.size - 1] != type))) {
                        sb.append("</%s>\n".printf(stack.remove_at(stack.size - 1)));
                        levels.remove_at(levels.size - 1);
                    }
                    if (stack.size == 0 || levels[levels.size - 1] < b.indent) {
                        sb.append("<%s>\n".printf(type));
                        stack.add(type);
                        levels.add(b.indent);
                    }
                    string inner = tag_html(b.tags) + html_inline(b.spans);
                    if (b.kind == BlockKind.CHECK) inner = "<input type=\"checkbox\" disabled%s> %s".printf(b.checked ? " checked" : "", b.checked ? "<span class=\"done\">%s</span>".printf(inner) : inner);
                    sb.append("<li%s>%s</li>\n".printf(anchor, inner));
                    i++;
                    continue;
                }
                while (stack.size > 0) {
                    sb.append("</%s>\n".printf(stack.remove_at(stack.size - 1)));
                    levels.remove_at(levels.size - 1);
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
                        sb.append("<blockquote%s>%s%s</blockquote>\n".printf(anchor, tag_html(b.tags), html_inline(b.spans)));
                        break;
                    case BlockKind.RULE:
                        sb.append("<hr>\n");
                        break;
                    case BlockKind.TABLE:
                        sb.append("<table%s>\n".printf(anchor));
                        var t = b.table;
                        t.normalize();
                        for (int r = 0; r < t.rows.size; r++) {
                            sb.append("<tr>");
                            for (int c = 0; c < t.columns; c++) {
                                string cell = r == 0 ? "th" : "td";
                                string style = "";
                                if (t.shade(r, c) != "") style += "background:%s;".printf(t.shade(r, c));
                                if (t.aligns[c] != "") style += "text-align:%s;".printf(t.aligns[c]);
                                sb.append("<%s%s>%s</%s>".printf(cell, style != "" ? " style=\"%s\"".printf(style) : "", esc(t.cell(r, c)).replace("\n", "<br>"), cell));
                            }
                            sb.append("</tr>\n");
                        }
                        sb.append("</table>\n");
                        break;
                    case BlockKind.IMAGE:
                    case BlockKind.INK:
                    case BlockKind.EQUATION:
                        var heq = equation_of(b);
                        if (heq != null) {
                            sb.append("<p%s>%s</p>\n".printf(anchor, heq.mathml_for_display()));
                            break;
                        }
                        string src = embed ? data_uri(resolve(b.image)) : b.image;
                        string w = b.width > 0 ? " width=\"%d\"".printf(b.width) : "";
                        if (b.kind == BlockKind.EQUATION) w = " style=\"height:2em\"";
                        sb.append("<p%s><img src=\"%s\" alt=\"%s\"%s></p>\n".printf(anchor, src, esc(b.alt), w));
                        break;
                    case BlockKind.FILE:
                    case BlockKind.RECORDING:
                        sb.append("<p%s><em>%s</em></p>\n".printf(anchor, esc(_("Attachment: %s").printf(b.alt))));
                        var info = RecordingInfo.load(resolve(b.image));
                        if (info.transcript != null && info.transcript != "") sb.append("<blockquote>%s</blockquote>\n".printf(esc(info.transcript)));
                        break;
                    default:
                        if (level > 0) {
                            sb.append("<h%d%s>%s%s</h%d>\n".printf(int.min(6, level + 1), anchor, tag_html(b.tags), html_inline(b.spans), int.min(6, level + 1)));
                        } else if (b.plain_text() == "" && b.tags.length == 0) {
                            sb.append("<p>&nbsp;</p>\n");
                        } else {
                            string style = b.indent > 0 ? " style=\"margin-left:%dem\"".printf(b.indent * 2) : "";
                            sb.append("<p%s%s>%s%s</p>\n".printf(anchor, style, tag_html(b.tags), html_inline(b.spans)));
                        }
                        break;
                }
                i++;
            }
            while (stack.size > 0) sb.append("</%s>\n".printf(stack.remove_at(stack.size - 1)));
            return sb.str;
        }

        private void write_markdown(string path) throws Error {
            string dir = Path.get_dirname(path);
            string stem = Path.get_basename(path);
            if (stem.has_suffix(".md")) stem = stem.substring(0, stem.length - 3);
            string files_dir = stem + "_files";
            var sb = new StringBuilder();
            bool first = true;
            foreach (var p in pages) {
                if (!first) sb.append("\n\n---\n\n");
                first = false;
                var d = p.doc();
                string body = d.flow_markdown();
                if (d.meta.ink != "") body += "\n![%s](%s)".printf(_("Drawing"), d.meta.ink);
                foreach (string target in NoteAttachments.links(body)) {
                    if (!target.has_prefix("attachments/")) continue;
                    string src = resolve(target);
                    if (!FileUtils.test(src, FileTest.IS_REGULAR)) continue;
                    string name = Path.get_basename(src);
                    string out_dir = Path.build_filename(dir, files_dir);
                    DirUtils.create_with_parents(out_dir, 0755);
                    File.new_for_path(src).copy(File.new_for_path(Path.build_filename(out_dir, name)), FileCopyFlags.OVERWRITE);
                    body = body.replace(target, files_dir + "/" + Uri.escape_string(name, null, false));
                }
                var h = new Block(BlockKind.HEADING1);
                h.add(new Span(p.display_title()));
                sb.append(RichText.render_block(h));
                sb.append("\n\n");
                sb.append(body);
            }
            sb.append("\n");
            FileUtils.set_contents(path, sb.str);
        }

        private static string cm(double px) {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            return (px * 2.54 / 96.0).format(buf, "%.3f") + "cm";
        }

        private class OdtContext {
            public Gee.HashMap<string, string> text_styles = new Gee.HashMap<string, string>();
            public Gee.ArrayList<string> auto_styles = new Gee.ArrayList<string>();
            public Gee.HashMap<string, string> images = new Gee.HashMap<string, string>();
            public int frame = 0;
            public int table = 0;
            public int objects = 0;
            public Gee.ArrayList<string> manifest = new Gee.ArrayList<string>();
        }

        private string odt_span_style(OdtContext ctx, Span s) {
            var props = new StringBuilder();
            if (s.bold) props.append(" fo:font-weight=\"bold\"");
            if (s.italic) props.append(" fo:font-style=\"italic\"");
            if (s.underline || s.href != "") props.append(" style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"");
            if (s.strike) props.append(" style:text-line-through-style=\"solid\"");
            if (s.color != "") props.append(" fo:color=\"%s\"".printf(s.color));
            else if (s.href != "") props.append(" fo:color=\"#1c71d8\"");
            if (s.highlight != "") props.append(" fo:background-color=\"%s\"".printf(s.highlight == "yellow" ? "#ffe066" : s.highlight));
            if (s.font != "") props.append(" style:font-name=\"%s\" fo:font-family=\"%s\"".printf(esc(s.font), esc(s.font)));
            if (s.code) props.append(" style:font-name=\"Monospace\" fo:font-family=\"Monospace\"");
            if (s.size > 0) props.append(" fo:font-size=\"%dpt\"".printf(s.size));
            string key = props.str;
            if (key == "") return "";
            if (!ctx.text_styles.has_key(key)) {
                string name = "T%d".printf(ctx.text_styles.size + 1);
                ctx.text_styles[key] = name;
                ctx.auto_styles.add("<style:style style:name=\"%s\" style:family=\"text\"><style:text-properties%s/></style:style>".printf(name, key));
            }
            return ctx.text_styles[key];
        }

        private string odt_inline(OdtContext ctx, Gee.List<Span> spans, string[] tags) {
            var sb = new StringBuilder();
            if (tags.length > 0) {
                var t = new Span(Inline.tag_labels(tags));
                t.bold = true;
                t.color = "#9141ac";
                sb.append("<text:span text:style-name=\"%s\">%s</text:span>".printf(odt_span_style(ctx, t), esc(t.text)));
            }
            foreach (var s in spans) {
                if (s.text == "") continue;
                string style = odt_span_style(ctx, s);
                string t = esc(s.text);
                if (style != "") t = "<text:span text:style-name=\"%s\">%s</text:span>".printf(style, t);
                if (s.href != "") {
                    string h = href_for(s.href);
                    if (h != "") t = "<text:a xlink:type=\"simple\" xlink:href=\"%s\">%s</text:a>".printf(esc(h), t);
                }
                sb.append(t);
            }
            return sb.str;
        }

        private string odt_image(OdtContext ctx, Block b, ZipWriter zip) throws Error {
            string file = resolve(b.image);
            if (!FileUtils.test(file, FileTest.IS_REGULAR)) return "";
            string name = ctx.images[file];
            if (name == null) {
                name = "Pictures/%d-%s".printf(ctx.images.size + 1, Attachments.clean_name(Path.get_basename(file)));
                uint8[] data;
                FileUtils.get_data(file, out data);
                zip.add(name, data, false);
                ctx.images[file] = name;
            }
            double w, h;
            image_size(file, b, out w, out h);
            ctx.frame++;
            return "<draw:frame draw:name=\"img%d\" text:anchor-type=\"as-char\" svg:width=\"%s\" svg:height=\"%s\"><draw:image xlink:href=\"%s\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/></draw:frame>".printf(
                ctx.frame, cm(w), cm(h), name);
        }

        public void image_size(string file, Block b, out double w, out double h) {
            int iw = 0, ih = 0;
            Gdk.Pixbuf.get_file_info(file, out iw, out ih);
            if (file.has_suffix(".svg") && Path.get_basename(file).has_prefix("ink-")) {
                var doc = InkDoc.load(file);
                int ew, eh;
                doc.extent(out ew, out eh);
                if (ew > 0) {
                    iw = ew;
                    ih = eh;
                }
            }
            if (iw <= 0 || ih <= 0) {
                iw = 400;
                ih = 300;
            }
            w = b.width > 0 ? b.width : iw;
            if (b.kind == BlockKind.EQUATION) w = iw / 2.0;
            w = double.min(w, 620);
            h = ih * w / iw;
        }

        public uint8[] odt() throws Error {
            var zip = new ZipWriter();
            zip.add_text("mimetype", "application/vnd.oasis.opendocument.text", false);
            var ctx = new OdtContext();
            var body = new StringBuilder();
            foreach (var p in pages) {
                body.append("<text:h text:style-name=\"%s\" text:outline-level=\"1\">%s</text:h>\n".printf(body.len > 0 ? "PageTitleBreak" : "Title", esc(p.display_title())));
                if (p.created > 0) body.append("<text:p text:style-name=\"Date\">%s</text:p>\n".printf(esc(new DateTime.from_unix_local(p.created).format("%A %e %B %Y, %H:%M"))));
                var blocks = p.blocks();
                int i = 0;
                while (i < blocks.size) {
                    var b = blocks[i];
                    if (b.kind.is_list()) {
                        int j = i;
                        body.append(odt_list(ctx, blocks, ref j, b.indent));
                        i = j;
                        continue;
                    }
                    int level = b.kind.heading_level();
                    switch (b.kind) {
                        case BlockKind.CODE:
                            body.append("<text:p text:style-name=\"Code\">%s</text:p>\n".printf(esc(b.raw).replace("  ", " <text:s/>")));
                            break;
                        case BlockKind.QUOTE:
                            body.append("<text:p text:style-name=\"Quote\">%s</text:p>\n".printf(odt_inline(ctx, b.spans, b.tags)));
                            break;
                        case BlockKind.RULE:
                            body.append("<text:p text:style-name=\"Rule\"/>\n");
                            break;
                        case BlockKind.TABLE:
                            body.append(odt_table(ctx, b.table));
                            break;
                        case BlockKind.IMAGE:
                        case BlockKind.INK:
                        case BlockKind.EQUATION:
                            if (b.kind == BlockKind.INK) {
                                string png = ink_png(b);
                                if (png != "") {
                                    var copy = RichText.image_block(b.alt, png, 0);
                                    body.append("<text:p text:style-name=\"Standard\">%s</text:p>\n".printf(odt_image(ctx, copy, zip)));
                                    break;
                                }
                            }
                            var oeq = equation_of(b);
                            if (oeq != null) {
                                body.append("<text:p text:style-name=\"Formula\">%s</text:p>\n".printf(odt_formula(ctx, b, oeq, zip)));
                                break;
                            }
                            body.append("<text:p text:style-name=\"Standard\">%s</text:p>\n".printf(odt_image(ctx, b, zip)));
                            break;
                        case BlockKind.FILE:
                        case BlockKind.RECORDING:
                            body.append("<text:p text:style-name=\"Standard\">%s</text:p>\n".printf(esc(_("Attachment: %s").printf(b.alt))));
                            break;
                        default:
                            if (level > 0) {
                                body.append("<text:h text:style-name=\"Heading_20_%d\" text:outline-level=\"%d\">%s</text:h>\n".printf(int.min(6, level), int.min(6, level + 1), odt_inline(ctx, b.spans, b.tags)));
                            } else {
                                string style = b.indent > 0 ? "Indent%d".printf(int.min(b.indent, 8)) : "Standard";
                                body.append("<text:p text:style-name=\"%s\">%s</text:p>\n".printf(style, odt_inline(ctx, b.spans, b.tags)));
                            }
                            break;
                    }
                    i++;
                }
            }
            var auto = new StringBuilder();
            foreach (string s in ctx.auto_styles) auto.append(s + "\n");
            auto.append("<style:style style:name=\"PageTitleBreak\" style:family=\"paragraph\" style:parent-style-name=\"Title\"><style:paragraph-properties fo:break-before=\"page\"/></style:style>\n");
            for (int k = 1; k <= 8; k++) auto.append("<style:style style:name=\"Indent%d\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"><style:paragraph-properties fo:margin-left=\"%.1fcm\"/></style:style>\n".printf(k, k * 0.8));
            auto.append(list_styles());
            string content = """<?xml version="1.0" encoding="UTF-8"?>
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.3">
<office:automatic-styles>
%s</office:automatic-styles>
<office:body><office:text>
%s</office:text></office:body></office:document-content>
""".printf(auto.str, body.str);
            zip.add_text("content.xml", content);
            zip.add_text("styles.xml", ODT_STYLES);
            zip.add_text("meta.xml", """<?xml version="1.0" encoding="UTF-8"?>
<office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/" office:version="1.3"><office:meta><meta:generator>Singularity Notes</meta:generator><dc:title>%s</dc:title></office:meta></office:document-meta>
""".printf(esc(pages.size > 0 ? pages[0].display_title() : "")));
            var manifest = new StringBuilder("""<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
<manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>
<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
<manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
<manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>
""");
            foreach (var e in ctx.images.entries) {
                bool uncertain;
                string mime = ContentType.get_mime_type(ContentType.guess(e.value, null, out uncertain)) ?? "image/png";
                manifest.append("<manifest:file-entry manifest:full-path=\"%s\" manifest:media-type=\"%s\"/>\n".printf(e.value, mime));
            }
            foreach (string m in ctx.manifest) manifest.append(m + "\n");
            manifest.append("</manifest:manifest>\n");
            zip.add_text("META-INF/manifest.xml", manifest.str);
            return zip.finish();
        }

        private string odt_formula(OdtContext ctx, Block b, Singularity.Equations.Equation eq, ZipWriter zip) throws Error {
            ctx.objects++;
            string name = "Object %d".printf(ctx.objects);
            zip.add_text(name + "/content.xml", eq.to_odf_object());
            string png = resolve(b.image);
            uint8[] data;
            FileUtils.get_data(png, out data);
            zip.add("ObjectReplacements/" + name, data, false);
            ctx.manifest.add("<manifest:file-entry manifest:full-path=\"%s/\" manifest:media-type=\"%s\"/>".printf(name, Singularity.Equations.Equation.ODF_MEDIA_TYPE));
            ctx.manifest.add("<manifest:file-entry manifest:full-path=\"%s/content.xml\" manifest:media-type=\"text/xml\"/>".printf(name));
            ctx.manifest.add("<manifest:file-entry manifest:full-path=\"ObjectReplacements/%s\" manifest:media-type=\"image/png\"/>".printf(name));
            double w, h;
            image_size(png, b, out w, out h);
            ctx.frame++;
            return "<draw:frame draw:name=\"Formula%d\" text:anchor-type=\"as-char\" svg:width=\"%s\" svg:height=\"%s\"><draw:object xlink:href=\"./%s\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/><draw:image xlink:href=\"./ObjectReplacements/%s\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/><svg:desc>%s</svg:desc></draw:frame>".printf(
                ctx.frame, cm(w), cm(h), name, name, esc(eq.speech));
        }

        private string ink_png(Block b) {
            string file = resolve(b.image);
            var doc = InkDoc.load(file);
            if (doc.strokes.size == 0) return "";
            string out_path;
            try {
                int fd = FileUtils.open_tmp("notes-ink-export-XXXXXX.png", out out_path);
                FileUtils.close(fd);
            } catch (FileError e) {
                return "";
            }
            int w, h;
            doc.extent(out w, out h);
            var s = new Cairo.ImageSurface(Cairo.Format.ARGB32, int.max(1, w + 8), int.max(1, h + 8));
            var cr = new Cairo.Context(s);
            foreach (var st in doc.strokes) st.draw(cr);
            s.write_to_png(out_path);
            temp_files.add(out_path);
            return out_path;
        }

        private Gee.ArrayList<string> temp_files = new Gee.ArrayList<string>();

        public void cleanup() {
            foreach (string f in temp_files) FileUtils.unlink(f);
            temp_files.clear();
        }

        private string list_styles() {
            var sb = new StringBuilder();
            sb.append("<text:list-style style:name=\"LBullet\">");
            for (int l = 1; l <= 10; l++) sb.append("<text:list-level-style-bullet text:level=\"%d\" text:bullet-char=\"%s\"><style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" fo:text-indent=\"-0.6cm\" fo:margin-left=\"%.1fcm\"/></style:list-level-properties></text:list-level-style-bullet>".printf(l, l % 2 == 1 ? "•" : "◦", 0.6 + l * 0.6));
            sb.append("</text:list-style>\n<text:list-style style:name=\"LNumber\">");
            for (int l = 1; l <= 10; l++) sb.append("<text:list-level-style-number text:level=\"%d\" style:num-format=\"%s\" style:num-suffix=\".\"><style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" fo:text-indent=\"-0.6cm\" fo:margin-left=\"%.1fcm\"/></style:list-level-properties></text:list-level-style-number>".printf(l, l % 3 == 1 ? "1" : l % 3 == 2 ? "a" : "i", 0.6 + l * 0.6));
            sb.append("</text:list-style>\n");
            return sb.str;
        }

        private string odt_list(OdtContext ctx, Gee.List<Block> blocks, ref int i, int level) {
            var sb = new StringBuilder();
            string style = blocks[i].kind == BlockKind.NUMBERED ? "LNumber" : "LBullet";
            sb.append("<text:list text:style-name=\"%s\">\n".printf(style));
            while (i < blocks.size && blocks[i].kind.is_list() && blocks[i].indent >= level) {
                var b = blocks[i];
                if (b.indent > level) {
                    sb.append("<text:list-item>");
                    sb.append(odt_list(ctx, blocks, ref i, b.indent));
                    sb.append("</text:list-item>\n");
                    continue;
                }
                if ((b.kind == BlockKind.NUMBERED) != (style == "LNumber")) break;
                string prefix = b.kind == BlockKind.CHECK ? (b.checked ? "[x] " : "[ ] ") : "";
                sb.append("<text:list-item><text:p text:style-name=\"Standard\">%s%s</text:p></text:list-item>\n".printf(esc(prefix), odt_inline(ctx, b.spans, b.tags)));
                i++;
            }
            sb.append("</text:list>\n");
            return sb.str;
        }

        private string odt_table(OdtContext ctx, TableData t) {
            t.normalize();
            ctx.table++;
            var sb = new StringBuilder();
            string tname = "Table%d".printf(ctx.table);
            sb.append("<table:table table:name=\"%s\">\n".printf(tname));
            sb.append("<table:table-column table:number-columns-repeated=\"%d\"/>\n".printf(t.columns));
            for (int r = 0; r < t.rows.size; r++) {
                sb.append("<table:table-row>");
                for (int c = 0; c < t.columns; c++) {
                    string shade = t.shade(r, c);
                    string cell_style = "Cell";
                    if (shade != "") {
                        cell_style = "%sC%d_%d".printf(tname, r, c);
                        ctx.auto_styles.add("<style:style style:name=\"%s\" style:family=\"table-cell\"><style:table-cell-properties fo:background-color=\"%s\" fo:border=\"0.5pt solid #999999\" fo:padding=\"0.1cm\"/></style:style>".printf(cell_style, shade));
                    }
                    string text = esc(t.cell(r, c));
                    if (r == 0) text = "<text:span text:style-name=\"%s\">%s</text:span>".printf(odt_span_style(ctx, bold_span()), text);
                    sb.append("<table:table-cell table:style-name=\"%s\" office:value-type=\"string\"><text:p>%s</text:p></table:table-cell>".printf(cell_style, text));
                }
                sb.append("</table:table-row>\n");
            }
            sb.append("</table:table>\n");
            return sb.str;
        }

        private static Span bold_span() {
            var s = new Span("x");
            s.bold = true;
            return s;
        }

        private const string ODT_STYLES = """<?xml version="1.0" encoding="UTF-8"?>
<office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.3">
<office:styles>
<style:style style:name="Standard" style:family="paragraph"><style:paragraph-properties fo:margin-bottom="0.15cm"/><style:text-properties fo:font-size="11pt"/></style:style>
<style:style style:name="Title" style:family="paragraph" style:parent-style-name="Standard"><style:text-properties fo:font-size="24pt" fo:font-weight="bold"/></style:style>
<style:style style:name="Date" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:margin-bottom="0.4cm"/><style:text-properties fo:color="#77767b" fo:font-size="9pt"/></style:style>
<style:style style:name="Heading_20_1" style:display-name="Heading 1" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:margin-top="0.4cm"/><style:text-properties fo:font-size="20pt" fo:font-weight="bold"/></style:style>
<style:style style:name="Heading_20_2" style:display-name="Heading 2" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:margin-top="0.3cm"/><style:text-properties fo:font-size="16pt" fo:font-weight="bold"/></style:style>
<style:style style:name="Heading_20_3" style:display-name="Heading 3" style:family="paragraph" style:parent-style-name="Standard"><style:text-properties fo:font-size="14pt" fo:font-weight="bold"/></style:style>
<style:style style:name="Heading_20_4" style:display-name="Heading 4" style:family="paragraph" style:parent-style-name="Standard"><style:text-properties fo:font-size="12pt" fo:font-weight="bold"/></style:style>
<style:style style:name="Heading_20_5" style:display-name="Heading 5" style:family="paragraph" style:parent-style-name="Standard"><style:text-properties fo:font-size="11pt" fo:font-weight="bold"/></style:style>
<style:style style:name="Heading_20_6" style:display-name="Heading 6" style:family="paragraph" style:parent-style-name="Standard"><style:text-properties fo:font-size="11pt" fo:font-weight="bold" fo:font-style="italic"/></style:style>
<style:style style:name="Quote" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:margin-left="0.8cm" fo:border-left="1.5pt solid #c0bfbc" fo:padding-left="0.3cm"/><style:text-properties fo:font-style="italic" fo:color="#5e5c64"/></style:style>
<style:style style:name="Code" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:background-color="#f3f3f5" fo:margin-bottom="0cm"/><style:text-properties style:font-name="Monospace" fo:font-family="Monospace" fo:font-size="10pt"/></style:style>
<style:style style:name="Formula" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="center"/></style:style>
<style:style style:name="Rule" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:border-bottom="0.5pt solid #c0bfbc"/></style:style>
<style:style style:name="Cell" style:family="table-cell"><style:table-cell-properties fo:border="0.5pt solid #999999" fo:padding="0.1cm"/></style:style>
</office:styles>
</office:document-styles>
""";

        private class DocxContext {
            public Gee.ArrayList<string> rels = new Gee.ArrayList<string>();
            public Gee.HashMap<string, string> image_rels = new Gee.HashMap<string, string>();
            public int next_rel = 10;
            public int drawing = 0;
            public int num_id = 2;
            public Gee.ArrayList<string> nums = new Gee.ArrayList<string>();
        }

        private static string docx_color(string c) {
            string s = c.has_prefix("#") ? c.substring(1) : c;
            if (s == "yellow") return "FFE066";
            if (s.length == 3) s = "%c%c%c%c%c%c".printf(s[0], s[0], s[1], s[1], s[2], s[2]);
            return s.up();
        }

        private string docx_run(Span s) {
            var rpr = new StringBuilder();
            if (s.font != "" || s.code) rpr.append("<w:rFonts w:ascii=\"%s\" w:hAnsi=\"%s\" w:cs=\"%s\"/>".printf(esc(s.code ? "Courier New" : s.font), esc(s.code ? "Courier New" : s.font), esc(s.code ? "Courier New" : s.font)));
            if (s.bold) rpr.append("<w:b/>");
            if (s.italic) rpr.append("<w:i/>");
            if (s.strike) rpr.append("<w:strike/>");
            if (s.color != "") rpr.append("<w:color w:val=\"%s\"/>".printf(docx_color(s.color)));
            else if (s.href != "") rpr.append("<w:color w:val=\"1C71D8\"/>");
            if (s.size > 0) rpr.append("<w:sz w:val=\"%d\"/>".printf(s.size * 2));
            if (s.underline || s.href != "") rpr.append("<w:u w:val=\"single\"/>");
            if (s.highlight != "") rpr.append("<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"%s\"/>".printf(docx_color(s.highlight)));
            string pr = rpr.len > 0 ? "<w:rPr>%s</w:rPr>".printf(rpr.str) : "";
            return "<w:r>%s<w:t xml:space=\"preserve\">%s</w:t></w:r>".printf(pr, esc(s.text));
        }

        private string docx_inline(DocxContext ctx, Gee.List<Span> spans, string[] tags) {
            var sb = new StringBuilder();
            if (tags.length > 0) {
                var t = new Span(Inline.tag_labels(tags));
                t.bold = true;
                t.color = "#9141ac";
                sb.append(docx_run(t));
            }
            foreach (var s in spans) {
                if (s.text == "") continue;
                string h = s.href != "" ? href_for(s.href) : "";
                if (h != "" && !h.has_prefix("#")) {
                    string id = "rId%d".printf(ctx.next_rel++);
                    ctx.rels.add("<Relationship Id=\"%s\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"%s\" TargetMode=\"External\"/>".printf(id, esc(h)));
                    sb.append("<w:hyperlink r:id=\"%s\">%s</w:hyperlink>".printf(id, docx_run(s)));
                } else if (h.has_prefix("#")) {
                    sb.append("<w:hyperlink w:anchor=\"%s\">%s</w:hyperlink>".printf(esc(h.substring(1).replace("-", "_")), docx_run(s)));
                } else {
                    sb.append(docx_run(s));
                }
            }
            return sb.str;
        }

        private string docx_para(string style, string runs, string extra = "") {
            string ppr = style != "" || extra != "" ? "<w:pPr>%s%s</w:pPr>".printf(style != "" ? "<w:pStyle w:val=\"%s\"/>".printf(style) : "", extra) : "";
            return "<w:p>%s%s</w:p>\n".printf(ppr, runs);
        }

        private string docx_image(DocxContext ctx, Block b, ZipWriter zip) throws Error {
            string file = resolve(b.image);
            if (b.kind == BlockKind.INK) {
                string png = ink_png(b);
                if (png == "") return "";
                file = png;
            }
            if (!FileUtils.test(file, FileTest.IS_REGULAR)) return "";
            if (file.has_suffix(".svg")) {
                try {
                    var pix = new Gdk.Pixbuf.from_file(file);
                    string png;
                    int fd = FileUtils.open_tmp("notes-svg-XXXXXX.png", out png);
                    FileUtils.close(fd);
                    pix.savev(png, "png", {}, {});
                    temp_files.add(png);
                    file = png;
                } catch (Error e) {
                    return "";
                }
            }
            string rid = ctx.image_rels[file];
            if (rid == null) {
                rid = "rId%d".printf(ctx.next_rel++);
                string ext = file.contains(".") ? file.substring(file.last_index_of(".") + 1).down() : "png";
                string name = "media/image%d.%s".printf(ctx.image_rels.size + 1, ext);
                uint8[] data;
                FileUtils.get_data(file, out data);
                zip.add("word/" + name, data, false);
                ctx.rels.add("<Relationship Id=\"%s\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"%s\"/>".printf(rid, name));
                ctx.image_rels[file] = rid;
            }
            var probe = RichText.image_block(b.alt, file, b.width);
            probe.kind = b.kind == BlockKind.INK ? BlockKind.IMAGE : b.kind;
            double w, h;
            image_size(file, probe, out w, out h);
            int64 cx = (int64) (w * 9525);
            int64 cy = (int64) (h * 9525);
            ctx.drawing++;
            return ("<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"%lld\" cy=\"%lld\"/><wp:docPr id=\"%d\" name=\"Picture %d\" descr=\"%s\"/>"
                + "<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
                + "<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:nvPicPr><pic:cNvPr id=\"%d\" name=\"image%d\"/><pic:cNvPicPr/></pic:nvPicPr>"
                + "<pic:blipFill><a:blip r:embed=\"%s\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"%lld\" cy=\"%lld\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>").printf(
                cx, cy, ctx.drawing, ctx.drawing, esc(b.alt), ctx.drawing, ctx.drawing, rid, cx, cy);
        }

        public uint8[] docx() throws Error {
            var zip = new ZipWriter();
            var ctx = new DocxContext();
            var body = new StringBuilder();
            bool first = true;
            foreach (var p in pages) {
                string brk = first ? "" : "<w:pageBreakBefore/>";
                first = false;
                body.append(docx_para("Title", docx_run(new Span(p.display_title())), brk));
                if (p.created > 0) {
                    var d = new Span(new DateTime.from_unix_local(p.created).format("%A %e %B %Y, %H:%M"));
                    d.color = "#77767b";
                    body.append(docx_para("", docx_run(d)));
                }
                var blocks = p.blocks();
                int bullet_num = 0;
                int number_num = 0;
                bool in_numbered = false;
                for (int i = 0; i < blocks.size; i++) {
                    var b = blocks[i];
                    string bm = b.anchor != "" ? "<w:bookmarkStart w:id=\"%d\" w:name=\"%s\"/><w:bookmarkEnd w:id=\"%d\"/>".printf(i + 1000, b.anchor.replace("-", "_"), i + 1000) : "";
                    if (b.kind == BlockKind.NUMBERED && !in_numbered) {
                        number_num = ctx.num_id++;
                        ctx.nums.add("<w:num w:numId=\"%d\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>".printf(number_num));
                    }
                    in_numbered = b.kind.is_list() ? (in_numbered || b.kind == BlockKind.NUMBERED) : false;
                    if (b.kind.is_list() && bullet_num == 0) bullet_num = 1;
                    int level = b.kind.heading_level();
                    switch (b.kind) {
                        case BlockKind.BULLET:
                        case BlockKind.CHECK:
                        case BlockKind.NUMBERED:
                            int num = b.kind == BlockKind.NUMBERED ? number_num : 1;
                            string prefix = b.kind == BlockKind.CHECK ? (b.checked ? "[x] " : "[ ] ") : "";
                            var spans = new Gee.ArrayList<Span>();
                            if (prefix != "") spans.add(new Span(prefix));
                            foreach (var s in b.spans) {
                                var c = s.with_text(s.text);
                                if (b.kind == BlockKind.CHECK && b.checked) c.strike = true;
                                spans.add(c);
                            }
                            body.append(docx_para("ListParagraph", bm + docx_inline(ctx, spans, b.tags), "<w:numPr><w:ilvl w:val=\"%d\"/><w:numId w:val=\"%d\"/></w:numPr>".printf(int.min(b.indent, 8), num)));
                            break;
                        case BlockKind.CODE:
                            var cs = new Span(b.raw);
                            cs.code = true;
                            body.append(docx_para("Code", docx_run(cs)));
                            break;
                        case BlockKind.QUOTE:
                            body.append(docx_para("Quote", bm + docx_inline(ctx, b.spans, b.tags)));
                            break;
                        case BlockKind.RULE:
                            body.append(docx_para("", "", "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"C0BFBC\"/></w:pBdr>"));
                            break;
                        case BlockKind.TABLE:
                            body.append(docx_table(b.table));
                            break;
                        case BlockKind.IMAGE:
                        case BlockKind.INK:
                        case BlockKind.EQUATION:
                            var deq = equation_of(b);
                            if (deq != null) {
                                deq.display = true;
                                body.append("<w:p>%s%s</w:p>\n".printf(bm, deq.to_omml()));
                                break;
                            }
                            body.append(docx_para("", bm + docx_image(ctx, b, zip)));
                            break;
                        case BlockKind.FILE:
                        case BlockKind.RECORDING:
                            var fs = new Span(_("Attachment: %s").printf(b.alt));
                            fs.italic = true;
                            body.append(docx_para("", docx_run(fs)));
                            break;
                        default:
                            if (level > 0) body.append(docx_para("Heading%d".printf(int.min(6, level)), bm + docx_inline(ctx, b.spans, b.tags)));
                            else body.append(docx_para("", bm + docx_inline(ctx, b.spans, b.tags), b.indent > 0 ? "<w:ind w:left=\"%d\"/>".printf(b.indent * 454) : ""));
                            break;
                    }
                }
            }
            string document = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
<w:body>
%s<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
</w:body>
</w:document>
""".printf(body.str);
            var rels = new StringBuilder("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
""");
            foreach (string r in ctx.rels) rels.append(r + "\n");
            rels.append("</Relationships>\n");
            zip.add_text("[Content_Types].xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Default Extension="png" ContentType="image/png"/>
<Default Extension="jpg" ContentType="image/jpeg"/>
<Default Extension="jpeg" ContentType="image/jpeg"/>
<Default Extension="gif" ContentType="image/gif"/>
<Default Extension="webp" ContentType="image/webp"/>
<Default Extension="bmp" ContentType="image/bmp"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
</Types>
""");
            zip.add_text("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
""");
            zip.add_text("word/document.xml", document);
            zip.add_text("word/_rels/document.xml.rels", rels.str);
            zip.add_text("word/styles.xml", DOCX_STYLES);
            zip.add_text("word/numbering.xml", numbering(ctx));
            return zip.finish();
        }

        private string docx_table(TableData t) {
            t.normalize();
            var sb = new StringBuilder();
            int cols = t.columns;
            int w = 9638 / int.max(1, cols);
            sb.append("<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>");
            foreach (string side in new string[] { "top", "left", "bottom", "right", "insideH", "insideV" }) sb.append("<w:%s w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>".printf(side));
            sb.append("</w:tblBorders></w:tblPr><w:tblGrid>");
            for (int c = 0; c < cols; c++) sb.append("<w:gridCol w:w=\"%d\"/>".printf(w));
            sb.append("</w:tblGrid>\n");
            for (int r = 0; r < t.rows.size; r++) {
                sb.append("<w:tr>");
                for (int c = 0; c < cols; c++) {
                    string shade = t.shade(r, c);
                    string tcpr = "<w:tcW w:w=\"%d\" w:type=\"dxa\"/>".printf(w);
                    if (shade != "") tcpr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"%s\"/>".printf(docx_color(shade));
                    var s = new Span(t.cell(r, c));
                    s.bold = r == 0;
                    string jc = t.aligns[c] == "center" ? "center" : t.aligns[c] == "right" ? "right" : "";
                    string ppr = jc != "" ? "<w:pPr><w:jc w:val=\"%s\"/></w:pPr>".printf(jc) : "";
                    sb.append("<w:tc><w:tcPr>%s</w:tcPr><w:p>%s%s</w:p></w:tc>".printf(tcpr, ppr, docx_run(s)));
                }
                sb.append("</w:tr>\n");
            }
            sb.append("</w:tbl>\n<w:p/>\n");
            return sb.str;
        }

        private string numbering(DocxContext ctx) {
            var sb = new StringBuilder("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:abstractNum w:abstractNumId="0">""");
            for (int l = 0; l < 9; l++) sb.append("<w:lvl w:ilvl=\"%d\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"%s\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"%d\" w:hanging=\"360\"/></w:pPr></w:lvl>".printf(l, l % 2 == 0 ? "•" : "◦", 720 + l * 360));
            sb.append("</w:abstractNum>\n<w:abstractNum w:abstractNumId=\"1\">");
            string[] fmts = { "decimal", "lowerLetter", "lowerRoman" };
            for (int l = 0; l < 9; l++) sb.append("<w:lvl w:ilvl=\"%d\"><w:start w:val=\"1\"/><w:numFmt w:val=\"%s\"/><w:lvlText w:val=\"%%%d.\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"%d\" w:hanging=\"360\"/></w:pPr></w:lvl>".printf(l, fmts[l % 3], l + 1, 720 + l * 360));
            sb.append("</w:abstractNum>\n<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>\n");
            foreach (string n in ctx.nums) sb.append(n + "\n");
            sb.append("</w:numbering>\n");
            return sb.str;
        }

        private const string DOCX_STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="80"/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="48"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="200"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="3"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="4"/></w:pPr><w:rPr><w:b/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:basedOn w:val="Normal"/><w:pPr><w:outlineLvl w:val="5"/></w:pPr><w:rPr><w:b/><w:i/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="567"/></w:pPr><w:rPr><w:i/><w:color w:val="5E5C64"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0"/><w:shd w:val="clear" w:color="auto" w:fill="F3F3F5"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/><w:sz w:val="20"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/></w:style>
<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/></w:style>
</w:styles>
""";
    }
}
