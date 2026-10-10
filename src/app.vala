using Gtk;

namespace Singularity.Apps.Notes {

    public class NotesApp : Singularity.Application {
        public Singularity.Notes.NoteStore store { get; private set; }
        public GLib.Settings? settings { get; private set; default = null; }
        public SyncController sync { get; private set; }
        public Notebooks notebooks { get; private set; }
        public SectionLocks locks { get; private set; }
        public Trash trash { get; private set; }
        public History history { get; private set; }
        public Templates templates { get; private set; }
        public LockedFiles locked_files { get; private set; }
        public WebAccess web_access { get; private set; }
        public NotesCollab collab { get; private set; }

        private NotesWindow? window = null;
        private NotesSearch search_provider;

        public NotesApp() {
            Object(application_id: "dev.sinty.notes", flags: ApplicationFlags.HANDLES_COMMAND_LINE);
            search_provider = new NotesSearch(this);
            search_provider.export(this);
        }

        private uint notes_bus_id = 0;
        private uint collab_bus_id = 0;

        public override bool dbus_register(DBusConnection connection, string object_path) throws Error {
            if (!base.dbus_register(connection, object_path)) return false;
            notes_bus_id = connection.register_object("/dev/sinty/notes/Notes", new NotesBus(this));
            collab_bus_id = connection.register_object("/dev/sinty/notes/Collab", new NoteCollabBus(this));
            return true;
        }

        public override void dbus_unregister(DBusConnection connection, string object_path) {
            if (notes_bus_id != 0) connection.unregister_object(notes_bus_id);
            notes_bus_id = 0;
            if (collab_bus_id != 0) connection.unregister_object(collab_bus_id);
            collab_bus_id = 0;
            base.dbus_unregister(connection, object_path);
        }

