namespace Singularity.Apps.Notes {

    public errordomain MathError {
        SYNTAX,
        DOMAIN
    }

    public abstract class MathNode : Object {
        public abstract double eval(double x) throws MathError;
        public abstract bool uses_x();
    }

    public class NumNode : MathNode {
        public double value;
        public NumNode(double v) {
            value = v;
        }
        public override double eval(double x) {
            return value;
        }
        public override bool uses_x() {
            return false;
        }
    }

    public class VarNode : MathNode {
        public override double eval(double x) {
            return x;
        }
        public override bool uses_x() {
            return true;
        }
    }

    public class BinNode : MathNode {
        public char op;
        public MathNode a;
        public MathNode b;
        public BinNode(char op, MathNode a, MathNode b) {
            this.op = op;
            this.a = a;
            this.b = b;
        }
        public override double eval(double x) throws MathError {
            double l = a.eval(x);
            double r = b.eval(x);
            switch (op) {
                case '+': return l + r;
                case '-': return l - r;
                case '*': return l * r;
                case '/':
                    if (r == 0) throw new MathError.DOMAIN(_("Division by zero"));
                    return l / r;
                case '^': return Math.pow(l, r);
                default: throw new MathError.SYNTAX("op");
            }
        }
        public override bool uses_x() {
            return a.uses_x() || b.uses_x();
        }
    }

    public class NegNode : MathNode {
        public MathNode a;
        public NegNode(MathNode a) {
            this.a = a;
        }
        public override double eval(double x) throws MathError {
            return -a.eval(x);
        }
        public override bool uses_x() {
            return a.uses_x();
        }
    }

    public class FuncNode : MathNode {
        public string name;
        public MathNode arg;
        public FuncNode(string name, MathNode arg) {
            this.name = name;
            this.arg = arg;
        }
        public override double eval(double x) throws MathError {
            double v = arg.eval(x);
            switch (name) {
                case "sin": return Math.sin(v);
                case "cos": return Math.cos(v);
                case "tan": return Math.tan(v);
                case "asin":
                case "arcsin": return Math.asin(v);
                case "acos":
                case "arccos": return Math.acos(v);
                case "atan":
                case "arctan": return Math.atan(v);
                case "sqrt":
                    if (v < 0) throw new MathError.DOMAIN(_("Square root of a negative number"));
                    return Math.sqrt(v);
                case "ln":
                    if (v <= 0) throw new MathError.DOMAIN(_("Logarithm of a non-positive number"));
                    return Math.log(v);
                case "log":
                    if (v <= 0) throw new MathError.DOMAIN(_("Logarithm of a non-positive number"));
                    return Math.log10(v);
                case "exp": return Math.exp(v);
                case "abs": return v.abs();
                default: throw new MathError.SYNTAX(_("Unknown function %s").printf(name));
            }
        }
        public override bool uses_x() {
            return arg.uses_x();
        }
    }

    public class MathParser {
        private string s;
        private int i;

        public static MathNode parse(string text) throws MathError {
            var p = new MathParser();
            p.s = normalize(text);
            p.i = 0;
            var n = p.parse_sum();
            p.skip();
            if (p.i < p.s.length) throw new MathError.SYNTAX(_("Unexpected “%s”").printf(p.s.substring(p.i, 1)));
            return n;
        }

        public static string normalize(string text) {
            string t = text.strip();
            t = t.replace("\\left", "").replace("\\right", "").replace("\\cdot", "*").replace("\\times", "*").replace("\\div", "/");
            t = t.replace("\\pi", "pi").replace("π", "pi").replace("×", "*").replace("÷", "/").replace("−", "-").replace("²", "^2").replace("³", "^3");
            try {
                var frac = new Regex("\\\\frac\\{([^{}]*)\\}\\{([^{}]*)\\}");
                for (int k = 0; k < 6; k++) t = frac.replace(t, -1, 0, "((\\1)/(\\2))");
                t = new Regex("\\\\sqrt\\{([^{}]*)\\}").replace(t, -1, 0, "sqrt(\\1)");
                t = new Regex("\\\\(sin|cos|tan|ln|log|exp)").replace(t, -1, 0, "\\1");
            } catch (RegexError e) {
            }
            t = t.replace("{", "(").replace("}", ")").replace("\\", "");
            return t;
        }

        private void skip() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\t')) i++;
        }

