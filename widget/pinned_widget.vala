using Gtk;
using Singularity;

namespace SingularityNotesWidget {

    public class PinnedProvider : Object, OverviewWidgetProvider {
        public string id { get { return "notes.pinned"; } }
        public string provider_id { get { return "dev.sinty.notes"; } }
        public string display_name { get { return _("Notes"); } }
        public string icon_name { get { return "dev.sinty.notes"; } }
        public WidgetSize[] supported_sizes {
            get {
                if (_sizes == null) {
                    _sizes = new WidgetSize[3];
                    _sizes[0] = WidgetSize(2, 1);
                    _sizes[1] = WidgetSize(2, 2);
                    _sizes[2] = WidgetSize(4, 2);
                }
                return _sizes;
            }
        }
        private WidgetSize[] _sizes;

        public Gtk.Widget create_instance(string instance_id, WidgetSize size, Variant? config) {
            return new PinnedInstance(size);
        }
    }

    public class PinnedInstance : Box {
        private WidgetSize size;
        private Box notes_box;
        private Label header;
        private ulong changed_id = 0;
        private Singularity.Notes.NoteStore store;

        public PinnedInstance(WidgetSize size) {
            Object(orientation: Orientation.VERTICAL, spacing: 6);
            this.size = size;
            add_css_class("overview-widget-card");
            add_css_class("overview-notes-pinned");
            hexpand = true;
            vexpand = true;
            overflow = Overflow.HIDDEN;

            var inner = new Box(Orientation.VERTICAL, 6);
            inner.margin_top = 12;
            inner.margin_bottom = 12;
            inner.margin_start = 14;
            inner.margin_end = 10;
            inner.vexpand = true;
            append(inner);

            var top = new Box(Orientation.HORIZONTAL, 8);
            var icon = new Image.from_icon_name("dev.sinty.notes");
            icon.pixel_size = 24;
            top.append(icon);
            header = new Label(_("Pinned Notes"));
            header.xalign = 0;
            header.hexpand = true;
            header.add_css_class("heading");
            top.append(header);
            var add = new Button.from_icon_name("list-add-symbolic");
            add.add_css_class("flat");
            add.add_css_class("circular");
            add.tooltip_text = _("New Note");
            add.clicked.connect(() => activate_app("new-note", null));
            top.append(add);
            inner.append(top);

            notes_box = new Box(size.w >= 4 ? Orientation.HORIZONTAL : Orientation.VERTICAL, 6);
            notes_box.vexpand = true;
            notes_box.homogeneous = size.w >= 4;
            inner.append(notes_box);

            store = Singularity.Notes.NoteStore.get_default();
            changed_id = store.changed.connect(() => {
                Idle.add(() => {
                    refresh();
                    return Source.REMOVE;
                });
            });
            destroy.connect(() => {
                if (changed_id != 0) store.disconnect(changed_id);
                changed_id = 0;
            });
            refresh();
        }

        private int capacity() {
            if (size.w >= 4) return 3;
            if (size.h >= 2) return 3;
            return 1;
        }

        private void refresh() {
            Widget? child;
            while ((child = notes_box.get_first_child()) != null) notes_box.remove(child);
            var shown = new Gee.ArrayList<Singularity.Notes.Note>();
            foreach (var n in store.all()) if (n.pinned && shown.size < capacity()) shown.add(n);
            header.label = shown.size > 0 ? _("Pinned Notes") : _("Recent Notes");
            if (shown.size == 0) {
                foreach (var n in store.all()) if (shown.size < capacity()) shown.add(n);
            }
            if (shown.size == 0) {
                var empty = new Label(_("Notes you pin appear here"));
                empty.add_css_class("dim-label");
                empty.wrap = true;
                empty.vexpand = true;
                notes_box.append(empty);
                return;
            }
            foreach (var n in shown) notes_box.append(card(n));
        }

        private Widget card(Singularity.Notes.Note n) {
            var b = new Button();
            b.add_css_class("flat");
            b.add_css_class("overview-notes-card");
            var box = new Box(Orientation.VERTICAL, 2);
            var title = new Label(n.title != "" ? n.title : _("New Note"));
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.add_css_class("heading");
            box.append(title);
            string snippet = n.snippet;
            if (snippet != "") {
                var sub = new Label(snippet);
                sub.xalign = 0;
                sub.ellipsize = Pango.EllipsizeMode.END;
                sub.lines = size.w >= 4 && size.h >= 2 ? 4 : 1;
                sub.wrap = size.w >= 4 && size.h >= 2;
                sub.add_css_class("caption");
                sub.add_css_class("dim-label");
                box.append(sub);
            }
            b.child = box;
            string id = n.id;
            b.clicked.connect(() => activate_app("show-note", new Variant.string(id)));
            return b;
        }

        private void activate_app(string action, Variant? target) {
            OverviewWidgetRegistry.get_default().close_overview();
            var parameters = new VariantBuilder(new VariantType("av"));
            if (target != null) parameters.add("v", target);
            var platform = new VariantBuilder(new VariantType("a{sv}"));
            Bus.get.begin(BusType.SESSION, null, (o, r) => {
                try {
                    var bus = Bus.get.end(r);
                    bus.call.begin("dev.sinty.notes", "/dev/sinty/notes", "org.freedesktop.Application", "ActivateAction",
                        new Variant("(s@av@a{sv})", action, parameters.end(), platform.end()),
                        null, DBusCallFlags.NONE, 20000, null, (obj, res) => {
                            try {
                                bus.call.end(res);
                            } catch (Error e) {
                                warning("Notes widget: %s", e.message);
                            }
                        });
                } catch (Error e) {
                    warning("Notes widget: %s", e.message);
                }
            });
        }
    }

    [CCode (cname = "singularity_notes_widget_new")]
    public static Object singularity_notes_widget_new() {
        return new PinnedProvider();
    }
}
