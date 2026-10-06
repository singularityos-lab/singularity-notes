namespace Singularity.Apps.Notes {

    public class SyncItem : Object {
        public string local_id = "";
        public string remote_id = "";
        public string etag = "";
        public NoteState base_state = new NoteState("");
    }

    public class SyncReport : Object {
        public int uploaded = 0;
        public int downloaded = 0;
        public int deleted_local = 0;
        public int deleted_remote = 0;
        public int merged = 0;
        public int conflicts = 0;

        public string describe() {
            return "up=%d down=%d del-local=%d del-remote=%d merged=%d conflicts=%d".printf(
                uploaded, downloaded, deleted_local, deleted_remote, merged, conflicts);
        }
    }

    public class SyncEngine : Object {
        public Singularity.Notes.NoteStore store { get; construct; }
        public NotesRemote remote { get; construct; }
        public string state_path { get; construct; }
        public string target_folder { get; set; default = ""; }
        public string include_prefix { get; set; default = ""; }
        public string[] exclude_prefixes = {};
        public bool sync_notebooks { get; set; default = true; }
        public bool meta_changed { get; private set; default = false; }

        private Gee.HashMap<string, SyncItem> items = new Gee.HashMap<string, SyncItem>();

        public SyncEngine(Singularity.Notes.NoteStore store, NotesRemote remote, string state_path) {
            Object(store: store, remote: remote, state_path: state_path);
            load_state();
        }

        public static string state_path_for(Singularity.Notes.NoteStore store, string account_id) {
            return Path.build_filename(store.dir, ".sync", account_id + ".json");
        }

        private void load_state() {
            items.clear();
            try {
                var parser = new Json.Parser();
                parser.load_from_file(state_path);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var o = root.get_object();
                if (!o.has_member("items")) return;
                o.get_object_member("items").foreach_member((obj, key, node) => {
                    var io = node.get_object();
                    var it = new SyncItem();
                    it.local_id = key;
                    it.remote_id = io.get_string_member("remote");
                    it.etag = io.has_member("etag") ? io.get_string_member("etag") : "";
                    if (io.has_member("base")) it.base_state = NoteState.from_json(io.get_object_member("base"));
                    items[key] = it;
                });
            } catch (Error e) {
            }
        }

        private void save_state() throws Error {
            var items_obj = new Json.Object();
            foreach (var it in items.values) {
                var io = new Json.Object();
                io.set_string_member("remote", it.remote_id);
                io.set_string_member("etag", it.etag);
                io.set_object_member("base", it.base_state.to_json());
                items_obj.set_object_member(it.local_id, io);
            }
            var root = new Json.Object();
            root.set_string_member("kind", remote.kind);
            root.set_object_member("items", items_obj);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(root);
            DirUtils.create_with_parents(Path.get_dirname(state_path), 0700);
            string text = Json.to_string(node, true);
            FileUtils.set_contents_full(state_path, text, text.length, FileSetContentsFlags.CONSISTENT, 0600);
        }

        public static bool under(string folder, string prefix) {
            return folder == prefix || folder.has_prefix(prefix + "/");
        }

        public bool accepts(string folder) {
            if (include_prefix != "" && !under(folder, include_prefix)) return false;
            foreach (string p in exclude_prefixes) if (p != "" && under(folder, p)) return false;
            return true;
        }

        public bool is_synced(string local_id) {
            return items.has_key(local_id);
        }

        private static NoteState state_of(Singularity.Notes.Note n) {
            return new NoteState(n.body, n.folder, n.pinned);
        }

        private void write_local(string id, NoteState state, int64 modified) throws Error {
            var n = store.lookup(id);
            if (n == null) {
                n = new Singularity.Notes.Note(id);
                n.created = modified > 0 ? modified : get_real_time() / 1000000;
            }
            n.body = state.content;
            n.folder = state.folder;
            n.pinned = state.pinned;
            n.modified = modified > 0 ? modified : get_real_time() / 1000000;
            store.save(n, false);
        }

        public async SyncReport sync(Cancellable? cancellable = null) throws Error {
            var report = new SyncReport();
            var known = new Gee.HashMap<string, string>();
            foreach (var it in items.values) known[it.remote_id] = it.etag;
            var remote_list = yield remote.list(known, cancellable);
            var remote_by_id = new Gee.HashMap<string, RemoteNote>();
            foreach (var r in remote_list) remote_by_id[r.remote_id] = r;
            var handled_remote = new Gee.HashSet<string>();
            var handled_local = new Gee.HashSet<string>();
            var pending_conflicts = new Gee.ArrayList<Singularity.Notes.Note>();

            foreach (var it in items.values.to_array()) {
                handled_local.add(it.local_id);
                var local_note = store.lookup(it.local_id);
                if (local_note != null && !accepts(local_note.folder)) {
                    var gone = remote_by_id[it.remote_id];
                    if (gone != null) handled_remote.add(it.remote_id);
                    try {
                        yield remote.remove(it.remote_id, gone != null ? gone.etag : it.etag, cancellable);
                        report.deleted_remote++;
                    } catch (IOError.CANCELLED e) {
                        throw e;
                    } catch (Error e) {
                    }
                    items.unset(it.local_id);
                    continue;
                }
                var r = remote_by_id[it.remote_id];
                if (r != null) handled_remote.add(it.remote_id);
                if (r != null && r.state != null) r.state.content = yield remote.localize(r.remote_id, it.local_id, r.state, store.dir, cancellable);
                NoteState? remote_state = null;
                if (r != null) remote_state = r.state != null ? r.state : (r.etag == it.etag ? it.base_state : null);
                if (r != null && remote_state == null) remote_state = it.base_state;
                var decision = SyncMerge.decide(it.base_state, local_note != null ? state_of(local_note) : null, remote_state);
                yield apply(it, decision, r, local_note, report, pending_conflicts, cancellable);
            }

            foreach (var n in store.all()) {
                if (handled_local.contains(n.id)) continue;
                if (target_folder != "" && n.folder != target_folder) continue;
                if (!accepts(n.folder)) continue;
                var it = new SyncItem();
                it.local_id = n.id;
                var decision = SyncMerge.decide(null, state_of(n), null);
                yield apply(it, decision, null, n, report, pending_conflicts, cancellable);
            }

            foreach (var r in remote_list) {
                if (handled_remote.contains(r.remote_id) || r.state == null) continue;
                if (!accepts(r.state.folder)) continue;
                var it = new SyncItem();
                it.local_id = Singularity.Notes.Note.new_id();
                it.remote_id = r.remote_id;
                it.etag = r.etag;
                r.state.content = yield remote.localize(r.remote_id, it.local_id, r.state, store.dir, cancellable);
                var decision = SyncMerge.decide(null, null, r.state);
                yield apply(it, decision, r, null, report, pending_conflicts, cancellable);
            }

            save_state();
            if (sync_notebooks) yield sync_meta(cancellable);
            return report;
        }

        private async void sync_meta(Cancellable? cancellable) throws Error {
            string path = Path.build_filename(store.dir, Notebooks.FILE_NAME);
            string local;
            try {
                if (!FileUtils.get_contents(path, out local)) local = "";
            } catch (FileError e) {
                local = "";
            }
            string? remote_text = yield remote.fetch_meta(cancellable);
            if (local.strip() == "" && (remote_text == null || remote_text.strip() == "")) return;
            string merged = Notebooks.merge_json(local, remote_text ?? "");
            if (merged != local) {
                FileUtils.set_contents_full(path, merged, merged.length, FileSetContentsFlags.CONSISTENT, 0600);
                meta_changed = true;
            }
            if (remote_text == null || merged != remote_text) yield remote.put_meta(merged, cancellable);
        }

        private async void apply(SyncItem it, MergeResult d, RemoteNote? r, Singularity.Notes.Note? local_note,
                                 SyncReport report, Gee.ArrayList<Singularity.Notes.Note> conflicts,
                                 Cancellable? cancellable) throws Error {
            int64 local_modified = local_note != null ? local_note.modified : 0;
            string match = r != null ? r.etag : it.etag;
            if (d.conflict_copy != null) {
                report.conflicts++;
                var copy = new Singularity.Notes.Note(Singularity.Notes.Note.new_id());
                copy.body = Singularity.Notes.Note.conflicted_copy_body(d.conflict_copy);
                copy.folder = local_note != null ? local_note.folder : (d.result != null ? d.result.folder : "");
                copy.created = get_real_time() / 1000000;
                copy.modified = copy.created;
                store.save(copy, false);
                conflicts.add(copy);
            }
            if (d.delete_local) {
                store.remove(it.local_id);
                report.deleted_local++;
            }
            if (d.delete_remote && r != null) {
                try {
                    yield remote.remove(it.remote_id, match, cancellable);
                    report.deleted_remote++;
                } catch (RemoteError.CHANGED e) {
                    return;
                }
            }
            if (d.forget) {
                items.unset(it.local_id);
                return;
            }
            if (d.result == null) return;
            if (d.write_local) {
                write_local(it.local_id, d.result, r != null ? r.modified : 0);
                if (d.write_remote) report.merged++;
                else report.downloaded++;
            }
            if (d.create_remote) {
                var created = yield remote.create(it.local_id, d.result, local_modified, cancellable);
                it.remote_id = created.remote_id;
                it.etag = created.etag;
                var outgoing = yield remote.publish(it.local_id, it.remote_id, d.result, store.dir, cancellable);
                if (outgoing.content != d.result.content) {
                    try {
                        var linked = yield remote.update(it.remote_id, it.etag, outgoing, local_modified, cancellable);
                        it.etag = linked.etag;
                    } catch (RemoteError.CHANGED e) {
                    }
                }
                report.uploaded++;
            } else if (d.write_remote) {
                try {
                    var outgoing = yield remote.publish(it.local_id, it.remote_id, d.result, store.dir, cancellable);
                    var updated = yield remote.update(it.remote_id, match, outgoing, local_modified, cancellable);
                    it.etag = updated.etag;
                    if (!d.write_local) report.uploaded++;
                } catch (RemoteError.CHANGED e) {
                    return;
                }
            } else if (r != null) {
                it.etag = r.etag;
            }
            it.base_state = d.result.copy();
            items[it.local_id] = it;
        }

        public void forget_all() {
            items.clear();
            FileUtils.unlink(state_path);
        }
    }
}
