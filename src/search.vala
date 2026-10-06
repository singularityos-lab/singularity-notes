namespace Singularity.Apps.Notes {

    public class NotesSearch : Singularity.SearchProviderService {
        private const int MAX_RESULTS = 12;
        private NotesApp app;

        public NotesSearch(NotesApp app) {
            this.app = app;
        }

        public override async string[] get_initial_results(string[] terms, Cancellable? cancellable) throws Error {
            string query = string.joinv(" ", terms).strip();
            if (query.char_count() < 2 || app.store == null) return {};
            string[] ids = {};
            var title_hits = new Gee.ArrayList<string>();
            var body_hits = new Gee.ArrayList<string>();
            string q = query.casefold();
            foreach (var n in app.store.all()) {
                if (SectionLocks.is_locked_body(n.body)) continue;
                string title = PageDoc.title_of(n.body).casefold();
                string hay = (PageDoc.parse(n.body).plain_text() + "\n" + n.folder + "\n" + OcrIndex.media_text(app.store.dir, n.body)).casefold();
                bool ok = true;
                foreach (string term in q.split(" ")) if (term != "" && !hay.contains(term)) ok = false;
                if (!ok) continue;
                if (title.contains(q)) title_hits.add(n.id);
                else body_hits.add(n.id);
            }
            foreach (string id in title_hits) {
                if (ids.length >= MAX_RESULTS) break;
                ids += id;
            }
            foreach (string id in body_hits) {
                if (ids.length >= MAX_RESULTS) break;
                ids += id;
            }
            return ids;
        }

        public override async Singularity.SearchResultMeta[] get_result_metas(string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            int rank = 0;
            foreach (string id in ids) {
                var n = app.store.lookup(id);
                if (n == null) continue;
                string title = PageDoc.title_of(n.body);
                var meta = new Singularity.SearchResultMeta(id, title != "" ? title : _("Untitled Page"));
                string when = NotesFormat.when(n.modified);
                string snippet = PageDoc.snippet_of(n.body);
                string[] parts = {};
                if (when != "") parts += when;
                if (n.folder != "") parts += n.folder;
                if (snippet != "") parts += snippet;
                meta.description = string.joinv(", ", parts);
                meta.icon = new ThemedIcon("dev.sinty.notes");
                meta.add_action("copy", _("Copy"), "edit-copy-symbolic");
                meta.score = 100 - rank;
                rank++;
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result(string id, string[] terms, uint32 timestamp) throws Error {
            app.activate_action("show-note", new Variant.string(id));
            return null;
        }

        public override async Singularity.SearchActivationReply? activate_action(string id, string action_id, string[] terms, uint32 timestamp) throws Error {
            var n = app.store.lookup(id);
            if (n == null || action_id != "copy" || SectionLocks.is_locked_body(n.body)) return null;
            return Singularity.SearchActivationReply.copy(PageDoc.parse(n.body).plain_text().strip());
        }
    }
}