        private MathNode parse_sum() throws MathError {
            var left = parse_product();
            while (true) {
                skip();
                if (i < s.length && (s[i] == '+' || s[i] == '-')) {
                    char op = s[i++];
                    left = new BinNode(op, left, parse_product());
                } else {
                    return left;
                }
            }
        }

        private MathNode parse_product() throws MathError {
            var left = parse_unary();
            while (true) {
                skip();
                if (i < s.length && (s[i] == '*' || s[i] == '/')) {
                    char op = s[i++];
                    left = new BinNode(op, left, parse_unary());
                } else if (i < s.length && (s[i].isalpha() || s[i] == '(' || s[i].isdigit() || s[i] == '.')) {
                    left = new BinNode('*', left, parse_power());
                } else {
                    return left;
                }
            }
        }

        private MathNode parse_unary() throws MathError {
            skip();
            if (i < s.length && s[i] == '-') {
                i++;
                return new NegNode(parse_unary());
            }
            if (i < s.length && s[i] == '+') {
                i++;
                return parse_unary();
            }
            return parse_power();
        }

        private MathNode parse_power() throws MathError {
            var b = parse_atom();
            skip();
            if (i < s.length && s[i] == '^') {
                i++;
                return new BinNode('^', b, parse_unary());
            }
            return b;
        }

