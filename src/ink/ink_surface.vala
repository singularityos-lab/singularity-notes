using Gtk;

namespace Singularity.Apps.Notes {

    public class InkSurface : Widget {
        public signal void changed();
        public signal void convert_text_requested(Gee.List<Stroke> strokes);
        public signal void convert_math_requested(Gee.List<Stroke> strokes);
        public signal void correct_requested();
        public signal void status(string message);

        public InkDoc doc;
        public bool grow = false;
        public bool can_correct = false;
        private Stroke? current = null;
        private Gee.ArrayList<InkPoint> lasso = new Gee.ArrayList<InkPoint>();
        private Gee.HashSet<Stroke> selection = new Gee.HashSet<Stroke>();
        private bool moving = false;
        private double last_x;
        private double last_y;
        private double start_x;
        private double start_y;
        private bool erased = false;
        private double ruler_x = 320;
        private double ruler_y = 180;
        private bool moving_ruler = false;
        private bool snapping = false;
        private double ruler_start_x;
        private double ruler_start_y;
        public const double RULER_LENGTH = 640;
        public const double RULER_WIDTH = 52;

        public InkSurface(InkDoc doc) {
            this.doc = doc;
            focusable = true;
            add_css_class("notes-ink");
            var drag = new GestureDrag();
            drag.button = Gdk.BUTTON_PRIMARY;
            drag.drag_begin.connect(on_begin);
            drag.drag_update.connect(on_update);
            drag.drag_end.connect(on_end);
            add_controller(drag);
            var keys = new EventControllerKey();
            keys.key_pressed.connect((kv, code, state) => {
                if ((kv == Gdk.Key.Delete || kv == Gdk.Key.BackSpace) && selection.size > 0) {
                    delete_selection();
                    return true;
                }
                if (kv == Gdk.Key.Escape && selection.size > 0) {
                    selection.clear();
                    queue_draw();
                    return true;
                }
                return false;
            });
            add_controller(keys);
            var right = new GestureClick();
            right.button = Gdk.BUTTON_SECONDARY;
            right.pressed.connect((n, x, y) => {
                right.set_state(EventSequenceState.CLAIMED);
                open_menu(x, y);
            });
            add_controller(right);
            Menus.register(this, (w, x, y) => ((InkSurface) w).open_menu(x, y));
            InkTools.get_default().notify["ruler"].connect(() => queue_draw());
            InkTools.get_default().notify["ruler-angle"].connect(() => queue_draw());
            InkTools.get_default().notify["tool"].connect(() => {
                if (!InkTools.get_default().drawing || InkTools.get_default().tool != InkTool.LASSO) {
                    selection.clear();
                    queue_draw();
                }
                update_cursor();
            });
            update_cursor();
        }

        private void open_menu(double x, double y) {
            if (InkTools.get_default().ruler && on_ruler(x, y)) {
                Menus.popup(this, x, y, (m) => {
                    var tools = InkTools.get_default();
                    m.add_item(_("Rotate Left 15°"), "object-rotate-left-symbolic", () => tools.ruler_angle = tools.ruler_angle - 15);
                    m.add_item(_("Rotate Right 15°"), "object-rotate-right-symbolic", () => tools.ruler_angle = tools.ruler_angle + 15);
                    m.add_item(_("Straighten"), null, () => tools.ruler_angle = 0);
                    m.add_item(_("Hide Ruler"), null, () => tools.ruler = false);
                });
                return;
            }
            if (selection.size == 0) {
                foreach (var s in doc.strokes) if (s.hits(x, y, 6)) selection.add(s);
                queue_draw();
            }
            Menus.popup(this, x, y, (m) => build_menu(m));
        }

        private void update_cursor() {
            var t = InkTools.get_default().tool;
            set_cursor_from_name(t == InkTool.NONE ? null : t == InkTool.ERASER ? "cell" : t == InkTool.LASSO ? "crosshair" : "crosshair");
        }

