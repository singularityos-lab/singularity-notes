namespace Singularity.Apps.Notes {

    public class WebAccess : Object {
        public const string COOKIE = "notes_web";

        public Singularity.Notes.NoteStore store { get; construct; }
        public Notebooks notebooks { get; construct; }
        public string pin { get; private set; }
        public string key { get; private set; }
        public uint port { get; private set; default = 0; }
        public bool lan { get; private set; default = false; }
        public bool running { get; private set; default = false; }
        public signal void page_saved(string id);

        private Soup.Server? server = null;
        private Gee.HashSet<string> sessions = new Gee.HashSet<string>();
        private int failures = 0;

        public WebAccess(Singularity.Notes.NoteStore store, Notebooks notebooks) {
            Object(store: store, notebooks: notebooks);
            pin = "%06d".printf(Random.int_range(0, 1000000));
            key = Uuid.string_random().replace("-", "");
        }

        public void start(uint want, bool on_lan) throws Error {
            stop();
            server = new Soup.Server("server-header", "SingularityNotes");
            server.add_handler(null, handle);
            if (on_lan) server.listen_all(want, Soup.ServerListenOptions.IPV4_ONLY);
            else server.listen_local(want, Soup.ServerListenOptions.IPV4_ONLY);
            foreach (var uri in server.get_uris()) port = uri.get_port();
            lan = on_lan;
            running = true;
        }

        public void stop() {
            if (server != null) server.disconnect();
            server = null;
            sessions.clear();
            running = false;
        }

        public void renew() {
            pin = "%06d".printf(Random.int_range(0, 1000000));
            key = Uuid.string_random().replace("-", "");
            sessions.clear();
            failures = 0;
        }

        public static string lan_address() {
            string? fixed_address = Environment.get_variable("NOTES_LIVE_ADDRESS");
            if (fixed_address != null && fixed_address.strip() != "") return fixed_address.strip();
            try {
                var sock = new Socket(SocketFamily.IPV4, SocketType.DATAGRAM, SocketProtocol.UDP);
                sock.connect(new InetSocketAddress.from_string("192.0.2.1", 9));
                var local = sock.get_local_address() as InetSocketAddress;
                sock.close();
                if (local != null) {
                    string a = local.address.to_string();
                    if (a != "0.0.0.0") return a;
                }
            } catch (Error e) {
            }
            return "127.0.0.1";
        }

        public string address() {
            return "http://%s:%u/".printf(lan ? lan_address() : "127.0.0.1", port);
        }

        public string link() {
            return address() + "?key=" + key;
        }

        private static string esc(string s) {
            return Markup.escape_text(s);
        }

        private static string qarg(string s) {
            return Uri.escape_string(s, null, false);
        }

        private bool authorized(Soup.ServerMessage msg, HashTable<string, string>? query) {
            if (query != null && query.lookup("key") == key) {
                string sid = Uuid.string_random();
                sessions.add(sid);
                msg.get_response_headers().append("Set-Cookie", "%s=%s; Path=/; HttpOnly; SameSite=Strict".printf(COOKIE, sid));
                return true;
            }
            string? cookie = msg.get_request_headers().get_one("Cookie");
            if (cookie == null) return false;
            foreach (string part in cookie.split(";")) {
                string p = part.strip();
                if (p.has_prefix(COOKIE + "=") && sessions.contains(p.substring(COOKIE.length + 1))) return true;
            }
            return false;
        }

        private void respond(Soup.ServerMessage msg, uint status, string html) {
            msg.set_status(status, null);
            msg.get_response_headers().append("Cache-Control", "no-store");
            msg.get_response_headers().append("X-Frame-Options", "DENY");
            msg.get_response_headers().append("Content-Security-Policy", "default-src 'none'; img-src data:; style-src 'unsafe-inline'; form-action 'self'");
            msg.set_response("text/html; charset=utf-8", Soup.MemoryUse.COPY, html.data);
        }

        private void redirect(Soup.ServerMessage msg, string location) {
            msg.set_status(303, null);
            msg.get_response_headers().append("Location", location);
            msg.set_response("text/plain", Soup.MemoryUse.COPY, "".data);
        }

        private string page(string title, string body, string back = "") {
            var sb = new StringBuilder();
            sb.append("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
            sb.append("<title>%s</title>\n".printf(esc(title)));
            sb.append("<style>\n");
            sb.append(":root{--bg:#fafafb;--card:#ffffff;--fg:#1e1e22;--dim:#6b6a70;--line:#e3e3e7;--accent:#8a5cf5;--accent-fg:#ffffff}\n");
            sb.append("@media (prefers-color-scheme: dark){:root{--bg:#1d1d20;--card:#28282c;--fg:#ececf0;--dim:#a2a1a8;--line:#3a3a40;--accent:#a684ff;--accent-fg:#16161a}}\n");
            sb.append("*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif}\n");
            sb.append("header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:12px 16px;display:flex;gap:12px;align-items:center}\n");
            sb.append("header h1{font-size:18px;margin:0;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}\n");
            sb.append("main{max-width:48em;margin:0 auto;padding:16px}\n");
            sb.append("a{color:var(--accent);text-decoration:none}\n");
            sb.append(".button{display:inline-block;border:0;border-radius:999px;padding:8px 16px;background:var(--line);color:var(--fg);font:inherit;cursor:pointer}\n");
            sb.append(".button.primary{background:var(--accent);color:var(--accent-fg)}\n");
            sb.append(".group{background:var(--card);border:1px solid var(--line);border-radius:14px;margin:0 0 16px;overflow:hidden}\n");
            sb.append(".group h2{font-size:13px;font-weight:600;color:var(--dim);margin:0;padding:10px 16px 4px;text-transform:uppercase;letter-spacing:.04em}\n");
            sb.append(".row{display:block;padding:10px 16px;border-top:1px solid var(--line);color:var(--fg)}\n.row:first-of-type{border-top:0}\n");
            sb.append(".row small{display:block;color:var(--dim);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}\n");
            sb.append("input[type=search],input[type=password],input[type=text],textarea{width:100%;font:inherit;color:var(--fg);background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 12px}\n");
            sb.append("textarea{min-height:60vh;font-family:ui-monospace,monospace;font-size:14px;font-variant-ligatures:none}\n");
            sb.append("form.search{margin-bottom:16px}.actions{display:flex;gap:8px;margin:12px 0}\n");
            sb.append("article{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:4px 16px 16px}\n");
            sb.append("article img{max-width:100%;height:auto}table{border-collapse:collapse}td,th{border:1px solid var(--line);padding:4px 8px}\n");
            sb.append("blockquote{border-left:3px solid var(--line);margin:0;padding-left:12px;color:var(--dim)}pre{background:var(--bg);padding:8px;border-radius:8px;overflow:auto}\n");
            sb.append("li:has(> input[type=checkbox]){list-style:none;margin-left:-1.2em}.tag{color:var(--accent);font-weight:600;font-size:.85em}.done{text-decoration:line-through;color:var(--dim)}.note{color:var(--dim)}\n");
            sb.append("</style>\n</head>\n<body>\n<header>");
            if (back != "") sb.append("<a class=\"button\" href=\"%s\">%s</a>".printf(esc(back), esc(_("Back"))));
            sb.append("<h1>%s</h1></header>\n<main>\n".printf(esc(title)));
            sb.append(body);
            sb.append("\n</main>\n</body>\n</html>\n");
            return sb.str;
        }

        private bool hidden(Singularity.Notes.Note n) {
            return n.id == Singularity.Notes.NoteStore.QUICK_NOTE_ID || n.id.has_prefix(Singularity.Notes.NoteStore.WIDGET_PREFIX);
        }

        private string folder_label(string folder) {
            if (folder == "") return _("Unfiled");
            return folder.replace("/", " / ");
        }

        private string list_html(string query) {
            var sb = new StringBuilder();
            sb.append("<form class=\"search\" method=\"get\" action=\"/\"><input type=\"search\" name=\"q\" value=\"%s\" placeholder=\"%s\"></form>\n".printf(esc(query), esc(_("Search notes"))));
            var groups = new Gee.TreeMap<string, Gee.ArrayList<Singularity.Notes.Note>>();
            var notes = query != "" ? store.search(query) : store.all();
            foreach (var n in notes) {
                if (hidden(n)) continue;
                var list = groups[n.folder];
                if (list == null) {
                    list = new Gee.ArrayList<Singularity.Notes.Note>();
                    groups[n.folder] = list;
                }
                list.add(n);
            }
            if (groups.size == 0) sb.append("<p class=\"note\">%s</p>".printf(esc(query != "" ? _("No notes match your search.") : _("There are no notes yet."))));
            foreach (var e in groups.entries) {
                sb.append("<section class=\"group\"><h2>%s</h2>".printf(esc(folder_label(e.key))));
                e.value.sort((a, b) => a.modified > b.modified ? -1 : (a.modified < b.modified ? 1 : 0));
                foreach (var n in e.value) {
                    bool sealed = SectionLocks.is_locked_body(n.body);
                    string title = n.title != "" ? n.title : _("Untitled Page");
                    string sub = sealed ? _("Password protected") : new DateTime.from_unix_local(n.modified).format("%e %B %Y, %H:%M").strip();
                    sb.append("<a class=\"row\" href=\"/page?id=%s\">%s<small>%s</small></a>".printf(qarg(n.id), esc(title), esc(sub)));
                }
                sb.append("<div class=\"actions\" style=\"padding:0 16px 12px\"><a class=\"button\" href=\"/new?folder=%s\">%s</a></div></section>\n".printf(qarg(e.key), esc(_("New Page"))));
            }
            return page(_("Notes"), sb.str);
        }

        private string view_html(Singularity.Notes.Note n) {
            string title = n.title != "" ? n.title : _("Untitled Page");
            if (SectionLocks.is_locked_body(n.body)) {
                return page(title, "<p class=\"note\">%s</p>".printf(esc(_("This page is in a password-protected section. Open it on the computer to read it."))), "/");
            }
            var ex = new Exporter(store.dir);
            var ep = new ExportPage(n.id, title, n.created, n.body);
            var blocks = ep.blocks();
            if (blocks.size > 0 && blocks[0].kind == BlockKind.HEADING1) blocks.remove_at(0);
            var sb = new StringBuilder();
            sb.append("<div class=\"actions\"><a class=\"button primary\" href=\"/edit?id=%s\">%s</a></div>".printf(qarg(n.id), esc(_("Edit"))));
            sb.append("<article>%s</article>".printf(ex.html_blocks(blocks, true)));
            return page(title, sb.str, "/");
        }

        private string edit_html(Singularity.Notes.Note n, string notice = "") {
            string title = n.title != "" ? n.title : _("Untitled Page");
            var sb = new StringBuilder();
            if (notice != "") sb.append("<p class=\"note\">%s</p>".printf(esc(notice)));
            sb.append("<form method=\"post\" action=\"/edit?id=%s\">".printf(qarg(n.id)));
            sb.append("<input type=\"hidden\" name=\"base\" value=\"%s\">".printf(esc(Base64.encode(n.body.data))));
            sb.append("<textarea name=\"body\">%s</textarea>".printf(esc(n.body)));
            sb.append("<div class=\"actions\"><button class=\"button primary\" type=\"submit\">%s</button><a class=\"button\" href=\"/page?id=%s\">%s</a></div></form>".printf(esc(_("Save")), qarg(n.id), esc(_("Cancel"))));
            return page(title, sb.str, "/page?id=" + qarg(n.id));
        }

        private string login_html(bool failed) {
            var sb = new StringBuilder();
            sb.append("<p>%s</p>".printf(esc(_("Enter the code shown in Notes on your computer."))));
            if (failed) sb.append("<p class=\"note\">%s</p>".printf(esc(_("That code is not right."))));
            sb.append("<form method=\"post\" action=\"/login\"><input type=\"password\" inputmode=\"numeric\" autocomplete=\"one-time-code\" name=\"pin\" autofocus><div class=\"actions\"><button class=\"button primary\" type=\"submit\">%s</button></div></form>".printf(esc(_("Open Notes"))));
            return page(_("Notes"), sb.str);
        }

        private HashTable<weak string, weak string> form_of(Soup.ServerMessage msg) {
            var body = msg.get_request_body().flatten();
            string text = ((string) body.get_data()).make_valid((ssize_t) body.get_size());
            return Soup.Form.decode(text);
        }

        private void handle(Soup.Server srv, Soup.ServerMessage msg, string path, HashTable<string, string>? query) {
            string method = msg.get_method();
            if (path == "/login" && method == "POST") {
                var form = form_of(msg);
                if (failures < 10 && form.lookup("pin") == pin) {
                    string sid = Uuid.string_random();
                    sessions.add(sid);
                    msg.get_response_headers().append("Set-Cookie", "%s=%s; Path=/; HttpOnly; SameSite=Strict".printf(COOKIE, sid));
                    redirect(msg, "/");
                } else {
                    failures++;
                    respond(msg, 403, login_html(true));
                }
                return;
            }
            if (!authorized(msg, query)) {
                respond(msg, 401, login_html(false));
                return;
            }
            string? id = query != null ? query.lookup("id") : null;
            Singularity.Notes.Note? note = id != null ? store.lookup(id) : null;
            switch (path) {
                case "/":
                    respond(msg, 200, list_html(query != null ? (query.lookup("q") ?? "") : ""));
                    return;
                case "/page":
                    if (note == null) break;
                    respond(msg, 200, view_html(note));
                    return;
                case "/edit":
                    if (note == null || SectionLocks.is_locked_body(note.body)) break;
                    if (method == "POST") {
                        var form = form_of(msg);
                        string mine = (form.lookup("body") ?? "").replace("\r\n", "\n");
                        string base_text = (string) Base64.decode(form.lookup("base") ?? "");
                        string current = note.body;
                        string? merged = current == base_text ? mine : Singularity.Notes.LineMerge.merge(base_text, mine, current);
                        if (merged == null) {
                            var copy = note.copy();
                            copy.body = mine;
                            respond(msg, 409, edit_html(copy, _("This page changed on the computer while you were editing. Review your text and save again.")));
                            return;
                        }
                        try {
                            var n = note.copy();
                            n.body = merged;
                            store.save(n);
                            page_saved(n.id);
                        } catch (Error e) {
                            respond(msg, 500, page(_("Notes"), "<p class=\"note\">%s</p>".printf(esc(e.message)), "/"));
                            return;
                        }
                        redirect(msg, "/page?id=" + qarg(note.id));
                        return;
                    }
                    respond(msg, 200, edit_html(note));
                    return;
                case "/new":
                    string folder = query != null ? (query.lookup("folder") ?? "") : "";
                    if (folder != "" && notebooks.is_locked(folder)) break;
                    try {
                        var n = store.create("# %s\n\n".printf(_("Untitled Page")), folder);
                        page_saved(n.id);
                        redirect(msg, "/edit?id=" + qarg(n.id));
                    } catch (Error e) {
                        respond(msg, 500, page(_("Notes"), "<p class=\"note\">%s</p>".printf(esc(e.message)), "/"));
                    }
                    return;
                default:
                    break;
            }
            respond(msg, 404, page(_("Notes"), "<p class=\"note\">%s</p>".printf(esc(_("This page does not exist."))), "/"));
        }
    }
}