        protected override void startup() {
            base.startup();
            IconTheme.get_for_display(Gdk.Display.get_default()).add_resource_path("/dev/sinty/notes/icons");
            var provider = new CssProvider();
            provider.load_from_string(CSS);
            StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            var schemas = SettingsSchemaSource.get_default();
            if (schemas != null && schemas.lookup("dev.sinty.notes", true) != null) settings = new GLib.Settings("dev.sinty.notes");
            store = Singularity.Notes.NoteStore.get_default();
            collab = new NotesCollab(this);
            collab.status.connect((message) => {
                if (window != null) window.add_toast(new Singularity.Widgets.Toast(message));
            });
            notebooks = new Notebooks(store.dir);
            TagCatalog.get_default().notebooks = notebooks;
            locks = new SectionLocks(notebooks);
            locked_files = new LockedFiles(locks, store.dir);
            trash = new Trash(store.dir);
            watch_tasks();
            web_access = new WebAccess(store, notebooks);
            trash.purge_old();
            history = new History(store.dir);
            templates = new Templates(store.dir);
            sync = new SyncController(store, settings);
            sync.notebooks = notebooks;
            sync.meta_updated.connect(() => {
                notebooks.load();
                notebooks.changed();
            });
            sync.start.begin();
            notebooks.changed.connect(() => sync.request());
            sync.watch_shared();

            var menu = new GLib.Menu();
            var file_menu = new GLib.Menu();
            var file_new = new GLib.Menu();
            file_new.append(_("New Page"), "win.new-note");
            file_new.append(_("New Subpage"), "win.new-subpage");
            file_new.append(_("New Page from Template…"), "win.new-from-template");
            file_new.append(_("New Section…"), "win.new-folder");
            file_new.append(_("New Section Group…"), "win.new-group");
            file_new.append(_("New Notebook…"), "win.new-notebook");
            file_menu.append_section(null, file_new);
            var file_io = new GLib.Menu();
            file_io.append(_("Import…"), "win.import");
            file_io.append(_("Export Page…"), "win.export-page");
            file_io.append(_("Export Section…"), "win.export-section");
            if (Capabilities.has_app("dev.sinty.slides")) file_io.append(_("Create Presentation"), "win.create-presentation");
            file_io.append(_("Print…"), "win.print");
            file_io.append(_("Share…"), "win.share");
            file_io.append(_("Save as Template…"), "win.save-template");
            file_menu.append_section(null, file_io);
            var file_live = new GLib.Menu();
            file_live.append(_("Start Live Session…"), "win.live-start");
            file_live.append(_("Join Live Session…"), "win.live-join");
            file_live.append(_("Leave Live Session"), "win.live-leave");
            file_live.append(_("Phone and Browser Access…"), "win.web-access");
            file_menu.append_section(null, file_live);
            var file_close = new GLib.Menu();
            file_close.append(_("Lock Protected Sections"), "win.lock-all");
            file_close.append(_("Close Window"), "win.close");
            file_close.append(_("Quit"), "app.quit");
            file_menu.append_section(null, file_close);
            menu.append_submenu(_("File"), file_menu);
            var edit_menu = new GLib.Menu();
            var edit_undo = new GLib.Menu();
            edit_undo.append(_("Undo"), "win.undo");
            edit_undo.append(_("Redo"), "win.redo");
            edit_menu.append_section(null, edit_undo);
            var edit_find = new GLib.Menu();
            edit_find.append(_("Search All Notes"), "win.find");
            edit_find.append(_("Find in Page"), "win.find-in-page");
            edit_menu.append_section(null, edit_find);
            var edit_page = new GLib.Menu();
            edit_page.append(_("Pin or Unpin"), "win.pin");
            edit_page.append(_("Make Subpage"), "win.demote");
            edit_page.append(_("Promote Subpage"), "win.promote");
            edit_page.append(_("Move Page Up"), "win.move-up");
            edit_page.append(_("Move Page Down"), "win.move-down");
            edit_page.append(_("Page Versions…"), "win.versions");
            edit_page.append(_("Delete Page"), "win.delete");
            edit_menu.append_section(null, edit_page);
            menu.append_submenu(_("Edit"), edit_menu);
            var view_menu = new GLib.Menu();
            view_menu.append(_("Tags"), "win.tags");
            view_menu.append(_("Recycle Bin"), "win.trash");
            view_menu.append(_("Math Assistant"), "win.math");
            view_menu.append(_("Immersive Reader"), "win.immersive-reader");
            if (Capabilities.available(Contracts.TRANSLATION)) view_menu.append(_("Translate…"), "win.translate");
            var insert_menu = new GLib.Menu();
            insert_menu.append(_("Table"), "win.insert-table");
            insert_menu.append(_("Drawing Space"), "win.insert-drawing");
            insert_menu.append(_("Equation…"), "win.insert-equation");
            insert_menu.append(_("Record Audio"), "win.record-audio");
            insert_menu.append(_("Record Video"), "win.record-video");
            insert_menu.append(_("Stop Recording"), "win.stop-recording");
            insert_menu.append(_("Transcribe Recordings"), "win.transcribe");
            if (Capabilities.available(Contracts.TASKS)) insert_menu.append(_("Add to Tasks…"), "win.add-task");
            menu.append_submenu(_("Insert"), insert_menu);
            menu.append_submenu(_("View"), view_menu);
            var sync_menu = new GLib.Menu();
            sync_menu.append(_("Sync Now"), "win.sync-now");
            sync_menu.append(_("Online Accounts…"), "win.accounts");
            menu.append_submenu(_("Sync"), sync_menu);
            set_menubar(menu);

            var quit_action = new SimpleAction("quit", null);
            quit_action.activate.connect(() => {
                if (window != null) window.flush();
                quit();
            });
            add_action(quit_action);
            var show = new SimpleAction("show-note", VariantType.STRING);
            show.activate.connect((p) => {
                activate();
                window.show_note(p.get_string());
            });
            add_action(show);
            var create = new SimpleAction("new-note", null);
            create.activate.connect(() => {
                activate();
                window.new_note();
            });
            add_action(create);

            var clip_text = new SimpleAction("clip-text", VariantType.STRING);
            clip_text.activate.connect((p) => {
                activate();
                clip(p.get_string());
            });
            add_action(clip_text);
            var clip_files = new SimpleAction("clip-files", new VariantType("as"));
            clip_files.activate.connect((p) => {
                activate();
                clip_uris(p.get_strv());
            });
            add_action(clip_files);

            set_accels_for_action("win.new-note", {"<Control>n"});
            set_accels_for_action("win.new-subpage", {"<Control><Shift>n"});
            set_accels_for_action("win.demote", {"<Control><Alt>bracketright"});
            set_accels_for_action("win.promote", {"<Control><Alt>bracketleft"});
            set_accels_for_action("win.move-up", {"<Alt><Shift>Up"});
            set_accels_for_action("win.move-down", {"<Alt><Shift>Down"});
            set_accels_for_action("win.print", {"<Control>p"});
            set_accels_for_action("win.find-in-page", {"<Control>f"});
            set_accels_for_action("win.undo", {"<Control>z"});
            set_accels_for_action("win.redo", {"<Control>y", "<Control><Shift>z"});
            set_accels_for_action("win.find", {"<Control>e"});
            set_accels_for_action("win.close", {"<Control>w"});
            set_accels_for_action("app.quit", {"<Control>q"});
            set_accels_for_action("win.pin", {"<Control>d"});
            set_accels_for_action("win.delete", {"<Control>Delete"});
        }

