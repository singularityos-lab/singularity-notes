namespace Singularity.Apps.Notes {

    public class ImportedNote : Object {
        public string title = "";
        public string body = "";
        public int64 created = 0;
        public int64 modified = 0;
        public Gee.ArrayList<string> tags = new Gee.ArrayList<string>();
    }

    public class Clipper : Object {
        public static Soup.Session session() {
            var s = new Soup.Session();
            s.user_agent = "Mozilla/5.0 (X11; Linux x86_64) SingularityNotes/1.0";
            s.timeout = 30;
            return s;
        }

        public static bool is_url(string text) {
            string t = text.strip();
            return (t.has_prefix("http://") || t.has_prefix("https://")) && !t.contains(" ") && !t.contains("\n");
        }

        public static async ImportedNote clip(string url, string notes_dir, string note_id, Cancellable? cancellable) throws Error {
            var s = session();
            var msg = new Soup.Message("GET", url);
            if (msg == null) throw new IOError.INVALID_ARGUMENT(_("The address is not valid"));
            var bytes = yield s.send_and_read_async(msg, Priority.DEFAULT, cancellable);
            if (msg.status_code >= 400) throw new IOError.FAILED(_("The page answered with error %u").printf(msg.status_code));
            string? ctype = msg.response_headers.get_content_type(null);
            var result = new ImportedNote();
            if (ctype != null && ctype.has_prefix("image/")) {
                string rel = yield save_bytes(bytes, url, notes_dir, note_id);
                result.title = Path.get_basename(url);
                result.body = "![%s](%s)".printf(RichText.escape(result.title), rel);
            } else {
                string html = ((string) bytes.get_data()).make_valid((ssize_t) bytes.get_size());
                var conv = new HtmlConverter();
                conv.base_url = url;
                conv.convert(html, true);
                yield fetch_images(conv, notes_dir, note_id, s, cancellable);
                result.title = conv.title != "" ? conv.title : url;
                result.body = RichText.render(conv.blocks);
            }
            var src = new Block(BlockKind.PARAGRAPH);
            var em = new Span(_("Clipped from "));
            em.italic = true;
            src.add(em);
            var link = new Span(url, false, true, url.replace(" ", "%20").replace(")", "%29"));
            src.add(link);
            var when = new Span(_(" on %s").printf(new DateTime.now_local().format("%x %H:%M")));
            when.italic = true;
            src.add(when);
            result.body = RichText.render_block(src) + "\n\n" + result.body;
            return result;
        }

        private static async string save_bytes(Bytes bytes, string url, string notes_dir, string note_id) throws Error {
            string name = Path.get_basename(url.split("?")[0]);
            if (name == "" || !name.contains(".")) name = "picture.png";
            string dir = Attachments.dir_for(notes_dir, note_id);
            DirUtils.create_with_parents(dir, 0700);
            string target = Attachments.unique_path(dir, name);
            FileUtils.set_data(target, bytes.get_data());
            FileUtils.chmod(target, 0600);
            return Attachments.relative(note_id, target);
        }

        public static async void fetch_images(HtmlConverter conv, string notes_dir, string note_id, Soup.Session? session, Cancellable? cancellable) {
            var s = session ?? Clipper.session();
            int n = 0;
            foreach (var img in conv.images) {
                if (n >= 60) break;
                string src = img.src;
                try {
                    if (src.has_prefix("data:")) {
                        int comma = src.index_of(",");
                        if (comma < 0 || !src.substring(0, comma).contains("base64")) continue;
                        var data = Base64.decode(src.substring(comma + 1));
                        string ext = src.has_prefix("data:image/jpeg") ? "jpg" : src.has_prefix("data:image/gif") ? "gif" : src.has_prefix("data:image/svg") ? "svg" : "png";
                        img.block.image = yield save_bytes(new Bytes(data), "picture." + ext, notes_dir, note_id);
                    } else if (src.has_prefix("file://")) {
                        string? path = File.new_for_uri(src).get_path();
                        if (path == null || !FileUtils.test(path, FileTest.IS_REGULAR) || !Attachments.is_image(path)) continue;
                        img.block.image = Attachments.import_file(notes_dir, note_id, File.new_for_path(path));
                    } else if (src.has_prefix("http://") || src.has_prefix("https://")) {
                        var msg = new Soup.Message("GET", src);
                        if (msg == null) continue;
                        var bytes = yield s.send_and_read_async(msg, Priority.DEFAULT, cancellable);
                        if (msg.status_code >= 400 || bytes.get_size() == 0) continue;
                        string? ct = msg.response_headers.get_content_type(null);
                        if (ct != null && !ct.has_prefix("image/")) continue;
                        img.block.image = yield save_bytes(bytes, src, notes_dir, note_id);
                    }
                    n++;
                } catch (Error e) {
                }
            }
            foreach (var img in conv.images) {
                if (!img.block.image.has_prefix("attachments/")) {
                    img.block.kind = BlockKind.PARAGRAPH;
                    string label = img.block.alt != "" ? img.block.alt : _("Picture");
                    if (img.block.image.has_prefix("http")) img.block.add(new Span(label, false, false, img.block.image));
                    else img.block.add(new Span(label));
                }
            }
        }
    }

    public class Importer : Object {
        public static bool supported(string path) {
            string p = path.down();
            return p.has_suffix(".enex") || p.has_suffix(".md") || p.has_suffix(".markdown") || p.has_suffix(".txt")
                || p.has_suffix(".html") || p.has_suffix(".htm") || p.has_suffix(".docx") || p.has_suffix(".odt") || p.has_suffix(".one");
        }

        public static async Gee.List<ImportedNote> import_file(File file, Singularity.Notes.NoteStore store, string folder) throws Error {
            string path = file.get_path() ?? "";
            string p = path.down();
            var list = new Gee.ArrayList<ImportedNote>();
            uint8[] data;
            FileUtils.get_data(path, out data);
            string name = Path.get_basename(path);
            int dot = name.last_index_of(".");
            string stem = dot > 0 ? name.substring(0, dot) : name;
            if (p.has_suffix(".enex")) {
                list.add_all(yield enex(((string) data).make_valid((ssize_t) data.length), store, folder));
                return list;
            }
            if (p.has_suffix(".one")) {
                list.add_all(yield OneNoteImporter.import_data(data, store, folder));
                return list;
            }
            var n = new ImportedNote();
            n.title = stem;
            var note = store.create("", folder);
            if (p.has_suffix(".html") || p.has_suffix(".htm")) {
                var conv = new HtmlConverter();
                conv.base_url = file.get_uri();
                conv.convert(((string) data).make_valid((ssize_t) data.length), false);
                foreach (var img in conv.images) {
                    if (img.src.has_prefix("file://")) {
                        try {
                            img.block.image = Attachments.import_file(store.dir, note.id, File.new_for_uri(img.src));
                        } catch (Error e) {
                        }
                    }
                }
                yield Clipper.fetch_images(conv, store.dir, note.id, null, null);
                if (conv.title != "") n.title = conv.title;
                n.body = RichText.render(conv.blocks);
            } else if (p.has_suffix(".docx")) {
                n.body = docx_to_markdown(data, store.dir, note.id);
            } else if (p.has_suffix(".odt")) {
                n.body = odt_to_markdown(data, store.dir, note.id);
            } else {
                string text = ((string) data).make_valid((ssize_t) data.length);
                var d = PageDoc.parse(text);
                if (d.title != "") {
                    n.title = d.title;
                    n.body = d.body;
                } else {
                    n.body = text;
                }
                string base_dir = Path.get_dirname(path);
                foreach (string target in NoteAttachments.links(n.body)) {
                    if (target.contains("://")) continue;
                    string src = Path.is_absolute(target) ? target : Path.build_filename(base_dir, Uri.unescape_string(target) ?? target);
                    if (!FileUtils.test(src, FileTest.IS_REGULAR)) continue;
                    try {
                        string rel = Attachments.import_file(store.dir, note.id, File.new_for_path(src));
                        n.body = n.body.replace("](" + target + ")", "](" + rel + ")");
                    } catch (Error e) {
                    }
                }
            }
            var doc = new PageDoc();
            doc.title = n.title;
            doc.body = n.body;
            note.body = doc.serialize();
            store.save(note, true);
            list.add(n);
            return list;
        }

        private static int64 enex_time(string t) {
            if (t.length < 15) return 0;
            string iso = "%s-%s-%sT%s:%s:%sZ".printf(t.substring(0, 4), t.substring(4, 2), t.substring(6, 2), t.substring(9, 2), t.substring(11, 2), t.substring(13, 2));
            var dt = new DateTime.from_iso8601(iso, new TimeZone.utc());
            return dt != null ? dt.to_unix() : 0;
        }

        public static async Gee.List<ImportedNote> enex(string xml, Singularity.Notes.NoteStore store, string folder) throws Error {
            var list = new Gee.ArrayList<ImportedNote>();
            Xml.Doc* doc = Xml.Parser.read_memory(xml, xml.length, null, null, Xml.ParserOption.NOENT | Xml.ParserOption.NONET | Xml.ParserOption.HUGE | Xml.ParserOption.RECOVER | Xml.ParserOption.NOERROR | Xml.ParserOption.NOWARNING);
            if (doc == null) throw new IOError.INVALID_DATA(_("The Evernote file could not be read"));
            Xml.Node* root = doc->get_root_element();
            for (Xml.Node* n = root != null ? root->children : null; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE || n->name != "note") continue;
                var imported = new ImportedNote();
                string content = "";
                var resource_list = new Gee.ArrayList<Xml.Node*>();
                for (Xml.Node* c = n->children; c != null; c = c->next) {
                    if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                    switch (c->name) {
                        case "title": imported.title = c->get_content().strip(); break;
                        case "content": content = c->get_content(); break;
                        case "created": imported.created = enex_time(c->get_content().strip()); break;
                        case "updated": imported.modified = enex_time(c->get_content().strip()); break;
                        case "tag": imported.tags.add(c->get_content().strip()); break;
                        case "resource": resource_list.add(c); break;
                        default: break;
                    }
                }
                var note = store.create("", folder);
                var saved = new Gee.HashMap<string, string>();
                foreach (var r in resource_list) {
                    string data_b64 = "";
                    string mime = "";
                    string fname = "";
                    for (Xml.Node* c = r->children; c != null; c = c->next) {
                        if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (c->name == "data") data_b64 = c->get_content();
                        else if (c->name == "mime") mime = c->get_content().strip();
                        else if (c->name == "resource-attributes") {
                            for (Xml.Node* a = c->children; a != null; a = a->next) if (a->type == Xml.ElementType.ELEMENT_NODE && a->name == "file-name") fname = a->get_content().strip();
                        }
                    }
                    if (data_b64 == "") continue;
                    var raw = Base64.decode(data_b64.replace("\n", "").replace("\r", "").replace(" ", ""));
                    string hash = Checksum.compute_for_data(ChecksumType.MD5, raw);
                    if (fname == "") {
                        string ext = mime.has_suffix("jpeg") ? "jpg" : mime.contains("/") ? mime.substring(mime.index_of("/") + 1) : "bin";
                        fname = "resource-%s.%s".printf(hash.substring(0, 8), ext);
                    }
                    string dir = Attachments.dir_for(store.dir, note.id);
                    DirUtils.create_with_parents(dir, 0700);
                    string target = Attachments.unique_path(dir, fname);
                    FileUtils.set_data(target, raw);
                    saved[hash] = Attachments.relative(note.id, target);
                }
                var conv = new HtmlConverter();
                conv.convert(content, false);
                foreach (var img in conv.images) {
                    if (!img.src.has_prefix("enex-hash:")) continue;
                    string hash = img.src.substring(10);
                    string? rel = saved[hash];
                    if (rel == null) {
                        img.block.kind = BlockKind.PARAGRAPH;
                        continue;
                    }
                    img.block.image = rel;
                    if (!Attachments.is_image(rel)) {
                        img.block.kind = BlockKind.FILE;
                        img.block.alt = Path.get_basename(rel);
                    }
                }
                yield Clipper.fetch_images(conv, store.dir, note.id, null, null);
                imported.body = RichText.render(conv.blocks);
                if (imported.tags.size > 0) {
                    var tl = new Block(BlockKind.PARAGRAPH);
                    var s = new Span(_("Tags: %s").printf(string.joinv(", ", imported.tags.to_array())));
                    s.italic = true;
                    tl.add(s);
                    imported.body += "\n" + RichText.render_block(tl);
                }
                var pd = new PageDoc();
                pd.title = imported.title;
                pd.body = imported.body;
                note.body = pd.serialize();
                if (imported.created > 0) note.created = imported.created;
                store.save(note, false);
                if (imported.modified > 0) {
                    note.modified = imported.modified;
                    store.save(note, false);
                }
                list.add(imported);
            }
            delete doc;
            return list;
        }

        private static string xml_text_runs(Xml.Node* p, string ns_text, bool odt) {
            var sb = new StringBuilder();
            for (Xml.Node* c = p->children; c != null; c = c->next) {
                if (c->type == Xml.ElementType.TEXT_NODE) {
                    sb.append(RichText.escape(c->content ?? ""));
                    continue;
                }
                if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (!odt && c->name == "r") {
                    bool b = false, i = false, u = false, s = false;
                    string text = "";
                    for (Xml.Node* r = c->children; r != null; r = r->next) {
                        if (r->type != Xml.ElementType.ELEMENT_NODE) continue;
                        if (r->name == "rPr") {
                            for (Xml.Node* q = r->children; q != null; q = q->next) {
                                if (q->type != Xml.ElementType.ELEMENT_NODE) continue;
                                string? val = q->get_ns_prop("val", "http://schemas.openxmlformats.org/wordprocessingml/2006/main");
                                bool on = val == null || (val != "false" && val != "0" && val != "none");
                                if (q->name == "b") b = on;
                                else if (q->name == "i") i = on;
                                else if (q->name == "u") u = on;
                                else if (q->name == "strike") s = on;
                            }
                        } else if (r->name == "t") {
                            text += r->get_content();
                        } else if (r->name == "tab") {
                            text += " ";
                        } else if (r->name == "br") {
                            text += " ";
                        }
                    }
                    if (text == "") continue;
                    var span = new Span(text, b, i);
                    span.underline = u;
                    span.strike = s;
                    var l = new Gee.ArrayList<Span>();
                    l.add(span);
                    sb.append(RichText.render_inline(l));
                } else if (!odt && c->name == "hyperlink") {
                    sb.append(xml_text_runs(c, ns_text, odt));
                } else if (odt && (c->name == "span" || c->name == "a")) {
                    sb.append(xml_text_runs(c, ns_text, odt));
                } else if (odt && c->name == "s") {
                    sb.append(" ");
                } else if (odt && (c->name == "tab" || c->name == "line-break")) {
                    sb.append(" ");
                }
            }
            return sb.str;
        }

        public static string docx_to_markdown(uint8[] data, string notes_dir, string note_id) throws Error {
            var zip = new ZipReader(data);
            string? xml = zip.read_text("word/document.xml");
            if (xml == null) throw new IOError.INVALID_DATA(_("This is not a Word document"));
            Xml.Doc* doc = Xml.Parser.read_memory(xml, xml.length, null, null, Xml.ParserOption.NONET | Xml.ParserOption.HUGE);
            if (doc == null) throw new IOError.INVALID_DATA(_("This is not a Word document"));
            var lines = new Gee.ArrayList<string>();
            Xml.Node* body = null;
            for (Xml.Node* n = doc->get_root_element()->children; n != null; n = n->next) if (n->type == Xml.ElementType.ELEMENT_NODE && n->name == "body") body = n;
            for (Xml.Node* p = body != null ? body->children : null; p != null; p = p->next) {
                if (p->type != Xml.ElementType.ELEMENT_NODE) continue;
                if (p->name == "p") {
                    string style = "";
                    bool list = false;
                    int ilvl = 0;
                    for (Xml.Node* c = p->children; c != null; c = c->next) {
                        if (c->type != Xml.ElementType.ELEMENT_NODE || c->name != "pPr") continue;
                        for (Xml.Node* q = c->children; q != null; q = q->next) {
                            if (q->type != Xml.ElementType.ELEMENT_NODE) continue;
                            if (q->name == "pStyle") style = q->get_ns_prop("val", "http://schemas.openxmlformats.org/wordprocessingml/2006/main") ?? "";
                            if (q->name == "numPr") {
                                list = true;
                                for (Xml.Node* z = q->children; z != null; z = z->next) if (z->type == Xml.ElementType.ELEMENT_NODE && z->name == "ilvl") ilvl = int.parse(z->get_ns_prop("val", "http://schemas.openxmlformats.org/wordprocessingml/2006/main") ?? "0");
                            }
                        }
                    }
                    string text = xml_text_runs(p, "", false);
                    string s = style.down();
                    if (s == "title") lines.add("## " + text);
                    else if (s.has_prefix("heading")) lines.add(string.nfill(int.min(6, int.parse(s.substring(7)) + 1), '#') + " " + text);
                    else if (list) lines.add(string.nfill(ilvl * 4, ' ') + "- " + text);
                    else if (s == "quote") lines.add("> " + text);
                    else lines.add(text);
                } else if (p->name == "tbl") {
                    var t = new TableData();
                    for (Xml.Node* tr = p->children; tr != null; tr = tr->next) {
                        if (tr->type != Xml.ElementType.ELEMENT_NODE || tr->name != "tr") continue;
                        var row = new Gee.ArrayList<string>();
                        for (Xml.Node* tc = tr->children; tc != null; tc = tc->next) {
                            if (tc->type == Xml.ElementType.ELEMENT_NODE && tc->name == "tc") row.add(tc->get_content().strip());
                        }
                        t.rows.add(row);
                    }
                    if (t.rows.size > 0) lines.add(RichText.render_table(t));
                }
            }
            delete doc;
            foreach (string name in zip.names()) {
                if (!name.has_prefix("word/media/")) continue;
                var raw = zip.read(name);
                if (raw == null) continue;
                string dir = Attachments.dir_for(notes_dir, note_id);
                DirUtils.create_with_parents(dir, 0700);
                string target = Attachments.unique_path(dir, Path.get_basename(name));
                FileUtils.set_data(target, raw);
                lines.add("![%s](%s)".printf(Path.get_basename(name), Attachments.relative(note_id, target)));
            }
            return string.joinv("\n", lines.to_array());
        }

        public static string odt_to_markdown(uint8[] data, string notes_dir, string note_id) throws Error {
            var zip = new ZipReader(data);
            string? xml = zip.read_text("content.xml");
            if (xml == null) throw new IOError.INVALID_DATA(_("This is not an OpenDocument text"));
            Xml.Doc* doc = Xml.Parser.read_memory(xml, xml.length, null, null, Xml.ParserOption.NONET | Xml.ParserOption.HUGE);
            if (doc == null) throw new IOError.INVALID_DATA(_("This is not an OpenDocument text"));
            var lines = new Gee.ArrayList<string>();
            odt_walk(doc->get_root_element(), lines, 0, zip, notes_dir, note_id);
            delete doc;
            return string.joinv("\n", lines.to_array());
        }

        private static void odt_walk(Xml.Node* node, Gee.ArrayList<string> lines, int depth, ZipReader zip, string notes_dir, string note_id) {
            for (Xml.Node* n = node->children; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                switch (n->name) {
                    case "h":
                        string lvl = n->get_ns_prop("outline-level", "urn:oasis:names:tc:opendocument:xmlns:text:1.0") ?? "1";
                        lines.add(string.nfill(int.min(6, int.parse(lvl) + 1), '#') + " " + xml_text_runs(n, "", true));
                        break;
                    case "p":
                        if (depth > 0) lines.add(string.nfill((depth - 1) * 4, ' ') + "- " + xml_text_runs(n, "", true));
                        else lines.add(xml_text_runs(n, "", true));
                        for (Xml.Node* f = n->children; f != null; f = f->next) {
                            if (f->type != Xml.ElementType.ELEMENT_NODE || f->name != "frame") continue;
                            for (Xml.Node* im = f->children; im != null; im = im->next) {
                                if (im->type != Xml.ElementType.ELEMENT_NODE || im->name != "image") continue;
                                string? href = im->get_ns_prop("href", "http://www.w3.org/1999/xlink");
                                if (href == null) continue;
                                try {
                                    var raw = zip.read(href);
                                    if (raw == null) continue;
                                    string dir = Attachments.dir_for(notes_dir, note_id);
                                    DirUtils.create_with_parents(dir, 0700);
                                    string target = Attachments.unique_path(dir, Path.get_basename(href));
                                    FileUtils.set_data(target, raw);
                                    lines.add("![%s](%s)".printf(Path.get_basename(href), Attachments.relative(note_id, target)));
                                } catch (Error e) {
                                }
                            }
                        }
                        break;
                    case "list":
                        odt_walk(n, lines, depth + 1, zip, notes_dir, note_id);
                        break;
                    case "table":
                        var t = new TableData();
                        for (Xml.Node* tr = n->children; tr != null; tr = tr->next) {
                            if (tr->type != Xml.ElementType.ELEMENT_NODE || tr->name != "table-row") continue;
                            var row = new Gee.ArrayList<string>();
                            for (Xml.Node* tc = tr->children; tc != null; tc = tc->next) {
                                if (tc->type == Xml.ElementType.ELEMENT_NODE && tc->name == "table-cell") row.add(tc->get_content().strip());
                            }
                            t.rows.add(row);
                        }
                        if (t.rows.size > 0) lines.add(RichText.render_table(t));
                        break;
                    default:
                        odt_walk(n, lines, depth, zip, notes_dir, note_id);
                        break;
                }
            }
        }
    }
}
