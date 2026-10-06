namespace Singularity.Apps.Notes {

    public enum InkTool {
        NONE,
        PEN,
        HIGHLIGHTER,
        ERASER,
        LASSO,
        LINE,
        ARROW,
        RECTANGLE,
        ELLIPSE,
        TRIANGLE;

        public bool is_shape() {
            return this == LINE || this == ARROW || this == RECTANGLE || this == ELLIPSE || this == TRIANGLE;
        }

        public string shape_id() {
            switch (this) {
                case LINE: return "line";
                case ARROW: return "arrow";
                case RECTANGLE: return "rect";
                case ELLIPSE: return "ellipse";
                case TRIANGLE: return "triangle";
                default: return "";
            }
        }
    }

    public class InkTools : Object {
        private static InkTools? instance = null;
        public InkTool tool { get; set; default = InkTool.NONE; }
        public string color { get; set; default = "#1c71d8"; }
        public double width { get; set; default = 3.0; }
        public string highlighter_color { get; set; default = "#f6d32d"; }
        public double highlighter_width { get; set; default = 16.0; }
        public bool ruler { get; set; default = false; }
        public double ruler_angle { get; set; default = 0; }

        public static InkTools get_default() {
            if (instance == null) instance = new InkTools();
            return instance;
        }

        public bool drawing {
            get { return tool != InkTool.NONE; }
        }
    }

    public class InkPoint {
        public double x;
        public double y;

        public InkPoint(double x, double y) {
            this.x = x;
            this.y = y;
        }
    }

    public class Stroke : Object {
        public string tool = "pen";
        public string shape = "";
        public string color = "#1c71d8";
        public double width = 3;
        public double opacity = 1;
        public Gee.ArrayList<InkPoint> points = new Gee.ArrayList<InkPoint>();

        public Stroke copy() {
            var s = new Stroke();
            s.tool = tool;
            s.shape = shape;
            s.color = color;
            s.width = width;
            s.opacity = opacity;
            foreach (var p in points) s.points.add(new InkPoint(p.x, p.y));
            return s;
        }

        public void bounds(out double x0, out double y0, out double x1, out double y1) {
            x0 = double.MAX;
            y0 = double.MAX;
            x1 = -double.MAX;
            y1 = -double.MAX;
            foreach (var p in points) {
                x0 = double.min(x0, p.x);
                y0 = double.min(y0, p.y);
                x1 = double.max(x1, p.x);
                y1 = double.max(y1, p.y);
            }
            double pad = width / 2;
            x0 -= pad;
            y0 -= pad;
            x1 += pad;
            y1 += pad;
        }

        public void translate(double dx, double dy) {
            foreach (var p in points) {
                p.x += dx;
                p.y += dy;
            }
        }

        public bool hits(double x, double y, double radius) {
            if (shape != "" && points.size >= 2) {
                var outline = shape_outline();
                for (int i = 0; i + 1 < outline.size; i++) {
                    if (segment_distance(x, y, outline[i], outline[i + 1]) <= radius + width / 2) return true;
                }
                return false;
            }
            if (points.size == 1) return Math.hypot(points[0].x - x, points[0].y - y) <= radius + width / 2;
            for (int i = 0; i + 1 < points.size; i++) {
                if (segment_distance(x, y, points[i], points[i + 1]) <= radius + width / 2) return true;
            }
            return false;
        }

        public static double segment_distance(double x, double y, InkPoint a, InkPoint b) {
            double dx = b.x - a.x;
            double dy = b.y - a.y;
            double len2 = dx * dx + dy * dy;
            if (len2 == 0) return Math.hypot(x - a.x, y - a.y);
            double t = ((x - a.x) * dx + (y - a.y) * dy) / len2;
            t = t.clamp(0, 1);
            return Math.hypot(x - (a.x + t * dx), y - (a.y + t * dy));
        }

        public Gee.ArrayList<InkPoint> shape_outline() {
            var list = new Gee.ArrayList<InkPoint>();
            if (points.size < 2) return list;
            var a = points[0];
            var b = points[points.size - 1];
            double x0 = double.min(a.x, b.x);
            double y0 = double.min(a.y, b.y);
            double x1 = double.max(a.x, b.x);
            double y1 = double.max(a.y, b.y);
            switch (shape) {
                case "rect":
                    list.add(new InkPoint(x0, y0));
                    list.add(new InkPoint(x1, y0));
                    list.add(new InkPoint(x1, y1));
                    list.add(new InkPoint(x0, y1));
                    list.add(new InkPoint(x0, y0));
                    break;
                case "triangle":
                    list.add(new InkPoint((x0 + x1) / 2, y0));
                    list.add(new InkPoint(x1, y1));
                    list.add(new InkPoint(x0, y1));
                    list.add(new InkPoint((x0 + x1) / 2, y0));
                    break;
                case "ellipse":
                    double cx = (x0 + x1) / 2;
                    double cy = (y0 + y1) / 2;
                    double rx = (x1 - x0) / 2;
                    double ry = (y1 - y0) / 2;
                    for (int i = 0; i <= 48; i++) {
                        double t = 2 * Math.PI * i / 48;
                        list.add(new InkPoint(cx + rx * Math.cos(t), cy + ry * Math.sin(t)));
                    }
                    break;
                case "arrow":
                    list.add(new InkPoint(a.x, a.y));
                    list.add(new InkPoint(b.x, b.y));
                    double ang = Math.atan2(b.y - a.y, b.x - a.x);
                    double head = double.max(10, width * 4);
                    list.add(new InkPoint(b.x - head * Math.cos(ang - 0.45), b.y - head * Math.sin(ang - 0.45)));
                    list.add(new InkPoint(b.x, b.y));
                    list.add(new InkPoint(b.x - head * Math.cos(ang + 0.45), b.y - head * Math.sin(ang + 0.45)));
                    break;
                default:
                    list.add(new InkPoint(a.x, a.y));
                    list.add(new InkPoint(b.x, b.y));
                    break;
            }
            return list;
        }

        public void draw(Cairo.Context cr) {
            var c = Gdk.RGBA();
            c.parse(color);
            cr.set_source_rgba(c.red, c.green, c.blue, opacity);
            cr.set_line_width(width);
            cr.set_line_cap(tool == "highlighter" ? Cairo.LineCap.SQUARE : Cairo.LineCap.ROUND);
            cr.set_line_join(Cairo.LineJoin.ROUND);
            if (shape != "") {
                var outline = shape_outline();
                if (outline.size == 0) return;
                cr.move_to(outline[0].x, outline[0].y);
                for (int i = 1; i < outline.size; i++) cr.line_to(outline[i].x, outline[i].y);
                cr.stroke();
                return;
            }
            if (points.size == 0) return;
            if (points.size == 1) {
                cr.arc(points[0].x, points[0].y, width / 2, 0, 2 * Math.PI);
                cr.fill();
                return;
            }
            cr.move_to(points[0].x, points[0].y);
            for (int i = 1; i < points.size - 1; i++) {
                double mx = (points[i].x + points[i + 1].x) / 2;
                double my = (points[i].y + points[i + 1].y) / 2;
                cr.curve_to(points[i].x, points[i].y, points[i].x, points[i].y, mx, my);
            }
            cr.line_to(points[points.size - 1].x, points[points.size - 1].y);
            cr.stroke();
        }

        public string svg_path() {
            var sb = new StringBuilder();
            var pts = shape != "" ? shape_outline() : points;
            for (int i = 0; i < pts.size; i++) {
                sb.append(i == 0 ? "M" : " L");
                sb.append(" %s %s".printf(num(pts[i].x), num(pts[i].y)));
            }
            if (pts.size == 1) sb.append(" L %s %s".printf(num(pts[0].x + 0.1), num(pts[0].y)));
            return sb.str;
        }

        public string svg_points() {
            var sb = new StringBuilder();
            foreach (var p in points) {
                if (sb.len > 0) sb.append(" ");
                sb.append("%s,%s".printf(num(p.x), num(p.y)));
            }
            return sb.str;
        }

        public static string num(double v) {
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            return (Math.round(v * 10) / 10).format(buf, "%.1f");
        }
    }

    public class InkDoc : Object {
        public Gee.ArrayList<Stroke> strokes = new Gee.ArrayList<Stroke>();
        public int width = 640;
        public int height = 240;

        public static InkDoc load(string path) {
            var doc = new InkDoc();
            string text;
            try {
                if (!FileUtils.get_contents(path, out text)) return doc;
            } catch (FileError e) {
                return doc;
            }
            return parse(text);
        }

        public static InkDoc parse(string text) {
            var doc = new InkDoc();
            try {
                MatchInfo info;
                var svg = new Regex("<svg[^>]*>");
                if (svg.match(text, 0, out info)) {
                    string head = info.fetch(0);
                    int w = int.parse(RichText.attr(head, "width"));
                    int h = int.parse(RichText.attr(head, "height"));
                    if (w > 0) doc.width = w;
                    if (h > 0) doc.height = h;
                }
                var re = new Regex("<path\\s([^>]*)/>");
                if (re.match(text, 0, out info)) {
                    do {
                        string attrs = info.fetch(1);
                        var s = new Stroke();
                        s.tool = RichText.attr(attrs, "data-tool");
                        if (s.tool == "") s.tool = "pen";
                        s.shape = RichText.attr(attrs, "data-shape");
                        s.color = RichText.attr(attrs, "stroke");
                        if (s.color == "") s.color = "#000000";
                        s.width = double.parse(RichText.attr(attrs, "stroke-width"));
                        if (s.width <= 0) s.width = 2;
                        string op = RichText.attr(attrs, "stroke-opacity");
                        s.opacity = op != "" ? double.parse(op) : 1;
                        string pts = RichText.attr(attrs, "data-points");
                        if (pts == "") pts = points_from_d(RichText.attr(attrs, "d"));
                        foreach (string pair in pts.split(" ")) {
                            string[] xy = pair.split(",");
                            if (xy.length != 2) continue;
                            s.points.add(new InkPoint(double.parse(xy[0]), double.parse(xy[1])));
                        }
                        if (s.points.size > 0) doc.strokes.add(s);
                    } while (info.next());
                }
            } catch (RegexError e) {
            }
            return doc;
        }

        private static string points_from_d(string d) {
            var sb = new StringBuilder();
            string[] parts = d.replace("M", " ").replace("L", " ").replace(",", " ").split(" ");
            var nums = new Gee.ArrayList<string>();
            foreach (string p in parts) if (p.strip() != "") nums.add(p.strip());
            for (int i = 0; i + 1 < nums.size; i += 2) {
                if (sb.len > 0) sb.append(" ");
                sb.append(nums[i] + "," + nums[i + 1]);
            }
            return sb.str;
        }

        public string to_svg() {
            var sb = new StringBuilder();
            sb.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" data-notes-ink=\"1\">\n".printf(width, height, width, height));
            foreach (var s in strokes) {
                sb.append("<path d=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"%s\"".printf(s.svg_path(), s.color, Stroke.num(s.width)));
                if (s.opacity < 1) sb.append(" stroke-opacity=\"%s\"".printf(Stroke.num(s.opacity)));
                sb.append(" stroke-linecap=\"%s\" stroke-linejoin=\"round\" data-tool=\"%s\"".printf(s.tool == "highlighter" ? "square" : "round", s.tool));
                if (s.shape != "") sb.append(" data-shape=\"%s\"".printf(s.shape));
                sb.append(" data-points=\"%s\"/>\n".printf(s.svg_points()));
            }
            sb.append("</svg>\n");
            return sb.str;
        }

        public void save(string path) throws Error {
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            string text = to_svg();
            FileUtils.set_contents_full(path, text, text.length, FileSetContentsFlags.CONSISTENT, 0600);
        }

        public void extent(out int w, out int h) {
            w = 0;
            h = 0;
            foreach (var s in strokes) {
                double x0, y0, x1, y1;
                s.bounds(out x0, out y0, out x1, out y1);
                w = int.max(w, (int) x1);
                h = int.max(h, (int) y1);
            }
        }

        public Cairo.ImageSurface render(Gee.Collection<Stroke>? only, double scale, out double ox, out double oy) {
            double x0 = double.MAX, y0 = double.MAX, x1 = -double.MAX, y1 = -double.MAX;
            var list = only != null ? only : strokes;
            foreach (var s in list) {
                double a, b, c, d;
                s.bounds(out a, out b, out c, out d);
                x0 = double.min(x0, a);
                y0 = double.min(y0, b);
                x1 = double.max(x1, c);
                y1 = double.max(y1, d);
            }
            if (x0 > x1) {
                x0 = 0;
                y0 = 0;
                x1 = 10;
                y1 = 10;
            }
            double pad = 16;
            ox = x0 - pad;
            oy = y0 - pad;
            int w = (int) ((x1 - x0 + 2 * pad) * scale);
            int h = (int) ((y1 - y0 + 2 * pad) * scale);
            var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, int.max(1, w), int.max(1, h));
            var cr = new Cairo.Context(surface);
            cr.set_source_rgb(1, 1, 1);
            cr.paint();
            cr.scale(scale, scale);
            cr.translate(-ox, -oy);
            foreach (var s in list) {
                if (s.tool == "highlighter") continue;
                var dark = s.copy();
                dark.color = "#000000";
                dark.opacity = 1;
                dark.width = double.max(2.5, s.width);
                dark.draw(cr);
            }
            return surface;
        }
    }

    public class ShapeRecognizer {
        public static Stroke? recognize(Stroke s) {
            if (s.shape != "" || s.tool != "pen" || s.points.size < 3) return null;
            var pts = s.points;
            double x0, y0, x1, y1;
            s.bounds(out x0, out y0, out x1, out y1);
            double diag = Math.hypot(x1 - x0, y1 - y0);
            if (diag < 12) return null;
            var first = pts[0];
            var last = pts[pts.size - 1];
            double chord = Math.hypot(last.x - first.x, last.y - first.y);
            double maxdev = 0;
            foreach (var p in pts) maxdev = double.max(maxdev, Stroke.segment_distance(p.x, p.y, first, last));
            var result = new Stroke();
            result.tool = "pen";
            result.color = s.color;
            result.width = s.width;
            result.opacity = s.opacity;
            if (maxdev < chord * 0.08) {
                result.shape = "line";
                result.points.add(new InkPoint(first.x, first.y));
                result.points.add(new InkPoint(last.x, last.y));
                return result;
            }
            if (chord > diag * 0.3) return null;
            var simple = simplify(pts, diag * 0.06);
            if (simple.size >= 2 && Math.hypot(simple[0].x - simple[simple.size - 1].x, simple[0].y - simple[simple.size - 1].y) < diag * 0.3) {
                simple.remove_at(simple.size - 1);
            }
            double ix0 = x0 + s.width / 2;
            double iy0 = y0 + s.width / 2;
            double ix1 = x1 - s.width / 2;
            double iy1 = y1 - s.width / 2;
            double rect_err = 0;
            double ell_err = 0;
            double cx = (ix0 + ix1) / 2;
            double cy = (iy0 + iy1) / 2;
            double rx = double.max(1, (ix1 - ix0) / 2);
            double ry = double.max(1, (iy1 - iy0) / 2);
            foreach (var p in pts) {
                double d = double.min(double.min((p.x - ix0).abs(), (p.x - ix1).abs()), double.min((p.y - iy0).abs(), (p.y - iy1).abs()));
                rect_err += d;
                double nx = (p.x - cx) / rx;
                double ny = (p.y - cy) / ry;
                double r = Math.sqrt(nx * nx + ny * ny);
                ell_err += (r - 1).abs() * double.min(rx, ry);
            }
            rect_err /= pts.size;
            ell_err /= pts.size;
            string shape;
            if (simple.size == 3) shape = "triangle";
            else if (rect_err < ell_err && simple.size <= 6) shape = "rect";
            else shape = "ellipse";
            result.shape = shape;
            result.points.add(new InkPoint(ix0, iy0));
            result.points.add(new InkPoint(ix1, iy1));
            return result;
        }

        public static bool point_in_polygon(double x, double y, Gee.List<InkPoint> poly) {
            bool c = false;
            for (int i = 0, j = poly.size - 1; i < poly.size; j = i++) {
                var pi = poly[i];
                var pj = poly[j];
                if (((pi.y > y) != (pj.y > y)) && (x < (pj.x - pi.x) * (y - pi.y) / (pj.y - pi.y) + pi.x)) c = !c;
            }
            return c;
        }

        public static Gee.ArrayList<InkPoint> simplify(Gee.List<InkPoint> pts, double eps) {
            var out_list = new Gee.ArrayList<InkPoint>();
            if (pts.size < 3) {
                out_list.add_all(pts);
                return out_list;
            }
            var keep = new bool[pts.size];
            keep[0] = true;
            keep[pts.size - 1] = true;
            dp(pts, 0, pts.size - 1, eps, keep);
            for (int i = 0; i < pts.size; i++) if (keep[i]) out_list.add(pts[i]);
            return out_list;
        }

        private static void dp(Gee.List<InkPoint> pts, int a, int b, double eps, bool[] keep) {
            double best = 0;
            int idx = -1;
            for (int i = a + 1; i < b; i++) {
                double d = Stroke.segment_distance(pts[i].x, pts[i].y, pts[a], pts[b]);
                if (d > best) {
                    best = d;
                    idx = i;
                }
            }
            if (idx >= 0 && best > eps) {
                keep[idx] = true;
                dp(pts, a, idx, eps, keep);
                dp(pts, idx, b, eps, keep);
            }
        }
    }

    public class InkPalette {
        public const string[] COLORS = { "#000000", "#1c71d8", "#e01b24", "#2ec27e", "#ff7800", "#9141ac", "#f6d32d", "#ffffff" };

        public static string name_of(string c) {
            switch (c) {
                case "#000000": return _("Black");
                case "#1c71d8": return _("Blue");
                case "#e01b24": return _("Red");
                case "#2ec27e": return _("Green");
                case "#ff7800": return _("Orange");
                case "#9141ac": return _("Purple");
                case "#f6d32d": return _("Yellow");
                case "#ffffff": return _("White");
                default: return c;
            }
        }
    }
}
