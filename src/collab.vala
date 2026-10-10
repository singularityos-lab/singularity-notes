namespace Singularity.Apps.Notes {

    [DBus (name = "dev.sinty.Collab.Note1")]
    public class NoteCollabBus : Object {
        private unowned NotesApp app;

        public NoteCollabBus(NotesApp app) {
            this.app = app;
        }

        public void receive(string title, string payload, string from) throws Error {
            app.hold();
            try {
                app.collab.receive(title, payload, from);
            } finally {
                app.release();
            }
        }

        public void join(string session, string title, string snapshot, string role, string from) throws Error {
            app.collab.join(session, title, snapshot, role, from);
        }
    }

    public class NotesCollab : Object {
        private class Link {
            public Singularity.Collab.Session session;
            public Singularity.Collab.TextBinding binding;
        }

        private unowned NotesApp app;
        private Gee.HashMap<string, Link> links = new Gee.HashMap<string, Link>();

        public signal void changed(string note_id);
        public signal void status(string message);

        public NotesCollab(NotesApp app) {
            this.app = app;
            app.store.changed.connect(() => {
                foreach (var l in links.values) l.binding.local_changed();
            });
        }

        public static bool available() {
            return Singularity.Collab.Client.installed();
        }

        public bool is_shared(string note_id) {
            return links.has_key(note_id);
        }

        public string[] people(string note_id) {
            var l = links[note_id];
            return l != null ? l.session.people.to_array() : new string[0];
        }

        private Singularity.Notes.NoteStore store() {
            return app.store;
        }

        private string body_of(string note_id) {
            var n = store().lookup(note_id);
            return n != null ? n.body : "";
        }

        private void write_body(string note_id, string body) {
            var n = store().lookup(note_id);
            if (n == null) return;
            var copy = n.copy();
            copy.body = body;
            try {
                store().save(copy);
            } catch (Error e) {
                warning("notes: %s", e.message);
            }
        }

        private Link bind(string note_id, Singularity.Collab.Text text, string title) {
            var l = new Link();
            l.session = new Singularity.Collab.Session("Note", title, text);
            string id = note_id;
            l.binding = new Singularity.Collab.TextBinding(text, () => body_of(id), (body, who) => write_body(id, body));
            l.session.person_joined.connect((name) => {
                status(_("%s joined the page").printf(name));
                changed(id);
            });
            l.session.person_left.connect((name) => {
                status(_("%s left the page").printf(name));
                changed(id);
            });
            l.session.closed.connect(() => {
                links.unset(id);
                status(_("The page is no longer shared"));
                changed(id);
            });
            links[note_id] = l;
            return l;
        }

        public void share(string note_id, Gtk.Widget anchor) {
            var n = store().lookup(note_id);
            if (n == null) return;
            var l = links[note_id];
            if (l == null) l = bind(note_id, new Singularity.Collab.Text(n.body), n.title);
            var session = l.session;
            session.pick_and_share(anchor, (person) => {
                status(_("Invitation sent to %s").printf(person.name));
                changed(note_id);
            });
        }

        public void stop(string note_id) {
            var l = links[note_id];
            if (l != null) l.session.stop.begin();
        }

        public void send(string note_id, Gtk.Widget anchor) {
            var n = store().lookup(note_id);
            if (n == null) return;
            var payload = new Json.Object();
            payload.set_string_member("markdown", n.body);
            Singularity.Collab.send_to(anchor, "Note", n.title, Singularity.Collab.Shared.encode(payload), n.body, (person) => {
                status(_("Sent to %s").printf(person.name));
            });
        }

        public void receive(string title, string payload, string from) throws Error {
            var o = Singularity.Collab.Shared.decode(payload);
            string body = o != null ? o.get_string_member_with_default("markdown", "") : "";
            if (body == "") body = "# %s\n".printf(title);
            var n = store().create(body);
            app.open_note(n.id);
            status(_("Note received from %s").printf(from));
        }

        public void join(string session_id, string title, string snapshot, string role, string from) throws Error {
            var text = new Singularity.Collab.Text();
            text.load(snapshot);
            var n = store().create(text.to_string());
            var l = bind(n.id, text, title);
            l.session.join(session_id, from);
            app.open_note(n.id);
            status(_("You are working on %s with %s").printf(title, from));
        }
    }
}
