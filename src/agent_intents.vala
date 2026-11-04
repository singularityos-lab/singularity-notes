namespace Singularity.Apps.Notes {

    internal class NotesIntents : Object {
        private const string NOTE_ID = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}";

        private static Singularity.Notes.NoteStore store() {
            return Singularity.Notes.NoteStore.get_default();
        }

        private static string text(Json.Object args, string key) {
            return args.has_member(key) ? args.get_string_member(key) : "";
        }

        private static Singularity.Notes.Note find(Json.Object args) throws Error {
            var note = store().lookup(text(args, "id"));
            if (note == null) throw new IOError.NOT_FOUND("no note with this id");
            return note;
        }

        private static Json.Node brief(Singularity.Notes.Note note) {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("id").add_string_value(note.id);
            b.set_member_name("title").add_string_value(note.title);
            b.set_member_name("folder").add_string_value(note.folder);
            b.end_object();
            return b.get_root();
        }

        private static Json.Node briefs(Gee.List<Singularity.Notes.Note> notes, int64 limit) {
            var list = new Json.Array();
            foreach (var n in notes) {
                if (n.id == Singularity.Notes.NoteStore.QUICK_NOTE_ID || n.id.has_prefix(Singularity.Notes.NoteStore.WIDGET_PREFIX)) continue;
                if (list.get_length() == limit) break;
                list.add_element(brief(n));
            }
            var node = new Json.Node(Json.NodeType.ARRAY);
            node.set_array(list);
            return node;
        }

        internal static void install(NotesApp app) {
            var agent = app.agent;
            agent.add_intent("note_list", "List the most recent notes.",
                "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var recent = new Gee.ArrayList<Singularity.Notes.Note>();
                    recent.add_all(store().all());
                    recent.sort((a, b) => a.modified > b.modified ? -1 : (a.modified < b.modified ? 1 : 0));
                    return briefs(recent, args.has_member("limit") ? args.get_int_member("limit") : 50);
                });
            agent.add_intent("note_search", "Find notes by words in their title or text.",
                "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}",
                Singularity.AppIntentRisk.READ, (args) => briefs(store().search(text(args, "query")), 50));
            agent.add_intent("note_read", "Read the Markdown text of a note.", NOTE_ID,
                Singularity.AppIntentRisk.READ, (args) => {
                    var note = find(args);
                    var node = brief(note);
                    node.get_object().set_string_member("markdown", note.body);
                    return node;
                });
            agent.add_intent("note_create", "Create a note.",
                "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"markdown\":{\"type\":\"string\"},\"folder\":{\"type\":\"string\"}},\"required\":[\"title\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string body = "# %s\n".printf(text(args, "title"));
                    if (text(args, "markdown") != "") body += "\n" + text(args, "markdown").chomp() + "\n";
                    var note = store().create(body, text(args, "folder"));
                    return brief(note);
                });
            agent.add_intent("note_append", "Add Markdown at the end of a note, which stays open while it grows.",
                "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"markdown\":{\"type\":\"string\"}},\"required\":[\"id\",\"markdown\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var note = find(args).copy();
                    note.body = note.body.chomp() + "\n\n" + text(args, "markdown").chomp() + "\n";
                    store().save(note);
                    return brief(note);
                });
            agent.add_intent("note_show", "Open a note in the window.", NOTE_ID,
                Singularity.AppIntentRisk.READ, (args) => {
                    var note = find(args);
                    app.activate_action("show-note", new Variant.string(note.id));
                    return brief(note);
                });
            agent.add_intent("note_delete", "Delete a note.", NOTE_ID,
                Singularity.AppIntentRisk.IRREVERSIBLE, (args) => {
                    var note = find(args);
                    store().remove(note.id);
                    return brief(note);
                });
        }
    }
}