        private void build_menu(Singularity.Widgets.ContextMenu m) {
            bool any = selection.size > 0;
            var targets = any ? (Gee.Collection<Stroke>) selection : (Gee.Collection<Stroke>) doc.strokes;
            m.add_item(_("Ink to Shape"), "notes-shape-symbolic", () => convert_shapes(targets));
            m.add_item(_("Ink to Text"), "insert-text-symbolic", () => {
                var list = new Gee.ArrayList<Stroke>();
                list.add_all(targets);
                convert_text_requested(list);
            });
            m.add_item(_("Ink to Math"), "applications-science-symbolic", () => {
                var list = new Gee.ArrayList<Stroke>();
                list.add_all(targets);
                convert_math_requested(list);
            });
            if (can_correct) m.add_item(_("Correct Recognized Text"), "document-edit-symbolic", () => correct_requested());
            if (any) {
                m.add_separator();
                var colors = m.add_submenu(_("Color"), "color-select-symbolic");
                foreach (string c in InkPalette.COLORS) {
                    string cc = c;
                    colors.add_item(InkPalette.name_of(c), null, () => {
                        foreach (var s in selection) if (s.tool != "highlighter") s.color = cc;
                        queue_draw();
                        changed();
                    });
                }
                m.add_item(_("Delete"), "edit-delete-symbolic", () => delete_selection());
            } else {
                m.add_separator();
                m.add_item(_("Clear Drawing"), "edit-clear-symbolic", () => {
                    doc.strokes.clear();
                    queue_draw();
                    changed();
                });
            }
        }

        public void convert_shapes(Gee.Collection<Stroke> targets) {
            int n = 0;
            foreach (var s in targets.to_array()) {
                var r = ShapeRecognizer.recognize(s);
                if (r == null) continue;
                int idx = doc.strokes.index_of(s);
                if (idx < 0) continue;
                doc.strokes[idx] = r;
                selection.remove(s);
                n++;
            }
            queue_draw();
            if (n > 0) changed();
            status(n > 0 ? ngettext("%d stroke turned into a shape", "%d strokes turned into shapes", n).printf(n) : _("No shapes were recognized"));
        }

        public void delete_selection() {
            foreach (var s in selection) doc.strokes.remove(s);
            selection.clear();
            queue_draw();
            changed();
        }

        public void remove_strokes(Gee.Collection<Stroke> list) {
            foreach (var s in list) doc.strokes.remove(s);
            selection.clear();
            queue_draw();
            changed();
        }

        private void ruler_axes(out double ux, out double uy, out double nx, out double ny) {
            double a = InkTools.get_default().ruler_angle * Math.PI / 180.0;
            ux = Math.cos(a);
            uy = Math.sin(a);
            nx = -uy;
            ny = ux;
        }

        private bool on_ruler(double x, double y) {
            double ux, uy, nx, ny;
            ruler_axes(out ux, out uy, out nx, out ny);
            double dx = x - ruler_x;
            double dy = y - ruler_y;
            double along = dx * ux + dy * uy;
            double across = dx * nx + dy * ny;
            return along.abs() <= RULER_LENGTH / 2 && across >= 0 && across <= RULER_WIDTH;
        }

        private bool near_edge(double x, double y) {
            double ux, uy, nx, ny;
            ruler_axes(out ux, out uy, out nx, out ny);
            double dx = x - ruler_x;
            double dy = y - ruler_y;
            double along = dx * ux + dy * uy;
            double across = dx * nx + dy * ny;
            return along.abs() <= RULER_LENGTH / 2 + 20 && across < 0 && across > -26;
        }

        private InkPoint snap(double x, double y, double pad) {
            double ux, uy, nx, ny;
            ruler_axes(out ux, out uy, out nx, out ny);
            double along = (x - ruler_x) * ux + (y - ruler_y) * uy;
            return new InkPoint(ruler_x + along * ux - nx * pad, ruler_y + along * uy - ny * pad);
        }

