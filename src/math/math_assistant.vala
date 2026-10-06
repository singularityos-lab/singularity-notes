using Gtk;

namespace Singularity.Apps.Notes {

    public class MathAssistant {
        private delegate void Runner();

        public static void open(RichEditor editor, string initial) {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new Singularity.Widgets.AppDialog(app, true);
            dialog.set_title(_("Math Assistant"));
            dialog.set_default_size(580, 640);
            dialog.transient_for = editor.view.get_root() as Gtk.Window;
            var box = new Box(Orientation.VERTICAL, 12);
            box.margin_start = 20;
            box.margin_end = 20;
            box.margin_bottom = 20;
            var hint = new Label(_("Type an expression, a function of x or an equation, for example 2x + 3 = 11, x^2 - 5x + 6 = 0 or sin(x)"));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class("dim-label");
            box.append(hint);
            var entry = new Entry();
            entry.text = initial;
            entry.placeholder_text = "x^2 - 4 = 0";
            box.append(entry);
            var steps = new Label("");
            steps.wrap = true;
            steps.xalign = 0;
            steps.selectable = true;
            steps.add_css_class("notes-math-steps");
            box.append(steps);
            var graph = new Picture();
            graph.set_size_request(480, 300);
            graph.can_shrink = true;
            graph.visible = false;
            box.append(graph);
            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            var insert_graph = new Button.with_label(_("Insert Graph"));
            insert_graph.sensitive = false;
            var insert_steps = new Button.with_label(_("Insert Solution"));
            insert_steps.add_css_class("suggested-action");
            insert_steps.sensitive = false;
            var solve = new Button.with_label(_("Solve"));
            buttons.append(dialog.add_cancel_button(_("Close")));
            buttons.append(solve);
            buttons.append(insert_graph);
            buttons.append(insert_steps);
            box.append(buttons);
            dialog.content_box.append(box);
            MathSolution? current = null;
            Cairo.ImageSurface? plot = null;
            Runner run = () => {
                try {
                    current = MathSolver.solve(entry.text);
                    steps.label = string.joinv("\n", current.steps.to_array());
                    insert_steps.sensitive = true;
                    if (current.function != null && current.function.uses_x()) {
                        plot = MathSolver.plot(current.function, current.roots, 960, 600);
                        graph.paintable = texture_of(plot);
                        graph.visible = true;
                        insert_graph.sensitive = true;
                    } else {
                        graph.visible = false;
                        insert_graph.sensitive = false;
                        plot = null;
                    }
                } catch (MathError e) {
                    steps.label = e.message;
                    insert_steps.sensitive = false;
                    insert_graph.sensitive = false;
                    graph.visible = false;
                }
            };
            solve.clicked.connect(() => run());
            entry.activate.connect(() => run());
            insert_steps.clicked.connect(() => {
                if (current == null) return;
                var sb = new StringBuilder();
                foreach (string s in current.steps) sb.append(s + "\n");
                editor.insert_plain(sb.str);
                editor.changed();
                dialog.close_dialog();
            });
            insert_graph.clicked.connect(() => {
                if (plot == null || editor.note_id == "") return;
                string path = Attachments.new_path(editor.notes_dir, editor.note_id, "graph-", "png");
                plot.write_to_png(path);
                editor.insert_block_at_cursor(RichText.image_block(_("Graph of %s").printf(entry.text.strip()), Attachments.relative(editor.note_id, path), 480));
                dialog.close_dialog();
            });
            if (initial.strip() != "") run();
            dialog.open_dialog();
            entry.grab_focus();
        }

        public static Gdk.Texture texture_of(Cairo.ImageSurface s) {
            int w = s.get_width();
            int h = s.get_height();
            int stride = s.get_stride();
            s.flush();
            unowned uchar[] data = s.get_data();
            var copy = new uint8[stride * h];
            Memory.copy(copy, data, stride * h);
            return new Gdk.MemoryTexture(w, h, Gdk.MemoryFormat.B8G8R8X8, new Bytes.take(copy), stride);
        }
    }
}