        private uint tasks_signal = 0;

        private void watch_tasks() {
            var cap = Capabilities.lookup(Contracts.TASKS);
            if (cap == null) return;
            try {
                var bus = Bus.get_sync(BusType.SESSION);
                tasks_signal = bus.signal_subscribe(cap.bus_name, Contracts.TASKS, "Changed", cap.object_path, null, DBusSignalFlags.NONE, () => {
                    LinkedTasks.sync_from_tasks.begin(store);
                });
            } catch (Error e) {
                warning("Notes: cannot watch Tasks: %s", e.message);
            }
            LinkedTasks.sync_from_tasks.begin(store);
        }

        protected override void shutdown() {
            if (window != null) window.flush();
            if (sync != null) sync.stop();
            if (locked_files != null) locked_files.destroy_all();
            base.shutdown();
        }

        protected override int command_line(ApplicationCommandLine command_line) {
            string[] args = command_line.get_arguments();
            activate();
            if ("--new-note" in args) window.new_note();
            for (int i = 1; i < args.length; i++) {
                if (args[i] == "--clip" && i + 1 < args.length) clip(args[++i]);
                else if (args[i] == "--import" && i + 1 < args.length) clip_uris({ File.new_for_commandline_arg(args[++i]).get_uri() });
            }
            return 0;
        }

        public void clip(string text) {
            if (window == null) return;
            string t = text.strip();
            if (t == "") return;
            if (Clipper.is_url(t)) {
                var w = window;
                string placeholder_id = "";
                var n = w.create_page("", "");
                if (n == null) return;
                placeholder_id = n.id;
                w.add_toast(new Singularity.Widgets.Toast(_("Clipping the page…")));
                Clipper.clip.begin(t, store.dir, placeholder_id, null, (o, r) => {
                    try {
                        var got = Clipper.clip.end(r);
                        var note = store.lookup(placeholder_id);
                        if (note == null) return;
                        var d = PageDoc.parse(note.body);
                        d.title = got.title;
                        d.body = got.body;
                        var c = note.copy();
                        c.body = d.serialize();
                        store.save(c, true);
                        w.show_note(placeholder_id);
                    } catch (Error e) {
                        var note = store.lookup(placeholder_id);
                        if (note != null) {
                            var d = PageDoc.parse(note.body);
                            d.title = t;
                            var link = new Block(BlockKind.PARAGRAPH);
                            link.add(new Span(t, false, false, t.replace(" ", "%20").replace(")", "%29")));
                            d.body = RichText.render_block(link);
                            var c = note.copy();
                            c.body = d.serialize();
                            try {
                                store.save(c, true);
                            } catch (Error e2) {
                            }
                            w.show_note(placeholder_id);
                        }
                        w.add_toast(new Singularity.Widgets.Toast(_("The page could not be clipped: %s").printf(e.message)));
                    }
                });
                return;
            }
            var d = new PageDoc();
            string first = t.split("\n")[0].strip();
            d.title = first.length > 80 ? first.substring(0, first.index_of_nth_char(80)) : first;
            d.body = t;
            window.new_note(d.serialize());
        }

