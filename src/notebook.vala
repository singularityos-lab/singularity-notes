namespace Singularity.Apps.Notes {

    public enum FolderKind {
        NOTEBOOK,
        GROUP,
        SECTION;

        public string to_id() {
            switch (this) {
                case NOTEBOOK: return "notebook";
                case GROUP: return "group";
                default: return "section";
            }
        }

        public static FolderKind? from_id(string id) {
            switch (id) {
                case "notebook": return NOTEBOOK;
                case "group": return GROUP;
                case "section": return SECTION;
                default: return null;
            }
        }
    }

    public class FolderInfo : Object {
        public string path { get; set; default = ""; }
        public string kind_id { get; set; default = ""; }
        public string color { get; set; default = ""; }
        public double order { get; set; default = 0; }
        public string lock_check { get; set; default = ""; }
        public string lock_salt { get; set; default = ""; }
        public string share_account { get; set; default = ""; }
        public string share_path { get; set; default = ""; }
        public string template { get; set; default = ""; }
    }

    public class FolderNode : Object {
        public string path { get; construct; }
        public string name { get; construct; }
        public FolderKind kind { get; set; }
        public int depth { get; set; }
        public string color { get; set; default = ""; }
        public bool locked { get; set; default = false; }
        public Gee.ArrayList<FolderNode> children = new Gee.ArrayList<FolderNode>();

        public FolderNode(string path) {
            Object(path: path, name: path.contains("/") ? path.substring(path.last_index_of("/") + 1) : path);
        }

        public bool shared { get; set; default = false; }

        public string icon_name() {
            if (locked) return "system-lock-screen-symbolic";
            if (shared) return "emblem-shared-symbolic";
            switch (kind) {
                case FolderKind.NOTEBOOK: return "accessories-dictionary-symbolic";
                case FolderKind.GROUP: return "folder-symbolic";
                default: return "text-x-generic-symbolic";
            }
        }
    }

    public class Notebooks : Object {
        public const string FILE_NAME = ".notebooks.json";
        public const string[] COLORS = { "#3584e4", "#2ec27e", "#e5a50a", "#ff7800", "#e01b24", "#9141ac", "#986a44", "#5e5c64", "#1c71d8", "#26a269", "#c64600", "#813d9c" };

        public string dir { get; construct; }
        public signal void changed();

        private Gee.HashMap<string, FolderInfo> infos = new Gee.HashMap<string, FolderInfo>();
        public Gee.ArrayList<string> custom_tags = new Gee.ArrayList<string>();
        public Gee.HashMap<string, string> custom_tag_labels = new Gee.HashMap<string, string>();

        public Notebooks(string dir) {
            Object(dir: dir);
            load();
        }

        public string path_of_file() {
            return Path.build_filename(dir, FILE_NAME);
        }

        public void load() {
            infos.clear();
            custom_tags.clear();
            custom_tag_labels.clear();
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path_of_file());
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var o = root.get_object();
                if (o.has_member("folders")) {
                    o.get_object_member("folders").foreach_member((obj, key, node) => {
                        var fo = node.get_object();
                        var info = new FolderInfo();
                        info.path = key;
                        if (fo.has_member("kind")) info.kind_id = fo.get_string_member("kind");
                        if (fo.has_member("color")) info.color = fo.get_string_member("color");
                        if (fo.has_member("order")) info.order = fo.get_double_member("order");
                        if (fo.has_member("template")) info.template = fo.get_string_member("template");
                        if (fo.has_member("share")) {
                            var so = fo.get_object_member("share");
                            info.share_account = so.get_string_member("account");
                            info.share_path = so.get_string_member("path");
                        }
                        if (fo.has_member("lock")) {
                            var lo = fo.get_object_member("lock");
                            info.lock_salt = lo.get_string_member("salt");
                            info.lock_check = lo.get_string_member("check");
                        }
                        infos[key] = info;
                    });
                }
                if (o.has_member("tags")) {
                    o.get_array_member("tags").foreach_element((arr, i, node) => {
                        var to = node.get_object();
                        string id = to.get_string_member("id");
                        custom_tags.add(id);
                        custom_tag_labels[id] = to.get_string_member("label");
                    });
                }
            } catch (Error e) {
            }
        }

        public void save() {
            var folders = new Json.Object();
            var keys = new Gee.ArrayList<string>();
            keys.add_all(infos.keys);
            keys.sort();
            foreach (string k in keys) {
                var info = infos[k];
                var fo = new Json.Object();
                if (info.kind_id != "") fo.set_string_member("kind", info.kind_id);
                if (info.color != "") fo.set_string_member("color", info.color);
                if (info.order != 0) fo.set_double_member("order", info.order);
                if (info.template != "") fo.set_string_member("template", info.template);
                if (info.share_path != "") {
                    var so = new Json.Object();
                    so.set_string_member("account", info.share_account);
                    so.set_string_member("path", info.share_path);
                    fo.set_object_member("share", so);
                }
                if (info.lock_check != "") {
                    var lo = new Json.Object();
                    lo.set_string_member("salt", info.lock_salt);
                    lo.set_string_member("check", info.lock_check);
                    fo.set_object_member("lock", lo);
                }
                if (fo.get_size() > 0) folders.set_object_member(k, fo);
            }
            var tags = new Json.Array();
            foreach (string id in custom_tags) {
                var to = new Json.Object();
                to.set_string_member("id", id);
                to.set_string_member("label", custom_tag_labels[id] ?? id);
                tags.add_object_element(to);
            }
            var root = new Json.Object();
            root.set_object_member("folders", folders);
            root.set_array_member("tags", tags);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(root);
            try {
                DirUtils.create_with_parents(dir, 0700);
                string text = Json.to_string(node, true);
                FileUtils.set_contents_full(path_of_file(), text, text.length, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                warning("notes: cannot save the notebooks: %s", e.message);
            }
            changed();
        }

        public FolderInfo info(string path) {
            var i = infos[path];
            if (i == null) {
                i = new FolderInfo();
                i.path = path;
                infos[path] = i;
            }
            return i;
        }

        public FolderInfo? peek(string path) {
            return infos[path];
        }

        public static string parent_of(string path) {
            int slash = path.last_index_of("/");
            return slash > 0 ? path.substring(0, slash) : "";
        }

        public static string name_of(string path) {
            int slash = path.last_index_of("/");
            return slash >= 0 ? path.substring(slash + 1) : path;
        }

        public static int depth_of(string path) {
            int d = 0;
            for (int i = 0; i < path.length; i++) if (path[i] == '/') d++;
            return d;
        }

        public bool is_locked(string path) {
            string p = path;
            while (p != "") {
                var i = infos[p];
                if (i != null && i.lock_check != "") return true;
                p = parent_of(p);
            }
            return false;
        }

        public string? lock_root(string path) {
            string p = path;
            while (p != "") {
                var i = infos[p];
                if (i != null && i.lock_check != "") return p;
                p = parent_of(p);
            }
            return null;
        }

        public Gee.List<FolderNode> tree(Gee.Collection<string> folders) {
            var all = new Gee.TreeSet<string>();
            foreach (string f in folders) {
                string p = f;
                while (p != "") {
                    all.add(p);
                    p = parent_of(p);
                }
            }
            foreach (var e in infos.entries) if (e.value.kind_id != "" && e.key != "") all.add(e.key);
            var nodes = new Gee.HashMap<string, FolderNode>();
            foreach (string p in all) {
                var n = new FolderNode(p);
                n.depth = depth_of(p);
                var i = infos[p];
                if (i != null) {
                    n.color = i.color;
                    n.locked = i.lock_check != "";
                    n.shared = i.share_path != "";
                }
                nodes[p] = n;
            }
            var roots = new Gee.ArrayList<FolderNode>();
            foreach (string p in all) {
                var n = nodes[p];
                string parent = parent_of(p);
                if (parent != "" && nodes.has_key(parent)) nodes[parent].children.add(n);
                else roots.add(n);
            }
            foreach (var n in nodes.values) {
                var i = infos[n.path];
                FolderKind? k = i != null ? FolderKind.from_id(i.kind_id) : null;
                if (k != null) n.kind = k;
                else if (n.depth == 0) n.kind = n.children.size > 0 ? FolderKind.NOTEBOOK : FolderKind.SECTION;
                else n.kind = n.children.size > 0 ? FolderKind.GROUP : FolderKind.SECTION;
            }
            sort_nodes(roots);
            foreach (var n in nodes.values) sort_nodes(n.children);
            return roots;
        }

        private void sort_nodes(Gee.ArrayList<FolderNode> list) {
            list.sort((a, b) => {
                double oa = infos.has_key(a.path) ? infos[a.path].order : 0;
                double ob = infos.has_key(b.path) ? infos[b.path].order : 0;
                bool sa = a.kind == FolderKind.SECTION;
                bool sb = b.kind == FolderKind.SECTION;
                if (oa != ob) return oa < ob ? -1 : 1;
                if (sa != sb) return sa ? -1 : 1;
                return a.name.casefold().collate(b.name.casefold());
            });
        }

        public void set_kind(string path, FolderKind kind) {
            info(path).kind_id = kind.to_id();
            save();
        }

        public void set_color(string path, string color) {
            info(path).color = color;
            save();
        }

        public void reorder(Gee.List<string> siblings) {
            for (int i = 0; i < siblings.size; i++) info(siblings[i]).order = i + 1;
            save();
        }

        public void rename_prefix(string from, string to) {
            var moved = new Gee.HashMap<string, FolderInfo>();
            foreach (var e in infos.entries) {
                if (e.key == from || e.key.has_prefix(from + "/")) {
                    string np = to + e.key.substring(from.length);
                    e.value.path = np;
                    moved[np] = e.value;
                }
            }
            foreach (var e in moved.entries) {
                string old = from + e.key.substring(to.length);
                infos.unset(old);
            }
            foreach (var e in moved.entries) infos[e.key] = e.value;
            save();
        }

        public void forget(string path) {
            foreach (string k in infos.keys.to_array()) if (k == path || k.has_prefix(path + "/")) infos.unset(k);
            save();
        }

        private static Json.Object? parse_object(string text) {
            if (text.strip() == "") return null;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(text);
                var root = parser.get_root();
                if (root != null && root.get_node_type() == Json.NodeType.OBJECT) return root.get_object();
            } catch (Error e) {
            }
            return null;
        }

        public static string merge_json(string local, string remote) {
            var lo = parse_object(local);
            var ro = parse_object(remote);
            if (lo == null && ro == null) return local;
            if (lo == null) return remote;
            if (ro == null) return local;
            var folders = new Json.Object();
            var keys = new Gee.TreeSet<string>();
            var lf = lo.has_member("folders") ? lo.get_object_member("folders") : new Json.Object();
            var rf = ro.has_member("folders") ? ro.get_object_member("folders") : new Json.Object();
            foreach (string k in lf.get_members()) keys.add(k);
            foreach (string k in rf.get_members()) keys.add(k);
            foreach (string k in keys) {
                Json.Object? a = lf.has_member(k) ? lf.get_object_member(k) : null;
                Json.Object? b = rf.has_member(k) ? rf.get_object_member(k) : null;
                Json.Object pick = a ?? b;
                if (a != null && b != null && !a.has_member("lock") && b.has_member("lock")) pick = b;
                var copy = new Json.Object();
                foreach (string m in pick.get_members()) copy.set_member(m, pick.get_member(m).copy());
                if (a != null && b != null && pick == a) {
                    foreach (string m in b.get_members()) if (!copy.has_member(m) && m != "lock") copy.set_member(m, b.get_member(m).copy());
                }
                folders.set_object_member(k, copy);
            }
            var tags = new Json.Array();
            var seen = new Gee.HashSet<string>();
            foreach (var src in new Json.Object[] { lo, ro }) {
                if (!src.has_member("tags")) continue;
                foreach (var node in src.get_array_member("tags").get_elements()) {
                    var t = node.get_object();
                    string id = t.get_string_member("id");
                    if (seen.contains(id)) continue;
                    seen.add(id);
                    tags.add_object_element(t);
                }
            }
            var root = new Json.Object();
            root.set_object_member("folders", folders);
            root.set_array_member("tags", tags);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(root);
            string merged = Json.to_string(node, true);
            if (parse_object(local) != null && Json.to_string(node, true) == Json.to_string(re_node(lo), true)) return local;
            return merged;
        }

        private static Json.Node re_node(Json.Object o) {
            var n = new Json.Node(Json.NodeType.OBJECT);
            n.set_object(o);
            return n;
        }

        public Gee.List<FolderInfo> shared() {
            var list = new Gee.ArrayList<FolderInfo>();
            foreach (var i in infos.values) if (i.share_path != "" && i.share_account != "") list.add(i);
            return list;
        }

        public bool is_shared(string path) {
            string p = path;
            while (p != "") {
                var i = infos[p];
                if (i != null && i.share_path != "") return true;
                p = parent_of(p);
            }
            return false;
        }

        public string next_color() {
            int used = infos.size;
            return COLORS[used % COLORS.length];
        }
    }
}
