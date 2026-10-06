namespace Singularity.Apps.Notes {

    public const string LOCKED_MARKER = "<!-- notes-locked v1 -->";

    public class NoteState : Object {
        public string content { get; set; default = ""; }
        public string folder { get; set; default = ""; }
        public bool pinned { get; set; default = false; }

        public NoteState(string content, string folder = "", bool pinned = false) {
            Object(content: content, folder: folder, pinned: pinned);
        }

        public bool equals(NoteState other) {
            return content == other.content && folder == other.folder && pinned == other.pinned;
        }

        public NoteState copy() {
            return new NoteState(content, folder, pinned);
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("content", content);
            o.set_string_member("folder", folder);
            o.set_boolean_member("pinned", pinned);
            return o;
        }

        public static NoteState from_json(Json.Object o) {
            return new NoteState(
                o.has_member("content") ? o.get_string_member("content") : "",
                o.has_member("folder") ? o.get_string_member("folder") : "",
                o.has_member("pinned") && o.get_boolean_member("pinned"));
        }
    }

    public class MergeResult : Object {
        public NoteState? result = null;
        public bool write_local = false;
        public bool write_remote = false;
        public bool create_remote = false;
        public bool delete_local = false;
        public bool delete_remote = false;
        public bool forget = false;
        public string? conflict_copy = null;

        public string describe() {
            string[] parts = {};
            if (write_local) parts += "write-local";
            if (write_remote) parts += "write-remote";
            if (create_remote) parts += "create-remote";
            if (delete_local) parts += "delete-local";
            if (delete_remote) parts += "delete-remote";
            if (forget) parts += "forget";
            if (conflict_copy != null) parts += "conflict";
            return parts.length == 0 ? "none" : string.joinv(",", parts);
        }
    }

    public class SyncMerge : Object {

        public static MergeResult decide(NoteState? base_state, NoteState? local, NoteState? remote) {
            var r = new MergeResult();
            if (base_state == null) {
                if (local != null && remote == null) {
                    r.result = local;
                    r.create_remote = true;
                } else if (local == null && remote != null) {
                    r.result = remote;
                    r.write_local = true;
                } else if (local != null && remote != null) {
                    if (local.equals(remote)) {
                        r.result = local;
                    } else {
                        r.result = remote;
                        r.write_local = true;
                        if (local.content != remote.content) r.conflict_copy = local.content;
                    }
                } else {
                    r.forget = true;
                }
                return r;
            }
            if (local == null && remote == null) {
                r.forget = true;
                return r;
            }
            if (local == null) {
                if (remote.equals(base_state)) {
                    r.delete_remote = true;
                    r.forget = true;
                } else {
                    r.result = remote;
                    r.write_local = true;
                }
                return r;
            }
            if (remote == null) {
                if (local.equals(base_state)) {
                    r.delete_local = true;
                    r.forget = true;
                } else {
                    r.result = local;
                    r.create_remote = true;
                }
                return r;
            }
            bool local_changed = !local.equals(base_state);
            bool remote_changed = !remote.equals(base_state);
            if (!local_changed && !remote_changed) {
                r.result = local;
                return r;
            }
            if (local_changed && !remote_changed) {
                r.result = local;
                r.write_remote = true;
                return r;
            }
            if (!local_changed && remote_changed) {
                r.result = remote;
                r.write_local = true;
                return r;
            }
            var merged = new NoteState("");
            merged.folder = pick(base_state.folder, local.folder, remote.folder);
            merged.pinned = local.pinned != base_state.pinned && remote.pinned == base_state.pinned ? local.pinned : remote.pinned;
            string? text = merge_text(base_state.content, local.content, remote.content);
            if (text != null) {
                merged.content = text;
            } else {
                merged.content = remote.content;
                r.conflict_copy = local.content;
            }
            r.result = merged;
            r.write_local = !merged.equals(local);
            r.write_remote = !merged.equals(remote);
            return r;
        }

        private static string pick(string base_value, string local, string remote) {
            return Singularity.Notes.LineMerge.pick(base_value, local, remote);
        }

        public static string? merge_text(string base_text, string local, string remote) {
            if (local == remote) return local;
            if (local.contains(LOCKED_MARKER) || remote.contains(LOCKED_MARKER)) {
                if (local == base_text) return remote;
                if (remote == base_text) return local;
                return null;
            }
            return Singularity.Notes.LineMerge.merge(base_text, local, remote);
        }
    }
}
