using Gtk;

namespace Singularity.Apps.Notes {

    public class AgentCard : Object {
        private const int MAX_ROWS = 6;
        private static bool styled = false;

        private static void show_note (string id) {
            Bus.get.begin (BusType.SESSION, null, (obj, res) => {
                try {
                    var bus = Bus.get.end (res);
                    var args = new VariantBuilder (new VariantType ("av"));
                    args.add ("v", new Variant.string (id));
                    bus.call.begin ("dev.sinty.notes", "/dev/sinty/notes", "org.gtk.Actions", "Activate",
                        new Variant ("(sava{sv})", "show-note", args, new VariantBuilder (new VariantType ("a{sv}"))),
                        null, DBusCallFlags.NONE, 10000, null);
                } catch (Error e) {
                    warning ("Notes card: %s", e.message);
                }
            });
        }

        private static NoteRow? row_for (Json.Node node) {
            if (node.get_node_type () != Json.NodeType.OBJECT) return null;
            var o = node.get_object ();
            if (!o.has_member ("id")) return null;
            var note = Singularity.Notes.NoteStore.get_default ().lookup (o.get_string_member ("id"));
            if (note == null) return null;
            if (note.body.contains (LOCKED_MARKER)) return new NoteRow (note, true, _("Protected Page"), _("Unlock the section to read it"));
            return new NoteRow (note, true, PageDoc.title_of (note.body), PageDoc.snippet_of (note.body));
        }

        public static Widget? build (string intent, string args, string result) {
            Json.Node root;
            try {
                root = Json.from_string (result);
            } catch (Error e) {
                return null;
            }
            if (root == null) return null;
            if (!styled) {
                var css = new CssProvider ();
                css.load_from_string (NoteRow.STYLE);
                Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), css, STYLE_PROVIDER_PRIORITY_APPLICATION);
                styled = true;
            }
            var list = new ListBox ();
            list.selection_mode = SelectionMode.NONE;
            list.add_css_class ("boxed-list");
            list.row_activated.connect ((r) => show_note (((NoteRow) r).note.id));
            if (root.get_node_type () == Json.NodeType.ARRAY) {
                foreach (var n in root.get_array ().get_elements ()) {
                    if (list.get_row_at_index (MAX_ROWS - 1) != null) break;
                    var row = row_for (n);
                    if (row != null) list.append (row);
                }
            } else {
                var row = row_for (root);
                if (row != null) list.append (row);
            }
            if (list.get_row_at_index (0) == null) {
                var none = new Label (_("No pages"));
                none.add_css_class ("dim-label");
                none.xalign = 0;
                return none;
            }
            return list;
        }
    }

    [CCode (cname = "singularity_notes_card_new")]
    public Widget? agent_card_new (string intent, string args, string result) {
        return AgentCard.build (intent, args, result);
    }
}