        public void clip_uris(string[] uris) {
            if (window == null || uris.length == 0) return;
            var n = window.create_page("", "");
            if (n == null) return;
            var sb = new StringBuilder();
            string title = "";
            foreach (string u in uris) {
                var f = File.new_for_uri(u);
                string path = f.get_path() ?? "";
                if (path == "") {
                    if (Clipper.is_url(u)) {
                        clip(u);
                    }
                    continue;
                }
                if (title == "") title = f.get_basename() ?? "";
                try {
                    if (Importer.supported(path) && uris.length == 1 && !path.down().has_suffix(".txt")) {
                        store.remove(n.id);
                        Importer.import_file.begin(f, store, "", (o, r) => {
                            try {
                                var got = Importer.import_file.end(r);
                                window.add_toast(new Singularity.Widgets.Toast(ngettext("%d page imported", "%d pages imported", got.size).printf(got.size)));
                            } catch (Error e) {
                                window.add_toast(new Singularity.Widgets.Toast(e.message));
                            }
                        });
                        return;
                    }
                    string rel = Attachments.import_file(store.dir, n.id, f);
                    if (Attachments.is_image(path)) {
                        sb.append("![%s](%s)\n".printf(RichText.escape(f.get_basename() ?? ""), rel));
                    } else {
                        sb.append("[%s](%s)\n".printf(RichText.escape(f.get_basename() ?? ""), rel));
                        if (Attachments.is_pdf(path)) {
                            int page = 1;
                            foreach (string img in Attachments.pdf_printout(store.dir, n.id, Path.build_filename(store.dir, rel))) {
                                sb.append("![%s](%s)\n".printf(RichText.escape(_("%s, page %d").printf(f.get_basename(), page++)), img));
                            }
                        }
                    }
                } catch (Error e) {
                    window.add_toast(new Singularity.Widgets.Toast(e.message));
                }
            }
            if (sb.len == 0) {
                try {
                    store.remove(n.id);
                } catch (Error e) {
                }
                return;
            }
            var d = new PageDoc();
            d.title = title;
            d.body = sb.str;
            var c = n.copy();
            c.body = d.serialize();
            try {
                store.save(c, true);
            } catch (Error e) {
            }
            window.show_note(n.id);
        }

        protected override void activate() {
            if (window == null) {
                window = new NotesWindow(this);
                window.close_request.connect(() => {
                    window.flush();
                    window = null;
                    return false;
                });
            }
            window.present();
        }

        public void open_note(string id) {
            hold();
            activate();
            window.show_note(id);
            release();
        }

