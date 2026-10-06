namespace Singularity.Apps.Notes {

    public class HwConv {
        public int cin;
        public int cout;
        public float[] w;
        public float[] b;
    }

    public class HwLstm {
        public int input;
        public int hidden;
        public float[] wih;
        public float[] whh;
        public float[] bias;
    }

    public class HwNet : Object {
        public const int H = 40;
        public const int PAD = 3;
        public const int WMAX = 480;
        public const int SS = 4;
        public const double LW = 2.2;
        public const string MAGIC = "SHWN1";

        public string chars { get; private set; default = ""; }
        public string source { get; private set; default = ""; }
        public string license { get; private set; default = ""; }
        private unichar[] alphabet = {};
        private HwConv[] convs = {};
        private float[] proj_w;
        private float[] proj_b;
        private int proj_in;
        private int proj_out;
        private HwLstm[] lstm = {};
        private float[] out_w;
        private float[] out_b;
        private int classes;

        public int class_count {
            get { return classes; }
        }

        public static string? find_model() {
            string? env = Environment.get_variable("NOTES_HANDWRITING_MODEL");
            if (env != null && FileUtils.test(env, FileTest.IS_REGULAR)) return env;
            var dirs = new Gee.ArrayList<string>();
            dirs.add(Environment.get_user_data_dir());
            foreach (string d in Environment.get_system_data_dirs()) dirs.add(d);
            foreach (string d in dirs) {
                string path = Path.build_filename(d, "singularity-notes", "handwriting", "words.shwn");
                if (FileUtils.test(path, FileTest.IS_REGULAR)) return path;
            }
            return null;
        }

        private static float half(uint16 h) {
            uint32 sign = ((uint32) h & 0x8000) << 16;
            uint32 exp = ((uint32) h >> 10) & 0x1f;
            uint32 mant = (uint32) h & 0x3ff;
            uint32 bits;
            if (exp == 0) {
                if (mant == 0) {
                    bits = sign;
                } else {
                    int e = -1;
                    do {
                        e++;
                        mant <<= 1;
                    } while ((mant & 0x400) == 0);
                    bits = sign | ((uint32) (127 - 15 - e) << 23) | ((mant & 0x3ff) << 13);
                }
            } else if (exp == 31) {
                bits = sign | 0x7f800000 | (mant << 13);
            } else {
                bits = sign | ((exp + 112) << 23) | (mant << 13);
            }
            float f = 0;
            Memory.copy(&f, &bits, 4);
            return f;
        }

        private class Reader {
            public uint8[] data;
            public size_t pos = 0;

            public Reader(owned uint8[] data) {
                this.data = (owned) data;
            }

            public uint32 u32() throws Error {
                if (pos + 4 > data.length) throw new IOError.INVALID_DATA("truncated model");
                uint32 v = data[pos] | ((uint32) data[pos + 1] << 8) | ((uint32) data[pos + 2] << 16) | ((uint32) data[pos + 3] << 24);
                pos += 4;
                return v;
            }

            public string str() throws Error {
                uint32 n = u32();
                if (pos + n > data.length) throw new IOError.INVALID_DATA("truncated model");
                var sb = new StringBuilder.sized(n);
                for (uint32 i = 0; i < n; i++) sb.append_c((char) data[pos + i]);
                pos += n;
                return sb.str;
            }

            public float[] tensor(int expect) throws Error {
                uint32 n = u32();
                if (n != expect || pos + n * 2 > data.length) throw new IOError.INVALID_DATA("bad tensor size");
                var t = new float[n];
                for (uint32 i = 0; i < n; i++) {
                    t[i] = half((uint16) (data[pos] | (data[pos + 1] << 8)));
                    pos += 2;
                }
                return t;
            }
        }

        public static HwNet? load(string path) {
            uint8[] data;
            try {
                FileUtils.get_data(path, out data);
                if (data.length < 8 || Memory.cmp(data, MAGIC.data, MAGIC.length) != 0) return null;
                var rd = new Reader((owned) data);
                rd.pos = MAGIC.length;
                var net = new HwNet();
                net.source = rd.str();
                net.license = rd.str();
                net.chars = rd.str();
                unichar[] al = {};
                int i = 0;
                unichar c;
                while (net.chars.get_next_char(ref i, out c)) al += c;
                net.alphabet = al;
                net.classes = al.length + 1;
                int nconv = (int) rd.u32();
                HwConv[] convs = {};
                for (int k = 0; k < nconv; k++) {
                    var cv = new HwConv();
                    cv.cin = (int) rd.u32();
                    cv.cout = (int) rd.u32();
                    cv.w = rd.tensor(cv.cin * cv.cout * 9);
                    cv.b = rd.tensor(cv.cout);
                    convs += cv;
                }
                net.convs = convs;
                net.proj_in = (int) rd.u32();
                net.proj_out = (int) rd.u32();
                net.proj_w = rd.tensor(net.proj_in * net.proj_out);
                net.proj_b = rd.tensor(net.proj_out);
                int nl = (int) rd.u32();
                HwLstm[] ls = {};
                for (int k = 0; k < nl; k++) {
                    var l = new HwLstm();
                    l.input = (int) rd.u32();
                    l.hidden = (int) rd.u32();
                    l.wih = rd.tensor(4 * l.hidden * l.input);
                    l.whh = rd.tensor(4 * l.hidden * l.hidden);
                    l.bias = rd.tensor(4 * l.hidden);
                    ls += l;
                }
                net.lstm = ls;
                int oin = (int) rd.u32();
                int oout = (int) rd.u32();
                if (oout != net.classes) return null;
                net.out_w = rd.tensor(oin * oout);
                net.out_b = rd.tensor(oout);
                return net;
            } catch (Error e) {
                warning("handwriting model %s: %s", path, e.message);
                return null;
            }
        }

        public static float[]? render(Gee.List<Stroke> strokes, out int width) {
            double left, scale;
            return render_scaled(strokes, out width, out left, out scale);
        }

        public static float[]? render_scaled(Gee.List<Stroke> strokes, out int width, out double left, out double scale) {
            width = 0;
            left = 0;
            scale = 1;
            double x0 = double.MAX, y0 = double.MAX, x1 = -double.MAX, y1 = -double.MAX;
            int count = 0;
            foreach (var s in strokes) foreach (var p in s.points) {
                x0 = double.min(x0, p.x);
                y0 = double.min(y0, p.y);
                x1 = double.max(x1, p.x);
                y1 = double.max(y1, p.y);
                count++;
            }
            if (count == 0) return null;
            double w = x1 - x0;
            double h = y1 - y0;
            double inner = H - 2 * PAD;
            double sc = inner / double.max(h, 1e-6);
            if (w * sc > WMAX - 2 * PAD) sc = (WMAX - 2 * PAD) / double.max(w, 1e-6);
            int wd = (int) Math.ceil(w * sc) + 2 * PAD;
            wd = int.max(wd, H / 2);
            double oy = PAD + (inner - h * sc) / 2;
            left = x0;
            scale = sc;
            int gh = H * SS;
            int gw = wd * SS;
            var grid = new uint8[gh * gw];
            double r = Math.round(LW * SS / 2 * 4) / 4.0;
            int ri = (int) Math.ceil(r);
            int[] dxs = {};
            int[] dys = {};
            for (int yy = -ri; yy <= ri; yy++) for (int xx = -ri; xx <= ri; xx++) if (xx * xx + yy * yy <= r * r) {
                dxs += xx;
                dys += yy;
            }
            double step = 0.5 * SS;
            foreach (var s in strokes) {
                double px = 0, py = 0;
                for (int k = 0; k < s.points.size; k++) {
                    double qx = ((s.points[k].x - x0) * sc + PAD) * SS;
                    double qy = ((s.points[k].y - y0) * sc + oy) * SS;
                    if (k == 0) {
                        stamp(grid, gw, gh, qx, qy, dxs, dys);
                    } else {
                        double len = Math.hypot(qx - px, qy - py);
                        int n = int.max(1, (int) Math.ceil(len / step));
                        for (int j = 1; j <= n; j++) {
                            double t = (double) j / n;
                            stamp(grid, gw, gh, px + (qx - px) * t, py + (qy - py) * t, dxs, dys);
                        }
                    }
                    px = qx;
                    py = qy;
                }
            }
            var img = new float[H * wd];
            for (int y = 0; y < H; y++) {
                for (int x = 0; x < wd; x++) {
                    int sum = 0;
                    for (int a = 0; a < SS; a++) for (int b = 0; b < SS; b++) sum += grid[(y * SS + a) * gw + x * SS + b];
                    img[y * wd + x] = sum / (float) (SS * SS);
                }
            }
            width = wd;
            return img;
        }

        private static void stamp(uint8[] grid, int gw, int gh, double x, double y, int[] dxs, int[] dys) {
            int cx = (int) Math.floor(x);
            int cy = (int) Math.floor(y);
            for (int i = 0; i < dxs.length; i++) {
                int X = cx + dxs[i];
                int Y = cy + dys[i];
                if (X >= 0 && X < gw && Y >= 0 && Y < gh) grid[Y * gw + X] = 1;
            }
        }

        private static void conv_part(float[] input, int cin, int h, int w, HwConv cv, float[] dst, int o0, int o1) {
            int plane = h * w;
            for (int o = o0; o < o1; o++) {
                int ob = o * plane;
                float bias = cv.b[o];
                for (int i = 0; i < plane; i++) dst[ob + i] = bias;
                for (int ci = 0; ci < cin; ci++) {
                    int ib = ci * plane;
                    int wb = (o * cin + ci) * 9;
                    for (int ky = 0; ky < 3; ky++) {
                        for (int kx = 0; kx < 3; kx++) {
                            float k = cv.w[wb + ky * 3 + kx];
                            if (k == 0) continue;
                            int dy = ky - 1;
                            int dx = kx - 1;
                            int ys = int.max(0, -dy), ye = int.min(h, h - dy);
                            int xs = int.max(0, -dx), xe = int.min(w, w - dx);
                            for (int y = ys; y < ye; y++) {
                                int orow = ob + y * w;
                                int irow = ib + (y + dy) * w + dx;
                                for (int x = xs; x < xe; x++) dst[orow + x] += k * input[irow + x];
                            }
                        }
                    }
                }
                for (int i = 0; i < plane; i++) if (dst[ob + i] < 0) dst[ob + i] = 0;
            }
        }

        private static float[] conv(float[] input, int cin, int h, int w, HwConv cv) {
            var dst = new float[cv.cout * h * w];
            int n = int.min((int) get_num_processors(), 8);
            if (n <= 1 || (long) h * w * cin * cv.cout < 200000) {
                conv_part(input, cin, h, w, cv, dst, 0, cv.cout);
                return dst;
            }
            var threads = new Thread<bool>[n - 1];
            int step = (cv.cout + n - 1) / n;
            for (int k = 1; k < n; k++) {
                int o0 = int.min(cv.cout, k * step);
                int o1 = int.min(cv.cout, o0 + step);
                threads[k - 1] = new Thread<bool>("hw-conv", () => {
                    conv_part(input, cin, h, w, cv, dst, o0, o1);
                    return true;
                });
            }
            conv_part(input, cin, h, w, cv, dst, 0, int.min(cv.cout, step));
            foreach (var t in threads) t.join();
            return dst;
        }

        private static float[] pool(float[] input, int c, int h, int w, int ph, int pw, out int oh, out int ow) {
            oh = h / ph;
            ow = w / pw;
            var out = new float[c * oh * ow];
            for (int k = 0; k < c; k++) {
                for (int y = 0; y < oh; y++) {
                    for (int x = 0; x < ow; x++) {
                        float m = -float.MAX;
                        for (int a = 0; a < ph; a++) for (int b = 0; b < pw; b++) m = float.max(m, input[k * h * w + (y * ph + a) * w + x * pw + b]);
                        out[k * oh * ow + y * ow + x] = m;
                    }
                }
            }
            return out;
        }

        private static float sigmoid(float x) {
            return 1.0f / (1.0f + (float) Math.exp(-x));
        }

        private static float[] run_lstm(float[] input, int T, HwLstm l, bool reverse) {
            int hd = l.hidden;
            var out = new float[T * hd];
            var hs = new float[hd];
            var cs = new float[hd];
            var gates = new float[4 * hd];
            for (int step = 0; step < T; step++) {
                int t = reverse ? T - 1 - step : step;
                for (int g = 0; g < 4 * hd; g++) {
                    float acc = l.bias[g];
                    int wb = g * l.input;
                    int ib = t * l.input;
                    for (int i = 0; i < l.input; i++) acc += l.wih[wb + i] * input[ib + i];
                    int hb = g * hd;
                    for (int i = 0; i < hd; i++) acc += l.whh[hb + i] * hs[i];
                    gates[g] = acc;
                }
                for (int i = 0; i < hd; i++) {
                    float ig = sigmoid(gates[i]);
                    float fg = sigmoid(gates[hd + i]);
                    float gg = (float) Math.tanh(gates[2 * hd + i]);
                    float og = sigmoid(gates[3 * hd + i]);
                    cs[i] = fg * cs[i] + ig * gg;
                    hs[i] = og * (float) Math.tanh(cs[i]);
                    out[t * hd + i] = hs[i];
                }
            }
            return out;
        }

        public float[]? forward(float[] img, int width, out int steps) {
            steps = 0;
            int w = (width + 3) / 4 * 4;
            var x = new float[H * w];
            for (int y = 0; y < H; y++) for (int i = 0; i < width; i++) x[y * w + i] = img[y * width + i];
            int h = H, oh, ow;
            var a = conv(x, 1, h, w, convs[0]);
            a = pool(a, convs[0].cout, h, w, 2, 2, out oh, out ow);
            h = oh;
            w = ow;
            a = conv(a, convs[0].cout, h, w, convs[1]);
            a = pool(a, convs[1].cout, h, w, 2, 2, out oh, out ow);
            h = oh;
            w = ow;
            a = conv(a, convs[1].cout, h, w, convs[2]);
            a = conv(a, convs[2].cout, h, w, convs[3]);
            a = pool(a, convs[3].cout, h, w, 2, 1, out oh, out ow);
            h = oh;
            w = ow;
            a = conv(a, convs[3].cout, h, w, convs[4]);
            int c = convs[4].cout;
            int T = w;
            if (c * h != proj_in || T < 1) return null;
            var seq = new float[T * proj_out];
            var feat = new float[proj_in];
            for (int t = 0; t < T; t++) {
                for (int k = 0; k < c; k++) for (int y = 0; y < h; y++) feat[k * h + y] = a[k * h * w + y * w + t];
                for (int o = 0; o < proj_out; o++) {
                    float acc = proj_b[o];
                    int wb = o * proj_in;
                    for (int i = 0; i < proj_in; i++) acc += proj_w[wb + i] * feat[i];
                    seq[t * proj_out + o] = acc > 0 ? acc : 0;
                }
            }
            int dim = proj_out;
            for (int k = 0; k + 1 < lstm.length; k += 2) {
                var input = seq;
                var fl = lstm[k];
                float[]? f = null;
                var th = new Thread<bool>("hw-lstm", () => {
                    f = run_lstm(input, T, fl, false);
                    return true;
                });
                var b = run_lstm(seq, T, lstm[k + 1], true);
                th.join();
                int hd = lstm[k].hidden;
                var cat = new float[T * 2 * hd];
                for (int t = 0; t < T; t++) {
                    for (int i = 0; i < hd; i++) {
                        cat[t * 2 * hd + i] = f[t * hd + i];
                        cat[t * 2 * hd + hd + i] = b[t * hd + i];
                    }
                }
                seq = cat;
                dim = 2 * hd;
            }
            var lp = new float[T * classes];
            for (int t = 0; t < T; t++) {
                float mx = -float.MAX;
                for (int o = 0; o < classes; o++) {
                    float acc = out_b[o];
                    int wb = o * dim;
                    for (int i = 0; i < dim; i++) acc += out_w[wb + i] * seq[t * dim + i];
                    lp[t * classes + o] = acc;
                    mx = float.max(mx, acc);
                }
                double sum = 0;
                for (int o = 0; o < classes; o++) sum += Math.exp(lp[t * classes + o] - mx);
                float lse = mx + (float) Math.log(sum);
                for (int o = 0; o < classes; o++) lp[t * classes + o] -= lse;
            }
            steps = T;
            return lp;
        }

        public string greedy(float[] lp, int T) {
            var sb = new StringBuilder();
            int prev = 0;
            for (int t = 0; t < T; t++) {
                int best = 0;
                for (int o = 1; o < classes; o++) if (lp[t * classes + o] > lp[t * classes + best]) best = o;
                if (best != prev && best != 0) sb.append_unichar(alphabet[best - 1]);
                prev = best;
            }
            return sb.str;
        }

        public double[] space_cuts(float[] lp, int T, double left, double scale) {
            double[] cuts = {};
            int space = -1;
            for (int j = 0; j < alphabet.length; j++) if (alphabet[j] == ' ') space = j + 1;
            if (space < 0) return cuts;
            int start = -1;
            for (int t = 0; t <= T; t++) {
                bool on = false;
                if (t < T) {
                    int best = 0;
                    for (int o = 1; o < classes; o++) if (lp[t * classes + o] > lp[t * classes + best]) best = o;
                    on = best == space;
                }
                if (on && start < 0) start = t;
                if (!on && start >= 0) {
                    double xn = (start + t) / 2.0 * 4 + 2;
                    cuts += left + (xn - PAD) / scale;
                    start = -1;
                }
            }
            return cuts;
        }

        public int[]? encode(string text) {
            int[] labels = {};
            int i = 0;
            unichar c;
            while (text.get_next_char(ref i, out c)) {
                int k = -1;
                for (int j = 0; j < alphabet.length; j++) if (alphabet[j] == c) {
                    k = j;
                    break;
                }
                if (k < 0) return null;
                labels += k + 1;
            }
            return labels;
        }

        private static double logadd(double a, double b) {
            if (a == -double.INFINITY) return b;
            if (b == -double.INFINITY) return a;
            if (a > b) return a + Math.log1p(Math.exp(b - a));
            return b + Math.log1p(Math.exp(a - b));
        }

        public double nll(float[] lp, int T, int[] labels) {
            int L = labels.length;
            if (L == 0) {
                double s = 0;
                for (int t = 0; t < T; t++) s += lp[t * classes];
                return -s;
            }
            int S = 2 * L + 1;
            int need = L;
            for (int k = 1; k < L; k++) if (labels[k] == labels[k - 1]) need++;
            if (need > T) return double.INFINITY;
            var alpha = new double[S];
            var next = new double[S];
            for (int s = 0; s < S; s++) alpha[s] = -double.INFINITY;
            alpha[0] = lp[0];
            alpha[1] = lp[labels[0]];
            for (int t = 1; t < T; t++) {
                int lo = int.max(0, S - 2 * (T - t));
                for (int s = 0; s < S; s++) {
                    if (s < lo) {
                        next[s] = -double.INFINITY;
                        continue;
                    }
                    int lab = (s % 2 == 0) ? 0 : labels[s / 2];
                    double v = alpha[s];
                    if (s > 0) v = logadd(v, alpha[s - 1]);
                    if (s > 1 && lab != 0 && labels[s / 2] != labels[s / 2 - 1]) v = logadd(v, alpha[s - 2]);
                    next[s] = v == -double.INFINITY ? v : v + lp[t * classes + lab];
                }
                var tmp = alpha;
                alpha = next;
                next = tmp;
            }
            return -logadd(alpha[S - 1], alpha[S - 2]);
        }
    }

    public class HwLexicon {
        private int[] label = new int[1024];
        private int[] first = new int[1024];
        private int[] next = new int[1024];
        private int[] word = new int[1024];
        private int nodes = 1;
        public Gee.ArrayList<string> words = new Gee.ArrayList<string>();

        public HwLexicon() {
            first[0] = -1;
            next[0] = -1;
            word[0] = -1;
            label[0] = 0;
        }

        public int size {
            get { return words.size; }
        }

        private int child(int node, int lab) {
            for (int c = first[node]; c >= 0; c = next[c]) if (label[c] == lab) return c;
            if (nodes == label.length) {
                int n = label.length * 2;
                label.resize(n);
                first.resize(n);
                next.resize(n);
                word.resize(n);
            }
            int k = nodes++;
            label[k] = lab;
            first[k] = -1;
            word[k] = -1;
            next[k] = first[node];
            first[node] = k;
            return k;
        }

        public void add(string text, int[] labels) {
            int node = 0;
            foreach (int l in labels) node = child(node, l);
            if (word[node] < 0) {
                word[node] = words.size;
                words.add(text);
            }
        }

        private class Hit {
            public int word;
            public float score;
        }

        private float[] lp;
        private int T;
        private int C;
        private float[] tail;
        private int keep;
        private Gee.ArrayList<Hit> hits;
        private float bar;

        private void offer(int w, float score) {
            if (hits.size >= keep && score >= bar) return;
            var h = new Hit();
            h.word = w;
            h.score = score;
            hits.add(h);
            if (hits.size >= keep * 2) {
                hits.sort((a, b) => a.score < b.score ? -1 : (a.score > b.score ? 1 : 0));
                while (hits.size > keep) hits.remove_at(hits.size - 1);
                bar = hits[hits.size - 1].score;
            }
        }

        private float[] buf_b;
        private float[] buf_c;
        private int fan = 1;
        private int fan_nodes = -1;
        private int depth_max;

        private void visit(int node, int depth, int poff, int plab) {
            if (depth + 1 >= depth_max) return;
            int[] kids = {};
            for (int c = first[node]; c >= 0; c = next[c]) kids += c;
            int n = kids.length;
            var bounds = new float[n];
            for (int i = 0; i < n; i++) {
                int c = kids[i];
                int lab = label[c];
                int off = ((depth + 1) * fan + i) * T;
                float bound = float.INFINITY;
                for (int t = 0; t < T; t++) {
                    float enter;
                    if (t == 0) {
                        enter = depth == 0 ? 0 : float.INFINITY;
                    } else {
                        enter = buf_b[poff + t - 1];
                        if (plab != lab && buf_c[poff + t - 1] < enter) enter = buf_c[poff + t - 1];
                        if (buf_c[off + t - 1] < enter) enter = buf_c[off + t - 1];
                    }
                    float cc = enter - lp[t * C + lab];
                    float stay = t == 0 ? float.INFINITY : float.min(buf_b[off + t - 1], buf_c[off + t - 1]);
                    float cb = stay - lp[t * C];
                    buf_c[off + t] = cc;
                    buf_b[off + t] = cb;
                    float here = float.min(cb, cc) + tail[t + 1];
                    if (here < bound) bound = here;
                }
                bounds[i] = bound;
            }
            var order = new int[n];
            for (int i = 0; i < n; i++) order[i] = i;
            for (int i = 1; i < n; i++) {
                int v = order[i];
                int j = i - 1;
                while (j >= 0 && bounds[order[j]] > bounds[v]) {
                    order[j + 1] = order[j];
                    j--;
                }
                order[j + 1] = v;
            }
            for (int k = 0; k < n; k++) {
                int i = order[k];
                if (hits.size >= keep && bounds[i] >= bar) break;
                int c = kids[i];
                int off = ((depth + 1) * fan + i) * T;
                if (word[c] >= 0) offer(word[c], float.min(buf_b[off + T - 1], buf_c[off + T - 1]));
                if (first[c] >= 0) visit(c, depth + 1, off, label[c]);
            }
        }

        public Gee.ArrayList<string> search(float[] lp, int T, int classes, int keep) {
            this.lp = lp;
            this.T = T;
            this.C = classes;
            this.keep = keep;
            hits = new Gee.ArrayList<Hit>();
            bar = float.INFINITY;
            tail = new float[T + 1];
            tail[T] = 0;
            for (int t = T - 1; t >= 0; t--) {
                float m = -float.INFINITY;
                for (int o = 0; o < classes; o++) m = float.max(m, lp[t * classes + o]);
                tail[t] = tail[t + 1] - m;
            }
            if (fan_nodes != nodes) {
                fan = 1;
                for (int i = 0; i < nodes; i++) {
                    int k = 0;
                    for (int c = first[i]; c >= 0; c = next[c]) k++;
                    fan = int.max(fan, k);
                }
                fan_nodes = nodes;
            }
            depth_max = T + 2;
            buf_b = new float[(depth_max + 1) * fan * T];
            buf_c = new float[(depth_max + 1) * fan * T];
            float acc = 0;
            for (int t = 0; t < T; t++) {
                acc -= lp[t * classes];
                buf_b[t] = acc;
                buf_c[t] = float.INFINITY;
            }
            visit(0, 0, 0, -1);
            hits.sort((a, b) => a.score < b.score ? -1 : (a.score > b.score ? 1 : 0));
            var out = new Gee.ArrayList<string>();
            foreach (var h in hits) {
                if (out.size >= keep) break;
                out.add(words[h.word]);
            }
            this.lp = null;
            buf_b = null;
            buf_c = null;
            return out;
        }
    }
}
