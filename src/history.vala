namespace Singularity.Apps.Notes {

    public class PageVersion : Object {
        public int64 time { get; construct; }
        public string path { get; construct; }
        public string author { get; construct; }

        public PageVersion(int64 time, string path, string author) {
            Object(time: time, path: path, author: author);
        }

        public string text() {
            string t;
            try {
                if (FileUtils.get_contents(path, out t)) return t;
            } catch (FileError e) {
            }
            return "";
        }
    }

    public class History : Object {
        public const int64 MIN_GAP = 300;
        public const int KEEP = 200;
        public string dir { get; construct; }

        public History(string notes_dir) {
            Object(dir: Path.build_filename(notes_dir, ".versions"));
        }

        private string note_dir(string id) {
            return Path.build_filename(dir, id);
        }

        public static string author_name() {
            string real = Environment.get_real_name();
            return real != null && real != "" && real != "Unknown" ? real : Environment.get_user_name();
        }

        public Gee.List<PageVersion> list(string id) {
            var result = new Gee.ArrayList<PageVersion>();
            try {
                var d = Dir.open(note_dir(id));
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.has_suffix(".md")) continue;
                    string stem = name.substring(0, name.length - 3);
                    string author = "";
                    int dash = stem.index_of("-");
                    if (dash > 0) {
                        author = Uri.unescape_string(stem.substring(dash + 1)) ?? "";
                        stem = stem.substring(0, dash);
                    }
                    result.add(new PageVersion(int64.parse(stem), Path.build_filename(note_dir(id), name), author));
                }
            } catch (FileError e) {
            }
            result.sort((a, b) => a.time > b.time ? -1 : (a.time < b.time ? 1 : 0));
            return result;
        }

        public bool record(string id, string text, bool force = false) {
            if (!Singularity.Notes.NoteStore.valid_id(id) || text.strip() == "") return false;
            var existing = list(id);
            int64 now = get_real_time() / 1000000;
            if (existing.size > 0) {
                if (existing[0].text() == text) return false;
                if (!force && now - existing[0].time < MIN_GAP) {
                    try {
                        FileUtils.set_contents(existing[0].path, text);
                    } catch (FileError e) {
                    }
                    return true;
                }
            }
            try {
                DirUtils.create_with_parents(note_dir(id), 0700);
                string name = "%lld-%s.md".printf(now, Uri.escape_string(author_name(), null, false).replace("-", "%2D"));
                FileUtils.set_contents_full(Path.build_filename(note_dir(id), name), text, text.length, FileSetContentsFlags.CONSISTENT, 0600);
            } catch (Error e) {
                return false;
            }
            for (int i = KEEP; i < existing.size; i++) FileUtils.unlink(existing[i].path);
            return true;
        }

        public void forget(string id) {
            foreach (var v in list(id)) FileUtils.unlink(v.path);
            DirUtils.remove(note_dir(id));
        }
    }

    public class TrashItem : Object {
        public string id { get; construct; }
        public int64 deleted { get; construct; }
        public string text { get; construct; }
        public string folder { get; construct; }

        public TrashItem(string id, int64 deleted, string text, string folder) {
            Object(id: id, deleted: deleted, text: text, folder: folder);
        }

        public string title() {
            var n = Singularity.Notes.Note.parse(id, text);
            string t = PageDoc.title_of(n.body);
            return t != "" ? t : _("Untitled Page");
        }
    }

    public class Trash : Object {
        public const int64 KEEP_DAYS = 60;
        public string dir { get; construct; }
        public string notes_dir { get; construct; }

        public signal void changed();

        public Trash(string notes_dir) {
            Object(notes_dir: notes_dir, dir: Path.build_filename(notes_dir, ".trash"));
        }

        public void put(Singularity.Notes.Note note) throws Error {
            DirUtils.create_with_parents(dir, 0700);
            string text = note.serialize();
            FileUtils.set_contents_full(Path.build_filename(dir, note.id + ".md"), text, text.length, FileSetContentsFlags.CONSISTENT, 0600);
            FileUtils.set_contents(Path.build_filename(dir, note.id + ".deleted"), "%lld".printf(get_real_time() / 1000000));
            changed();
        }

        public Gee.List<TrashItem> items() {
            var list = new Gee.ArrayList<TrashItem>();
            try {
                var d = Dir.open(dir);
                string? name;
                while ((name = d.read_name()) != null) {
                    if (!name.has_suffix(".md")) continue;
                    string id = name.substring(0, name.length - 3);
                    string text;
                    string when = "0";
                    try {
                        FileUtils.get_contents(Path.build_filename(dir, name), out text);
                        FileUtils.get_contents(Path.build_filename(dir, id + ".deleted"), out when);
                    } catch (FileError e) {
                        continue;
                    }
                    var n = Singularity.Notes.Note.parse(id, text);
                    list.add(new TrashItem(id, int64.parse(when.strip()), text, n.folder));
                }
            } catch (FileError e) {
            }
            list.sort((a, b) => a.deleted > b.deleted ? -1 : (a.deleted < b.deleted ? 1 : 0));
            return list;
        }

        public Singularity.Notes.Note? restore(string id, Singularity.Notes.NoteStore store) throws Error {
            string path = Path.build_filename(dir, id + ".md");
            string text;
            if (!FileUtils.get_contents(path, out text)) return null;
            var n = Singularity.Notes.Note.parse(id, text);
            if (store.lookup(id) != null) n = Singularity.Notes.Note.parse(Singularity.Notes.Note.new_id(), text);
            store.save(n, false);
            FileUtils.unlink(path);
            FileUtils.unlink(Path.build_filename(dir, id + ".deleted"));
            changed();
            return n;
        }

        public void delete_forever(string id) {
            FileUtils.unlink(Path.build_filename(dir, id + ".md"));
            FileUtils.unlink(Path.build_filename(dir, id + ".deleted"));
            remove_tree(Attachments.dir_for(notes_dir, id));
            new History(notes_dir).forget(id);
            changed();
        }

        public static void remove_tree(string path) {
            if (!FileUtils.test(path, FileTest.IS_DIR)) return;
            try {
                var d = Dir.open(path);
                string? name;
                while ((name = d.read_name()) != null) {
                    string child = Path.build_filename(path, name);
                    if (FileUtils.test(child, FileTest.IS_DIR) && !FileUtils.test(child, FileTest.IS_SYMLINK)) remove_tree(child);
                    else FileUtils.unlink(child);
                }
            } catch (FileError e) {
            }
            DirUtils.remove(path);
        }

        public void empty() {
            foreach (var i in items()) delete_forever(i.id);
        }

        public int purge_old() {
            int64 limit = get_real_time() / 1000000 - KEEP_DAYS * 86400;
            int n = 0;
            foreach (var i in items()) {
                if (i.deleted > 0 && i.deleted < limit) {
                    delete_forever(i.id);
                    n++;
                }
            }
            return n;
        }
    }
}
