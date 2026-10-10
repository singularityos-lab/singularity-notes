namespace Singularity.Apps.Notes {

    [DBus (name = "dev.sinty.Notes1")]
    public class NotesBus : Object {
        private unowned NotesApp app;

        public NotesBus(NotesApp app) {
            this.app = app;
        }

        private Singularity.Notes.NoteStore store() {
            return Singularity.Notes.NoteStore.get_default();
        }

        private Singularity.Notes.Note target(string note_id, string new_title) throws Error {
            if (note_id != "" && store().lookup(note_id) != null) return store().lookup(note_id).copy();
            return store().create("# %s\n".printf(new_title != "" ? new_title : _("Untitled Note")));
        }

        public void list_recent(int limit, [DBus (signature = "a(ss)")] out Variant notes) throws Error {
            var recent = new Gee.ArrayList<Singularity.Notes.Note>();
            foreach (var n in store().all()) {
                if (n.id == Singularity.Notes.NoteStore.QUICK_NOTE_ID || n.id.has_prefix(Singularity.Notes.NoteStore.WIDGET_PREFIX)) continue;
                recent.add(n);
            }
            recent.sort((a, b) => a.modified > b.modified ? -1 : (a.modified < b.modified ? 1 : 0));
            var builder = new VariantBuilder(new VariantType("a(ss)"));
            int shown = 0;
            foreach (var n in recent) {
                if (shown++ == int.max(1, limit)) break;
                builder.add("(ss)", n.id, n.title);
            }
            notes = builder.end();
        }

        public void append(string note_id, string new_title, string markdown, out string id, out string title) throws Error {
            app.hold();
            try {
                var note = target(note_id, new_title);
                note.body = note.body.chomp() + "\n\n" + markdown.chomp() + "\n";
                store().save(note);
                id = note.id;
                title = note.title;
            } finally {
                app.release();
            }
        }

        public void attach_file(string note_id, string new_title, string path, string name, out string id, out string link) throws Error {
            app.hold();
            try {
                if (name == "" || name.contains("/") || name.has_prefix(".")) throw new IOError.INVALID_ARGUMENT(_("Invalid attachment name"));
                var note = target(note_id, new_title);
                if (note_id == "" || store().lookup(note_id) == null) store().save(note);
                string dir = store().attachments_dir(note.id);
                DirUtils.create_with_parents(dir, 0700);
                string dest = Path.build_filename(dir, name);
                File.new_for_path(path).copy(File.new_for_path(dest), FileCopyFlags.OVERWRITE);
                FileUtils.chmod(dest, 0600);
                id = note.id;
                link = "attachments/%s/%s".printf(note.id, name);
            } finally {
                app.release();
            }
        }

        public void show(string note_id) throws Error {
            app.activate_action("show-note", new Variant.string(note_id));
        }
    }
}
