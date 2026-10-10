using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Notes {

    public class NoteRow : ListBoxRow {
        public Singularity.Notes.Note note { get; construct; }
        public int level { get; construct; }
        public signal void toggle_children();
        public Button? expander = null;

        public NoteRow(Singularity.Notes.Note note, bool show_folder, string title, string snippet, int level = 0, int children = 0, bool collapsed = false) {
            Object(note: note, level: level);
            add_css_class("notes-row");
            if (level > 0) add_css_class("notes-subpage");
            var outer = new Box(Orientation.HORIZONTAL, 4);
            outer.margin_start = level * 22;
            if (children > 0) {
                expander = new Button.from_icon_name(collapsed ? "pan-end-symbolic" : "pan-down-symbolic");
                expander.add_css_class("flat");
                expander.add_css_class("notes-expander");
                expander.valign = Align.START;
                expander.tooltip_text = collapsed ? _("Show Subpages") : _("Hide Subpages");
                expander.clicked.connect(() => toggle_children());
                outer.append(expander);
            } else {
                var gap = new Box(Orientation.HORIZONTAL, 0);
                gap.set_size_request(24, -1);
                outer.append(gap);
            }
            var box = new Box(Orientation.VERTICAL, 2);
            box.hexpand = true;
            var top = new Box(Orientation.HORIZONTAL, 6);
            var title_label = new Label(title != "" ? title : _("Untitled Page"));
            title_label.xalign = 0;
            title_label.hexpand = true;
            title_label.ellipsize = Pango.EllipsizeMode.END;
            title_label.add_css_class("notes-row-title");
            top.append(title_label);
            if (note.pinned) {
                var pin = new Image.from_icon_name("view-pin-symbolic");
                pin.pixel_size = 14;
                pin.add_css_class("notes-pin");
                pin.tooltip_text = _("Pinned");
                top.append(pin);
            }
            box.append(top);
            var meta = new Box(Orientation.HORIZONTAL, 6);
            var when = new Label(NotesFormat.when(note.modified));
            when.add_css_class("notes-row-date");
            meta.append(when);
            string snip = snippet;
            if (snip == "" && show_folder && note.folder != "") snip = note.folder;
            var sub = new Label(snip != "" ? snip : _("No additional text"));
            sub.xalign = 0;
            sub.hexpand = true;
            sub.ellipsize = Pango.EllipsizeMode.END;
            sub.add_css_class("notes-row-snippet");
            meta.append(sub);
            box.append(meta);
            if (show_folder && note.folder != "" && snippet != "") {
                var folder = new Label(note.folder.replace("/", " › "));
                folder.xalign = 0;
                folder.ellipsize = Pango.EllipsizeMode.END;
                folder.add_css_class("notes-row-folder");
                box.append(folder);
            }
            outer.append(box);
            child = Singularity.Animation.ListAnimator.wrap(outer);
        }
    }

    public class NotesFormat {
        public static string when(int64 unix_time) {
            if (unix_time <= 0) return "";
            var t = new DateTime.from_unix_local(unix_time);
            var now = new DateTime.now_local();
            if (t.get_year() == now.get_year() && t.get_day_of_year() == now.get_day_of_year()) return t.format("%H:%M");
            var yesterday = now.add_days(-1);
            if (t.get_year() == yesterday.get_year() && t.get_day_of_year() == yesterday.get_day_of_year()) return _("Yesterday");
            if (now.difference(t) < 6 * TimeSpan.DAY) return t.format("%A");
            return t.format("%x");
        }
    }

    public class NotesWindow : Singularity.Widgets.Window {
        private const string ALL = "all";
        private const string PINNED = "pinned";
        private const string QUICK = "quick";
        private const string TAGS = "tags";
        private const string TRASH = "trash";

        private NotesApp app;
        private Singularity.Notes.NoteStore store;
        private AppSidebar sidebar;
        private Stack stack;
        private Stack list_stack;
        private Stack editor_stack;
        private ListBox list;
        private StatusPage empty;
        private Label heading;
        private Label count_label;
        private PageView page;
        private Ribbon ribbon;
        private BubbleSwitcher ribbon_switcher;
        private SearchBubble search;
        private Button pin_bubble;
        private Button page_menu_bubble;
        private Button delete_bubble;
        private Singularity.Animation.ListAnimator animator;
        private TagSummary tag_summary;
        private Box trash_detail;
        private Label trash_title;
        private Label trash_preview;
        private StatusPage locked_page;
        private string view = ALL;
        private string query = "";
        private string current_id = "";
        private Singularity.Notes.Note? editing = null;
        private uint refresh_source = 0;
        private SidebarRow? sync_row = null;
        private Gee.HashMap<string, SidebarRow> view_rows = new Gee.HashMap<string, SidebarRow>();
        private Gee.HashSet<string> collapsed_folders = new Gee.HashSet<string>();
        private Gee.HashSet<string> collapsed_pages = new Gee.HashSet<string>();
        private Gee.HashMap<string, string> plain_cache = new Gee.HashMap<string, string>();
        private string selected_trash = "";
        private Button add_page_button;

        public NotesWindow(NotesApp app) {
            Object(application: app);
            this.app = app;
            this.store = app.store;
            set_default_size(1280, 780);
            set_title(_("Notes"));

            sidebar = new AppSidebar(250);
            set_sidebar(sidebar);

            stack = new Stack();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.transition_duration = Singularity.Motion.Duration.MEDIUM;
            stack.add_named(build_welcome(), "welcome");
            stack.add_named(build_main(), "main");
            set_content(stack);

            ribbon_switcher = ribbon.tabs;
            ribbon.attach(this);
            search = add_bubble_search(_("Search Notes"), (t) => {
                query = t.strip();
                queue_refresh();
            });
            add_bubble_icon("list-add-symbolic", _("New Page (Ctrl+N)"), () => new_note());
            pin_bubble = add_bubble_icon("view-pin-symbolic", _("Pin Page"), () => toggle_pin());
            page_menu_bubble = add_bubble_icon("view-more-symbolic", _("Page"), () => {
                var n = store.lookup(current_id);
                if (n != null) Menus.popup(page_menu_bubble, page_menu_bubble.get_width() / 2.0, page_menu_bubble.get_height(), (m) => page_menu(m, n));
            });
            delete_bubble = add_bubble_icon("user-trash-symbolic", _("Delete Page"), () => delete_current());

            install_actions();
            ((SimpleAction) lookup_action("sync-with")).set_state(new Variant.string(app.sync.chosen_id()));
            store.changed.connect(() => {
                plain_cache.clear();
                queue_refresh();
            });
            store.changed.connect(follow_store);
            app.notebooks.changed.connect(queue_refresh);
            app.locks.changed.connect(() => {
                plain_cache.clear();
                app.locked_files.wipe();
                var cur_note = store.lookup(current_id);
                if (cur_note != null && SectionLocks.is_locked_body(cur_note.body) && app.locks.is_unlocked(cur_note.folder)) app.locked_files.prepare(cur_note.folder, cur_note.id, plain_body(cur_note));
                queue_refresh();
                if (current_id != "") {
                    var n = store.lookup(current_id);
                    if (n != null && !app.locks.is_unlocked(n.folder)) {
                        current_id = "";
                        editor_stack.visible_child_name = "nothing";
                    }
                }
            });
            app.trash.changed.connect(queue_refresh);
            app.sync.changed.connect(() => {
                update_sync_row();
                var sa = lookup_action("sync-with") as SimpleAction;
                if (sa != null) sa.set_state(new Variant.string(app.sync.chosen_id()));
                if (app.sync.status == SyncStatus.DONE && app.sync.message != "") add_toast(new Toast(app.sync.message));
            });
            app.sync.accounts_changed.connect(queue_refresh);
            app.sync.presence_changed.connect(update_presence);
            OcrIndex.get_default().indexed.connect(() => plain_cache.clear());
            view = app.settings != null ? app.settings.get_string("last-view") : ALL;
            if (!valid_view(view)) view = ALL;
            refresh();
            string last = app.settings != null ? app.settings.get_string("last-note") : "";
            if (last != "" && store.lookup(last) != null && view != TAGS && view != TRASH) open_note(last);
            else select_first();
            stack.notify["visible-child-name"].connect(() => {
                set_sidebar_visible(stack.visible_child_name != "welcome");
                update_bubbles();
            });
            stack.visible_child_name = store.all().size == 0 && store.extra_folders().length == 0 ? "welcome" : "main";
            set_sidebar_visible(stack.visible_child_name != "welcome");
            Timeout.add_seconds(30, () => {
                int minutes = app.settings != null ? app.settings.get_int("lock-after") : 10;
                if (minutes > 0) app.locks.lock_idle(minutes * 60);
                return Source.CONTINUE;
            });
            index_media.begin();
        }

        private bool valid_view(string v) {
            if (v == ALL || v == PINNED || v == QUICK || v == TAGS || v == TRASH) return true;
            if (v.has_prefix("folder:")) {
                string f = v.substring(7);
                foreach (string x in store.folders()) if (x == f || x.has_prefix(f + "/")) return true;
                return app.notebooks.peek(f) != null;
            }
            return false;
        }

        private async void index_media() {
            if (app.settings != null && !app.settings.get_boolean("recognize-images")) return;
            yield;
            foreach (var n in store.all()) {
                if (SectionLocks.is_locked_body(n.body)) continue;
                OcrIndex.get_default().index_note(store.dir, n.id, n.body);
            }
        }

        private Widget build_welcome() {
            var wp = new WelcomePage();
            wp.app_icon_name = "dev.sinty.notes";
            wp.title = _("Notes");
            wp.subtitle = _("Notebooks for ideas, lists, drawings and recordings, kept in sync with your accounts");
            wp.add_action("text-x-generic", _("New Page"), _("Start writing right away"), () => new_note());
            wp.add_action("accessories-dictionary", _("New Notebook"), _("Sections and pages for a subject or a project"), () => new_folder(FolderKind.NOTEBOOK, ""));
            wp.add_action("notes-checklist", _("New Page from a Template"), _("Meeting notes, to-do lists, lecture notes and more"), () => choose_template());
            wp.add_action("singularity-account-nextcloud", _("Sync with an Account"), _("Nextcloud Notes or a WebDAV folder from Online Accounts"), () => open_accounts());
            return wp;
        }

        private Widget build_main() {
            var content = new Box(Orientation.HORIZONTAL, 0);

            var column = new Box(Orientation.VERTICAL, 0);
            column.set_size_request(300, -1);
            column.hexpand = false;
            column.add_css_class("notes-list-column");
            var header = new Box(Orientation.VERTICAL, 0);
            header.margin_start = 20;
            header.margin_end = 20;
            header.margin_bottom = 8;
            apply_view_edge(header);
            heading = new Label("");
            heading.xalign = 0;
            heading.ellipsize = Pango.EllipsizeMode.END;
            heading.add_css_class("title-2");
            header.append(heading);
            count_label = new Label("");
            count_label.xalign = 0;
            count_label.add_css_class("dim-label");
            header.append(count_label);
            column.append(header);

            list = new ListBox();
            list.add_css_class("notes-list");
            list.selection_mode = SelectionMode.SINGLE;
            list.row_selected.connect((row) => {
                var nr = row as NoteRow;
                if (nr == null) return;
                if (view == TRASH) {
                    show_trash_item(nr.note.id);
                    return;
                }
                if (nr.note.id != current_id) open_note(nr.note.id);
            });
            animator = new Singularity.Animation.ListAnimator(list);
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = list;

            empty = new StatusPage();
            empty.compact = true;
            list_stack = new Stack();
            list_stack.vexpand = true;
            list_stack.transition_type = StackTransitionType.CROSSFADE;
            list_stack.add_named(scroll, "list");
            list_stack.add_named(empty, "empty");
            column.append(list_stack);
            var add_page = new Button();
            var add_box = new Box(Orientation.HORIZONTAL, 6);
            add_box.append(new Image.from_icon_name("list-add-symbolic"));
            add_box.append(new Label(_("Add Page")));
            add_page.child = add_box;
            add_page.add_css_class("flat");
            add_page.add_css_class("notes-add-page");
            add_page.margin_start = 12;
            add_page.margin_end = 12;
            add_page.margin_bottom = 10;
            add_page.clicked.connect(() => new_note());
            add_page_button = add_page;
            Menus.on_secondary(add_page, (m) => {
                m.add_item(_("New Page"), "text-x-generic-symbolic", () => new_note());
                m.add_item(_("New Subpage"), "notes-subpage-symbolic", () => new_subpage());
                m.add_item(_("New Page from Template…"), "document-new-symbolic", () => choose_template());
            });
            column.append(add_page);
            content.append(column);
            content.append(new Separator(Orientation.VERTICAL));

            page = new PageView();
            page.notes_dir = store.dir;
            page.hexpand = true;
            page.edited.connect(on_edited);
            page.status.connect((m) => add_toast(new Toast(m)));
            page.navigate.connect(navigate);
            page.page_link_requested.connect((ed) => pick_link(ed, true));
            page.link_dialog_requested.connect((ed) => pick_link(ed, false));
            RichEditor.link_title = (href) => title_for_link(href);
            page.date_changed.connect((t) => {
                var n = store.lookup(current_id);
                if (n == null) return;
                var c = n.copy();
                c.created = t;
                save(c, false);
                editing = c.copy();
            });
            ribbon = new Ribbon(page);
            ribbon.tag_summary_requested.connect(() => select_view(TAGS));
            ribbon.versions_requested.connect(() => show_versions());
            ribbon.page_link_requested.connect(() => {
                if (page.active_editor != null) pick_link(page.active_editor, false);
            });
            var editor_box = new Box(Orientation.VERTICAL, 0);
            apply_view_edge(editor_box);
            editor_box.append(ribbon);
            editor_box.append(page);

            var nothing = new StatusPage();
            nothing.icon_name = "text-x-generic-symbolic";
            nothing.title = _("No Page Selected");
            nothing.description = _("Pick a page from the list or start a new one");
            var start_button = new Button.with_label(_("New Page"));
            start_button.add_css_class("pill");
            start_button.add_css_class("suggested-action");
            start_button.halign = Align.CENTER;
            start_button.clicked.connect(() => new_note());
            nothing.child = start_button;

            tag_summary = new TagSummary(store, app.locks);
            tag_summary.open_hit.connect((hit) => {
                show_note(hit.note_id);
                Idle.add(() => {
                    page.jump_to_block(hit.block_index);
                    return Source.REMOVE;
                });
            });

            locked_page = new StatusPage();
            locked_page.icon_name = "system-lock-screen-symbolic";
            locked_page.title = _("This Section Is Protected");
            locked_page.description = _("Enter the password to see its pages");
            var unlock_button = new Button.with_label(_("Unlock"));
            unlock_button.add_css_class("pill");
            unlock_button.add_css_class("suggested-action");
            unlock_button.halign = Align.CENTER;
            unlock_button.clicked.connect(() => ask_unlock(view_folder()));
            locked_page.child = unlock_button;

            trash_detail = new Box(Orientation.VERTICAL, 12);
            trash_detail.margin_start = 32;
            trash_detail.margin_end = 32;
            trash_detail.margin_top = 24;
            trash_title = new Label("");
            trash_title.xalign = 0;
            trash_title.add_css_class("title-2");
            trash_title.wrap = true;
            trash_detail.append(trash_title);
            var trash_buttons = new Box(Orientation.HORIZONTAL, 8);
            var restore = new Button.with_label(_("Restore"));
            restore.add_css_class("suggested-action");
            restore.clicked.connect(() => restore_trash(selected_trash));
            var forever = new Button.with_label(_("Delete Forever"));
            forever.add_css_class("destructive-action");
            forever.clicked.connect(() => delete_trash_forever(selected_trash));
            var empty_bin = new Button.with_label(_("Empty Recycle Bin"));
            empty_bin.clicked.connect(() => confirm_empty_trash());
            trash_buttons.append(restore);
            trash_buttons.append(forever);
            trash_buttons.append(empty_bin);
            trash_detail.append(trash_buttons);
            var preview_scroll = new ScrolledWindow();
            preview_scroll.vexpand = true;
            trash_preview = new Label("");
            trash_preview.xalign = 0;
            trash_preview.yalign = 0;
            trash_preview.wrap = true;
            trash_preview.selectable = true;
            trash_preview.add_css_class("notes-trash-preview");
            preview_scroll.child = trash_preview;
            trash_detail.append(preview_scroll);

            editor_stack = new Stack();
            editor_stack.hexpand = true;
            editor_stack.transition_type = StackTransitionType.CROSSFADE;
            editor_stack.add_named(editor_box, "editor");
            editor_stack.add_named(nothing, "nothing");
            editor_stack.add_named(tag_summary, "tags");
            editor_stack.add_named(locked_page, "locked");
            editor_stack.add_named(trash_detail, "trash");
            content.append(editor_stack);
            return content;
        }

        private void install_actions() {
            var entries = new ActionEntry[] {
                { "new-note", () => new_note() },
                { "new-subpage", () => new_subpage() },
                { "new-from-template", () => choose_template() },
                { "new-folder", () => new_folder(FolderKind.SECTION, current_parent()) },
                { "new-notebook", () => new_folder(FolderKind.NOTEBOOK, "") },
                { "new-group", () => new_folder(FolderKind.GROUP, current_parent()) },
                { "find", () => search.grab_focus_entry() },
                { "find-in-page", () => page.open_find(false) },
                { "pin", () => toggle_pin() },
                { "delete", () => delete_current() },
                { "undo", () => page.undo() },
                { "redo", () => page.redo() },
                { "versions", () => show_versions() },
                { "export-page", () => export_dialog(false) },
                { "export-section", () => export_dialog(true) },
                { "print", () => print_current() },
                { "import", () => import_files() },
                { "save-template", () => save_as_template() },
                { "share", () => share_current() },
                { "create-presentation", () => create_presentation() },
                { "tags", () => select_view(TAGS) },
                { "trash", () => select_view(TRASH) },
                { "lock-all", () => app.locks.lock_all() },
                { "promote", () => change_level(-1) },
                { "demote", () => change_level(1) },
                { "move-up", () => move_page(-1) },
                { "move-down", () => move_page(1) },
                { "math", () => page.open_math_assistant() },
                { "record-audio", () => page.start_recording(false) },
                { "record-video", () => page.start_recording(true) },
                { "stop-recording", () => page.stop_recording() },
                { "immersive-reader", () => page.open_reader() },
                { "translate", () => page.translate() },
                { "add-task", () => page.add_task() },
                { "transcribe", () => page.transcribe_all() },
                { "insert-equation", () => page.insert_equation() },
                { "insert-table", () => page.insert_table(3, 3) },
                { "insert-drawing", () => page.insert_drawing() },
                { "protect-section", on_protect_section, "s" },
                { "open-section", on_open_section, "s" },
                { "sync-now", () => app.sync.sync_now() },
                { "accounts", () => open_accounts() },
                { "sync-with", on_sync_with, "s", "''" },
                { "move-to", on_move_to, "s" },
                { "live-start", () => start_live() },
                { "live-join", () => join_live() },
                { "live-invite", () => show_live_invite() },
                { "live-leave", () => leave_live(true) },
                { "web-access", () => web_access_dialog() },
                { "close", () => close() }
            };
            add_action_entries(entries, this);
        }

        private string current_parent() {
            string f = view_folder();
            if (f == "") return "";
            var tree = app.notebooks.tree(store.folders());
            var node = find_node(tree, f);
            if (node != null && node.kind == FolderKind.SECTION) return Notebooks.parent_of(f);
            return f;
        }

        private FolderNode? find_node(Gee.List<FolderNode> nodes, string path) {
            foreach (var n in nodes) {
                if (n.path == path) return n;
                var inner = find_node(n.children, path);
                if (inner != null) return inner;
            }
            return null;
        }

        private void on_sync_with(SimpleAction action, Variant? value) {
            action.set_state(value);
            app.sync.choose(value.get_string());
        }

        private void on_protect_section(SimpleAction action, Variant? value) {
            string path = value.get_string();
            if (app.locks.has_password(path)) ask_unlock(path);
            else set_password(path);
        }

        private void on_open_section(SimpleAction action, Variant? value) {
            string path = value.get_string();
            select_view(path == "" ? QUICK : "folder:" + path);
        }

        private void on_move_to(SimpleAction action, Variant? value) {
            move_note_to(current_id, value.get_string());
        }

        private void move_note_to(string id, string folder) {
            var n = store.lookup(id);
            if (n == null || n.folder == folder) return;
            if (!app.locks.is_unlocked(folder)) {
                add_toast(new Toast(_("Unlock the section first")));
                return;
            }
            string plain = plain_body(n);
            var kids = children_of(n);
            if (SectionLocks.is_locked_body(n.body)) app.locked_files.unprotect(n.folder, n.id, plain);
            var c = n.copy();
            c.folder = folder;
            var d = PageDoc.parse(plain);
            d.meta.level = 0;
            d.meta.order = next_order(folder);
            c.body = seal_for(folder, d.serialize(), c.id);
            save(c, false);
            foreach (var child in kids) {
                var cc = child.copy();
                string cp = plain_body(child);
                if (SectionLocks.is_locked_body(child.body)) app.locked_files.unprotect(child.folder, child.id, cp);
                cc.folder = folder;
                cc.body = seal_for(folder, cp, cc.id);
                save(cc, false);
            }
            if (id == current_id) editing = store.lookup(id).copy();
        }

        private void open_accounts() {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync(BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_settings("accounts");
            } catch (Error e) {
                add_toast(new Toast(_("Settings are not available")));
            }
        }

        private void queue_refresh() {
            if (refresh_source != 0) return;
            refresh_source = Idle.add(() => {
                refresh_source = 0;
                refresh();
                return Source.REMOVE;
            });
        }

        private string view_folder() {
            return view.has_prefix("folder:") ? view.substring(7) : "";
        }

        public string plain_body(Singularity.Notes.Note n) {
            if (!SectionLocks.is_locked_body(n.body)) return n.body;
            string key = n.id + ":" + (n.body.length.to_string());
            if (plain_cache.has_key(key)) return plain_cache[key];
            string? plain = app.locks.decrypt(n.folder, n.body);
            if (plain == null) return n.body;
            plain_cache[key] = plain;
            return plain;
        }

        private string seal_for(string folder, string plain, string id = "") {
            if (!app.locks.has_password(folder)) return plain;
            string? sealed_body = app.locks.encrypt(folder, plain);
            if (sealed_body == null) return plain;
            return sealed_body + app.locked_files.commit(folder, id, plain);
        }

        private bool readable(Singularity.Notes.Note n) {
            return !SectionLocks.is_locked_body(n.body) || app.locks.is_unlocked(n.folder);
        }

        private void rebuild_sidebar() {
            Widget? child;
            while ((child = sidebar.box.get_first_child()) != null) sidebar.box.remove(child);
            view_rows.clear();
            int pinned = 0;
            int quick = 0;
            foreach (var n in store.all()) {
                if (n.pinned) pinned++;
                if (n.folder == "") quick++;
            }
            add_view_row(ALL, "view-list-symbolic", _("All Pages"), store.all().size, 0);
            add_view_row(PINNED, "view-pin-symbolic", _("Pinned"), pinned, 0);
            add_view_row(QUICK, "document-edit-symbolic", _("Quick Notes"), quick, 0);
            add_view_row(TAGS, "notes-tag-symbolic", _("Tags"), 0, 0);
            add_view_row(TRASH, "user-trash-symbolic", _("Recycle Bin"), app.trash.items().size, 0);
            var notebooks_label = new SidebarSectionLabel(_("Notebooks"));
            sidebar.box.append(notebooks_label);
            var tree = app.notebooks.tree(store.folders());
            foreach (var node in tree) add_folder_rows(node);
            var add = new SidebarRow("list-add-symbolic", _("New Notebook"));
            add.clicked.connect(() => new_folder(FolderKind.NOTEBOOK, ""));
            Menus.on_secondary(add, (m) => {
                m.add_item(_("New Notebook"), "accessories-dictionary-symbolic", () => new_folder(FolderKind.NOTEBOOK, ""));
                m.add_item(_("New Section"), "text-x-generic-symbolic", () => new_folder(FolderKind.SECTION, ""));
                m.add_item(_("Import…"), "document-open-symbolic", () => import_files());
                m.add_item(_("Open a Shared Notebook…"), "emblem-shared-symbolic", () => share_notebook("", true));
            });
            sidebar.box.append(add);
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop.drop.connect((v, x, y) => {
                string s = v.get_string();
                if (s.has_prefix("folder:")) move_folder(s.substring(7), "", -1);
                return true;
            });
            notebooks_label.add_controller(drop);
            var spacer = new Box(Orientation.VERTICAL, 0);
            spacer.vexpand = true;
            sidebar.box.append(spacer);
            sidebar.box.append(build_sync_row());
            foreach (var e in view_rows.entries) e.value.set_active(query == "" && e.key == view);
        }

        private int count_in(string folder) {
            int n = 0;
            foreach (var note in store.all()) if (note.folder == folder || note.folder.has_prefix(folder + "/")) n++;
            return n;
        }

        private void add_folder_rows(FolderNode node) {
            string id = "folder:" + node.path;
            var row = add_view_row(id, node.icon_name(), node.name, count_in(node.path), node.depth);
            if (node.kind == FolderKind.SECTION && node.color != "") {
                var inner = row.get_child() as Box;
                if (inner != null) {
                    var dot = new DrawingArea();
                    dot.set_size_request(8, 8);
                    dot.valign = Align.CENTER;
                    string color = node.color;
                    dot.set_draw_func((a, cr, w, h) => {
                        var c = Gdk.RGBA();
                        c.parse(color);
                        cr.arc(w / 2.0, h / 2.0, 4, 0, 2 * Math.PI);
                        cr.set_source_rgba(c.red, c.green, c.blue, 1);
                        cr.fill();
                    });
                    inner.prepend(dot);
                }
            }
            if (node.children.size > 0) {
                var inner = row.get_child() as Box;
                if (inner != null) {
                    bool closed = collapsed_folders.contains(node.path);
                    var exp = new Button.from_icon_name(closed ? "pan-end-symbolic" : "pan-down-symbolic");
                    exp.add_css_class("flat");
                    exp.add_css_class("notes-expander");
                    exp.tooltip_text = closed ? _("Expand") : _("Collapse");
                    exp.clicked.connect(() => {
                        if (collapsed_folders.contains(node.path)) collapsed_folders.remove(node.path);
                        else collapsed_folders.add(node.path);
                        queue_refresh();
                    });
                    inner.append(exp);
                }
            }
            var click = new GestureClick();
            click.button = Gdk.BUTTON_SECONDARY;
            click.pressed.connect((n, x, y) => Menus.popup(row, x, y, (m) => folder_menu(m, node)));
            row.add_controller(click);
            var drag = new DragSource();
            drag.actions = Gdk.DragAction.MOVE;
            drag.prepare.connect(() => new Gdk.ContentProvider.for_value("folder:" + node.path));
            row.add_controller(drag);
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop.drop.connect((v, x, y) => {
                string s = v.get_string();
                if (s.has_prefix("folder:")) {
                    string src = s.substring(7);
                    if (node.kind == FolderKind.SECTION) move_folder(src, Notebooks.parent_of(node.path), sibling_index(node.path) + (y > row.get_height() / 2 ? 1 : 0));
                    else move_folder(src, node.path, -1);
                } else if (s.has_prefix("page:")) {
                    move_note_to(s.substring(5), node.path);
                }
                return true;
            });
            row.add_controller(drop);
            if (!collapsed_folders.contains(node.path)) foreach (var c in node.children) add_folder_rows(c);
        }

        private int sibling_index(string path) {
            var sibs = siblings_of(Notebooks.parent_of(path));
            return sibs.index_of(path);
        }

        private Gee.List<string> siblings_of(string parent) {
            var tree = app.notebooks.tree(store.folders());
            Gee.List<FolderNode> nodes = tree;
            if (parent != "") {
                var p = find_node(tree, parent);
                nodes = p != null ? p.children : new Gee.ArrayList<FolderNode>();
            }
            var list = new Gee.ArrayList<string>();
            foreach (var n in nodes) list.add(n.path);
            return list;
        }

        private void folder_menu(Singularity.Widgets.ContextMenu m, FolderNode node) {
            string path = node.path;
            if (node.kind != FolderKind.SECTION) {
                m.add_item(_("New Section"), "text-x-generic-symbolic", () => new_folder(FolderKind.SECTION, path));
                m.add_item(_("New Section Group"), "folder-new-symbolic", () => new_folder(FolderKind.GROUP, path));
            } else {
                m.add_item(_("New Page"), "list-add-symbolic", () => {
                    select_view("folder:" + path);
                    new_note();
                });
            }
            m.add_separator();
            m.add_item(_("Rename…"), "document-edit-symbolic", () => rename_folder(path));
            if (node.kind == FolderKind.SECTION) {
                var tpl = m.add_submenu(_("Template for New Pages"), "document-new-symbolic");
                tpl.add_item(_("Blank Page"), null, () => {
                    app.notebooks.info(path).template = "";
                    app.notebooks.save();
                });
                foreach (var t in app.templates.all()) {
                    string tid = t.id;
                    tpl.add_item(t.name, t.icon, () => {
                        app.notebooks.info(path).template = tid;
                        app.notebooks.save();
                        add_toast(new Toast(_("New pages in “%s” start from %s").printf(Notebooks.name_of(path), t.name)));
                    });
                }
                var colors = m.add_submenu(_("Section Color"), "color-select-symbolic");
                colors.add_item(_("None"), null, () => app.notebooks.set_color(path, ""));
                string[] names = { _("Blue"), _("Green"), _("Yellow"), _("Orange"), _("Red"), _("Purple"), _("Brown"), _("Grey") };
                for (int i = 0; i < 8; i++) {
                    string c = Notebooks.COLORS[i];
                    colors.add_item(names[i], null, () => app.notebooks.set_color(path, c));
                }
            }
            var sibs = siblings_of(Notebooks.parent_of(path));
            int idx = sibs.index_of(path);
            if (idx > 0) m.add_item(_("Move Up"), "go-up-symbolic", () => move_folder(path, Notebooks.parent_of(path), idx - 1));
            if (idx >= 0 && idx + 1 < sibs.size) m.add_item(_("Move Down"), "go-down-symbolic", () => move_folder(path, Notebooks.parent_of(path), idx + 2));
            var move = m.add_submenu(_("Move To"), "folder-symbolic");
            if (Notebooks.parent_of(path) != "") move.add_item(_("Top Level"), null, () => move_folder(path, "", -1));
            foreach (var target in all_containers(app.notebooks.tree(store.folders()))) {
                if (target.path == path || target.path.has_prefix(path + "/") || target.path == Notebooks.parent_of(path)) continue;
                string t = target.path;
                move.add_item(t.replace("/", " › "), null, () => move_folder(path, t, -1));
            }
            m.add_separator();
            if (node.kind == FolderKind.SECTION || node.kind == FolderKind.GROUP) {
                if (!app.locks.has_password(path)) {
                    m.add_item(_("Password Protect…"), "dialog-password-symbolic", () => set_password(path));
                } else if (app.notebooks.lock_root(path) == path) {
                    if (app.locks.is_unlocked(path)) m.add_item(_("Lock Now"), "system-lock-screen-symbolic", () => app.locks.lock_section(path));
                    else m.add_item(_("Unlock…"), "system-lock-screen-symbolic", () => ask_unlock(path));
                    m.add_item(_("Change Password…"), "dialog-password-symbolic", () => change_password(path));
                    m.add_item(_("Remove Password…"), "dialog-password-symbolic", () => remove_password(path));
                }
            }
            if (node.kind != FolderKind.SECTION || node.depth == 0) {
                var info = app.notebooks.peek(path);
                if (info != null && info.share_path != "") {
                    m.add_item(_("Stop Sharing"), "emblem-shared-symbolic", () => {
                        info.share_path = "";
                        info.share_account = "";
                        app.notebooks.save();
                        add_toast(new Toast(_("The notebook is no longer shared from here")));
                    });
                } else if (node.depth == 0) {
                    m.add_item(_("Share Notebook…"), "emblem-shared-symbolic", () => share_notebook(path, false));
                }
            }
            m.add_item(_("Copy Link to Section"), "insert-link-symbolic", () => {
                string href = "section:" + Uri.escape_string(path, "/", false);
                get_clipboard().set_text(href);
                RichEditor.copied_link = href;
                add_toast(new Toast(_("Link copied. Paste it in any page.")));
            });
            m.add_item(_("Export Section…"), "document-save-as-symbolic", () => {
                select_view("folder:" + path);
                export_dialog(true);
            });
            m.add_separator();
            m.add_item(_("Delete…"), "user-trash-symbolic", () => delete_folder(path));
        }

        private Gee.List<FolderNode> all_containers(Gee.List<FolderNode> nodes) {
            var list = new Gee.ArrayList<FolderNode>();
            foreach (var n in nodes) {
                if (n.kind != FolderKind.SECTION) list.add(n);
                list.add_all(all_containers(n.children));
            }
            return list;
        }

        public Gee.List<FolderNode> all_sections(Gee.List<FolderNode>? nodes = null) {
            var list = new Gee.ArrayList<FolderNode>();
            foreach (var n in nodes ?? app.notebooks.tree(store.folders())) {
                if (n.kind == FolderKind.SECTION) list.add(n);
                list.add_all(all_sections(n.children));
            }
            return list;
        }

        private void build_sync_menu(GLib.Menu menu) {
            var targets = new GLib.Menu();
            var off = new GLib.MenuItem(_("Keep Notes on This Computer"), null);
            off.set_action_and_target_value("win.sync-with", new Variant.string(""));
            targets.append_item(off);
            foreach (var a in app.sync.accounts()) {
                var item = new GLib.MenuItem(_("Sync with %s").printf(a.display_name), null);
                item.set_action_and_target_value("win.sync-with", new Variant.string(a.id));
                targets.append_item(item);
            }
            menu.append_section(_("Sync"), targets);
            var more = new GLib.Menu();
            if (app.sync.account != null) more.append(_("Sync Now"), "win.sync-now");
            more.append(_("Online Accounts…"), "win.accounts");
            menu.append_section(null, more);
        }

        private Widget build_sync_row() {
            sync_row = new SidebarRow("emblem-synchronizing-symbolic", "");
            sync_row.add_css_class("notes-sync-row");
            var menu = new GLib.Menu();
            build_sync_menu(menu);
            var popover = new PopoverMenu.from_model(menu);
            popover.set_parent(sync_row);
            popover.position = PositionType.TOP;
            var owner = sync_row;
            owner.destroy.connect(() => popover.unparent());
            sync_row.clicked.connect(() => popover.popup());
            update_sync_row();
            return sync_row;
        }

        private void update_sync_row() {
            if (sync_row == null) return;
            var s = app.sync;
            string text;
            string icon = "emblem-synchronizing-symbolic";
            switch (s.status) {
                case SyncStatus.OFF:
                    text = _("Not Synced");
                    icon = "computer-symbolic";
                    break;
                case SyncStatus.SYNCING:
                    text = _("Syncing…");
                    break;
                case SyncStatus.DONE:
                    text = _("Synced at %s").printf(new DateTime.from_unix_local(s.last_sync).format("%H:%M"));
                    icon = "emblem-ok-symbolic";
                    break;
                case SyncStatus.FAILED:
                    text = _("Sync Failed");
                    icon = "dialog-warning-symbolic";
                    break;
                case SyncStatus.ATTENTION:
                    text = _("Sign In Again");
                    icon = "dialog-warning-symbolic";
                    break;
                default:
                    text = _("Waiting to Sync");
                    break;
            }
            var inner = sync_row.get_child() as Box;
            if (inner != null) {
                var img = inner.get_first_child() as Image;
                if (img != null) img.icon_name = icon;
                var lbl = img != null ? img.get_next_sibling() as Label : null;
                if (lbl != null) lbl.label = text;
            }
            string tip = s.account != null ? "%s\n%s".printf(s.account.display_name, SyncController.method_label(s.account)) : _("Notes stay on this computer");
            if (s.message != "") tip += "\n" + s.message;
            sync_row.tooltip_text = tip;
        }

        private SidebarRow add_view_row(string id, string icon, string text, int count, int depth) {
            var row = new SidebarRow(icon, text);
            if (depth > 0) row.margin_start = depth * 16;
            if (count > 0) {
                var badge = new Label(count.to_string());
                badge.add_css_class("notes-count");
                var inner = row.get_child() as Box;
                if (inner != null) inner.append(badge);
            }
            row.clicked.connect(() => select_view(id));
            if (id == TRASH) {
                var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
                drop.drop.connect((v, x, y) => {
                    string s = v.get_string();
                    if (s.has_prefix("page:")) delete_note(s.substring(5));
                    return true;
                });
                row.add_controller(drop);
                Menus.on_secondary(row, (m) => m.add_item(_("Empty Recycle Bin"), "user-trash-symbolic", () => confirm_empty_trash()));
            }
            if (id == QUICK) {
                var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
                drop.drop.connect((v, x, y) => {
                    string s = v.get_string();
                    if (s.has_prefix("page:")) move_note_to(s.substring(5), "");
                    return true;
                });
                row.add_controller(drop);
            }
            view_rows[id] = row;
            sidebar.box.append(row);
            return row;
        }

        private void move_folder(string src, string new_parent, int index) {
            if (new_parent == src || new_parent.has_prefix(src + "/")) return;
            string name = Notebooks.name_of(src);
            string dest = new_parent == "" ? name : new_parent + "/" + name;
            if (dest != src) {
                foreach (string f in store.folders()) {
                    if (f == dest) {
                        add_toast(new Toast(_("There is already a section named “%s” there").printf(name)));
                        return;
                    }
                }
                rename_prefix(src, dest);
            }
            var sibs = siblings_of(new_parent);
            sibs.remove(dest);
            if (index < 0 || index > sibs.size) sibs.add(dest);
            else sibs.insert(index, dest);
            app.notebooks.reorder(sibs);
        }

        private void rename_prefix(string from, string to) {
            page.flush();
            foreach (var n in store.all()) {
                if (n.folder != from && !n.folder.has_prefix(from + "/")) continue;
                var c = n.copy();
                c.folder = to + n.folder.substring(from.length);
                save(c, false);
            }
            var extras = store.extra_folders();
            foreach (string f in extras) {
                if (f != from && !f.has_prefix(from + "/")) continue;
                try {
                    store.add_folder(to + f.substring(from.length));
                    store.remove_folder(f);
                } catch (Error e) {
                }
            }
            try {
                store.add_folder(to);
            } catch (Error e) {
            }
            app.notebooks.rename_prefix(from, to);
            if (view == "folder:" + from || view.has_prefix("folder:" + from + "/")) view = "folder:" + to + view.substring(7 + from.length);
            if (editing != null) {
                var cur = store.lookup(editing.id);
                if (cur != null) editing = cur.copy();
            }
            queue_refresh();
        }

        private void share_notebook(string path, bool open_existing) {
            var accounts = new Gee.ArrayList<Singularity.Accounts.Account>();
            foreach (var a in app.sync.accounts()) if (a.has_capability(Singularity.Accounts.Capability.FILES) && a.get_endpoint("webdav") != null) accounts.add(a);
            if (accounts.size == 0) {
                add_toast(new Toast(_("Add an account with Files in Online Accounts to share notebooks")));
                return;
            }
            string title = open_existing ? _("Open a Shared Notebook") : _("Share “%s”").printf(path);
            string body = open_existing ? _("Pick the account and the folder that someone shared with you. Its pages appear here and stay in sync.")
                : _("The notebook is kept in this folder of your cloud. Share the folder with other people in your cloud; everyone who opens it in Notes edits the same pages, synced every 30 seconds.");
            var dialog = new ConfirmDialog(app, title, "emblem-shared", body, open_existing ? _("Open") : _("Share"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = this;
            string[] names = {};
            foreach (var a in accounts) names += a.display_name;
            var drop = new DropDown.from_strings(names);
            dialog.custom_area.append(drop);
            var folder = new Entry();
            folder.placeholder_text = _("Folder in the Cloud");
            folder.text = open_existing ? "" : "Shared Notebooks/" + path;
            dialog.custom_area.append(folder);
            Entry? name_entry = null;
            if (open_existing) {
                name_entry = new Entry();
                name_entry.placeholder_text = _("Notebook Name");
                dialog.custom_area.append(name_entry);
                folder.changed.connect(() => {
                    string f = folder.text.strip();
                    while (f.has_suffix("/")) f = f.substring(0, f.length - 1);
                    name_entry.text = Notebooks.name_of(f);
                });
            }
            dialog.response.connect((r) => {
                string f = folder.text.strip();
                while (f.has_prefix("/")) f = f.substring(1);
                while (f.has_suffix("/")) f = f.substring(0, f.length - 1);
                if (r == ConfirmDialog.Response.PRIMARY && f != "" && !f.contains("..")) {
                    string local = open_existing ? (name_entry.text.strip() != "" ? name_entry.text.strip() : Notebooks.name_of(f)) : path;
                    local = local.replace("/", "-");
                    var info = app.notebooks.info(local);
                    info.kind_id = FolderKind.NOTEBOOK.to_id();
                    info.share_account = accounts[(int) drop.selected].id;
                    info.share_path = f;
                    app.notebooks.save();
                    try {
                        store.add_folder(local);
                    } catch (Error e) {
                    }
                    app.sync.sync_now();
                    add_toast(new Toast(open_existing ? _("Opening the shared notebook…") : _("The notebook is shared through %s").printf(accounts[(int) drop.selected].display_name)));
                    select_view("folder:" + local);
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        private void rename_folder(string path) {
            string old_name = Notebooks.name_of(path);
            var dialog = new ConfirmDialog(app, _("Rename “%s”").printf(old_name), "document-edit", _("Choose a new name."), _("Rename"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = this;
            var entry = new Entry();
            entry.text = old_name;
            dialog.custom_area.append(entry);
            entry.changed.connect(() => {
                string t = entry.text.strip();
                dialog.primary_sensitive = t != "" && !t.contains("/") && t != old_name;
            });
            dialog.primary_sensitive = false;
            entry.activate.connect(() => {
                if (dialog.primary_sensitive) dialog.response(ConfirmDialog.Response.PRIMARY);
            });
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    string parent = Notebooks.parent_of(path);
                    string dest = parent == "" ? entry.text.strip() : parent + "/" + entry.text.strip();
                    rename_prefix(path, dest);
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
            entry.grab_focus();
        }

        private void delete_folder(string path) {
            int n = count_in(path);
            var dialog = new ConfirmDialog(app, _("Delete “%s”?").printf(Notebooks.name_of(path)), "user-trash",
                n > 0 ? ngettext("Its %d page moves to the Recycle Bin.", "Its %d pages move to the Recycle Bin.", n).printf(n) : _("It has no pages."),
                _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = this;
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    page.flush();
                    foreach (var note in store.all().to_array()) {
                        if (note.folder != path && !note.folder.has_prefix(path + "/")) continue;
                        trash_note(note);
                    }
                    foreach (string f in store.extra_folders()) {
                        if (f != path && !f.has_prefix(path + "/")) continue;
                        try {
                            store.remove_folder(f);
                        } catch (Error e) {
                        }
                    }
                    app.notebooks.forget(path);
                    if (view == "folder:" + path || view.has_prefix("folder:" + path + "/")) select_view(ALL);
                    queue_refresh();
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        private bool trash_note(Singularity.Notes.Note note) {
            try {
                app.trash.put(note);
                store.remove(note.id);
                return true;
            } catch (Error e) {
                add_toast(new Toast(e.message));
                return false;
            }
        }

        private void password_dialog(string title, string body, bool confirm, bool ask_old, owned PasswordDone done) {
            var dialog = new ConfirmDialog(app, title, "dialog-password", body, _("OK"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = this;
            PasswordEntry? old_entry = null;
            if (ask_old) {
                old_entry = new PasswordEntry();
                old_entry.placeholder_text = _("Current Password");
                old_entry.show_peek_icon = true;
                dialog.custom_area.append(old_entry);
            }
            var entry = new PasswordEntry();
            entry.placeholder_text = ask_old ? _("New Password") : _("Password");
            entry.show_peek_icon = true;
            dialog.custom_area.append(entry);
            PasswordEntry? again = null;
            if (confirm) {
                again = new PasswordEntry();
                again.placeholder_text = _("Confirm Password");
                dialog.custom_area.append(again);
                var note = new Label(_("If you forget the password nobody can recover these pages."));
                note.wrap = true;
                note.add_css_class("dim-label");
                note.add_css_class("caption");
                dialog.custom_area.append(note);
            }
            dialog.primary_sensitive = false;
            Checker check = () => {
                bool ok = entry.text != "" && (again == null || again.text == entry.text) && (old_entry == null || old_entry.text != "");
                dialog.primary_sensitive = ok;
            };
            entry.changed.connect(() => check());
            if (again != null) again.changed.connect(() => check());
            if (old_entry != null) old_entry.changed.connect(() => check());
            entry.activate.connect(() => {
                if (dialog.primary_sensitive) dialog.response(ConfirmDialog.Response.PRIMARY);
            });
            if (again != null) again.activate.connect(() => {
                if (dialog.primary_sensitive) dialog.response(ConfirmDialog.Response.PRIMARY);
            });
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    if (!done(entry.text, old_entry != null ? old_entry.text : "")) {
                        entry.text = "";
                        add_toast(new Toast(_("The password is not correct")));
                        return;
                    }
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
            if (old_entry != null) old_entry.grab_focus();
            else entry.grab_focus();
        }

        private delegate bool PasswordDone(string password, string old_password);
        private delegate void Checker();

        private Gee.List<Singularity.Notes.Note> notes_under(string path) {
            var list = new Gee.ArrayList<Singularity.Notes.Note>();
            foreach (var n in store.all()) if (n.folder == path || n.folder.has_prefix(path + "/")) list.add(n);
            return list;
        }

        private void set_password(string path) {
            password_dialog(_("Password Protect “%s”").printf(Notebooks.name_of(path)), _("The pages are encrypted with this password, here and on the sync server."), true, false, (pw, old) => {
                page.flush();
                var plain = new Gee.HashMap<string, string>();
                foreach (var n in notes_under(path)) plain[n.id] = plain_body(n);
                app.locks.set_password(path, pw);
                foreach (var n in notes_under(path)) {
                    var c = n.copy();
                    c.body = seal_for(n.folder, plain[n.id], n.id);
                    save(c, false);
                    new History(store.dir).forget(n.id);
                    foreach (string target in NoteAttachments.links(plain[n.id])) {
                        string p = Path.build_filename(store.dir, target);
                        FileUtils.unlink(OcrIndex.cache_path(p));
                    }
                }
                if (editing != null) {
                    var cur = store.lookup(editing.id);
                    if (cur != null) editing = cur.copy();
                }
                add_toast(new Toast(_("The section is protected")));
                return true;
            });
        }

        private void ask_unlock(string path) {
            password_dialog(_("Unlock “%s”").printf(Notebooks.name_of(app.notebooks.lock_root(path) ?? path)), _("Enter the password of this section."), false, false, (pw, old) => {
                if (!app.locks.unlock(path, pw)) return false;
                select_view("folder:" + path);
                return true;
            });
        }

        private void change_password(string path) {
            password_dialog(_("Change Password"), _("Enter the current password and a new one."), true, true, (pw, old) => {
                if (!app.locks.unlock(path, old)) return false;
                var plain = new Gee.HashMap<string, string>();
                foreach (var n in notes_under(path)) {
                    plain[n.id] = plain_body(n);
                    app.locked_files.unprotect(n.folder, n.id, plain[n.id]);
                }
                app.locks.set_password(path, pw);
                foreach (var n in notes_under(path)) {
                    var c = n.copy();
                    c.body = seal_for(n.folder, plain[n.id], n.id);
                    save(c, false);
                }
                add_toast(new Toast(_("Password changed")));
                return true;
            });
        }

        private void remove_password(string path) {
            password_dialog(_("Remove Password"), _("The pages of this section are stored without encryption again."), false, false, (pw, old) => {
                if (!app.locks.unlock(path, pw)) return false;
                var plain = new Gee.HashMap<string, string>();
                foreach (var n in notes_under(path)) {
                    plain[n.id] = plain_body(n);
                    app.locked_files.unprotect(n.folder, n.id, plain[n.id]);
                }
                app.locks.clear_password(path);
                foreach (var n in notes_under(path)) {
                    var c = n.copy();
                    c.body = plain[n.id];
                    save(c, false);
                }
                add_toast(new Toast(_("The password was removed")));
                return true;
            });
        }

        public void select_view(string id) {
            if (id != TRASH && id != TAGS) page.flush();
            view = id;
            if (app.settings != null) app.settings.set_string("last-view", id);
            if (query != "") search.clear();
            refresh();
            if (view == TAGS) {
                tag_summary.reload();
                editor_stack.visible_child_name = "tags";
                current_id = "";
                update_bubbles();
                return;
            }
            select_first();
        }

        private Gee.List<Singularity.Notes.Note> ordered(Gee.List<Singularity.Notes.Note> notes) {
            var list = new Gee.ArrayList<Singularity.Notes.Note>();
            list.add_all(notes);
            var metas = new Gee.HashMap<string, PageMeta>();
            foreach (var n in list) metas[n.id] = PageDoc.parse(plain_body(n)).meta;
            list.sort((a, b) => {
                double oa = metas[a.id].order != 0 ? metas[a.id].order : a.created;
                double ob = metas[b.id].order != 0 ? metas[b.id].order : b.created;
                if (oa != ob) return oa < ob ? -1 : 1;
                return strcmp(a.id, b.id);
            });
            return list;
        }

        private int level_of(Singularity.Notes.Note n) {
            return PageDoc.parse(plain_body(n)).meta.level;
        }

        private Gee.List<Singularity.Notes.Note> section_pages(string folder) {
            var l = new Gee.ArrayList<Singularity.Notes.Note>();
            foreach (var n in store.all()) if (n.folder == folder) l.add(n);
            return ordered(l);
        }

        private Gee.List<Singularity.Notes.Note> children_of(Singularity.Notes.Note parent) {
            var list = new Gee.ArrayList<Singularity.Notes.Note>();
            var pages = section_pages(parent.folder);
            int idx = -1;
            for (int i = 0; i < pages.size; i++) if (pages[i].id == parent.id) idx = i;
            if (idx < 0) return list;
            int level = level_of(parent);
            for (int i = idx + 1; i < pages.size; i++) {
                if (level_of(pages[i]) <= level) break;
                list.add(pages[i]);
            }
            return list;
        }

        private string search_text(Singularity.Notes.Note n) {
            string key = "s:" + n.id + ":" + n.body.length.to_string();
            if (plain_cache.has_key(key)) return plain_cache[key];
            string body = plain_body(n);
            string t = (PageDoc.parse(body).plain_text() + "\n" + n.folder + "\n" + OcrIndex.media_text(store.dir, body)).casefold();
            foreach (var hit in TagIndex.scan(n.id, body)) t += "\n" + TagCatalog.get_default().lookup(hit.tag).label.casefold();
            plain_cache[key] = t;
            return t;
        }

        private Gee.List<Singularity.Notes.Note> visible_notes() {
            if (query != "") {
                var l = new Gee.ArrayList<Singularity.Notes.Note>();
                string q = query.casefold();
                foreach (var n in store.all()) {
                    if (!readable(n)) continue;
                    string hay = search_text(n);
                    bool ok = true;
                    foreach (string term in q.split(" ")) if (term != "" && !hay.contains(term)) ok = false;
                    if (ok) l.add(n);
                }
                return l;
            }
            if (view == PINNED) {
                var l = new Gee.ArrayList<Singularity.Notes.Note>();
                foreach (var n in store.all()) if (n.pinned) l.add(n);
                return l;
            }
            if (view == QUICK) return section_pages("");
            if (view == ALL) return store.all();
            string f = view_folder();
            if (f == "") return store.all();
            var direct = section_pages(f);
            if (direct.size > 0 || !has_child_folders(f)) return direct;
            var l = new Gee.ArrayList<Singularity.Notes.Note>();
            foreach (var n in store.all()) if (n.folder.has_prefix(f + "/")) l.add(n);
            return l;
        }

        private bool has_child_folders(string f) {
            foreach (string x in store.folders()) if (x.has_prefix(f + "/")) return true;
            foreach (string x in store.extra_folders()) if (x.has_prefix(f + "/")) return true;
            return false;
        }

        private bool manual_order {
            get { return query == "" && (view == QUICK || (view.has_prefix("folder:") && section_pages(view_folder()).size > 0)); }
        }

        private void refresh() {
            rebuild_sidebar();
            string f = view_folder();
            if (query != "") heading.label = _("Search");
            else if (view == PINNED) heading.label = _("Pinned");
            else if (view == QUICK) heading.label = _("Quick Notes");
            else if (view == TAGS) heading.label = _("Tags");
            else if (view == TRASH) heading.label = _("Recycle Bin");
            else if (f != "") heading.label = Notebooks.name_of(f);
            else heading.label = _("All Pages");

            Widget? child;
            while ((child = list.get_first_child()) != null) list.remove(child);

            if (view == TRASH && query == "") {
                var items = app.trash.items();
                count_label.label = ngettext("%d page, kept for 60 days", "%d pages, kept for 60 days", items.size).printf(items.size);
                NoteRow? sel = null;
                foreach (var it in items) {
                    var n = Singularity.Notes.Note.parse(it.id, it.text);
                    n.modified = it.deleted;
                    string body = SectionLocks.is_locked_body(n.body) ? _("Protected page") : PageDoc.snippet_of(n.body);
                    var row = new NoteRow(n, true, it.title(), body);
                    list.append(row);
                    if (it.id == selected_trash) sel = row;
                }
                if (sel != null) list.select_row(sel);
                show_empty_or_list(items.size, "user-trash-symbolic", _("The Recycle Bin Is Empty"), _("Deleted pages stay here for 60 days"));
                update_bubbles();
                return;
            }
            if (view == TAGS && query == "") {
                count_label.label = "";
                show_empty_or_list(0, "notes-tag-symbolic", _("Tag Summary"), _("Every tagged paragraph and to-do of your notebooks is listed on the right"));
                update_bubbles();
                return;
            }
            if (f != "" && query == "" && !app.locks.is_unlocked(f)) {
                count_label.label = _("Protected");
                show_empty_or_list(0, "system-lock-screen-symbolic", _("Protected Section"), _("Unlock it to see its pages"));
                editor_stack.visible_child_name = "locked";
                update_bubbles();
                return;
            }

            var notes = visible_notes();
            count_label.label = ngettext("%d page", "%d pages", notes.size).printf(notes.size);
            NoteRow? selected = null;
            bool manual = manual_order;
            int skip_level = -1;
            for (int i = 0; i < notes.size; i++) {
                var n = notes[i];
                if (!readable(n)) {
                    var row = new NoteRow(n, f == "", _("Protected Page"), _("Unlock the section to read it"));
                    list.append(row);
                    continue;
                }
                string body = plain_body(n);
                var doc = PageDoc.parse(body);
                int level = manual ? doc.meta.level : 0;
                if (skip_level >= 0) {
                    if (level > skip_level) continue;
                    skip_level = -1;
                }
                int children = 0;
                if (manual) {
                    for (int j = i + 1; j < notes.size; j++) {
                        if (PageDoc.parse(plain_body(notes[j])).meta.level > level) children++;
                        else break;
                    }
                }
                bool closed = collapsed_pages.contains(n.id);
                var row = new NoteRow(n, f == "" || view == ALL, PageDoc.title_of(body), PageDoc.snippet_of(body), level, children, closed);
                string nid = n.id;
                row.toggle_children.connect(() => {
                    if (collapsed_pages.contains(nid)) collapsed_pages.remove(nid);
                    else collapsed_pages.add(nid);
                    queue_refresh();
                });
                if (closed && children > 0) skip_level = level;
                attach_row_dnd(row);
                var click = new GestureClick();
                click.button = Gdk.BUTTON_SECONDARY;
                click.pressed.connect((nn, x, y) => {
                    var note = store.lookup(nid);
                    if (note != null) Menus.popup(row, x, y, (m) => page_menu(m, note));
                });
                row.add_controller(click);
                list.append(row);
                if (n.id == current_id) selected = row;
            }
            if (selected != null) list.select_row(selected);
            if (notes.size == 0) {
                if (query != "") show_empty_or_list(0, "system-search-symbolic", _("No Results"), _("No page contains “%s”").printf(query));
                else if (view == PINNED) show_empty_or_list(0, "view-pin-symbolic", _("No Pinned Pages"), _("Pin the pages you need often to keep them on top"));
                else show_empty_or_list(0, "text-x-generic-symbolic", _("No Pages"), _("Pages you write here appear in this list"));
            } else {
                list_stack.visible_child_name = "list";
            }
            var current = store.lookup(current_id);
            if (current == null && current_id != "") {
                current_id = "";
                editor_stack.visible_child_name = "nothing";
            }
            if (editor_stack.visible_child_name == "locked" || editor_stack.visible_child_name == "tags" || editor_stack.visible_child_name == "trash") {
                editor_stack.visible_child_name = current_id != "" ? "editor" : "nothing";
            }
            update_bubbles();
            if (stack.visible_child_name == "welcome" && (store.all().size > 0 || store.extra_folders().length > 0)) {
                stack.visible_child_name = "main";
            }
        }

        private void show_empty_or_list(int count, string icon, string title, string description) {
            if (count > 0) {
                list_stack.visible_child_name = "list";
                return;
            }
            empty.icon_name = icon;
            empty.title = title;
            empty.description = description;
            list_stack.visible_child_name = "empty";
        }

        private void attach_row_dnd(NoteRow row) {
            var drag = new DragSource();
            drag.actions = Gdk.DragAction.MOVE;
            string id = row.note.id;
            drag.prepare.connect((x, y) => new Gdk.ContentProvider.for_value("page:" + id));
            row.add_controller(drag);
            var drop = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            drop.drop.connect((v, x, y) => {
                string s = v.get_string();
                if (!s.has_prefix("page:") || !manual_order) return false;
                string src = s.substring(5);
                if (src == id) return false;
                bool after = y > row.get_height() / 2;
                bool sub = x > 60;
                drop_page(src, id, after, sub);
                return true;
            });
            row.add_controller(drop);
        }

        private double next_order(string folder) {
            double max = 0;
            bool explicit = false;
            foreach (var n in section_pages(folder)) {
                var m = PageDoc.parse(plain_body(n)).meta;
                if (m.order == 0) continue;
                explicit = true;
                max = double.max(max, m.order);
            }
            return explicit ? Math.floor(max) + 1 : 0;
        }

        private void write_order(Gee.List<Singularity.Notes.Note> pages, Gee.HashMap<string, int>? levels) {
            for (int i = 0; i < pages.size; i++) {
                var n = pages[i];
                string plain = plain_body(n);
                var d = PageDoc.parse(plain);
                int want_level = levels != null && levels.has_key(n.id) ? levels[n.id] : d.meta.level;
                if (d.meta.order == i + 1 && d.meta.level == want_level) continue;
                d.meta.order = i + 1;
                d.meta.level = want_level;
                var c = n.copy();
                c.body = seal_for(n.folder, d.serialize(), n.id);
                save(c, false);
                if (n.id == current_id) {
                    editing = store.lookup(n.id).copy();
                    page.reload(plain_body(editing));
                }
            }
        }

        private void drop_page(string src_id, string target_id, bool after, bool as_sub) {
            var src = store.lookup(src_id);
            var target = store.lookup(target_id);
            if (src == null || target == null) return;
            page.flush();
            if (src.folder != target.folder) move_note_to(src_id, target.folder);
            src = store.lookup(src_id);
            var pages = new Gee.ArrayList<Singularity.Notes.Note>();
            pages.add_all(section_pages(target.folder));
            var moving = new Gee.ArrayList<Singularity.Notes.Note>();
            moving.add(src);
            moving.add_all(children_of(src));
            foreach (var m in moving) {
                for (int i = 0; i < pages.size; i++) if (pages[i].id == m.id) {
                    pages.remove_at(i);
                    break;
                }
            }
            int at = -1;
            for (int i = 0; i < pages.size; i++) if (pages[i].id == target_id) at = i;
            if (at < 0) at = pages.size - 1;
            int insert_at = at + (after ? 1 : 0);
            if (after) {
                int tl = level_of(pages[at]);
                while (insert_at < pages.size && level_of(pages[insert_at]) > tl) insert_at++;
            }
            int base_level = level_of(src);
            int new_level = as_sub ? int.min(2, level_of(target) + 1) : level_of(target);
            if (!after && !as_sub) new_level = level_of(target);
            var levels = new Gee.HashMap<string, int>();
            foreach (var m in moving) levels[m.id] = (level_of(m) - base_level + new_level).clamp(0, 2);
            for (int i = moving.size - 1; i >= 0; i--) pages.insert(insert_at.clamp(0, pages.size), moving[i]);
            write_order(pages, levels);
            queue_refresh();
        }

        private void move_page(int delta) {
            var n = store.lookup(current_id);
            if (n == null) return;
            var pages = section_pages(n.folder);
            int idx = -1;
            for (int i = 0; i < pages.size; i++) if (pages[i].id == n.id) idx = i;
            int target = idx + delta;
            if (idx < 0 || target < 0 || target >= pages.size) return;
            drop_page(n.id, pages[target].id, delta > 0, false);
        }

        private void change_level(int delta) {
            var n = store.lookup(current_id);
            if (n == null) return;
            page.flush();
            n = store.lookup(current_id);
            var pages = section_pages(n.folder);
            int idx = -1;
            for (int i = 0; i < pages.size; i++) if (pages[i].id == n.id) idx = i;
            if (idx < 0) return;
            int level = level_of(n);
            int max = idx > 0 ? int.min(2, level_of(pages[idx - 1]) + 1) : 0;
            int want = (level + delta).clamp(0, max);
            if (want == level) return;
            var levels = new Gee.HashMap<string, int>();
            levels[n.id] = want;
            foreach (var c in children_of(n)) levels[c.id] = (level_of(c) + (want - level)).clamp(0, 2);
            write_order(pages, levels);
            queue_refresh();
        }

        private void update_bubbles() {
            add_page_button.visible = view != TAGS && view != TRASH && query == "";
            var n = store.lookup(current_id);
            bool shown = n != null && stack.visible_child_name == "main" && editor_stack.visible_child_name == "editor";
            pin_bubble.visible = shown;
            page_menu_bubble.visible = shown;
            delete_bubble.visible = shown;
            ribbon_switcher.visible = shown;
            pin_bubble.tooltip_text = n != null && n.pinned ? _("Unpin Page") : _("Pin Page");
            if (n != null && n.pinned) pin_bubble.add_css_class("notes-pinned");
            else pin_bubble.remove_css_class("notes-pinned");
        }

        private void select_first() {
            if (view == TRASH) {
                var row = list.get_row_at_index(0) as NoteRow;
                if (row != null) list.select_row(row);
                else {
                    selected_trash = "";
                    editor_stack.visible_child_name = "nothing";
                }
                current_id = "";
                update_bubbles();
                return;
            }
            if (view == TAGS) return;
            for (int i = 0; ; i++) {
                var row = list.get_row_at_index(i) as NoteRow;
                if (row == null) break;
                if (readable(row.note)) {
                    open_note(row.note.id);
                    return;
                }
            }
            current_id = "";
            if (editor_stack.visible_child_name != "locked") editor_stack.visible_child_name = "nothing";
            update_bubbles();
        }

        public void open_note(string id) {
            var n = store.lookup(id);
            if (n == null) return;
            if (live_client != null && id != live_note) leave_live(true);
            if (!readable(n)) {
                ask_unlock(n.folder);
                return;
            }
            page.flush();
            current_id = id;
            editing = n.copy();
            if (app.settings != null) app.settings.set_string("last-note", id);
            string pb = plain_body(n);
            if (SectionLocks.is_locked_body(n.body)) {
                app.locked_files.prepare(n.folder, n.id, pb);
                page.notes_dir = app.locked_files.root;
            } else {
                page.notes_dir = store.dir;
            }
            page.load(id, pb, n.created);
            var focus_now = get_focus();
            if (focus_now != null && focus_now.is_ancestor(page) && !(focus_now is TextView)) page.focus_start();
            editor_stack.visible_child_name = "editor";
            page.opacity = 0.0;
            Singularity.Motion.tween(page, "opacity", 1.0, Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
            for (int i = 0; ; i++) {
                var row = list.get_row_at_index(i) as NoteRow;
                if (row == null) break;
                if (row.note.id == id) {
                    if (list.get_selected_row() != row) list.select_row(row);
                    break;
                }
            }
            if (!SectionLocks.is_locked_body(n.body) && (app.settings == null || app.settings.get_boolean("recognize-images"))) OcrIndex.get_default().index_note(store.dir, n.id, n.body);
            app.locks.touch(n.folder);
            app.sync.current_page = n.id;
            app.sync.current_folder = n.folder;
            update_presence();
            update_bubbles();
        }

        private CollabServer? live_server = null;
        private CollabClient? live_client = null;
        private string live_note = "";
        private string live_link = "";

        private static string my_name() {
            string n = Environment.get_real_name();
            if (n == "" || n == "Unknown") n = Environment.get_user_name();
            return n;
        }

        private Picture qr_picture(string text) {
            var pic = new Picture();
            pic.can_shrink = true;
            pic.content_fit = ContentFit.CONTAIN;
            pic.set_size_request(180, 180);
            pic.halign = Align.CENTER;
            try {
                var qr = Singularity.QrCode.encode_text(text, Singularity.QrEcLevel.MEDIUM);
                pic.paintable = qr.to_texture(6);
            } catch (Error e) {
                pic.visible = false;
            }
            return pic;
        }

        private Label link_label(string text) {
            var l = new Label(text);
            l.wrap = true;
            l.wrap_mode = Pango.WrapMode.CHAR;
            l.add_css_class("monospace");
            l.justify = Justification.CENTER;
            return l;
        }

        private void start_live() {
            var n = store.lookup(current_id);
            if (n == null || editor_stack.visible_child_name != "editor") {
                add_toast(new Toast(_("Open a page to start a live session")));
                return;
            }
            if (SectionLocks.is_locked_body(n.body)) {
                add_toast(new Toast(_("Pages in password-protected sections cannot be edited live")));
                return;
            }
            if (live_server != null && live_note == n.id) {
                show_live_invite();
                return;
            }
            leave_live(false);
            page.flush();
            var server = new CollabServer();
            try {
                try {
                    server.listen(7780, true);
                } catch (Error e) {
                    server.listen(0, true);
                }
            } catch (Error e) {
                add_toast(new Toast(_("The live session could not start: %s").printf(e.message)));
                return;
            }
            live_server = server;
            live_note = n.id;
            live_link = CollabClient.make_link(WebAccess.lan_address(), server.port, n.id, server.token);
            connect_live("ws://127.0.0.1:%u/live".printf(server.port), server.token, n.id, page.serialize(), true);
        }

        private void connect_live(string url, string token, string doc, string? initial, bool host) {
            var client = new CollabClient(doc, my_name(), CollabClient.random_color());
            live_client = client;
            live_note = doc;
            bool attached = false;
            client.ready.connect((text) => {
                if (attached || live_client != client) return;
                attached = true;
                var existing = store.lookup(doc);
                if (existing == null) {
                    var nn = new Singularity.Notes.Note(doc);
                    nn.body = text;
                    nn.created = get_real_time() / 1000000;
                    try {
                        store.save(nn);
                    } catch (Error e) {
                        add_toast(new Toast(e.message));
                        leave_live(false);
                        return;
                    }
                }
                if (current_id != doc) open_note(doc);
                page.attach_live(client);
                if (host) show_live_invite();
                else add_toast(new Toast(_("You joined the live session")));
            });
            client.closed.connect((reason) => {
                if (live_client != client) return;
                if (!attached) add_toast(new Toast(reason));
                leave_live(false);
            });
            page.live_ended.disconnect(on_live_ended);
            page.live_ended.connect(on_live_ended);
            client.connect_to.begin(url, token, initial, (o, r) => {
                try {
                    client.connect_to.end(r);
                } catch (Error e) {
                    if (live_client == client) {
                        add_toast(new Toast(_("Could not reach the live session: %s").printf(e.message)));
                        leave_live(false);
                    }
                }
            });
        }

        private void on_live_ended(string reason) {
            add_toast(new Toast(reason));
            leave_live(false);
        }

        private void show_live_invite() {
            if (live_server == null || live_link == "") {
                add_toast(new Toast(_("Start a live session first")));
                return;
            }
            var dialog = new ConfirmDialog(app, _("Live Session"), "network-workgroup",
                _("People on your network join with this link, in Notes under File, Join Live Session, or by scanning the code. Everyone edits this page at the same time and sees each other's cursor. The session ends when you leave it."),
                _("Copy Link"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = this;
            dialog.custom_area.append(qr_picture(live_link));
            dialog.custom_area.append(link_label(live_link));
            dialog.set_secondary(_("End Session"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    get_clipboard().set_text(live_link);
                    add_toast(new Toast(_("Link copied")));
                } else if (r == ConfirmDialog.Response.SECONDARY) {
                    leave_live(true);
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        private void join_live() {
            var dialog = new ConfirmDialog(app, _("Join Live Session"), "network-workgroup",
                _("Paste the link that the host of the session copied for you."), _("Join"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = this;
            var entry = new Entry();
            entry.placeholder_text = "notes-live://";
            dialog.custom_area.append(entry);
            dialog.primary_sensitive = false;
            entry.changed.connect(() => {
                string u, d, t;
                dialog.primary_sensitive = CollabClient.parse_link(entry.text, out u, out d, out t) && Singularity.Notes.NoteStore.valid_id(d);
            });
            entry.activate.connect(() => {
                if (dialog.primary_sensitive) dialog.response(ConfirmDialog.Response.PRIMARY);
            });
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    string url, doc, token;
                    if (CollabClient.parse_link(entry.text, out url, out doc, out token)) {
                        leave_live(false);
                        page.flush();
                        connect_live(url, token, doc, null, false);
                    }
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
            entry.grab_focus();
        }

        private void leave_live(bool announce) {
            bool was = live_client != null || live_server != null;
            page.detach_live();
            var c = live_client;
            live_client = null;
            if (c != null) c.disconnect_live();
            if (live_server != null) live_server.stop();
            live_server = null;
            live_note = "";
            live_link = "";
            if (was && announce) add_toast(new Toast(_("You left the live session")));
            update_presence();
        }

        private void web_access_dialog() {
            var web = app.web_access;
            var dialog = new ConfirmDialog(app, _("Phone and Browser Access"), "phone",
                _("Read, search and edit your notes from a phone or any browser."),
                _("Copy Link"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = this;
            var group = new PreferencesGroup();
            var on = new SwitchRow(_("Allow Access"), _("Protected sections stay here"), web.running);
            var lan = new SwitchRow(_("Local Network"), _("When off, only this computer"), web.running ? web.lan : true);
            var renew = new Button.with_label(_("New Code"));
            renew.halign = Align.START;
            group.add_row(on);
            group.add_row(lan);
            dialog.custom_area.append(group);
            var sign_box = new Box(Orientation.HORIZONTAL, 16);
            sign_box.halign = Align.CENTER;
            var qr_box = new Box(Orientation.VERTICAL, 0);
            qr_box.valign = Align.CENTER;
            qr_box.set_size_request(124, 124);
            sign_box.append(qr_box);
            var info = new Box(Orientation.VERTICAL, 4);
            info.valign = Align.CENTER;
            var hint = new Label(_("Scan the code, or open"));
            hint.xalign = 0f;
            hint.wrap = true;
            hint.max_width_chars = 22;
            hint.add_css_class("dim-label");
            var addr = new Label("");
            addr.xalign = 0f;
            addr.wrap = true;
            addr.wrap_mode = Pango.WrapMode.CHAR;
            addr.max_width_chars = 22;
            var hint2 = new Label(_("and type the code"));
            hint2.xalign = 0f;
            hint2.add_css_class("dim-label");
            var pin_label = new Label("");
            pin_label.xalign = 0f;
            pin_label.add_css_class("title-2");
            info.append(hint);
            info.append(addr);
            info.append(hint2);
            info.append(pin_label);
            info.append(renew);
            sign_box.append(info);
            dialog.custom_area.append(sign_box);
            Picture? pic = null;
            bool busy = false;
            SourceFunc update = () => {
                if (pic != null) qr_box.remove(pic);
                pic = null;
                sign_box.opacity = web.running ? 1.0 : 0.0;
                renew.sensitive = web.running;
                addr.label = web.running ? web.address() : "";
                pin_label.label = web.running ? web.pin : "";
                dialog.primary_sensitive = web.running;
                if (web.running) {
                    pic = qr_picture(web.link());
                    pic.set_size_request(124, 124);
                    qr_box.append(pic);
                }
                return false;
            };
            SourceFunc apply = () => {
                if (busy) return false;
                busy = true;
                if (on.active) {
                    try {
                        web.start(7781, lan.active);
                    } catch (Error e) {
                        try {
                            web.start(0, lan.active);
                        } catch (Error e2) {
                            add_toast(new Toast(e2.message));
                            on.active = false;
                        }
                    }
                } else {
                    web.stop();
                }
                busy = false;
                update();
                return false;
            };
            on.switch_btn.notify["active"].connect(() => apply());
            lan.switch_btn.notify["active"].connect(() => {
                if (on.active) apply();
            });
            renew.clicked.connect(() => {
                web.renew();
                update();
            });
            update();
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY && web.running) {
                    get_clipboard().set_text(web.link());
                    add_toast(new Toast(_("Link copied")));
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        private void update_presence() {
            var n = store.lookup(current_id);
            if (n == null) {
                page.set_presence(null);
                return;
            }
            foreach (var e in app.sync.presence.entries) {
                if (SyncEngine.under(n.folder, e.key)) {
                    page.set_presence(e.value);
                    return;
                }
            }
            page.set_presence(null);
        }

        public void show_note(string id) {
            var n = store.lookup(id);
            if (n == null) return;
            if (query != "") search.clear();
            bool visible = false;
            foreach (var v in visible_notes()) if (v.id == id) visible = true;
            if (!visible || view == TAGS || view == TRASH) {
                view = n.folder != "" ? "folder:" + n.folder : QUICK;
                refresh();
            }
            stack.visible_child_name = "main";
            open_note(id);
        }

        private void navigate(string uri) {
            if (uri.has_prefix("section:")) {
                string path = Uri.unescape_string(uri.substring(8)) ?? uri.substring(8);
                if (valid_view("folder:" + path)) select_view("folder:" + path);
                else add_toast(new Toast(_("The linked section no longer exists")));
                return;
            }
            string rest = uri.substring(5);
            string anchor = "";
            int hash = rest.index_of("#");
            if (hash >= 0) {
                anchor = rest.substring(hash + 1);
                rest = rest.substring(0, hash);
            }
            if (store.lookup(rest) == null) {
                add_toast(new Toast(_("The linked page no longer exists")));
                return;
            }
            show_note(rest);
            if (anchor != "") Idle.add(() => {
                page.jump_to_anchor(anchor);
                return Source.REMOVE;
            });
        }

        private void on_edited(string body) {
            var n = editing != null && editing.id == page.note_id ? editing : null;
            if (n == null) {
                var found = store.lookup(page.note_id);
                if (found == null) return;
                n = found.copy();
            }
            string stored = seal_for(n.folder, body, n.id);
            n.body = stored;
            save(n, true);
            app.history.record(n.id, n.serialize());
            editing = n.copy();
            string back = plain_body(n);
            if (back != body && n.id == page.note_id) page.reload(back);
            app.locks.touch(n.folder);
        }

        private void follow_store() {
            if (editing == null || current_id == "" || editing.id != current_id || page.pending) return;
            var n = store.lookup(current_id);
            if (n == null || n.same_version(editing)) return;
            editing = n.copy();
            string plain = plain_body(n);
            if (plain != page.serialize()) page.reload(plain);
        }

        private void save(Singularity.Notes.Note n, bool touch) {
            var previous = store.lookup(n.id);
            LinkedTasks.push(previous != null ? previous.body : null, n.body);
            try {
                store.save(n, touch);
            } catch (Error e) {
                add_toast(new Toast(_("The page could not be saved: %s").printf(e.message)));
            }
        }

        public Singularity.Notes.Note? create_page(string body, string folder, int level = 0, double order = 0) {
            try {
                var d = PageDoc.parse(body);
                d.meta.level = level;
                d.meta.order = order != 0 ? order : next_order(folder);
                var n = store.create(seal_for(folder, d.serialize()), folder);
                if (view == PINNED) {
                    n.pinned = true;
                    store.save(n, false);
                }
                return n;
            } catch (Error e) {
                add_toast(new Toast(_("The page could not be created: %s").printf(e.message)));
                return null;
            }
        }

        private string target_folder() {
            string f = view_folder();
            if (f == "") return "";
            var node = find_node(app.notebooks.tree(store.folders()), f);
            if (node != null && node.kind != FolderKind.SECTION) {
                foreach (var c in node.children) if (c.kind == FolderKind.SECTION) return c.path;
                return "";
            }
            return f;
        }

        public void new_note(string body = "") {
            page.flush();
            if (query != "") search.clear();
            string folder = target_folder();
            if (!app.locks.is_unlocked(folder)) {
                ask_unlock(folder);
                return;
            }
            string start = body;
            if (start == "" && folder != "") {
                var info = app.notebooks.peek(folder);
                if (info != null && info.template != "") {
                    foreach (var t in app.templates.all()) if (t.id == info.template) start = t.instantiate();
                }
            }
            var n = create_page(start, folder);
            if (n == null) return;
            if (folder != "" && view != "folder:" + folder) view = "folder:" + folder;
            else if (folder == "" && view != QUICK && view != ALL && view != PINNED) view = QUICK;
            stack.visible_child_name = "main";
            refresh();
            open_note(n.id);
            if (body == "") page.focus_title();
            else page.focus_body();
        }

        public void new_subpage() {
            var parent = store.lookup(current_id);
            if (parent == null) {
                new_note();
                return;
            }
            page.flush();
            int level = int.min(2, level_of(parent) + 1);
            var n = create_page("", parent.folder, level, 0.5);
            if (n == null) return;
            var pages = new Gee.ArrayList<Singularity.Notes.Note>();
            foreach (var p in section_pages(parent.folder)) if (p.id != n.id) pages.add(p);
            int idx = -1;
            for (int i = 0; i < pages.size; i++) if (pages[i].id == parent.id) idx = i;
            int at = idx + 1;
            while (at < pages.size && level_of(pages[at]) > level_of(parent)) at++;
            pages.insert(at, store.lookup(n.id));
            var levels = new Gee.HashMap<string, int>();
            levels[n.id] = level;
            write_order(pages, levels);
            collapsed_pages.remove(parent.id);
            refresh();
            open_note(n.id);
            page.focus_title();
        }

        public void new_from_clip(ImportedNote clip) {
            var d = new PageDoc();
            d.title = clip.title;
            d.body = clip.body;
            new_note(d.serialize());
        }

        private void toggle_pin() {
            var n = store.lookup(current_id);
            if (n == null) return;
            var c = n.copy();
            c.pinned = !c.pinned;
            save(c, false);
            editing = c.copy();
        }

        private void delete_note(string id) {
            var n = store.lookup(id);
            if (n == null) return;
            if (id == current_id) {
                delete_current();
                return;
            }
            trash_note(n);
        }

        private void delete_current() {
            var n = store.lookup(current_id);
            if (n == null) return;
            page.flush();
            n = store.lookup(current_id);
            var shown = visible_notes();
            int index = -1;
            for (int i = 0; i < shown.size; i++) if (shown[i].id == n.id) index = i;
            string? next_id = null;
            if (index >= 0 && index + 1 < shown.size) next_id = shown[index + 1].id;
            else if (index > 0) next_id = shown[index - 1].id;
            var kids = children_of(n);
            string saved_id = n.id;
            if (!trash_note(n)) return;
            foreach (var k in kids) {
                var kc = k.copy();
                var d = PageDoc.parse(plain_body(k));
                d.meta.level = int.max(0, d.meta.level - 1);
                kc.body = seal_for(k.folder, d.serialize(), kc.id);
                save(kc, false);
            }
            current_id = "";
            if (next_id != null && store.lookup(next_id) != null) open_note(next_id);
            else {
                editor_stack.visible_child_name = "nothing";
                update_bubbles();
            }
            var toast = new Toast(_("Page moved to the Recycle Bin"));
            toast.button_label = _("Undo");
            toast.button_clicked.connect(() => {
                try {
                    var r = app.trash.restore(saved_id, store);
                    if (r != null) show_note(r.id);
                } catch (Error e) {
                    add_toast(new Toast(e.message));
                }
            });
            add_toast(toast);
        }

        private void show_trash_item(string id) {
            selected_trash = id;
            foreach (var it in app.trash.items()) {
                if (it.id != id) continue;
                trash_title.label = it.title();
                var n = Singularity.Notes.Note.parse(it.id, it.text);
                trash_preview.label = SectionLocks.is_locked_body(n.body) ? _("This page is protected with a password. Restore it to its section and unlock the section to read it.") : PageDoc.parse(n.body).plain_text();
                editor_stack.visible_child_name = "trash";
            }
            update_bubbles();
        }

        private void restore_trash(string id) {
            if (id == "") return;
            try {
                var n = app.trash.restore(id, store);
                if (n != null) {
                    add_toast(new Toast(_("“%s” restored").printf(PageDoc.title_of(plain_body(n)) != "" ? PageDoc.title_of(plain_body(n)) : _("Untitled Page"))));
                    selected_trash = "";
                    refresh();
                    select_first();
                }
            } catch (Error e) {
                add_toast(new Toast(e.message));
            }
        }

        private void delete_trash_forever(string id) {
            if (id == "") return;
            var dialog = new ConfirmDialog(app, _("Delete Forever?"), "user-trash", _("The page and its attachments cannot be recovered."), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = this;
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    app.trash.delete_forever(id);
                    selected_trash = "";
                    refresh();
                    select_first();
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        private void confirm_empty_trash() {
            var dialog = new ConfirmDialog(app, _("Empty the Recycle Bin?"), "user-trash", _("All deleted pages and their attachments are removed for good."), _("Empty"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dialog.transient_for = this;
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) {
                    app.trash.empty();
                    selected_trash = "";
                    refresh();
                    editor_stack.visible_child_name = "nothing";
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        public void new_folder(FolderKind kind, string parent) {
            string title = kind == FolderKind.NOTEBOOK ? _("New Notebook") : kind == FolderKind.GROUP ? _("New Section Group") : _("New Section");
            string icon = kind == FolderKind.NOTEBOOK ? "accessories-dictionary" : "folder";
            var dialog = new ConfirmDialog(app, title, icon, parent != "" ? _("It is created in “%s”.").printf(parent.replace("/", " › ")) : _("Give it a name."),
                _("Create"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = this;
            var entry = new Entry();
            entry.placeholder_text = _("Name");
            dialog.custom_area.append(entry);
            dialog.primary_sensitive = false;
            entry.changed.connect(() => {
                string t = entry.text.strip();
                dialog.primary_sensitive = t != "" && !t.contains("\n") && !t.contains("/");
            });
            entry.activate.connect(() => {
                if (dialog.primary_sensitive) dialog.response(ConfirmDialog.Response.PRIMARY);
            });
            dialog.response.connect((r) => {
                string name = entry.text.strip();
                if (r == ConfirmDialog.Response.PRIMARY && name != "") {
                    string path = parent == "" ? name : parent + "/" + name;
                    try {
                        store.add_folder(path);
                        app.notebooks.info(path).kind_id = kind.to_id();
                        if (kind == FolderKind.SECTION) app.notebooks.info(path).color = app.notebooks.next_color();
                        app.notebooks.save();
                        if (kind == FolderKind.NOTEBOOK) {
                            string first = path + "/" + _("New Section");
                            store.add_folder(first);
                            app.notebooks.info(first).kind_id = FolderKind.SECTION.to_id();
                            app.notebooks.info(first).color = app.notebooks.next_color();
                            app.notebooks.save();
                            path = first;
                        }
                        stack.visible_child_name = "main";
                        collapsed_folders.remove(parent);
                        select_view("folder:" + path);
                    } catch (Error e) {
                        add_toast(new Toast(e.message));
                    }
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
            entry.grab_focus();
        }

        private void page_menu(Singularity.Widgets.ContextMenu m, Singularity.Notes.Note n) {
            if (n.id != current_id) open_note(n.id);
            m.add_item(_("New Subpage"), "notes-subpage-symbolic", () => new_subpage());
            if (manual_order) {
                int level = level_of(n);
                if (level < 2) m.add_item(_("Make Subpage"), "notes-indent-symbolic", () => change_level(1));
                if (level > 0) m.add_item(_("Promote Subpage"), "notes-outdent-symbolic", () => change_level(-1));
                m.add_item(_("Move Up"), "go-up-symbolic", () => move_page(-1));
                m.add_item(_("Move Down"), "go-down-symbolic", () => move_page(1));
            }
            var move = m.add_submenu(_("Move To"), "folder-symbolic");
            move.add_item(_("Quick Notes"), null, () => move_note_to(n.id, ""));
            foreach (var s in all_sections()) {
                if (s.path == n.folder) continue;
                string p = s.path;
                move.add_item(p.replace("/", " › "), null, () => move_note_to(n.id, p));
            }
            var copy = m.add_submenu(_("Copy To"), "edit-copy-symbolic");
            copy.add_item(_("Quick Notes"), null, () => copy_note_to(n.id, ""));
            foreach (var s in all_sections()) {
                string p = s.path;
                copy.add_item(p.replace("/", " › "), null, () => copy_note_to(n.id, p));
            }
            m.add_separator();
            m.add_item(n.pinned ? _("Unpin") : _("Pin"), "view-pin-symbolic", () => toggle_pin());
            m.add_item(_("Copy Link to Page"), "insert-link-symbolic", () => {
                get_clipboard().set_text("note:" + n.id);
                RichEditor.copied_link = "note:" + n.id;
                add_toast(new Toast(_("Link copied. Paste it in any page.")));
            });
            m.add_item(_("Page Versions…"), "document-open-recent-symbolic", () => show_versions());
            m.add_item(_("Save as Template…"), "document-new-symbolic", () => save_as_template());
            m.add_separator();
            m.add_item(_("Export…"), "document-save-as-symbolic", () => export_dialog(false));
            m.add_item(_("Print…"), "document-print-symbolic", () => print_current());
            m.add_item(_("Share…"), "emblem-shared-symbolic", () => share_current());
            if (NotesCollab.available() && !SectionLocks.is_locked_body(n.body)) {
                string nid = n.id;
                m.add_item(_("Send to…"), "document-send-symbolic", () => app.collab.send(nid, page_menu_bubble));
                if (app.collab.is_shared(nid)) {
                    m.add_item(_("Invite More People…"), "system-users-symbolic", () => app.collab.share(nid, page_menu_bubble));
                    m.add_item(_("Stop Working Together"), "process-stop-symbolic", () => app.collab.stop(nid));
                } else {
                    m.add_item(_("Work Together…"), "system-users-symbolic", () => app.collab.share(nid, page_menu_bubble));
                }
            }
            m.add_separator();
            m.add_item(_("Delete Page"), "user-trash-symbolic", () => delete_current());
        }

        private void copy_note_to(string id, string folder) {
            var n = store.lookup(id);
            if (n == null) return;
            if (!app.locks.is_unlocked(folder)) {
                add_toast(new Toast(_("Unlock the section first")));
                return;
            }
            string body = plain_body(n);
            bool source_locked = SectionLocks.is_locked_body(n.body);
            var copy = create_page("", folder);
            if (copy == null) return;
            string src_dir = Attachments.dir_for(store.dir, id);
            if (FileUtils.test(src_dir, FileTest.IS_DIR)) {
                try {
                    string dst_dir = Attachments.dir_for(store.dir, copy.id);
                    DirUtils.create_with_parents(dst_dir, 0700);
                    var d = Dir.open(src_dir);
                    string? name;
                    while ((name = d.read_name()) != null) {
                        File.new_for_path(Path.build_filename(src_dir, name)).copy(File.new_for_path(Path.build_filename(dst_dir, name)), FileCopyFlags.OVERWRITE);
                    }
                    body = body.replace("attachments/" + id + "/", "attachments/" + copy.id + "/");
                    if (source_locked) {
                        var dd = Dir.open(dst_dir);
                        string? locked_name;
                        var sealed_files = new Gee.ArrayList<string>();
                        while ((locked_name = dd.read_name()) != null) if (locked_name.has_suffix(LockedFiles.SUFFIX)) sealed_files.add(locked_name);
                        foreach (string ln in sealed_files) {
                            string src = Path.build_filename(dst_dir, ln);
                            if (app.locks.decrypt_file(n.folder, src, src.substring(0, src.length - LockedFiles.SUFFIX.length))) FileUtils.unlink(src);
                        }
                    }
                } catch (Error e) {
                }
            }
            var pd = PageDoc.parse(body);
            pd.meta.level = 0;
            pd.meta.order = next_order(folder);
            copy.body = seal_for(folder, pd.serialize(), copy.id);
            save(copy, false);
            add_toast(new Toast(_("Page copied")));
        }

        private void pick_link(RichEditor ed, bool brackets) {
            int sel_start, sel_end;
            bool selected = ed.selection_offsets(out sel_start, out sel_end);
            var picker = new LinkPicker(app, this, store, app.notebooks);
            picker.chosen.connect((label, href) => {
                if (brackets) ed.replace_brackets_with_link(label, href);
                else ed.insert_link(sel_start, sel_end, selected, label, href);
            });
            picker.open_dialog();
        }

        public string title_for_link(string href) {
            if (href.has_prefix("section:")) return Notebooks.name_of(Uri.unescape_string(href.substring(8)) ?? "");
            string id = href.substring(5);
            int hash = id.index_of("#");
            if (hash >= 0) id = id.substring(0, hash);
            var n = store.lookup(id);
            if (n == null) return "";
            string t = PageDoc.title_of(plain_body(n));
            return t != "" ? t : _("Untitled Page");
        }

        private void choose_template() {
            var picker = new TemplatePicker(app, this, app.templates);
            picker.chosen.connect((t) => new_note(t.instantiate()));
            picker.open_dialog();
        }

        private void save_as_template() {
            if (current_id == "") return;
            page.flush();
            var dialog = new ConfirmDialog(app, _("Save as Template"), "document-new", _("New pages can start from this one."), _("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = this;
            var entry = new Entry();
            entry.text = PageDoc.title_of(page.serialize());
            dialog.custom_area.append(entry);
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY && entry.text.strip() != "") {
                    var d = PageDoc.parse(page.serialize());
                    d.title = entry.text.strip();
                    d.meta.level = 0;
                    d.meta.order = 0;
                    try {
                        app.templates.save(entry.text.strip(), d.serialize());
                        add_toast(new Toast(_("Template saved")));
                    } catch (Error e) {
                        add_toast(new Toast(e.message));
                    }
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        private void show_versions() {
            if (current_id == "") return;
            page.flush();
            var n = store.lookup(current_id);
            if (n == null) return;
            app.history.record(n.id, n.serialize(), true);
            var dialog = new VersionsDialog(app, this, app.history, n.id, (text) => plain_body(Singularity.Notes.Note.parse(n.id, text)));
            dialog.restore.connect((text) => {
                var cur = store.lookup(current_id);
                if (cur == null) return;
                var restored = Singularity.Notes.Note.parse(cur.id, text);
                var c = cur.copy();
                c.body = restored.body;
                save(c, true);
                app.history.record(c.id, c.serialize(), true);
                editing = c.copy();
                page.reload(plain_body(c));
                add_toast(new Toast(_("Page version restored")));
            });
            dialog.open_dialog();
        }

        private Gee.List<ExportPage> export_pages(bool section) {
            var list = new Gee.ArrayList<ExportPage>();
            if (!section) {
                var n = store.lookup(current_id);
                if (n != null) {
                    string b = plain_body(n);
                    list.add(new ExportPage(n.id, PageDoc.title_of(b), n.created, b));
                }
                return list;
            }
            foreach (var n in visible_notes()) {
                if (!readable(n)) continue;
                string b = plain_body(n);
                list.add(new ExportPage(n.id, PageDoc.title_of(b), n.created, b));
            }
            return list;
        }

        private string export_dir(Gee.List<ExportPage> pages) {
            bool locked = false;
            foreach (var p in pages) {
                var n = store.lookup(p.id);
                if (n != null && SectionLocks.is_locked_body(n.body)) {
                    locked = true;
                    app.locked_files.prepare(n.folder, n.id, p.body);
                }
            }
            if (!locked) return store.dir;
            foreach (var p in pages) {
                foreach (string target in NoteAttachments.links(p.body)) {
                    string cached = Path.build_filename(app.locked_files.root, target);
                    string plain = Path.build_filename(store.dir, target);
                    if (!FileUtils.test(cached, FileTest.EXISTS) && FileUtils.test(plain, FileTest.IS_REGULAR)) {
                        try {
                            DirUtils.create_with_parents(Path.get_dirname(cached), 0700);
                            File.new_for_path(plain).copy(File.new_for_path(cached), FileCopyFlags.OVERWRITE);
                        } catch (Error e) {
                        }
                    }
                }
            }
            return app.locked_files.root;
        }

        private void export_dialog(bool section) {
            page.flush();
            var pages = export_pages(section);
            if (pages.size == 0) return;
            var dialog = new ExportDialog(app, this, section ? heading.label : pages[0].display_title());
            dialog.chosen.connect((fmt) => {
                var fd = new FileDialog();
                string name = section ? heading.label : pages[0].display_title();
                fd.initial_name = Attachments.clean_name(name).replace("/", "-") + "." + fmt.extension();
                fd.save.begin(this, null, (o, r) => {
                    try {
                        var file = fd.save.end(r);
                        if (file == null) return;
                        var ex = new Exporter(export_dir(pages));
                        ex.pages.add_all(pages);
                        ex.write(fmt, file.get_path());
                        ex.cleanup();
                        add_toast(new Toast(_("Exported to %s").printf(file.get_basename())));
                    } catch (Error e) {
                        if (!(e is Gtk.DialogError.DISMISSED)) add_toast(new Toast(_("The export failed: %s").printf(e.message)));
                    }
                });
            });
            dialog.open_dialog();
        }

        private void print_current() {
            page.flush();
            var pages = export_pages(false);
            if (pages.size == 0) return;
            var renderer = new NoteRenderer(export_dir(pages));
            renderer.pages.add_all(pages);
            Singularity.Print.run_callbacks.begin(this, pages[0].display_title(),
                (fmt) => renderer.paginate(fmt.width, fmt.height, fmt.margin_left, fmt.margin_top, fmt.margin_right, fmt.margin_bottom),
                (cr, index, fmt) => renderer.render_page(cr, index));
        }

        private void create_presentation() {
            page.flush();
            var n = store.lookup(current_id);
            if (n == null) return;
            string outline = outline_of(n.title, n.body);
            if (outline == "") return;
            ShareTargets.activate_app_action.begin("dev.sinty.slides", "new-from-outline", new Variant.string(outline));
        }

        internal static string outline_of(string title, string body) {
            var sb = new StringBuilder();
            bool slide_open = false;
            bool in_code = false;
            foreach (string raw in body.split("\n")) {
                string line = raw.replace("\r", "");
                string t = line.strip();
                if (t.has_prefix("```")) {
                    in_code = !in_code;
                    continue;
                }
                if (in_code || t == "" || t.has_prefix("![") || t.has_prefix("<!--")) continue;
                if (t.has_prefix("#")) {
                    int h = 0;
                    while (h < t.length && t[h] == '#') h++;
                    string heading = plain(t.substring(h).strip());
                    if (heading == "") continue;
                    sb.append(heading).append_c('\n');
                    slide_open = true;
                    continue;
                }
                if (!slide_open) {
                    sb.append(title != "" ? title : _("Untitled")).append_c('\n');
                    slide_open = true;
                }
                int indent = 0;
                while (indent < line.length && (line[indent] == ' ' || line[indent] == '\t')) indent += line[indent] == '\t' ? 2 : 1;
                int level = 1 + indent / 2;
                string item = t;
                foreach (string mark in new string[] { "- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ ", "> " }) {
                    if (item.has_prefix(mark)) {
                        item = item.substring(mark.length);
                        break;
                    }
                }
                int dot = item.index_of(". ");
                if (dot > 0 && dot <= 3 && uint64.try_parse(item.substring(0, dot))) item = item.substring(dot + 2);
                item = plain(item);
                if (item == "") continue;
                for (int i = 0; i < level.clamp(1, 5); i++) sb.append_c('\t');
                sb.append(item).append_c('\n');
            }
            return sb.str;
        }

        private static string plain(string text) {
            string s = text.replace("**", "").replace("__", "").replace("`", "");
            try {
                s = new Regex("\\[([^\\]]*)\\]\\([^)]*\\)").replace(s, -1, 0, "\\1");
            } catch (RegexError e) {
            }
            return s.strip();
        }

        private void share_current() {
            page.flush();
            var pages = export_pages(false);
            if (pages.size == 0) return;
            string dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity-notes", "share");
            DirUtils.create_with_parents(dir, 0700);
            string path = Path.build_filename(dir, Attachments.clean_name(pages[0].display_title()) + ".pdf");
            try {
                var ex = new Exporter(export_dir(pages));
                ex.pages.add_all(pages);
                ex.write(ExportFormat.PDF, path);
            } catch (Error e) {
                add_toast(new Toast(e.message));
                return;
            }
            var content = new ShareContent.for_files({ File.new_for_path(path) });
            content.title = pages[0].display_title();
            content.text = PageDoc.parse(pages[0].body).plain_text();
            var sheet = new ShareSheet(this, content, app);
            sheet.open_dialog();
        }

        private void import_files() {
            var fd = new FileDialog();
            fd.title = _("Import Notes");
            var filter = new FileFilter();
            filter.name = _("Notes and Documents");
            foreach (string p in new string[] { "*.enex", "*.md", "*.markdown", "*.txt", "*.html", "*.htm", "*.docx", "*.odt", "*.one" }) filter.add_pattern(p);
            var filters = new GLib.ListStore(typeof(FileFilter));
            filters.append(filter);
            fd.filters = filters;
            fd.open_multiple.begin(this, null, (o, r) => {
                try {
                    var files = fd.open_multiple.end(r);
                    if (files == null) return;
                    import_list.begin(files);
                } catch (Error e) {
                }
            });
        }

        private async void import_list(ListModel files) {
            string folder = target_folder();
            int count = 0;
            for (uint i = 0; i < files.get_n_items(); i++) {
                var f = (File) files.get_item(i);
                try {
                    var got = yield Importer.import_file(f, store, folder);
                    count += got.size;
                } catch (Error e) {
                    add_toast(new Toast(_("%s could not be imported: %s").printf(f.get_basename(), e.message)));
                }
            }
            if (count > 0) add_toast(new Toast(ngettext("%d page imported", "%d pages imported", count).printf(count)));
            queue_refresh();
        }

        public void flush() {
            page.flush();
        }

        public PageView page_view() {
            return page;
        }
    }
}
