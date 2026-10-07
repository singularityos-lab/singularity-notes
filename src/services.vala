using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Notes {

    public class TaskBridge {
        public const string TASKS_APP = "dev.sinty.tasks";

        public static bool available() {
            return ShareTargets.find_app_info(TASKS_APP) != null;
        }

        public static void ask(Gtk.Window? parent, string text, string page_title, string uid, owned Closure done) {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new ConfirmDialog(app, _("Add to Tasks"), "checkbox-checked", _("The task appears in Tasks with its due date and reminder."),
                _("Add Task"), ConfirmDialog.ActionStyle.SUGGESTED);
            dialog.transient_for = parent;
            var entry = new Entry();
            entry.text = text;
            dialog.custom_area.append(entry);
            var when = new DropDown.from_strings({ _("No Due Date"), _("Today"), _("Tomorrow"), _("This Week"), _("Next Week"), _("Choose a Date") });
            dialog.custom_area.append(when);
            var cal = new Gtk.Calendar();
            cal.visible = false;
            dialog.custom_area.append(cal);
            when.notify["selected"].connect(() => cal.visible = when.selected == 5);
            var link = new CheckButton.with_label(_("Mention this page in the task"));
            link.active = page_title != "";
            dialog.custom_area.append(link);
            entry.activate.connect(() => dialog.response(ConfirmDialog.Response.PRIMARY));
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY && entry.text.strip() != "") {
                    var now = new DateTime.now_local();
                    DateTime? due = null;
                    switch (when.selected) {
                        case 1: due = now; break;
                        case 2: due = now.add_days(1); break;
                        case 3: due = now.add_days(int.max(0, 5 - now.get_day_of_week())); break;
                        case 4: due = now.add_days(8 - now.get_day_of_week()); break;
                        case 5:
                            var d = cal.get_date();
                            due = d;
                            break;
                        default: break;
                    }
                    string title = entry.text.strip();
                    if (link.active && page_title != "") title += " (%s)".printf(page_title);
                    if (due != null) title += " " + due.format("%Y-%m-%d");
                    ShareTargets.activate_app_action.begin(TASKS_APP, "add-linked-task", new Variant("(ss)", uid, title));
                    done();
                }
                dialog.close_dialog();
            });
            dialog.open_dialog();
        }

        public delegate void Closure();
    }

    public class LinkedTasks {
        public const string TAG_PREFIX = "task-";
        private static Regex? check_line;
        private static Regex? task_tag;

        private static void ensure() {
            if (check_line != null) return;
            try {
                check_line = new Regex("^\\s*[-*] \\[([ xX])\\] ");
                task_tag = new Regex("\\[!task-([0-9a-f-]{8,})\\]");
            } catch (RegexError e) {
                warning("Linked tasks: %s", e.message);
            }
        }

        public static Gee.HashMap<string, bool> states(string body) {
            ensure();
            var result = new Gee.HashMap<string, bool>();
            if (check_line == null || !body.contains("[!task-")) return result;
            foreach (string line in body.split("\n")) {
                MatchInfo cm, tm;
                if (!check_line.match(line, 0, out cm)) continue;
                if (!task_tag.match(line, 0, out tm)) continue;
                result[tm.fetch(1)] = cm.fetch(1) != " ";
            }
            return result;
        }

        public static void push(string? old_body, string new_body) {
            if (!new_body.contains("[!task-")) return;
            var before = states(old_body ?? "");
            foreach (var e in states(new_body).entries) {
                if (before.has_key(e.key) && before[e.key] == e.value) continue;
                if (!before.has_key(e.key) && !e.value) continue;
                ShareTargets.activate_app_action.begin(TaskBridge.TASKS_APP, "set-task-completed", new Variant("(sb)", e.key, e.value));
            }
        }

        public static string apply(string body, Gee.Map<string, bool> done) {
            ensure();
            if (check_line == null || !body.contains("[!task-")) return body;
            var lines = body.split("\n");
            bool changed = false;
            for (int i = 0; i < lines.length; i++) {
                MatchInfo cm, tm;
                if (!check_line.match(lines[i], 0, out cm)) continue;
                if (!task_tag.match(lines[i], 0, out tm)) continue;
                string uid = tm.fetch(1);
                if (!done.has_key(uid)) continue;
                bool is_done = cm.fetch(1) != " ";
                if (is_done == done[uid]) continue;
                int start, end;
                cm.fetch_pos(1, out start, out end);
                lines[i] = lines[i].substring(0, start) + (done[uid] ? "x" : " ") + lines[i].substring(end);
                changed = true;
            }
            return changed ? string.joinv("\n", lines) : body;
        }

        public static Gee.HashMap<string, bool> read_tasks() {
            var result = new Gee.HashMap<string, bool>();
            string path = Path.build_filename(Environment.get_user_data_dir(), "singularity", "tasks", "tasks.json");
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT || !root.get_object().has_member("tasks")) return result;
                foreach (var node in root.get_object().get_array_member("tasks").get_elements()) {
                    var t = node.get_object();
                    if (t == null || !t.has_member("uid")) continue;
                    result[t.get_string_member("uid")] = t.get_boolean_member_with_default("completed", false);
                }
            } catch (Error e) {
            }
            return result;
        }

        public static void sync_from_tasks(Singularity.Notes.NoteStore store) {
            var done = read_tasks();
            if (done.size == 0) return;
            foreach (var n in store.all()) {
                if (!n.body.contains("[!task-")) continue;
                string updated = apply(n.body, done);
                if (updated == n.body) continue;
                var copy = n.copy();
                copy.body = updated;
                try {
                    store.save(copy, false);
                } catch (Error e) {
                    warning("Linked tasks: %s", e.message);
                }
            }
        }
    }

    [DBus (name = "dev.sinty.TranslateService")]
    public interface TranslateProxy : Object {
        public abstract async void translate(string text, string source, string target, out string translation, out string detected, out string provider) throws Error;
        public abstract string default_target() throws Error;
    }

    public class TranslateBridge {
        public delegate void Apply(string text, bool replace);
        private delegate void Runner();

        public static void open(Gtk.Window? parent, string text, owned Apply apply) {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new AppDialog(app, true);
            dialog.set_title(_("Translate"));
            dialog.set_default_size(560, 460);
            dialog.transient_for = parent;
            var box = new Box(Orientation.VERTICAL, 10);
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_bottom = 20;
            var source = new Label(text);
            source.wrap = true;
            source.xalign = 0;
            source.add_css_class("dim-label");
            source.max_width_chars = 60;
            box.append(source);
            var langs = new DropDown.from_strings({ _("Default Language"), "English", "Italiano", "Deutsch", "Français", "Español", "Português", "Nederlands", "Polski", "Русский", "日本語", "中文" });
            string[] codes = { "", "en", "it", "de", "fr", "es", "pt", "nl", "pl", "ru", "ja", "zh" };
            box.append(langs);
            var result = new Label(_("Translating…"));
            result.wrap = true;
            result.xalign = 0;
            result.yalign = 0;
            result.selectable = true;
            result.vexpand = true;
            result.add_css_class("notes-translation");
            var scroll = new ScrolledWindow();
            scroll.vexpand = true;
            scroll.child = result;
            box.append(scroll);
            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            buttons.append(dialog.add_cancel_button(_("Close")));
            var insert = new Button.with_label(_("Insert Below"));
            insert.sensitive = false;
            var replace = new Button.with_label(_("Replace"));
            replace.add_css_class("suggested-action");
            replace.sensitive = false;
            buttons.append(insert);
            buttons.append(replace);
            box.append(buttons);
            dialog.content_box.append(box);
            string translated = "";
            Runner run = () => {
                result.label = _("Translating…");
                insert.sensitive = false;
                replace.sensitive = false;
                translate.begin(text, codes[langs.selected], (o, r) => {
                    try {
                        translated = translate.end(r);
                        result.label = translated;
                        insert.sensitive = translated != "";
                        replace.sensitive = translated != "";
                    } catch (Error e) {
                        result.label = _("Translation is not available: %s").printf(e.message);
                    }
                });
            };
            langs.notify["selected"].connect(() => run());
            insert.clicked.connect(() => {
                apply(translated, false);
                dialog.close_dialog();
            });
            replace.clicked.connect(() => {
                apply(translated, true);
                dialog.close_dialog();
            });
            dialog.open_dialog();
            run();
        }

        public static async string translate(string text, string target) throws Error {
            TranslateProxy proxy = yield Bus.get_proxy(BusType.SESSION, "dev.sinty.TranslateService", "/dev/sinty/TranslateService");
            string to = target != "" ? target : proxy.default_target();
            string translation, detected, provider;
            yield proxy.translate(text, "", to, out translation, out detected, out provider);
            return translation;
        }
    }

    public class Speech : Object {
        private Subprocess? process = null;
        private Cancellable? cancel = null;

        public static string? program() {
            string? over = Environment.get_variable("NOTES_SPEECH");
            if (over != null && over != "") return over;
            foreach (string p in new string[] { "spd-say", "espeak-ng", "espeak" }) {
                string? found = Environment.find_program_in_path(p);
                if (found != null) return found;
            }
            return null;
        }

        public static bool available {
            get { return program() != null; }
        }

        public async bool say(string text, int rate) {
            string? prog = program();
            if (prog == null) return false;
            string[] argv = { prog };
            string name = Path.get_basename(prog);
            if (name == "spd-say") {
                argv += "--wait";
                argv += "-r";
                argv += rate.to_string();
            } else if (name.has_prefix("espeak")) {
                argv += "-s";
                argv += (175 + rate).to_string();
            }
            argv += text;
            cancel = new Cancellable();
            try {
                process = new Subprocess.newv(argv, SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                yield process.wait_async(cancel);
                return process.get_successful();
            } catch (Error e) {
                return false;
            } finally {
                process = null;
            }
        }

        public void stop() {
            if (cancel != null) cancel.cancel();
            if (process != null) process.force_exit();
            process = null;
        }
    }

    public class ImmersiveReader : AppDialog {
        private TextView view;
        private TextBuffer buffer;
        private TextTag tag_focus;
        private Gee.ArrayList<int> starts = new Gee.ArrayList<int>();
        private Gee.ArrayList<int> ends = new Gee.ArrayList<int>();
        private int current = -1;
        private bool reading = false;
        private Speech speech = new Speech();
        private Button play;
        private int size = 22;
        private string theme = "light";
        private int rate = 0;
        private CssProvider size_provider = new CssProvider();

        public ImmersiveReader(Gtk.Application app, Gtk.Window? owner, string title, string text) {
            base(app, true);
            transient_for = owner;
            set_title(_("Immersive Reader"));
            set_default_size(900, 680);
            add_css_class("notes-reader");
            var box = new Box(Orientation.VERTICAL, 8);
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_bottom = 16;
            var bar = new Box(Orientation.HORIZONTAL, 6);
            play = new Button.from_icon_name("media-playback-start-symbolic");
            play.tooltip_text = Speech.available ? _("Read Aloud") : _("Install a speech synthesizer such as espeak-ng to read aloud");
            play.sensitive = Speech.available;
            play.clicked.connect(() => toggle());
            bar.append(play);
            var prev = new Button.from_icon_name("media-skip-backward-symbolic");
            prev.tooltip_text = _("Previous Sentence");
            prev.clicked.connect(() => step(-1));
            bar.append(prev);
            var next = new Button.from_icon_name("media-skip-forward-symbolic");
            next.tooltip_text = _("Next Sentence");
            next.clicked.connect(() => step(1));
            bar.append(next);
            var slower = new Button.with_label(_("Slower"));
            slower.clicked.connect(() => rate = int.max(-60, rate - 20));
            bar.append(slower);
            var faster = new Button.with_label(_("Faster"));
            faster.clicked.connect(() => rate = int.min(60, rate + 20));
            bar.append(faster);
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            bar.append(spacer);
            var smaller = new Button.from_icon_name("zoom-out-symbolic");
            smaller.tooltip_text = _("Smaller Text");
            smaller.clicked.connect(() => set_size(size - 2));
            bar.append(smaller);
            var bigger = new Button.from_icon_name("zoom-in-symbolic");
            bigger.tooltip_text = _("Larger Text");
            bigger.clicked.connect(() => set_size(size + 2));
            bar.append(bigger);
            var themes = new BubbleSwitcher();
            themes.add_option("light", _("Light"));
            themes.add_option("sepia", _("Sepia"));
            themes.add_option("dark", _("Dark"));
            themes.selected.connect((t) => set_theme(t));
            bar.append(themes);
            box.append(bar);
            buffer = new TextBuffer(null);
            tag_focus = buffer.create_tag("focus", "background-rgba", rgba("rgba(255,214,0,0.45)"));
            view = new TextView.with_buffer(buffer);
            view.editable = false;
            view.cursor_visible = false;
            view.wrap_mode = WrapMode.WORD;
            view.left_margin = 60;
            view.right_margin = 60;
            view.top_margin = 30;
            view.bottom_margin = 60;
            view.pixels_below_lines = 14;
            view.pixels_inside_wrap = 8;
            view.add_css_class("notes-reader-text");
            var scroll = new ScrolledWindow();
            scroll.vexpand = true;
            scroll.child = view;
            box.append(scroll);
            var close = add_cancel_button(_("Close"));
            close.halign = Align.END;
            box.append(close);
            content_box.append(box);
            TextIter end;
            buffer.get_end_iter(out end);
            var title_tag = buffer.create_tag("title", "scale", 1.5, "weight", 700);
            buffer.insert_with_tags(ref end, title + "\n", -1, title_tag);
            buffer.insert(ref end, text, -1);
            split_sentences();
            StyleContext.add_provider_for_display(get_display(), size_provider, STYLE_PROVIDER_PRIORITY_USER + 5);
            set_size(size);
            set_theme(theme);
            var click = new GestureClick();
            click.released.connect((n, x, y) => {
                int bx, by;
                view.window_to_buffer_coords(TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
                TextIter it;
                if (!view.get_iter_at_location(out it, bx, by)) return;
                for (int i = 0; i < starts.size; i++) {
                    if (it.get_offset() >= starts[i] && it.get_offset() < ends[i]) {
                        focus_sentence(i);
                        break;
                    }
                }
            });
            view.add_controller(click);
            close_request.connect(() => {
                reading = false;
                speech.stop();
                return false;
            });
        }

        private static Gdk.RGBA rgba(string s) {
            var c = Gdk.RGBA();
            c.parse(s);
            return c;
        }

        private void split_sentences() {
            TextIter s, e;
            buffer.get_bounds(out s, out e);
            string all = s.get_text(e);
            int i = 0;
            unichar c;
            int chars = 0;
            int sentence_start_chars = 0;
            while (all.get_next_char(ref i, out c)) {
                chars++;
                if (c == '.' || c == '!' || c == '?' || c == '\n' || c == ';') {
                    if (chars - sentence_start_chars > 1) {
                        starts.add(sentence_start_chars);
                        ends.add(chars);
                    }
                    sentence_start_chars = chars;
                }
            }
            if (chars - sentence_start_chars > 1) {
                starts.add(sentence_start_chars);
                ends.add(chars);
            }
        }

        private void set_size(int s) {
            size = s.clamp(14, 48);
            size_provider.load_from_string("textview.notes-reader-text { font-size: %dpx; }".printf(size));
        }

        private void set_theme(string t) {
            theme = t;
            foreach (string x in new string[] { "light", "sepia", "dark" }) view.remove_css_class("notes-reader-" + x);
            view.add_css_class("notes-reader-" + t);
        }

        private void focus_sentence(int i) {
            if (i < 0 || i >= starts.size) return;
            current = i;
            TextIter s, e;
            buffer.get_bounds(out s, out e);
            buffer.remove_tag(tag_focus, s, e);
            buffer.get_iter_at_offset(out s, starts[i]);
            buffer.get_iter_at_offset(out e, ends[i]);
            buffer.apply_tag(tag_focus, s, e);
            view.scroll_to_iter(s, 0.2, true, 0, 0.4);
        }

        private void step(int d) {
            bool was = reading;
            if (was) {
                reading = false;
                speech.stop();
            }
            focus_sentence((current + d).clamp(0, starts.size - 1));
            if (was) {
                reading = true;
                read_from(current);
            }
        }

        private void toggle() {
            if (reading) {
                reading = false;
                speech.stop();
                play.icon_name = "media-playback-start-symbolic";
                return;
            }
            reading = true;
            play.icon_name = "media-playback-pause-symbolic";
            read_from(current < 0 ? 0 : current);
        }

        private void read_from(int i) {
            if (!reading || i >= starts.size) {
                reading = false;
                play.icon_name = "media-playback-start-symbolic";
                return;
            }
            focus_sentence(i);
            TextIter s, e;
            buffer.get_iter_at_offset(out s, starts[i]);
            buffer.get_iter_at_offset(out e, ends[i]);
            string text = s.get_text(e).strip();
            speech.say.begin(text, rate, (o, r) => {
                speech.say.end(r);
                if (reading && current == i) read_from(i + 1);
            });
        }
    }
}