        private void on_begin(double x, double y) {
            var tools = InkTools.get_default();
            if (!tools.drawing) return;
            if (tools.tool == InkTool.LASSO) grab_focus();
            start_x = x;
            start_y = y;
            last_x = x;
            last_y = y;
            erased = false;
            moving_ruler = false;
            snapping = false;
            if (tools.ruler && on_ruler(x, y)) {
                moving_ruler = true;
                ruler_start_x = ruler_x;
                ruler_start_y = ruler_y;
                return;
            }
            if (tools.ruler && (tools.tool == InkTool.PEN || tools.tool == InkTool.HIGHLIGHTER) && near_edge(x, y)) snapping = true;
            switch (tools.tool) {
                case InkTool.PEN:
                case InkTool.HIGHLIGHTER:
                    current = new Stroke();
                    current.tool = tools.tool == InkTool.PEN ? "pen" : "highlighter";
                    current.color = tools.tool == InkTool.PEN ? tools.color : tools.highlighter_color;
                    current.width = tools.tool == InkTool.PEN ? tools.width : tools.highlighter_width;
                    current.opacity = tools.tool == InkTool.PEN ? 1 : 0.4;
                    current.points.add(new InkPoint(x, y));
                    break;
                case InkTool.ERASER:
                    erase_at(x, y);
                    break;
                case InkTool.LASSO:
                    moving = false;
                    if (selection.size > 0 && in_selection(x, y)) {
                        moving = true;
                    } else {
                        selection.clear();
                        lasso.clear();
                        lasso.add(new InkPoint(x, y));
                    }
                    break;
                default:
                    if (tools.tool.is_shape()) {
                        current = new Stroke();
                        current.tool = "pen";
                        current.shape = tools.tool.shape_id();
                        current.color = tools.color;
                        current.width = tools.width;
                        current.points.add(new InkPoint(x, y));
                        current.points.add(new InkPoint(x, y));
                    }
                    break;
            }
            queue_draw();
        }

        private bool in_selection(double x, double y) {
            double x0, y0, x1, y1;
            selection_bounds(out x0, out y0, out x1, out y1);
            return x >= x0 - 6 && x <= x1 + 6 && y >= y0 - 6 && y <= y1 + 6;
        }

        private void selection_bounds(out double x0, out double y0, out double x1, out double y1) {
            x0 = double.MAX;
            y0 = double.MAX;
            x1 = -double.MAX;
            y1 = -double.MAX;
            foreach (var s in selection) {
                double a, b, c, d;
                s.bounds(out a, out b, out c, out d);
                x0 = double.min(x0, a);
                y0 = double.min(y0, b);
                x1 = double.max(x1, c);
                y1 = double.max(y1, d);
            }
        }

        private void on_update(double dx, double dy) {
            var tools = InkTools.get_default();
            if (!tools.drawing) return;
            double x = start_x + dx;
            double y = start_y + dy;
            if (moving_ruler) {
                ruler_x = ruler_start_x + dx;
                ruler_y = ruler_start_y + dy;
                queue_draw();
                return;
            }
            if (current != null && snapping) {
                double pad = current.width / 2 + 1;
                var a = snap(start_x, start_y, pad);
                var b = snap(x, y, pad);
                current.points.clear();
                current.points.add(a);
                current.points.add(b);
                queue_draw();
                return;
            }
            if (current != null) {
                if (current.shape != "") {
                    current.points[1] = new InkPoint(x, y);
                } else {
                    var lp = current.points[current.points.size - 1];
                    if (Math.hypot(x - lp.x, y - lp.y) >= 1.2) current.points.add(new InkPoint(x, y));
                }
            } else if (tools.tool == InkTool.ERASER) {
                erase_at(x, y);
            } else if (tools.tool == InkTool.LASSO) {
                if (moving) {
                    foreach (var s in selection) s.translate(x - last_x, y - last_y);
                } else {
                    lasso.add(new InkPoint(x, y));
                }
            }
            last_x = x;
            last_y = y;
            if (grow) ensure_room(x, y);
            queue_draw();
        }

        private void ensure_room(double x, double y) {
            bool resized = false;
            if (y + 40 > doc.height) {
                doc.height = (int) y + 80;
                resized = true;
            }
            if (x + 40 > doc.width) {
                doc.width = (int) x + 80;
                resized = true;
            }
            if (resized) queue_resize();
        }

