namespace Singularity.Apps.Notes {

    public class TagDef : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public string icon { get; construct; }
        public string shortcut { get; set; default = ""; }

        public TagDef(string id, string label, string icon) {
            Object(id: id, label: label, icon: icon);
        }
    }

    public class TagCatalog : Object {
        private static TagCatalog? instance = null;
        private Gee.ArrayList<TagDef> builtin = new Gee.ArrayList<TagDef>();
        public Notebooks? notebooks = null;

        public static TagCatalog get_default() {
            if (instance == null) instance = new TagCatalog();
            return instance;
        }

        private TagCatalog() {
            add("important", _("Important"), "starred-symbolic", "2");
            add("question", _("Question"), "dialog-question-symbolic", "3");
            add("remember", _("Remember for Later"), "bookmark-new-symbolic", "4");
            add("definition", _("Definition"), "accessories-dictionary-symbolic", "5");
            add("highlight", _("Highlight"), "notes-marker-symbolic", "6");
            add("contact", _("Contact"), "notes-contact-symbolic", "7");
            add("address", _("Address"), "find-location-symbolic", "8");
            add("phone", _("Phone Number"), "notes-phone-symbolic", "9");
            add("website", _("Website to Visit"), "web-browser-symbolic", "");
            add("idea", _("Idea"), "notes-idea-symbolic", "");
            add("password", _("Password"), "dialog-password-symbolic", "");
            add("critical", _("Critical"), "dialog-warning-symbolic", "");
            add("project-a", _("Project A"), "notes-flag-symbolic", "");
            add("project-b", _("Project B"), "notes-flag-symbolic", "");
            add("movie", _("Movie to See"), "video-x-generic-symbolic", "");
            add("book", _("Book to Read"), "x-office-document-symbolic", "");
            add("music", _("Music to Listen To"), "audio-x-generic-symbolic", "");
            add("source", _("Source for Article"), "notes-quote-symbolic", "");
            add("discuss", _("Discuss Later"), "notes-discuss-symbolic", "");
            add("meeting", _("Schedule Meeting"), "notes-calendar-symbolic", "");
            add("callback", _("Call Back"), "notes-phone-symbolic", "");
            add("priority-1", _("Priority 1"), "notes-flag-symbolic", "");
            add("priority-2", _("Priority 2"), "notes-flag-symbolic", "");
            add("client", _("Client Request"), "mail-send-symbolic", "");
            add("task", _("Task in Tasks"), "notes-task-symbolic", "");
        }

        private void add(string id, string label, string icon, string shortcut) {
            var t = new TagDef(id, label, icon);
            t.shortcut = shortcut;
            builtin.add(t);
        }

        public Gee.List<TagDef> all() {
            var list = new Gee.ArrayList<TagDef>();
            list.add_all(builtin);
            if (notebooks != null) {
                foreach (string id in notebooks.custom_tags) list.add(new TagDef(id, notebooks.custom_tag_labels[id] ?? id, "notes-tag-symbolic"));
            }
            return list;
        }

        public TagDef lookup(string id) {
            if (id.has_prefix("task-")) return new TagDef(id, _("Task in Tasks"), "notes-task-symbolic");
            foreach (var t in all()) if (t.id == id) return t;
            return new TagDef(id, id, "notes-tag-symbolic");
        }

        public TagDef? by_shortcut(string key) {
            foreach (var t in builtin) if (t.shortcut == key) return t;
            return null;
        }

        public string add_custom(string label) {
            string id = "custom-" + slug(label);
            if (notebooks != null && !(id in notebooks.custom_tags)) {
                notebooks.custom_tags.add(id);
                notebooks.custom_tag_labels[id] = label;
                notebooks.save();
            }
            return id;
        }

        public static string slug(string s) {
            var sb = new StringBuilder();
            string low = s.down();
            for (int i = 0; i < low.length; i++) {
                char c = low[i];
                if (c.isalnum()) sb.append_c(c);
                else if (sb.len > 0 && sb.str[sb.len - 1] != '-') sb.append_c('-');
            }
            string r = sb.str;
            while (r.has_suffix("-")) r = r.substring(0, r.length - 1);
            return r != "" ? r : Uuid.string_random().substring(0, 6);
        }
    }

    public class TagHit : Object {
        public string note_id { get; construct; }
        public string tag { get; construct; }
        public string text { get; construct; }
        public int block_index { get; construct; }
        public bool is_check { get; set; default = false; }
        public bool done { get; set; default = false; }

        public TagHit(string note_id, string tag, string text, int block_index) {
            Object(note_id: note_id, tag: tag, text: text, block_index: block_index);
        }
    }

    public class TagIndex {
        public static Gee.List<TagHit> scan(string note_id, string body) {
            var hits = new Gee.ArrayList<TagHit>();
            var doc = PageDoc.parse(body);
            int index = 0;
            foreach (string md in sources(doc)) {
                foreach (var b in RichText.parse(md)) {
                    string text = b.plain_text().strip();
                    if (b.kind == BlockKind.CHECK) {
                        var h = new TagHit(note_id, "todo", text, index);
                        h.is_check = true;
                        h.done = b.checked;
                        hits.add(h);
                    }
                    foreach (string t in b.tags) hits.add(new TagHit(note_id, t, text, index));
                    index++;
                }
            }
            return hits;
        }

        public static Gee.List<string> sources(PageDoc doc) {
            var list = new Gee.ArrayList<string>();
            if (doc.meta.is_canvas) foreach (var c in doc.containers) list.add(c.markdown);
            else list.add(doc.body);
            return list;
        }
    }
}
