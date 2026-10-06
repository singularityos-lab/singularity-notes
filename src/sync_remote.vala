namespace Singularity.Apps.Notes {

    public errordomain RemoteError {
        CHANGED,
        FAILED
    }

    public class Presence : Object {
        public string name { get; construct; }
        public string page { get; construct; }
        public int64 time { get; construct; }

        public Presence(string name, string page, int64 time) {
            Object(name: name, page: page, time: time);
        }
    }

    public class RemoteNote : Object {
        public string remote_id { get; set; default = ""; }
        public string etag { get; set; default = ""; }
        public int64 modified { get; set; default = 0; }
        public NoteState? state { get; set; default = null; }
    }

    public interface NotesRemote : Object {
        public abstract string kind { get; }
        public abstract async Gee.List<RemoteNote> list(Gee.Map<string, string> known_etags, Cancellable? cancellable) throws Error;
        public abstract async RemoteNote create(string local_id, NoteState state, int64 modified, Cancellable? cancellable) throws Error;
        public abstract async RemoteNote update(string remote_id, string etag, NoteState state, int64 modified, Cancellable? cancellable) throws Error;
        public abstract async void remove(string remote_id, string etag, Cancellable? cancellable) throws Error;

        public virtual async string localize(string remote_id, string local_id, NoteState state, string notes_dir, Cancellable? cancellable) throws Error {
            return state.content;
        }

        public virtual async NoteState publish(string local_id, string remote_id, NoteState state, string notes_dir, Cancellable? cancellable) throws Error {
            return state;
        }

        public virtual async string? fetch_meta(Cancellable? cancellable) throws Error {
            return null;
        }

        public virtual async void put_meta(string text, Cancellable? cancellable) throws Error {
        }
    }

    public class NoteAttachments : Object {
        public const string PROPFIND_NAMES = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>""";

        public static Gee.List<string> links(string content) {
            var list = new Gee.ArrayList<string>();
            try {
                var re = new Regex("!\\[[^\\]]*\\]\\(([^)\\s]+)\\)");
                MatchInfo info;
                if (re.match(content, 0, out info)) {
                    do {
                        string target = info.fetch(1);
                        if (!list.contains(target)) list.add(target);
                    } while (info.next());
                }
                var more = new Regex("(?:\\]\\(|src=\"|ink=|locked=)((?:attachments/|\\.attachments\\.)[^)\\s\"]+)");
                if (more.match(content, 0, out info)) {
                    do {
                        string target = info.fetch(1);
                        if (!list.contains(target)) list.add(target);
                    } while (info.next());
                }
            } catch (RegexError e) {
            }
            return list;
        }

        public static string[] sidecars(string name) {
            string[] out_list = {};
            if (name.has_prefix("recording-")) out_list += name + ".json";
            if (name.has_prefix("equation-")) {
                int dot = name.last_index_of(".");
                string stem = dot > 0 ? name.substring(0, dot) : name;
                out_list += stem + ".tex";
                out_list += stem + ".mml";
            }
            return out_list;
        }

        public static void add_with_sidecars(Gee.Map<string, string> files, string name, string path) {
            files[name] = path;
            foreach (string side in sidecars(name)) {
                string sp = Path.build_filename(Path.get_dirname(path), side);
                if (FileUtils.test(sp, FileTest.IS_REGULAR)) files[side] = sp;
            }
        }

        public static string replace_link(string content, string from, string to) {
            return content.replace("](" + from + ")", "](" + to + ")").replace("src=\"" + from + "\"", "src=\"" + to + "\"").replace("ink=" + from, "ink=" + to).replace("locked=" + from, "locked=" + to);
        }

        public static bool safe_name(string name) {
            if (name == "" || name.length > 255 || name.has_prefix(".")) return false;
            return !name.contains("/") && !name.contains("\\") && !name.contains("\n");
        }

        public static string local_name(string name) {
            return name.replace(" ", "-").replace("(", "").replace(")", "").replace("[", "").replace("]", "");
        }

        public static string escape_path(string path) {
            string[] parts = {};
            foreach (string p in path.split("/")) if (p != "") parts += Uri.escape_string(p, null, false);
            return string.joinv("/", parts);
        }

        public static string? local_link(string target, out string id, out string name) {
            id = "";
            name = "";
            if (!target.has_prefix("attachments/")) return null;
            string[] parts = target.split("/");
            if (parts.length != 3) return null;
            id = parts[1];
            name = Uri.unescape_string(parts[2]) ?? "";
            if (!Singularity.Notes.NoteStore.valid_id(id) || !safe_name(name)) return null;
            return target;
        }

        public static async void download(Singularity.Accounts.DavClient dav, string url, string target, Cancellable? cancellable) throws Error {
            var got = yield dav.get_resource(url, cancellable);
            DirUtils.create_with_parents(Path.get_dirname(target), 0700);
            FileUtils.set_data(target, got.body.get_data());
            FileUtils.chmod(target, 0600);
        }

        public static async Gee.Set<string>? remote_names(Singularity.Accounts.DavClient dav, string folder_url, Cancellable? cancellable) throws Error {
            Singularity.Accounts.Multistatus ms;
            try {
                ms = yield dav.propfind(folder_url, "1", PROPFIND_NAMES, cancellable);
            } catch (Singularity.Accounts.AccountsError.NOT_FOUND e) {
                return null;
            }
            var set = new Gee.HashSet<string>();
            foreach (var resp in ms.responses) {
                if (resp.removed || resp.is_type(Singularity.Accounts.NS_DAV, "collection")) continue;
                string href = resp.href;
                if (href.has_suffix("/")) continue;
                set.add(Uri.unescape_string(href.substring(href.last_index_of("/") + 1)) ?? "");
            }
            return set;
        }

        public static async void ensure_folders(Singularity.Accounts.DavClient dav, string root, string path, Cancellable? cancellable) throws Error {
            string url = root;
            foreach (string p in path.split("/")) {
                if (p == "") continue;
                url += Uri.escape_string(p, null, false) + "/";
                var response = yield dav.http.send("MKCOL", url, null, null, null, cancellable);
                if (response.status == 201 || response.status == 405) continue;
                Singularity.Accounts.HttpClient.check(response, "MKCOL");
            }
        }

        public static async void upload_missing(Singularity.Accounts.DavClient dav, string root, string folder_path,
                                                Gee.Map<string, string> files, Cancellable? cancellable) throws Error {
            string folder_url = root + escape_path(folder_path) + "/";
            var existing = yield remote_names(dav, folder_url, cancellable);
            if (existing == null) {
                yield ensure_folders(dav, root, folder_path, cancellable);
                existing = new Gee.HashSet<string>();
            }
            foreach (var e in files.entries) {
                if (existing.contains(e.key)) continue;
                uint8[] data;
                FileUtils.get_data(e.value, out data);
                bool uncertain;
                string mime = ContentType.get_mime_type(ContentType.guess(e.key, data, out uncertain)) ?? "application/octet-stream";
                yield dav.put(folder_url + Uri.escape_string(e.key, null, false), mime, new Bytes(data), null, false, cancellable);
            }
        }
    }

    public class NextcloudNotesRemote : Object, NotesRemote {
        private Singularity.Accounts.HttpClient http;
        private string root;
        private Singularity.Accounts.DavClient? files = null;
        private string files_root = "";
        private string? notes_path = null;

        public string kind { get { return "nextcloud-notes"; } }

        public NextcloudNotesRemote(Singularity.Accounts.Account account) {
            http = new Singularity.Accounts.HttpClient(account, Singularity.Accounts.Capability.NOTES);
            root = account.get_endpoint("notes") ?? "";
            if (!root.has_suffix("/")) root += "/";
            string? webdav = account.get_endpoint("webdav");
            if (webdav != null && webdav != "" && account.has_capability(Singularity.Accounts.Capability.FILES)) {
                files = new Singularity.Accounts.DavClient(new Singularity.Accounts.HttpClient(account, Singularity.Accounts.Capability.FILES));
                files_root = webdav.has_suffix("/") ? webdav : webdav + "/";
            }
        }

        private async string folder_path(string category, Cancellable? cancellable) {
            if (notes_path == null) {
                notes_path = "Notes";
                try {
                    var headers = new HashTable<string, string>(str_hash, str_equal);
                    headers.insert("Accept", "application/json");
                    var response = yield http.send("GET", root + "settings", null, null, headers, cancellable);
                    if (response.ok) {
                        var node = parse(response);
                        if (node != null && node.get_node_type() == Json.NodeType.OBJECT && node.get_object().has_member("notesPath")) {
                            string p = node.get_object().get_string_member("notesPath").strip();
                            while (p.has_prefix("/")) p = p.substring(1);
                            while (p.has_suffix("/")) p = p.substring(0, p.length - 1);
                            if (p != "" && !p.contains("..")) notes_path = p;
                        }
                    }
                } catch (Error e) {
                }
            }
            string path = notes_path;
            if (category != "" && !category.contains("..")) path += "/" + category;
            return path;
        }

        public async string localize(string remote_id, string local_id, NoteState state, string notes_dir, Cancellable? cancellable) throws Error {
            string content = state.content;
            if (!content.contains("](.attachments.")) return content;
            string? folder = null;
            foreach (string target in NoteAttachments.links(content)) {
                if (!target.has_prefix(".attachments.")) continue;
                int slash = target.index_of("/");
                if (slash < 0 || target.index_of("/", slash + 1) >= 0) continue;
                string dir = target.substring(0, slash);
                string name = Uri.unescape_string(target.substring(slash + 1)) ?? "";
                string local = NoteAttachments.local_name(name);
                if (!NoteAttachments.safe_name(name) || !NoteAttachments.safe_name(local)) continue;
                string path = Path.build_filename(notes_dir, "attachments", local_id, local);
                if (!FileUtils.test(path, FileTest.EXISTS)) {
                    if (files == null) continue;
                    if (folder == null) folder = yield folder_path(state.folder, cancellable);
                    try {
                        yield NoteAttachments.download(files, files_root + NoteAttachments.escape_path(folder + "/" + dir + "/" + name), path, cancellable);
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                        warning("notes: cannot download the attachment %s: %s", name, e.message);
                        continue;
                    }
                    foreach (string side in NoteAttachments.sidecars(name)) {
                        try {
                            yield NoteAttachments.download(files, files_root + NoteAttachments.escape_path(folder + "/" + dir + "/" + side), Path.build_filename(notes_dir, "attachments", local_id, NoteAttachments.local_name(side)), cancellable);
                        } catch (IOError.CANCELLED e) {
                            throw e;
                        } catch (Error e) {
                        }
                    }
                }
                content = NoteAttachments.replace_link(content, target, "attachments/%s/%s".printf(local_id, local));
            }
            return content;
        }

        public async NoteState publish(string local_id, string remote_id, NoteState state, string notes_dir, Cancellable? cancellable) throws Error {
            if (files == null || remote_id == "") return state;
            var upload = new Gee.HashMap<string, string>();
            var renames = new Gee.HashMap<string, string>();
            string dir = ".attachments." + remote_id;
            foreach (string target in NoteAttachments.links(state.content)) {
                string id;
                string name;
                if (NoteAttachments.local_link(target, out id, out name) == null) continue;
                string path = Path.build_filename(notes_dir, "attachments", id, name);
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                NoteAttachments.add_with_sidecars(upload, name, path);
                renames[target] = dir + "/" + Uri.escape_string(name, null, false);
            }
            if (upload.size == 0) return state;
            string folder = yield folder_path(state.folder, cancellable);
            yield NoteAttachments.upload_missing(files, files_root, folder + "/" + dir, upload, cancellable);
            string content = state.content;
            foreach (var e in renames.entries) content = NoteAttachments.replace_link(content, e.key, e.value);
            return new NoteState(content, state.folder, state.pinned);
        }

        public async string? fetch_meta(Cancellable? cancellable) throws Error {
            if (files == null) return null;
            string folder = yield folder_path("", cancellable);
            try {
                var got = yield files.get_resource(files_root + NoteAttachments.escape_path(folder + "/" + Notebooks.FILE_NAME), cancellable);
                return got.text();
            } catch (Singularity.Accounts.AccountsError.NOT_FOUND e) {
                return null;
            }
        }

        public async void put_meta(string text, Cancellable? cancellable) throws Error {
            if (files == null) return;
            string folder = yield folder_path("", cancellable);
            yield NoteAttachments.ensure_folders(files, files_root, folder, cancellable);
            yield files.put(files_root + NoteAttachments.escape_path(folder + "/" + Notebooks.FILE_NAME), "application/json", new Bytes(text.data), null, false, cancellable);
        }

        private static RemoteNote from_json(Json.Object o) {
            var r = new RemoteNote();
            r.remote_id = "%lld".printf(o.get_int_member("id"));
            r.etag = o.has_member("etag") ? o.get_string_member("etag") : "";
            r.modified = o.has_member("modified") ? o.get_int_member("modified") : 0;
            if (o.has_member("content")) {
                r.state = new NoteState(o.get_string_member("content"),
                    o.has_member("category") ? o.get_string_member("category") : "",
                    o.has_member("favorite") && o.get_boolean_member("favorite"));
            }
            return r;
        }

        private static Bytes body_of(NoteState state, int64 modified) {
            var o = new Json.Object();
            o.set_string_member("content", state.content);
            o.set_string_member("title", Singularity.Notes.Note.title_of(state.content));
            o.set_string_member("category", state.folder);
            o.set_boolean_member("favorite", state.pinned);
            if (modified > 0) o.set_int_member("modified", modified);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            return new Bytes(Json.to_string(node, false).data);
        }

        private static Json.Node parse(Singularity.Accounts.HttpResponse response) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(response.text());
            return parser.get_root();
        }

        public async Gee.List<RemoteNote> list(Gee.Map<string, string> known_etags, Cancellable? cancellable) throws Error {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            headers.insert("Accept", "application/json");
            var response = yield http.send_ok("GET", root + "notes", null, null, headers, cancellable);
            var list = new Gee.ArrayList<RemoteNote>();
            var node = parse(response);
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY) throw new RemoteError.FAILED(_("The server sent an unexpected answer"));
            foreach (var item in node.get_array().get_elements()) {
                if (item.get_node_type() != Json.NodeType.OBJECT) continue;
                var o = item.get_object();
                if (o.has_member("error") && o.get_boolean_member("error")) continue;
                list.add(from_json(o));
            }
            return list;
        }

        public async RemoteNote create(string local_id, NoteState state, int64 modified, Cancellable? cancellable) throws Error {
            var response = yield http.send_ok("POST", root + "notes", "application/json", body_of(state, modified), null, cancellable);
            return from_json(parse(response).get_object());
        }

        public async RemoteNote update(string remote_id, string etag, NoteState state, int64 modified, Cancellable? cancellable) throws Error {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            if (etag != "") headers.insert("If-Match", "\"%s\"".printf(etag));
            var response = yield http.send("PUT", root + "notes/" + remote_id, "application/json", body_of(state, modified), headers, cancellable);
            if (response.status == 412) throw new RemoteError.CHANGED("changed on the server");
            Singularity.Accounts.HttpClient.check(response, "PUT");
            return from_json(parse(response).get_object());
        }

        public async void remove(string remote_id, string etag, Cancellable? cancellable) throws Error {
            var headers = new HashTable<string, string>(str_hash, str_equal);
            if (etag != "") headers.insert("If-Match", "\"%s\"".printf(etag));
            var response = yield http.send("DELETE", root + "notes/" + remote_id, null, null, headers, cancellable);
            if (response.status == 404) return;
            if (response.status == 412) throw new RemoteError.CHANGED("changed on the server");
            Singularity.Accounts.HttpClient.check(response, "DELETE");
        }
    }

    public class WebDavNotesRemote : Object, NotesRemote {
        public const string FOLDER = "Notes";
        private Singularity.Accounts.DavClient dav;
        private string root;
        private bool folder_ready = false;

        public string kind { get { return "webdav"; } }

        public WebDavNotesRemote(Singularity.Accounts.Account account, string folder = FOLDER) {
            var http = new Singularity.Accounts.HttpClient(account, Singularity.Accounts.Capability.FILES);
            dav = new Singularity.Accounts.DavClient(http);
            string base_url = account.get_endpoint("webdav") ?? "";
            if (!base_url.has_suffix("/")) base_url += "/";
            root = base_url + NoteAttachments.escape_path(folder) + "/";
        }

        private static string strip_etag(string etag) {
            string e = etag.strip();
            if (e.has_prefix("W/")) e = e.substring(2);
            return e.replace("\"", "");
        }

        private static NoteState state_from_file(string text) {
            var n = Singularity.Notes.Note.parse("remote", text);
            return new NoteState(n.body, n.folder, n.pinned);
        }

        private static Bytes file_of(string id, NoteState state, int64 modified) {
            var n = new Singularity.Notes.Note(id);
            n.body = state.content;
            n.folder = state.folder;
            n.pinned = state.pinned;
            n.modified = modified;
            return new Bytes(n.serialize().data);
        }

        private async void ensure_folder(Cancellable? cancellable) throws Error {
            if (folder_ready) return;
            try {
                yield dav.propfind(root, "0", PROPFIND_BODY, cancellable);
            } catch (Singularity.Accounts.AccountsError.NOT_FOUND e) {
                string base_url = root;
                var parts = new Gee.ArrayList<string>();
                while (true) {
                    string trimmed = base_url.substring(0, base_url.length - 1);
                    int slash = trimmed.last_index_of("/");
                    if (slash < 0) break;
                    parts.insert(0, trimmed.substring(slash + 1));
                    base_url = trimmed.substring(0, slash + 1);
                    try {
                        yield dav.propfind(base_url, "0", PROPFIND_BODY, cancellable);
                        break;
                    } catch (Singularity.Accounts.AccountsError.NOT_FOUND e2) {
                    }
                }
                string url = base_url;
                foreach (string p in parts) {
                    url += p + "/";
                    try {
                        yield dav.mkcol(url, cancellable);
                    } catch (Singularity.Accounts.AccountsError e3) {
                        if (url == root) throw e3;
                    }
                }
            }
            folder_ready = true;
        }

        private const string PROPFIND_BODY = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getlastmodified/><d:resourcetype/></d:prop></d:propfind>""";

        public async Gee.List<RemoteNote> list(Gee.Map<string, string> known_etags, Cancellable? cancellable) throws Error {
            yield ensure_folder(cancellable);
            var ms = yield dav.propfind(root, "1", PROPFIND_BODY, cancellable);
            var list = new Gee.ArrayList<RemoteNote>();
            foreach (var resp in ms.responses) {
                if (resp.removed || resp.is_type(Singularity.Accounts.NS_DAV, "collection")) continue;
                string href = resp.href;
                string name = Uri.unescape_string(href.substring(href.last_index_of("/") + 1)) ?? "";
                if (!name.has_suffix(".md")) continue;
                var r = new RemoteNote();
                r.remote_id = name;
                r.etag = strip_etag(resp.text(Singularity.Accounts.NS_DAV, "getetag"));
                string? known = known_etags[name];
                if (known == null || known != r.etag || r.etag == "") {
                    var got = yield dav.get_resource(root + Uri.escape_string(name, null, false), cancellable);
                    if (got.body.get_size() > 0) r.state = state_from_file(got.text());
                    string? header = got.header("ETag");
                    if (header != null && header != "") r.etag = strip_etag(header);
                }
                list.add(r);
            }
            return list;
        }

        public async RemoteNote create(string local_id, NoteState state, int64 modified, Cancellable? cancellable) throws Error {
            yield ensure_folder(cancellable);
            string name = local_id + ".md";
            string url = root + Uri.escape_string(name, null, false);
            string etag;
            try {
                etag = yield dav.put(url, "text/markdown; charset=utf-8", file_of(local_id, state, modified), null, true, cancellable);
            } catch (Singularity.Accounts.AccountsError.CONFLICT e) {
                name = local_id + "-" + Singularity.Notes.Note.new_id().substring(0, 8) + ".md";
                url = root + Uri.escape_string(name, null, false);
                etag = yield dav.put(url, "text/markdown; charset=utf-8", file_of(local_id, state, modified), null, true, cancellable);
            }
            var r = new RemoteNote();
            r.remote_id = name;
            r.etag = strip_etag(etag);
            r.state = state;
            if (r.etag == "") r.etag = yield fetch_etag(url, cancellable);
            return r;
        }

        private async string fetch_etag(string url, Cancellable? cancellable) throws Error {
            var ms = yield dav.propfind(url, "0", PROPFIND_BODY, cancellable);
            foreach (var resp in ms.responses) return strip_etag(resp.text(Singularity.Accounts.NS_DAV, "getetag"));
            return "";
        }

        public async RemoteNote update(string remote_id, string etag, NoteState state, int64 modified, Cancellable? cancellable) throws Error {
            string url = root + Uri.escape_string(remote_id, null, false);
            string new_etag;
            string id = remote_id.has_suffix(".md") ? remote_id.substring(0, remote_id.length - 3) : remote_id;
            try {
                new_etag = yield dav.put(url, "text/markdown; charset=utf-8", file_of(id, state, modified), etag != "" ? "\"%s\"".printf(etag) : null, false, cancellable);
                if (etag != "" && strip_etag(new_etag) == etag) {
                    Timeout.add(1100, update.callback);
                    yield;
                    new_etag = yield dav.put(url, "text/markdown; charset=utf-8", file_of(id, state, modified), "\"%s\"".printf(etag), false, cancellable);
                }
            } catch (Singularity.Accounts.AccountsError.CONFLICT e) {
                throw new RemoteError.CHANGED("changed on the server");
            }
            var r = new RemoteNote();
            r.remote_id = remote_id;
            r.etag = strip_etag(new_etag);
            r.state = state;
            if (r.etag == "") r.etag = yield fetch_etag(url, cancellable);
            return r;
        }

        public async string localize(string remote_id, string local_id, NoteState state, string notes_dir, Cancellable? cancellable) throws Error {
            foreach (string target in NoteAttachments.links(state.content)) {
                string id;
                string name;
                if (NoteAttachments.local_link(target, out id, out name) == null) continue;
                string path = Path.build_filename(notes_dir, "attachments", id, name);
                if (FileUtils.test(path, FileTest.EXISTS)) continue;
                try {
                    yield NoteAttachments.download(dav, root + NoteAttachments.escape_path("attachments/" + id + "/" + name), path, cancellable);
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning("notes: cannot download the attachment %s: %s", name, e.message);
                    continue;
                }
                foreach (string side in NoteAttachments.sidecars(name)) {
                    try {
                        yield NoteAttachments.download(dav, root + NoteAttachments.escape_path("attachments/" + id + "/" + side), Path.build_filename(notes_dir, "attachments", id, side), cancellable);
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                    }
                }
            }
            return state.content;
        }

        public async NoteState publish(string local_id, string remote_id, NoteState state, string notes_dir, Cancellable? cancellable) throws Error {
            var by_folder = new Gee.HashMap<string, Gee.HashMap<string, string>>();
            foreach (string target in NoteAttachments.links(state.content)) {
                string id;
                string name;
                if (NoteAttachments.local_link(target, out id, out name) == null) continue;
                string path = Path.build_filename(notes_dir, "attachments", id, name);
                if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                if (!by_folder.has_key(id)) by_folder[id] = new Gee.HashMap<string, string>();
                NoteAttachments.add_with_sidecars(by_folder[id], name, path);
            }
            foreach (var e in by_folder.entries) {
                yield NoteAttachments.upload_missing(dav, root, "attachments/" + e.key, e.value, cancellable);
            }
            return state;
        }

        public async string? fetch_meta(Cancellable? cancellable) throws Error {
            yield ensure_folder(cancellable);
            try {
                var got = yield dav.get_resource(root + Notebooks.FILE_NAME, cancellable);
                return got.text();
            } catch (Singularity.Accounts.AccountsError.NOT_FOUND e) {
                return null;
            }
        }

        public async void put_meta(string text, Cancellable? cancellable) throws Error {
            yield ensure_folder(cancellable);
            yield dav.put(root + Notebooks.FILE_NAME, "application/json", new Bytes(text.data), null, false, cancellable);
        }

        public async void put_presence(string who, string page_id, Cancellable? cancellable) throws Error {
            yield ensure_folder(cancellable);
            string dir = root + ".presence/";
            try {
                yield dav.propfind(dir, "0", PROPFIND_BODY, cancellable);
            } catch (Singularity.Accounts.AccountsError.NOT_FOUND e) {
                yield dav.mkcol(dir, cancellable);
            }
            var o = new Json.Object();
            o.set_string_member("name", who);
            o.set_string_member("page", page_id);
            o.set_int_member("time", get_real_time() / 1000000);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            string file = TagCatalog.slug(who) + ".json";
            yield dav.put(dir + Uri.escape_string(file, null, false), "application/json", new Bytes(Json.to_string(node, false).data), null, false, cancellable);
        }

        public async Gee.List<Presence> list_presence(Cancellable? cancellable) throws Error {
            var list = new Gee.ArrayList<Presence>();
            string dir = root + ".presence/";
            Singularity.Accounts.Multistatus ms;
            try {
                ms = yield dav.propfind(dir, "1", PROPFIND_BODY, cancellable);
            } catch (Singularity.Accounts.AccountsError.NOT_FOUND e) {
                return list;
            }
            foreach (var resp in ms.responses) {
                if (resp.removed || resp.is_type(Singularity.Accounts.NS_DAV, "collection")) continue;
                string href = resp.href;
                string name = Uri.unescape_string(href.substring(href.last_index_of("/") + 1)) ?? "";
                if (!name.has_suffix(".json")) continue;
                try {
                    var got = yield dav.get_resource(dir + Uri.escape_string(name, null, false), cancellable);
                    var parser = new Json.Parser();
                    parser.load_from_data(got.text());
                    var o = parser.get_root().get_object();
                    list.add(new Presence(o.get_string_member("name"), o.get_string_member("page"), o.get_int_member("time")));
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                }
            }
            return list;
        }

        public async void remove(string remote_id, string etag, Cancellable? cancellable) throws Error {
            try {
                yield dav.delete(root + Uri.escape_string(remote_id, null, false), etag != "" ? "\"%s\"".printf(etag) : null, cancellable);
            } catch (Singularity.Accounts.AccountsError.CONFLICT e) {
                throw new RemoteError.CHANGED("changed on the server");
            }
        }
    }
}