        private MathNode parse_atom() throws MathError {
            skip();
            if (i >= s.length) throw new MathError.SYNTAX(_("The expression ends too early"));
            char c = s[i];
            if (c == '(') {
                i++;
                var n = parse_sum();
                skip();
                if (i >= s.length || s[i] != ')') throw new MathError.SYNTAX(_("A closing parenthesis is missing"));
                i++;
                return n;
            }
            if (c.isdigit() || c == '.') {
                int start = i;
                while (i < s.length && (s[i].isdigit() || s[i] == '.' || s[i] == ',')) i++;
                if (i < s.length && (s[i] == 'e' || s[i] == 'E') && i + 1 < s.length && (s[i + 1].isdigit() || s[i + 1] == '-')) {
                    i++;
                    if (s[i] == '-') i++;
                    while (i < s.length && s[i].isdigit()) i++;
                }
                return new NumNode(double.parse(s.substring(start, i - start).replace(",", ".")));
            }
            if (c.isalpha()) {
                int start = i;
                while (i < s.length && s[i].isalpha()) i++;
                string name = s.substring(start, i - start).down();
                if (name == "x") return new VarNode();
                if (name == "pi") return new NumNode(Math.PI);
                if (name == "e") return new NumNode(Math.E);
                string[] funcs = { "sin", "cos", "tan", "asin", "acos", "atan", "arcsin", "arccos", "arctan", "sqrt", "ln", "log", "exp", "abs" };
                if (name in funcs) {
                    skip();
                    MathNode arg;
                    if (i < s.length && s[i] == '(') arg = parse_atom();
                    else arg = parse_power();
                    return new FuncNode(name, arg);
                }
                if (name.has_prefix("x")) {
                    i = start + 1;
                    return new VarNode();
                }
                throw new MathError.SYNTAX(_("Unknown name “%s”").printf(name));
            }
            throw new MathError.SYNTAX(_("Unexpected “%s”").printf(c.to_string()));
        }
    }

    public class MathSolution : Object {
        public Gee.ArrayList<string> steps = new Gee.ArrayList<string>();
        public string answer = "";
        public MathNode? function = null;
        public Gee.ArrayList<double?> roots = new Gee.ArrayList<double?>();
    }

    public class MathSolver {
        public static string fmt(double v) {
            if (v.is_nan()) return _("undefined");
            if (v.is_infinity() != 0) return v > 0 ? "∞" : "-∞";
            double r = Math.round(v);
            if ((v - r).abs() < 1e-9) return "%.0f".printf(r);
            string out_s = "%.6g".printf(v);
            return out_s;
        }

        public static MathSolution solve(string input) throws MathError {
            var sol = new MathSolution();
            string text = MathParser.normalize(input);
            int eq = text.index_of("=");
            if (eq < 0) {
                var node = MathParser.parse(text);
                if (!node.uses_x()) {
                    double v = node.eval(0);
                    sol.steps.add(_("Evaluate: %s").printf(text));
                    sol.answer = "%s = %s".printf(text, fmt(v));
                    sol.steps.add(sol.answer);
                    return sol;
                }
                sol.function = node;
                sol.steps.add(_("Function: y = %s").printf(text));
                var d = describe_polynomial(node);
                if (d != null) sol.steps.add(d);
                find_roots(node, sol);
                if (sol.roots.size > 0) {
                    string[] parts = {};
                    foreach (var r in sol.roots) parts += "x = " + fmt(r);
                    sol.steps.add(_("Zeros: %s").printf(string.joinv(", ", parts)));
                }
                try {
                    sol.steps.add(_("Value at x = 0: y = %s").printf(fmt(node.eval(0))));
                } catch (MathError e) {
                }
                sol.answer = _("Graph of y = %s").printf(text);
                return sol;
            }
            string lhs = text.substring(0, eq);
            string rhs = text.substring(eq + 1);
            var l = MathParser.parse(lhs);
            var r = MathParser.parse(rhs);
            var f = new BinNode('-', l, r);
            sol.function = f;
            sol.steps.add(_("Equation: %s = %s").printf(lhs.strip(), rhs.strip()));
            if (!f.uses_x()) {
                double v = f.eval(0);
                sol.answer = v.abs() < 1e-9 ? _("The equation is always true") : _("The equation is never true");
                sol.steps.add(sol.answer);
                return sol;
            }
            sol.steps.add(_("Move everything to one side: %s - (%s) = 0").printf(lhs.strip(), rhs.strip()));
            double[] coef;
            int degree = polynomial(f, out coef);
            if (degree == 1) {
                double a = coef[1];
                double b = coef[0];
                sol.steps.add(_("Linear form: %s = 0").printf(poly(coef, 1)));
                sol.steps.add(_("Subtract %s from both sides: %sx = %s").printf(fmt(b), fmt(a), fmt(-b)));
                sol.steps.add(_("Divide both sides by %s").printf(fmt(a)));
                double x = -b / a;
                sol.roots.add(x);
                sol.answer = "x = " + fmt(x);
                sol.steps.add(sol.answer);
                return sol;
            }
            if (degree == 2) {
                double a = coef[2];
                double b = coef[1];
                double c = coef[0];
                sol.steps.add(_("Quadratic form: %s = 0").printf(poly(coef, 2)));
                double disc = b * b - 4 * a * c;
                sol.steps.add(_("Discriminant: Δ = b² - 4ac = %s").printf(fmt(disc)));
                if (disc < -1e-12) {
                    double re = -b / (2 * a);
                    double im = Math.sqrt(-disc) / (2 * a).abs();
                    sol.answer = "x = %s ± %si".printf(fmt(re), fmt(im));
                    sol.steps.add(_("Δ < 0: no real solutions"));
                    sol.steps.add(sol.answer);
                    return sol;
                }
                double sq = Math.sqrt(double.max(0, disc));
                sol.steps.add(_("x = (-b ± √Δ) / 2a"));
                double x1 = (-b - sq) / (2 * a);
                double x2 = (-b + sq) / (2 * a);
                sol.roots.add(x1);
                if (disc.abs() > 1e-12) sol.roots.add(x2);
                sol.answer = disc.abs() <= 1e-12 ? "x = " + fmt(x1) : "x₁ = %s, x₂ = %s".printf(fmt(x1), fmt(x2));
                sol.steps.add(sol.answer);
                return sol;
            }
            sol.steps.add(_("Search the solutions numerically"));
            find_roots(f, sol);
            if (sol.roots.size == 0) {
                sol.answer = _("No real solution found between -100 and 100");
            } else {
                string[] parts = {};
                foreach (var x in sol.roots) parts += "x ≈ " + fmt(x);
                sol.answer = string.joinv(", ", parts);
            }
            sol.steps.add(sol.answer);
            return sol;
        }

        public static string poly(double[] c, int degree) {
            var sb = new StringBuilder();
            for (int k = degree; k >= 0; k--) {
                double v = c[k];
                if (v == 0 && !(k == 0 && sb.len == 0)) continue;
                string mag = fmt(v.abs());
                if (k > 0 && mag == "1") mag = "";
                string term = mag + (k == 1 ? "x" : k == 2 ? "x²" : k == 3 ? "x³" : "");
                if (sb.len == 0) sb.append(v < 0 ? "-" + term : term);
                else sb.append((v < 0 ? " - " : " + ") + term);
            }
            return sb.len > 0 ? sb.str : "0";
        }

        private static string? describe_polynomial(MathNode n) {
            double[] c;
            int d = polynomial(n, out c);
            if (d == 1) return _("Straight line with slope %s and intercept %s").printf(fmt(c[1]), fmt(c[0]));
            if (d == 2) {
                double vx = -c[1] / (2 * c[2]);
                double vy = c[2] * vx * vx + c[1] * vx + c[0];
                return _("Parabola with vertex at (%s, %s)").printf(fmt(vx), fmt(vy));
            }
            return null;
        }

        public static int polynomial(MathNode f, out double[] coef) {
            coef = new double[4];
            try {
                double[] xs = { -2, -1, 0, 1, 2, 3 };
                double[] ys = new double[6];
                for (int k = 0; k < 6; k++) ys[k] = f.eval(xs[k]);
                for (int deg = 0; deg <= 3; deg++) {
                    var c = fit(xs, ys, deg);
                    bool ok = true;
                    double[] probe = { -3.5, 0.5, 4.25, 7 };
                    foreach (double px in probe) {
                        double expect = 0;
                        for (int k = deg; k >= 0; k--) expect = expect * px + c[k];
                        double got = f.eval(px);
                        if ((got - expect).abs() > 1e-7 * double.max(1, got.abs())) ok = false;
                    }
                    if (ok) {
                        for (int k = 0; k <= deg; k++) coef[k] = c[k].abs() < 1e-10 ? 0 : c[k];
                        int real = deg;
                        while (real > 0 && coef[real] == 0) real--;
                        return real;
                    }
                }
            } catch (MathError e) {
            }
            return -1;
        }

        private static double[] fit(double[] xs, double[] ys, int deg) {
            int n = deg + 1;
            var m = new double[n * (n + 1)];
            for (int r = 0; r < n; r++) {
                for (int c = 0; c < n; c++) m[r * (n + 1) + c] = Math.pow(xs[r], c);
                m[r * (n + 1) + n] = ys[r];
            }
            for (int col = 0; col < n; col++) {
                int piv = col;
                for (int r = col + 1; r < n; r++) if (m[r * (n + 1) + col].abs() > m[piv * (n + 1) + col].abs()) piv = r;
                for (int c = 0; c <= n; c++) {
                    double t = m[col * (n + 1) + c];
                    m[col * (n + 1) + c] = m[piv * (n + 1) + c];
                    m[piv * (n + 1) + c] = t;
                }
                double d = m[col * (n + 1) + col];
                if (d == 0) continue;
                for (int c = 0; c <= n; c++) m[col * (n + 1) + c] /= d;
                for (int r = 0; r < n; r++) {
                    if (r == col) continue;
                    double f = m[r * (n + 1) + col];
                    for (int c = 0; c <= n; c++) m[r * (n + 1) + c] -= f * m[col * (n + 1) + c];
                }
            }
            var out_c = new double[n];
            for (int r = 0; r < n; r++) out_c[r] = m[r * (n + 1) + n];
            return out_c;
        }

        private static double safe(MathNode f, double x) {
            try {
                return f.eval(x);
            } catch (MathError e) {
                return double.NAN;
            }
        }

        public static void find_roots(MathNode f, MathSolution sol) {
            double[,] ranges = { { -10, 10 }, { 10, 100 }, { -100, -10 } };
            for (int k = 0; k < 3 && sol.roots.size < 12; k++) scan(f, sol, ranges[k, 0], ranges[k, 1]);
            sol.roots.sort((a, b) => a < b ? -1 : (a > b ? 1 : 0));
        }

        private static void scan(MathNode f, MathSolution sol, double from, double to) {
            double step = 0.01;
            double prev_x = from;
            double prev = safe(f, prev_x);
            for (double x = from + step; x <= to + 1e-9; x += step) {
                double v = safe(f, x);
                if (!prev.is_nan() && !v.is_nan()) {
                    if (v == 0) add_root(sol, x);
                    else if ((prev < 0) != (v < 0) && (v - prev).abs() < 1e3) {
                        double a = prev_x, b = x, fa = prev;
                        for (int k = 0; k < 80; k++) {
                            double mid = (a + b) / 2;
                            double fm = safe(f, mid);
                            if ((fa < 0) == (fm < 0)) {
                                a = mid;
                                fa = fm;
                            } else {
                                b = mid;
                            }
                        }
                        add_root(sol, (a + b) / 2);
                    }
                }
                prev = v;
                prev_x = x;
                if (sol.roots.size >= 12) return;
            }
        }

        private static void add_root(MathSolution sol, double x) {
            double r = Math.round(x * 1e9) / 1e9;
            foreach (var e in sol.roots) if ((e - r).abs() < 1e-6) return;
            sol.roots.add(r);
        }

        public static Cairo.ImageSurface plot(MathNode f, Gee.List<double?> roots, int w, int h) {
            double xmin = -10, xmax = 10;
            if (roots.size > 0) {
                double lo = double.MAX, hi = -double.MAX;
                foreach (var r in roots) {
                    lo = double.min(lo, r);
                    hi = double.max(hi, r);
                }
                double span = double.max(4, hi - lo);
                xmin = lo - span * 0.6;
                xmax = hi + span * 0.6;
            }
            double ymin = double.MAX, ymax = -double.MAX;
            for (int k = 0; k <= 400; k++) {
                double x = xmin + (xmax - xmin) * k / 400;
                double y = safe(f, x);
                if (y.is_nan() || y.is_infinity() != 0 || y.abs() > 1e6) continue;
                ymin = double.min(ymin, y);
                ymax = double.max(ymax, y);
            }
            if (ymin > ymax) {
                ymin = -10;
                ymax = 10;
            }
            if (ymax - ymin < 1e-6) {
                ymin -= 1;
                ymax += 1;
            }
            double pad = (ymax - ymin) * 0.1;
            ymin -= pad;
            ymax += pad;
            var s = new Cairo.ImageSurface(Cairo.Format.RGB24, w, h);
            var cr = new Cairo.Context(s);
            cr.set_source_rgb(1, 1, 1);
            cr.paint();
            double sx = w / (xmax - xmin);
            double sy = h / (ymax - ymin);
            cr.set_line_width(1);
            cr.set_source_rgb(0.9, 0.9, 0.92);
            double gstep = nice_step(xmax - xmin);
            for (double gx = Math.ceil(xmin / gstep) * gstep; gx <= xmax; gx += gstep) {
                cr.move_to((gx - xmin) * sx + 0.5, 0);
                cr.line_to((gx - xmin) * sx + 0.5, h);
            }
            double ystep = nice_step(ymax - ymin);
            for (double gy = Math.ceil(ymin / ystep) * ystep; gy <= ymax; gy += ystep) {
                cr.move_to(0, h - (gy - ymin) * sy + 0.5);
                cr.line_to(w, h - (gy - ymin) * sy + 0.5);
            }
            cr.stroke();
            cr.set_source_rgb(0.35, 0.35, 0.4);
            cr.set_line_width(1.4);
            if (xmin < 0 && xmax > 0) {
                cr.move_to(-xmin * sx, 0);
                cr.line_to(-xmin * sx, h);
            }
            if (ymin < 0 && ymax > 0) {
                cr.move_to(0, h + ymin * sy);
                cr.line_to(w, h + ymin * sy);
            }
            cr.stroke();
            cr.set_font_size(11);
            for (double gx = Math.ceil(xmin / gstep) * gstep; gx <= xmax; gx += gstep) {
                if (gx.abs() < gstep / 2) continue;
                cr.move_to((gx - xmin) * sx + 2, double.min(h - 4, double.max(12, h + ymin * sy - 3)));
                cr.show_text(fmt(gx));
            }
            for (double gy = Math.ceil(ymin / ystep) * ystep; gy <= ymax; gy += ystep) {
                if (gy.abs() < ystep / 2) continue;
                cr.move_to(double.min(w - 30, double.max(2, -xmin * sx + 3)), h - (gy - ymin) * sy - 2);
                cr.show_text(fmt(gy));
            }
            cr.set_source_rgb(0.11, 0.44, 0.85);
            cr.set_line_width(2.4);
            bool pen = false;
            for (int k = 0; k <= w; k++) {
                double x = xmin + k / sx;
                double y = safe(f, x);
                if (y.is_nan() || y.is_infinity() != 0 || y > ymax + (ymax - ymin) * 4 || y < ymin - (ymax - ymin) * 4) {
                    pen = false;
                    continue;
                }
                double py = h - (y - ymin) * sy;
                if (!pen) cr.move_to(k, py);
                else cr.line_to(k, py);
                pen = true;
            }
            cr.stroke();
            cr.set_source_rgb(0.88, 0.11, 0.14);
            foreach (var r in roots) {
                cr.arc((r - xmin) * sx, h + ymin * sy, 4, 0, 2 * Math.PI);
                cr.fill();
            }
            return s;
        }

        private static double nice_step(double span) {
            double raw = span / 8;
            double mag = Math.pow(10, Math.floor(Math.log10(raw)));
            double n = raw / mag;
            double step = n < 1.5 ? 1 : n < 3.5 ? 2 : n < 7.5 ? 5 : 10;
            return step * mag;
        }
    }
}