        private const string CSS = """
.notes-list {
    background: transparent;
    padding: 0 10px 16px 10px;
}

.notes-list > row {
    border-radius: 12px;
    padding: 9px 10px;
    margin: 1px 0;
}

.notes-list > row:selected {
    background-color: alpha(@accent_bg_color, 0.16);
    color: inherit;
}

.notes-row-title {
    font-weight: 600;
}

.notes-subpage .notes-row-title {
    font-weight: 500;
}

.notes-row-date {
    font-size: 12px;
    font-weight: 600;
    opacity: 0.75;
}

.notes-row-snippet,
.notes-row-folder {
    font-size: 12px;
    opacity: 0.6;
}

.notes-expander {
    min-width: 20px;
    min-height: 20px;
    padding: 0;
}

.notes-pin,
.notes-pinned image {
    color: #e5a50a;
}

.notes-count {
    font-size: 12px;
    font-feature-settings: "tnum";
    opacity: 0.55;
}

.notes-text,
.notes-text text {
    background: transparent;
    font-size: 15px;
    caret-color: currentColor;
}

.notes-format-bar {
    border-bottom: 1px solid alpha(currentColor, 0.08);
}

.notes-page-header {
    padding: 18px 32px 4px 32px;
}

.notes-title-entry {
    font-size: 26px;
    font-weight: 700;
    background: transparent;
    padding: 0;
    min-height: 40px;
}

.notes-date-button {
    padding: 2px 0;
    min-height: 0;
}

.notes-date-button label {
    font-size: 12px;
}

.notes-image {
    border-radius: 10px;
}

.notes-resize-handle {
    background: alpha(@accent_bg_color, 0.85);
    border-radius: 7px 0 10px 0;
    opacity: 0.0;
}

.notes-image-object:hover .notes-resize-handle {
    opacity: 1.0;
}

.notes-file {
    padding: 8px 12px;
    border-radius: 12px;
    background: alpha(currentColor, 0.05);
}

.notes-file-name {
    font-weight: 600;
}

.notes-table {
    border: 1px solid alpha(currentColor, 0.18);
    border-radius: 6px;
}

.notes-cell {
    border-right: 1px solid alpha(currentColor, 0.14);
    border-bottom: 1px solid alpha(currentColor, 0.14);
    border-radius: 0;
    min-height: 30px;
    padding: 2px 8px;
    background: transparent;
}

.notes-cell-header {
    font-weight: 700;
    background: alpha(currentColor, 0.05);
}

.notes-shade-0, .notes-shade-0 text { background: alpha(#fff3bf, 0.9); color: #1e1e1e; }
.notes-shade-1, .notes-shade-1 text { background: alpha(#d3f9d8, 0.9); color: #1e1e1e; }
.notes-shade-2, .notes-shade-2 text { background: alpha(#d0ebff, 0.9); color: #1e1e1e; }
.notes-shade-3, .notes-shade-3 text { background: alpha(#ffe3e3, 0.9); color: #1e1e1e; }
.notes-shade-4, .notes-shade-4 text { background: alpha(#f3d9fa, 0.9); color: #1e1e1e; }
.notes-shade-5, .notes-shade-5 text { background: alpha(#e9ecef, 0.9); color: #1e1e1e; }
.notes-shade-6, .notes-shade-6 text { background: alpha(#ffd8a8, 0.9); color: #1e1e1e; }

.notes-ink-frame {
    border: 1px dashed alpha(currentColor, 0.18);
    border-radius: 8px;
}

.notes-ink-handle {
    min-width: 80px;
    border-radius: 4px;
    background: alpha(currentColor, 0.12);
}

.notes-ink-handle:hover {
    background: alpha(@accent_bg_color, 0.6);
}

.notes-canvas {
    background: transparent;
}

.notes-container {
    border-radius: 8px;
    border: 1px solid transparent;
}

.notes-container:hover,
.notes-container:focus-within {
    border-color: alpha(currentColor, 0.18);
}

.notes-container-grip {
    border-radius: 8px 8px 0 0;
}

.notes-container.page-selected {
    border-color: @accent_bg_color;
    background: alpha(@accent_bg_color, 0.12);
}

.notes-container:hover .notes-container-grip,
.notes-container:focus-within .notes-container-grip {
    background: alpha(currentColor, 0.08);
}

.notes-container-edge:hover {
    background: alpha(@accent_bg_color, 0.35);
}

.notes-recording {
    padding: 6px 10px;
    border-radius: 12px;
    background: alpha(currentColor, 0.05);
}

.notes-transcript {
    font-style: italic;
    opacity: 0.8;
    margin-top: 4px;
}

.notes-record-bar {
    padding: 8px 24px;
    background: alpha(#e01b24, 0.1);
}

.notes-record-dot {
    color: #e01b24;
}

.notes-tag-chip {
    color: #9141ac;
}

.notes-tag-important, .notes-tag-critical { color: #e5a50a; }
.notes-tag-question { color: #1c71d8; }
.notes-tag-idea { color: #e5a50a; }
.notes-tag-highlight { color: #c88800; }
.notes-tag-password, .notes-tag-priority-1 { color: #e01b24; }
.notes-tag-priority-2 { color: #ff7800; }
.notes-tag-contact, .notes-tag-phone, .notes-tag-callback, .notes-tag-address { color: #2ec27e; }

.notes-bg-yellow .notes-text, .notes-bg-yellow .notes-canvas, .notes-bg-yellow .notes-page-header { background-color: #fff9db; color: #1e1e22; }
.notes-bg-green .notes-text, .notes-bg-green .notes-canvas, .notes-bg-green .notes-page-header { background-color: #ebfbee; color: #1e1e22; }
.notes-bg-blue .notes-text, .notes-bg-blue .notes-canvas, .notes-bg-blue .notes-page-header { background-color: #e7f5ff; color: #1e1e22; }
.notes-bg-pink .notes-text, .notes-bg-pink .notes-canvas, .notes-bg-pink .notes-page-header { background-color: #fff0f6; color: #1e1e22; }
.notes-bg-purple .notes-text, .notes-bg-purple .notes-canvas, .notes-bg-purple .notes-page-header { background-color: #f3f0ff; color: #1e1e22; }
.notes-bg-grey .notes-text, .notes-bg-grey .notes-canvas, .notes-bg-grey .notes-page-header { background-color: #f1f3f5; color: #1e1e22; }
.notes-bg-orange .notes-text, .notes-bg-orange .notes-canvas, .notes-bg-orange .notes-page-header { background-color: #fff4e6; color: #1e1e22; }

.notes-bg-yellow entry, .notes-bg-yellow entry text, .notes-bg-yellow .notes-page-header label, .notes-bg-yellow .notes-canvas label { color: #1e1e22; }
.notes-bg-green entry, .notes-bg-green entry text, .notes-bg-green .notes-page-header label, .notes-bg-green .notes-canvas label { color: #1e1e22; }
.notes-bg-blue entry, .notes-bg-blue entry text, .notes-bg-blue .notes-page-header label, .notes-bg-blue .notes-canvas label { color: #1e1e22; }
.notes-bg-pink entry, .notes-bg-pink entry text, .notes-bg-pink .notes-page-header label, .notes-bg-pink .notes-canvas label { color: #1e1e22; }
.notes-bg-purple entry, .notes-bg-purple entry text, .notes-bg-purple .notes-page-header label, .notes-bg-purple .notes-canvas label { color: #1e1e22; }
.notes-bg-grey entry, .notes-bg-grey entry text, .notes-bg-grey .notes-page-header label, .notes-bg-grey .notes-canvas label { color: #1e1e22; }
.notes-bg-orange entry, .notes-bg-orange entry text, .notes-bg-orange .notes-page-header label, .notes-bg-orange .notes-canvas label { color: #1e1e22; }

.notes-trash-preview {
    font-size: 14px;
    padding: 4px;
}

.notes-template {
    padding: 14px 10px;
    border-radius: 14px;
}

.notes-math-steps {
    font-family: monospace;
    font-size: 14px;
}

.notes-presence {
    font-size: 12px;
    font-weight: 600;
    color: #26a269;
}

.notes-reader-text {
    font-family: serif;
}

.notes-reader-light, .notes-reader-light text { background-color: #ffffff; color: #1e1e22; }
.notes-reader-sepia, .notes-reader-sepia text { background-color: #f4ecd8; color: #3b2f1e; }
.notes-reader-dark, .notes-reader-dark text { background-color: #1e1e22; color: #e8e8ea; }

.notes-translation {
    font-size: 15px;
}

.notes-add-page {
    border-radius: 10px;
}
""";

        public static int main(string[] args) {
            Intl.setlocale(LocaleCategory.ALL, "");
            string locale_dir = "/usr/share/locale";
            try {
                string exe = FileUtils.read_link("/proc/self/exe");
                locale_dir = Path.build_filename(Path.get_dirname(Path.get_dirname(exe)), "share", "locale");
            } catch (Error e) {
            }
            Intl.bindtextdomain("singularity-notes", locale_dir);
            Intl.bind_textdomain_codeset("singularity-notes", "UTF-8");
            Intl.textdomain("singularity-notes");
            unowned string[] gst_args = null;
            Gst.init(ref gst_args);
            return new NotesApp().run(args);
        }
    }
}
