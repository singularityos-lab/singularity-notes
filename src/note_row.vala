using Gtk;

namespace Singularity.Apps.Notes {

    public class NoteRow : ListBoxRow {
        public const string STYLE = """
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
""";

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
}