        private void on_end(double dx, double dy) {
            var tools = InkTools.get_default();
            if (moving_ruler) {
                moving_ruler = false;
                return;
            }
            if (current != null) {
                if (current.shape == "" || current.points[0].x != current.points[1].x || current.points[0].y != current.points[1].y) {
                    doc.strokes.add(current);
                    changed();
                }
                current = null;
            } else if (tools.tool == InkTool.LASSO) {
                if (moving) {
                    changed();
                } else {
                    foreach (var s in doc.strokes) if (inside_lasso(s)) selection.add(s);
                    lasso.clear();
                }
                moving = false;
            } else if (tools.tool == InkTool.ERASER && erased) {
                changed();
            }
            queue_draw();
        }

        private bool inside_lasso(Stroke s) {
            if (lasso.size < 3) return false;
            int inside = 0;
            foreach (var p in s.points) if (ShapeRecognizer.point_in_polygon(p.x, p.y, lasso)) inside++;
            return inside * 2 > s.points.size;
        }

        private void erase_at(double x, double y) {
            foreach (var s in doc.strokes.to_array()) {
                if (s.hits(x, y, 6)) {
                    doc.strokes.remove(s);
                    erased = true;
                }
            }
        }

        private void draw_ruler(Cairo.Context cr) {
            cr.save();
            cr.set_dash(null, 0);
            cr.translate(ruler_x, ruler_y);
            cr.rotate(InkTools.get_default().ruler_angle * Math.PI / 180.0);
            cr.rectangle(-RULER_LENGTH / 2, 0, RULER_LENGTH, RULER_WIDTH);
            cr.set_source_rgba(0.93, 0.93, 0.95, 0.85);
            cr.fill_preserve();
            cr.set_source_rgba(0.3, 0.3, 0.35, 0.8);
            cr.set_line_width(1);
            cr.stroke();
            for (int i = 0; i <= (int) (RULER_LENGTH / 10); i++) {
                double tx = -RULER_LENGTH / 2 + i * 10;
                double len = i % 10 == 0 ? 18 : (i % 5 == 0 ? 12 : 7);
                cr.move_to(tx + 0.5, 0);
                cr.line_to(tx + 0.5, len);
            }
            cr.stroke();
            cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
            cr.set_font_size(11);
            string label = "%.0f°".printf(((InkTools.get_default().ruler_angle % 360) + 360) % 360);
            cr.move_to(-12, RULER_WIDTH - 10);
            cr.show_text(label);
            cr.restore();
        }

        public override SizeRequestMode get_request_mode() {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum = orientation == Orientation.HORIZONTAL ? 0 : (grow ? doc.height : 0);
            natural = orientation == Orientation.HORIZONTAL ? doc.width : doc.height;
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        public override void snapshot(Snapshot snapshot) {
            var rect = Graphene.Rect().init(0, 0, get_width(), get_height());
            var cr = snapshot.append_cairo(rect);
            foreach (var s in doc.strokes) s.draw(cr);
            if (current != null) current.draw(cr);
            if (lasso.size > 1) {
                cr.set_source_rgba(0.21, 0.52, 0.89, 0.9);
                cr.set_line_width(1.2);
                double[] dash = { 5, 4 };
                cr.set_dash(dash, 0);
                cr.move_to(lasso[0].x, lasso[0].y);
                foreach (var p in lasso) cr.line_to(p.x, p.y);
                cr.close_path();
                cr.stroke();
            }
            if (InkTools.get_default().ruler) draw_ruler(cr);
            if (selection.size > 0) {
                double x0, y0, x1, y1;
                selection_bounds(out x0, out y0, out x1, out y1);
                cr.set_source_rgba(0.21, 0.52, 0.89, 0.9);
                cr.set_line_width(1.2);
                double[] dash = { 4, 3 };
                cr.set_dash(dash, 0);
                cr.rectangle(x0 - 4, y0 - 4, x1 - x0 + 8, y1 - y0 + 8);
                cr.stroke();
            }
        }
    }
}
