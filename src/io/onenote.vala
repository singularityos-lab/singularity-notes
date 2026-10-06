namespace Singularity.Apps.Notes {

    public class OneProp : Object {
        public uint32 id;
        public uint32 kind;
        public uint64 scalar;
        public uint8[] data = {};
        public Gee.ArrayList<string> refs = new Gee.ArrayList<string>();
        public Gee.ArrayList<Gee.ArrayList<OneProp>> sets = new Gee.ArrayList<Gee.ArrayList<OneProp>>();
    }

    public class OneObject : Object {
        public uint32 jcid;
        public Gee.ArrayList<OneProp> props = new Gee.ArrayList<OneProp>();
        public string file_ref = "";
        public string extension = "";
        public Bytes? file_data = null;

        public uint32 kind {
            get { return jcid & 0xffff; }
        }

        public OneProp? find(uint32 id) {
            foreach (var p in props) if (p.id == id) return p;
            return null;
        }

        public Gee.List<string> refs(uint32 id) {
            var p = find(id);
            return p != null ? p.refs : new Gee.ArrayList<string>();
        }

        public bool has(uint32 id) {
            return find(id) != null;
        }

        public uint64 scalar(uint32 id, uint64 fallback = 0) {
            var p = find(id);
            return p != null && p.kind >= 2 && p.kind <= 6 ? p.scalar : fallback;
        }

        public bool flag(uint32 id) {
            return scalar(id) != 0;
        }

        public uint8[] bytes(uint32 id) {
            var p = find(id);
            return p != null ? p.data : new uint8[0];
        }

        public string text(uint32 id) {
            return OneText.utf16(bytes(id)).replace("\0", "").strip();
        }
    }

    public class OneSpace : Object {
        public Gee.HashMap<string, OneObject> objects = new Gee.HashMap<string, OneObject>();
        public Gee.HashMap<uint, string> roots = new Gee.HashMap<uint, string>();

        public OneObject? root(uint role) {
            string? key = roots[role];
            return key != null ? objects[key] : null;
        }
    }

    public class OneDocument : Object {
        public Gee.HashMap<string, OneSpace> spaces = new Gee.HashMap<string, OneSpace>();
        public Gee.ArrayList<string> order = new Gee.ArrayList<string>();
        public Gee.HashMap<string, Bytes> files = new Gee.HashMap<string, Bytes>();
        public string root_space = "";

        public Bytes? file_for(OneObject o) {
            if (o.file_data != null) return o.file_data;
            if (o.file_ref != "") return files[o.file_ref];
            return null;
        }

        public static OneDocument parse(uint8[] data) throws Error {
            var r = new OneReader(data);
            if (data.length < 1024) throw OneReader.damaged();
            string file_type = r.guid(0);
            if (file_type != "7b5c52e4-d88c-4da7-aeb1-5378d02996d3" && file_type != "43ff2fa1-efd9-4c76-9ee2-10ea5722765f") {
                throw new IOError.INVALID_DATA(_("This is not a OneNote file"));
            }
            string format = r.guid(48);
            if (format == "638de92f-a6d4-4bc1-9a36-b3fc2511a5b7") return new OnePackageReader(r).read();
            return new OneStoreReader(r).read();
        }
    }

    internal class OneText {
        public static string utf16(uint8[] b, int from = 0, int to = -1) {
            if (to < 0 || to > b.length / 2) to = b.length / 2;
            var sb = new StringBuilder();
            for (int i = from; i < to; i++) {
                uint u = b[2 * i] | (b[2 * i + 1] << 8);
                if (u >= 0xD800 && u <= 0xDBFF && i + 1 < to) {
                    uint lo = b[2 * i + 2] | (b[2 * i + 3] << 8);
                    if (lo >= 0xDC00 && lo <= 0xDFFF) {
                        sb.append_unichar((unichar) (0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)));
                        i++;
                        continue;
                    }
                }
                if (u >= 0xD800 && u <= 0xDFFF) u = 0xFFFD;
                sb.append_unichar((unichar) u);
            }
            return sb.str;
        }

        public static string latin1(uint8[] b, int from = 0, int to = -1) {
            if (to < 0 || to > b.length) to = b.length;
            var sb = new StringBuilder();
            for (int i = from; i < to; i++) sb.append_unichar((unichar) b[i]);
            return sb.str;
        }
    }

    internal class OneReader : Object {
        public uint8[] d;

        public OneReader(uint8[] data) {
            d = data;
        }

        public static Error damaged() {
            return new IOError.INVALID_DATA(_("The OneNote file is damaged"));
        }

        public void need(uint64 at, uint64 n) throws Error {
            if (at > d.length || n > d.length - at) throw damaged();
        }

        public uint8 u8(uint64 at) throws Error {
            need(at, 1);
            return d[at];
        }

        public uint16 u16(uint64 at) throws Error {
            need(at, 2);
            return (uint16) (d[at] | (d[at + 1] << 8));
        }

        public uint32 u32(uint64 at) throws Error {
            need(at, 4);
            return (uint32) d[at] | ((uint32) d[at + 1] << 8) | ((uint32) d[at + 2] << 16) | ((uint32) d[at + 3] << 24);
        }

        public uint64 u64(uint64 at) throws Error {
            return (uint64) u32(at) | ((uint64) u32(at + 4) << 32);
        }

        public uint8[] slice(uint64 at, uint64 n) throws Error {
            need(at, n);
            return d[(int) at:(int) (at + n)];
        }

        public string guid(uint64 at) throws Error {
            need(at, 16);
            return "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x".printf(u32(at), u16(at + 4), u16(at + 6),
                d[at + 8], d[at + 9], d[at + 10], d[at + 11], d[at + 12], d[at + 13], d[at + 14], d[at + 15]);
        }

        public string exguid(uint64 at) throws Error {
            return "%s:%u".printf(guid(at), u32(at + 16));
        }

        public static bool is_nil(string key) {
            return key == "" || key.has_prefix("00000000-0000-0000-0000-000000000000");
        }
    }

    internal class OneStreams {
        public Gee.List<string> oids = new Gee.ArrayList<string>();
        public Gee.List<string> osids = new Gee.ArrayList<string>();
        public Gee.List<string> ctxids = new Gee.ArrayList<string>();
        public int oi = 0;
        public int si = 0;
        public int ci = 0;
    }

    internal class OnePropReader : Object {
        protected OneReader r;
        protected int budget = 2000000;

        protected Gee.ArrayList<string> stream(ref uint64 o, out uint32 header, Gee.HashMap<uint32, string>? table) throws Error {
            header = r.u32(o);
            o += 4;
            uint32 n = header & 0xffffff;
            r.need(o, (uint64) n * 4);
            var list = new Gee.ArrayList<string>();
            for (uint32 i = 0; i < n; i++) {
                list.add(table != null ? compact(r.u32(o), table) : "");
                o += 4;
            }
            return list;
        }

        public static string compact(uint32 v, Gee.HashMap<uint32, string> table) {
            if (v == 0) return "";
            string? g = table[v >> 8];
            return g != null ? "%s:%u".printf(g, v & 0xff) : "";
        }

        protected OneObject object_at(uint32 jcid, uint64 at, uint64 end, Gee.HashMap<uint32, string>? table, Gee.List<string>? oids, Gee.List<string>? osids) throws Error {
            var obj = new OneObject();
            obj.jcid = jcid;
            var s = new OneStreams();
            uint64 o = at;
            uint32 h;
            var first = stream(ref o, out h, table);
            s.oids = oids ?? first;
            bool ext = ((h >> 30) & 1) != 0;
            if ((h >> 31) == 0) {
                uint32 h2;
                var second = stream(ref o, out h2, table);
                s.osids = osids ?? second;
                ext = ext || ((h2 >> 30) & 1) != 0;
            } else if (osids != null) {
                s.osids = osids;
            }
            if (ext) {
                uint32 h3;
                s.ctxids = stream(ref o, out h3, table);
            }
            obj.props = prop_set(ref o, end, s, 0);
            return obj;
        }

        protected Gee.ArrayList<OneProp> prop_set(ref uint64 o, uint64 end, OneStreams s, int level) throws Error {
            if (level > 32) throw OneReader.damaged();
            uint16 n = r.u16(o);
            o += 2;
            budget -= n;
            if (budget < 0 || o + (uint64) n * 4 > end) throw OneReader.damaged();
            var prids = new uint32[n];
            for (int i = 0; i < n; i++) {
                prids[i] = r.u32(o);
                o += 4;
            }
            var list = new Gee.ArrayList<OneProp>();
            foreach (uint32 prid in prids) list.add(prop_value(ref o, end, prid, s, level));
            return list;
        }

        private OneProp prop_value(ref uint64 o, uint64 end, uint32 prid, OneStreams s, int level) throws Error {
            var p = new OneProp();
            p.id = prid & 0x3ffffff;
            p.kind = (prid >> 26) & 0x1f;
            switch (p.kind) {
                case 0x1:
                    break;
                case 0x2:
                    p.scalar = prid >> 31;
                    break;
                case 0x3:
                    p.scalar = r.u8(o);
                    o += 1;
                    break;
                case 0x4:
                    p.scalar = r.u16(o);
                    o += 2;
                    break;
                case 0x5:
                    p.scalar = r.u32(o);
                    o += 4;
                    break;
                case 0x6:
                    p.scalar = r.u64(o);
                    o += 8;
                    break;
                case 0x7:
                    uint32 len = r.u32(o);
                    o += 4;
                    if (o + len > end) throw OneReader.damaged();
                    p.data = r.slice(o, len);
                    o += len;
                    break;
                case 0x8:
                case 0x9:
                case 0xA:
                case 0xB:
                case 0xC:
                case 0xD:
                    uint32 count = 1;
                    if ((p.kind & 1) == 1) {
                        count = r.u32(o);
                        o += 4;
                    }
                    budget -= (int) uint32.min(count, 1000000);
                    if (budget < 0) throw OneReader.damaged();
                    Gee.List<string> src = p.kind <= 0x9 ? s.oids : p.kind <= 0xB ? s.osids : s.ctxids;
                    for (uint32 i = 0; i < count; i++) {
                        int idx = p.kind <= 0x9 ? s.oi++ : p.kind <= 0xB ? s.si++ : s.ci++;
                        if (idx < src.size) p.refs.add(src[idx]);
                    }
                    break;
                case 0x10:
                    uint32 items = r.u32(o);
                    o += 4;
                    if (items == 0) break;
                    uint32 inner = r.u32(o);
                    o += 4;
                    for (uint32 i = 0; i < items; i++) {
                        if (((inner >> 26) & 0x1f) == 0x11) p.sets.add(prop_set(ref o, end, s, level + 1));
                        else prop_value(ref o, end, inner, s, level + 1);
                        if (budget < 0) throw OneReader.damaged();
                    }
                    break;
                case 0x11:
                    p.sets.add(prop_set(ref o, end, s, level + 1));
                    break;
                default:
                    throw OneReader.damaged();
            }
            if (o > end) throw OneReader.damaged();
            return p;
        }
    }

    internal class OneRevision {
        public string dep = "";
        public Gee.HashMap<string, OneObject> objects = new Gee.HashMap<string, OneObject>();
        public Gee.HashMap<uint, string> roots = new Gee.HashMap<uint, string>();
        public Gee.HashMap<uint32, string> table = new Gee.HashMap<uint32, string>();
    }

    internal class OneStoreReader : OnePropReader {
        private OneDocument doc = new OneDocument();
        private Gee.HashMap<string, OneRevision> revisions = new Gee.HashMap<string, OneRevision>();
        private Gee.HashMap<uint, string> role_rid = new Gee.HashMap<uint, string>();
        private Gee.HashMap<uint32, string> table = new Gee.HashMap<uint32, string>();
        private OneRevision? rev = null;
        private string last_rid = "";
        private string space_id = "";
        private int depth = 0;
        private int nodes = 0;

        public OneStoreReader(OneReader reader) {
            r = reader;
        }

        public OneDocument read() throws Error {
            node_list(r.u64(172), r.u32(180));
            return doc;
        }

        private uint64 chunk(uint64 p, uint stp_format, uint cb_format, out uint64 stp, out uint64 cb) throws Error {
            switch (stp_format) {
                case 0: stp = r.u64(p); p += 8; break;
                case 1: stp = r.u32(p); p += 4; break;
                case 2: stp = (uint64) r.u16(p) * 8; p += 2; break;
                default: stp = (uint64) r.u32(p) * 8; p += 4; break;
            }
            switch (cb_format) {
                case 0: cb = r.u32(p); p += 4; break;
                case 1: cb = r.u64(p); p += 8; break;
                case 2: cb = (uint64) r.u8(p) * 8; p += 1; break;
                default: cb = (uint64) r.u16(p) * 8; p += 2; break;
            }
            return p;
        }

        private void node_list(uint64 stp, uint64 cb) throws Error {
            if (depth > 48) throw OneReader.damaged();
            depth++;
            int fragments = 0;
            while (cb >= 36 && stp < r.d.length && fragments++ < 100000) {
                r.need(stp, cb);
                if (r.u64(stp) != 0xA4567AB1F5F7F4C4) throw OneReader.damaged();
                uint64 end = stp + cb - 20;
                uint64 o = stp + 16;
                while (o + 4 <= end) {
                    uint32 h = r.u32(o);
                    uint32 id = h & 0x3ff;
                    uint32 size = (h >> 10) & 0x1fff;
                    if (id == 0 || id == 0xff || size < 4 || o + size > end) break;
                    if (++nodes > 5000000) throw OneReader.damaged();
                    uint32 base_type = (h >> 27) & 0xf;
                    uint64 p = o + 4;
                    uint64 ref_stp = 0;
                    uint64 ref_cb = 0;
                    if (base_type == 1 || base_type == 2) p = chunk(p, (h >> 23) & 3, (h >> 25) & 3, out ref_stp, out ref_cb);
                    node(id, p, ref_stp, ref_cb);
                    o += size;
                }
                stp = r.u64(end);
                cb = r.u32(end + 8);
            }
            depth--;
        }

        private void begin_revision(string rid, string dep, uint role, bool default_context) {
            rev = new OneRevision();
            rev.dep = dep;
            revisions[rid] = rev;
            last_rid = rid;
            if (default_context) role_rid[role] = rid;
        }

        private void finish_space() {
            if (space_id == "") return;
            string cur = role_rid[1] ?? last_rid;
            var chain = new Gee.ArrayList<OneRevision>();
            var seen = new Gee.HashSet<string>();
            while (cur != "" && !seen.contains(cur) && revisions.has_key(cur)) {
                seen.add(cur);
                var rv = revisions[cur];
                chain.insert(0, rv);
                cur = OneReader.is_nil(rv.dep) ? "" : rv.dep;
            }
            var space = new OneSpace();
            foreach (var rv in chain) {
                space.objects.set_all(rv.objects);
                space.roots.set_all(rv.roots);
            }
            doc.spaces[space_id] = space;
            doc.order.add(space_id);
            revisions.clear();
            role_rid.clear();
            rev = null;
            last_rid = "";
            space_id = "";
        }

        private string? jcid_of(string key) {
            var seen = new Gee.HashSet<OneRevision>();
            var rv = rev;
            while (rv != null && !seen.contains(rv)) {
                seen.add(rv);
                var o = rv.objects[key];
                if (o != null) return "%u".printf(o.jcid);
                rv = revisions[rv.dep];
            }
            return null;
        }

        private void declare(string key, uint32 jcid, uint64 stp, uint64 cb) {
            if (rev == null || key == "") return;
            OneObject obj;
            try {
                if (cb > 0 && (jcid & 0x20000) != 0 || cb > 0 && (jcid & 0xffff0000) == 0) {
                    r.need(stp, cb);
                    obj = object_at(jcid, stp, stp + cb, table, null, null);
                } else {
                    obj = new OneObject();
                    obj.jcid = jcid;
                }
            } catch (Error e) {
                obj = new OneObject();
                obj.jcid = jcid;
            }
            rev.objects[key] = obj;
        }

        private void node(uint32 id, uint64 p, uint64 stp, uint64 cb) throws Error {
            switch (id) {
                case 0x004:
                    doc.root_space = r.exguid(p);
                    break;
                case 0x008:
                    node_list(stp, cb);
                    finish_space();
                    break;
                case 0x00C:
                    space_id = r.exguid(p);
                    break;
                case 0x010:
                case 0x090:
                case 0x0B0:
                    node_list(stp, cb);
                    break;
                case 0x01B:
                    begin_revision(r.exguid(p), r.exguid(p + 20), r.u32(p + 48), true);
                    break;
                case 0x01E:
                    begin_revision(r.exguid(p), r.exguid(p + 20), r.u32(p + 40), true);
                    break;
                case 0x01F:
                    begin_revision(r.exguid(p), r.exguid(p + 20), r.u32(p + 40), OneReader.is_nil(r.exguid(p + 46)));
                    break;
                case 0x021:
                case 0x022:
                    table = new Gee.HashMap<uint32, string>();
                    break;
                case 0x024:
                    table[r.u32(p)] = r.guid(p + 4);
                    break;
                case 0x025:
                case 0x026: {
                    var dep = rev != null ? revisions[rev.dep] : null;
                    if (dep == null) break;
                    uint32 from = r.u32(p);
                    uint32 count = id == 0x025 ? 1 : r.u32(p + 4);
                    uint32 to = id == 0x025 ? r.u32(p + 4) : r.u32(p + 8);
                    for (uint32 i = 0; i < uint32.min(count, 100000); i++) {
                        string? g = dep.table[from + i];
                        if (g != null) table[to + i] = g;
                    }
                    break;
                }
                case 0x028:
                    if (rev != null) rev.table = table;
                    break;
                case 0x02D:
                case 0x02E:
                    declare(compact(r.u32(p), table), r.u32(p + 4) & 0x3ff, stp, cb);
                    break;
                case 0x041:
                case 0x042: {
                    string key = compact(r.u32(p), table);
                    string? j = jcid_of(key);
                    if (j != null) declare(key, (uint32) uint64.parse(j), stp, cb);
                    break;
                }
                case 0x0A4:
                case 0x0A5:
                case 0x0C4:
                case 0x0C5:
                    declare(compact(r.u32(p), table), r.u32(p + 4), stp, cb);
                    break;
                case 0x072:
                case 0x073: {
                    string key = compact(r.u32(p), table);
                    uint64 q = p + (id == 0x072 ? 9 : 12);
                    uint32 cch = r.u32(q);
                    if (cch > 4096) break;
                    string reference = OneText.utf16(r.slice(q + 4, (uint64) cch * 2));
                    q += 4 + (uint64) cch * 2;
                    uint32 ech = r.u32(q);
                    string ext = ech <= 256 ? OneText.utf16(r.slice(q + 4, (uint64) ech * 2)) : "";
                    if (rev == null || key == "") break;
                    var obj = new OneObject();
                    obj.jcid = r.u32(p + 4);
                    obj.extension = ext;
                    if (reference.has_prefix("<ifndf>")) obj.file_ref = reference.substring(7).replace("{", "").replace("}", "").down();
                    rev.objects[key] = obj;
                    break;
                }
                case 0x059:
                    if (rev != null) rev.roots[r.u32(p + 4)] = compact(r.u32(p), table);
                    break;
                case 0x05A:
                    if (rev != null) rev.roots[r.u32(p + 20)] = r.exguid(p);
                    break;
                case 0x05C:
                    role_rid[r.u32(p + 20)] = r.exguid(p);
                    break;
                case 0x05D:
                    if (OneReader.is_nil(r.exguid(p + 24))) role_rid[r.u32(p + 20)] = r.exguid(p);
                    break;
                case 0x094: {
                    if (cb < 36) break;
                    uint64 len = r.u64(stp + 16);
                    if (len > cb - 36) break;
                    doc.files[r.guid(p)] = new Bytes(r.slice(stp + 36, len));
                    break;
                }
                default:
                    break;
            }
        }
    }

    internal class OneStreamObject {
        public uint type;
        public bool compound;
        public uint64 data;
        public uint64 length;
        public Gee.ArrayList<OneStreamObject> children = new Gee.ArrayList<OneStreamObject>();
    }

    internal class OnePackageReader : OnePropReader {
        private OneDocument doc = new OneDocument();
        private Gee.HashMap<string, OneStreamObject> elements = new Gee.HashMap<string, OneStreamObject>();
        private Gee.HashMap<string, uint64?> element_types = new Gee.HashMap<string, uint64?>();
        private Gee.HashMap<string, string> cell_map = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, string> revision_map = new Gee.HashMap<string, string>();
        private int count = 0;

        public OnePackageReader(OneReader reader) {
            r = reader;
        }

        private uint64 c64(ref uint64 o) throws Error {
            uint8 b = r.u8(o);
            uint64 v;
            if (b == 0) { v = 0; o += 1; }
            else if ((b & 1) != 0) { v = b >> 1; o += 1; }
            else if ((b & 2) != 0) { v = r.u16(o) >> 2; o += 2; }
            else if ((b & 4) != 0) { v = (r.u32(o) & 0xffffff) >> 3; o += 3; }
            else if ((b & 8) != 0) { v = r.u32(o) >> 4; o += 4; }
            else if ((b & 16) != 0) { v = (r.u64(o) & 0xffffffffff) >> 5; o += 5; }
            else if ((b & 32) != 0) { v = (r.u64(o) & 0xffffffffffff) >> 6; o += 6; }
            else if ((b & 64) != 0) { v = (r.u64(o) & 0xffffffffffffff) >> 7; o += 7; }
            else { v = r.u64(o + 1); o += 9; }
            return v;
        }

        private string exg(ref uint64 o) throws Error {
            uint8 b = r.u8(o);
            string key;
            if (b == 0) { o += 1; return ""; }
            if ((b & 7) == 4) { key = "%s:%u".printf(r.guid(o + 1), b >> 3); o += 17; }
            else if ((b & 63) == 32) { key = "%s:%u".printf(r.guid(o + 2), r.u16(o) >> 6); o += 18; }
            else if ((b & 127) == 64) { key = "%s:%u".printf(r.guid(o + 3), (r.u32(o) & 0xffffff) >> 7); o += 19; }
            else if (b == 128) { key = "%s:%u".printf(r.guid(o + 5), r.u32(o + 1)); o += 21; }
            else throw OneReader.damaged();
            return key;
        }

        private string cell(ref uint64 o) throws Error {
            string a = exg(ref o);
            string b = exg(ref o);
            return a + "|" + b;
        }

        private Gee.ArrayList<string> exg_array(ref uint64 o) throws Error {
            uint64 n = c64(ref o);
            if (n > 1000000) throw OneReader.damaged();
            var list = new Gee.ArrayList<string>();
            for (uint64 i = 0; i < n; i++) list.add(exg(ref o));
            return list;
        }

        private Gee.ArrayList<string> cell_array(ref uint64 o) throws Error {
            uint64 n = c64(ref o);
            if (n > 1000000) throw OneReader.damaged();
            var list = new Gee.ArrayList<string>();
            for (uint64 i = 0; i < n; i++) list.add(cell(ref o));
            return list;
        }

        private OneStreamObject? stream_object(ref uint64 o, int level) throws Error {
            if (level > 32 || ++count > 5000000) throw OneReader.damaged();
            uint8 b = r.u8(o);
            var s = new OneStreamObject();
            if ((b & 3) == 0) {
                uint16 v = r.u16(o);
                s.compound = ((v >> 2) & 1) != 0;
                s.type = (v >> 3) & 0x3f;
                s.length = v >> 9;
                o += 2;
            } else if ((b & 3) == 2) {
                uint32 v = r.u32(o);
                s.compound = ((v >> 2) & 1) != 0;
                s.type = (v >> 3) & 0x3fff;
                s.length = v >> 17;
                o += 4;
                if (s.length == 32767) s.length = c64(ref o);
            } else {
                return null;
            }
            r.need(o, s.length);
            s.data = o;
            o += s.length;
            if (s.compound) {
                while (true) {
                    uint8 e = r.u8(o);
                    if ((e & 3) == 1) {
                        o += 1;
                        break;
                    }
                    if ((e & 3) == 3) {
                        o += 2;
                        break;
                    }
                    var child = stream_object(ref o, level + 1);
                    if (child == null) break;
                    s.children.add(child);
                }
            }
            return s;
        }

        public OneDocument read() throws Error {
            uint64 o = 0x44;
            var root = stream_object(ref o, 0);
            if (root == null || root.children.size == 0) throw OneReader.damaged();
            var roots = new Gee.ArrayList<string>();
            string header_cell = "";
            foreach (var de in root.children[0].children) {
                if (de.type != 0x01) continue;
                uint64 p = de.data;
                string id = exg(ref p);
                if (r.u8(p) == 0) p += 1;
                else p += 25;
                uint64 t = c64(ref p);
                elements[id] = de;
                element_types[id] = t;
                if (t == 1) {
                    foreach (var c in de.children) {
                        uint64 q = c.data;
                        if (c.type == 0x0E) {
                            string cid = cell(ref q);
                            cell_map[cid] = exg(ref q);
                        } else if (c.type == 0x0D) {
                            string rid = exg(ref q);
                            revision_map[rid] = exg(ref q);
                        }
                    }
                } else if (t == 2) {
                    foreach (var c in de.children) {
                        if (c.type != 0x07) continue;
                        uint64 q = c.data;
                        string root_id = exg(ref q);
                        string cid = cell(ref q);
                        if (root_id.has_prefix("1a5a319c-c26b-41aa-b9c5-9bd8c44e07d4")) header_cell = cid;
                        else roots.add(cid);
                    }
                }
            }
            if (roots.size > 0) doc.root_space = roots[0];
            foreach (var entry in cell_map.entries) {
                if (entry.key == header_cell) continue;
                try {
                    var space = read_cell(entry.value);
                    if (space == null) continue;
                    doc.spaces[entry.key] = space;
                    doc.order.add(entry.key);
                } catch (Error e) {
                }
            }
            return doc;
        }

        private OneStreamObject? element(string id, uint64 type) {
            var e = elements[id];
            uint64? t = element_types[id];
            return e != null && t != null && t == type ? e : null;
        }

        private OneSpace? read_cell(string manifest_id) throws Error {
            var manifest = element(manifest_id, 3);
            if (manifest == null || manifest.children.size == 0) return null;
            uint64 q = manifest.children[0].data;
            string cur = exg(ref q);
            var chain = new Gee.ArrayList<OneStreamObject>();
            var seen = new Gee.HashSet<string>();
            while (cur != "" && !seen.contains(cur)) {
                seen.add(cur);
                string? mapped = revision_map[cur];
                var rm = mapped != null ? element(mapped, 4) : null;
                if (rm == null || rm.children.size == 0) break;
                chain.insert(0, rm);
                uint64 h = rm.children[0].data;
                exg(ref h);
                string base_id = exg(ref h);
                cur = OneReader.is_nil(base_id) ? "" : base_id;
            }
            if (chain.size == 0) return null;
            var space = new OneSpace();
            foreach (var rm in chain) {
                foreach (var c in rm.children) {
                    uint64 p = c.data;
                    if (c.type == 0x0A) {
                        string root_id = exg(ref p);
                        string obj = exg(ref p);
                        int colon = root_id.last_index_of(":");
                        if (root_id.has_prefix("4a3717f8-1c14-49e7-9526-81d942de1741") && colon > 0) space.roots[(uint) uint64.parse(root_id.substring(colon + 1))] = obj;
                    } else if (c.type == 0x19) {
                        var group = element(exg(ref p), 5);
                        if (group != null) read_group(group, space);
                    }
                }
            }
            return space;
        }

        private void read_group(OneStreamObject group, OneSpace space) throws Error {
            var decls = new Gee.ArrayList<string>();
            var parts = new Gee.ArrayList<uint64?>();
            var blobs = new Gee.ArrayList<bool>();
            var datas = new Gee.ArrayList<OneStreamObject>();
            foreach (var c in group.children) {
                if (c.type == 0x1D) {
                    foreach (var x in c.children) {
                        uint64 p = x.data;
                        if (x.type == 0x18) {
                            decls.add(exg(ref p));
                            parts.add(c64(ref p));
                            blobs.add(false);
                        } else if (x.type == 0x05) {
                            decls.add(exg(ref p));
                            exg(ref p);
                            parts.add(c64(ref p));
                            blobs.add(true);
                        }
                    }
                } else if (c.type == 0x1E) {
                    foreach (var x in c.children) if (x.type == 0x16 || x.type == 0x1C) datas.add(x);
                }
            }
            var blob_decls = new Gee.ArrayList<int>();
            var plain_decls = new Gee.ArrayList<int>();
            for (int i = 0; i < decls.size; i++) {
                if (blobs[i]) blob_decls.add(i);
                else plain_decls.add(i);
            }
            var plain_data = new Gee.ArrayList<OneStreamObject>();
            var blob_data = new Gee.ArrayList<OneStreamObject>();
            foreach (var x in datas) {
                if (x.type == 0x16) plain_data.add(x);
                else blob_data.add(x);
            }
            var fresh = new Gee.HashMap<string, OneObject>();
            var props = new Gee.HashMap<string, OneStreamObject>();
            for (int k = 0; k < plain_decls.size && k < plain_data.size; k++) {
                int i = plain_decls[k];
                string key = decls[i];
                uint64 part = parts[i];
                var x = plain_data[k];
                if (!fresh.has_key(key)) fresh[key] = new OneObject();
                if (part == 4) {
                    uint64 p = x.data;
                    exg_array(ref p);
                    cell_array(ref p);
                    uint64 size = c64(ref p);
                    if (size >= 4) fresh[key].jcid = r.u32(p);
                } else if (part == 1) {
                    props[key] = x;
                }
            }
            for (int k = 0; k < blob_decls.size && k < blob_data.size; k++) {
                int i = blob_decls[k];
                if (parts[i] != 2) continue;
                string key = decls[i];
                uint64 p = blob_data[k].data;
                exg_array(ref p);
                cell_array(ref p);
                var blob = element(exg(ref p), 10);
                if (blob == null || blob.children.size == 0) continue;
                uint64 b = blob.children[0].data;
                uint64 len = c64(ref b);
                if (!fresh.has_key(key)) fresh[key] = new OneObject();
                fresh[key].file_data = new Bytes(r.slice(b, len));
            }
            foreach (var entry in props.entries) {
                var x = entry.value;
                uint64 p = x.data;
                var oids = exg_array(ref p);
                var cells = cell_array(ref p);
                uint64 size = c64(ref p);
                r.need(p, size);
                var target = fresh[entry.key];
                try {
                    var parsed = object_at(target.jcid, p, p + size, null, oids, cells);
                    target.props = parsed.props;
                } catch (Error e) {
                }
            }
            foreach (var entry in fresh.entries) {
                var existing = space.objects[entry.key];
                if (existing != null && entry.value.jcid == 0) entry.value.jcid = existing.jcid;
                space.objects[entry.key] = entry.value;
            }
        }
    }

    public class OneInk : Object {
        public const double HIMETRIC_PER_PX = 2540.0 / 96.0;
        private const string DIM_X = "598a6a8f-52c0-4ba0-93af-af357411a561";
        private const string DIM_Y = "b53f9f75-04e0-4498-a7ee-c30dbb5a9011";

        private static uint64 read_uint(uint8[] data, ref int at) {
            uint64 value = 0;
            int shift = 0;
            while (at < data.length && shift < 64) {
                uint8 b = data[at++];
                value |= (uint64) (b & 0x7f) << shift;
                shift += 7;
                if ((b & 0x80) == 0) break;
            }
            return value;
        }

        public static int64[] decode_signed(uint8[] data) {
            int at = 0;
            uint64 count = read_uint(data, ref at) >> 1;
            var values = new int64[0];
            for (uint64 i = 0; i < count && at < data.length; i++) {
                uint64 v = read_uint(data, ref at);
                int64 magnitude = (int64) (v >> 1);
                values += (v & 1) != 0 ? -magnitude : magnitude;
            }
            return values;
        }

        public static uint8[] encode_signed(int64[] values) {
            var out_bytes = new ByteArray();
            write_uint(out_bytes, (uint64) values.length << 1);
            foreach (int64 v in values) write_uint(out_bytes, v < 0 ? ((uint64) (-v) << 1) | 1 : (uint64) v << 1);
            return out_bytes.steal();
        }

        private static void write_uint(ByteArray b, uint64 v) {
            do {
                uint8 byte = (uint8) (v & 0x7f);
                v >>= 7;
                if (v != 0) byte |= 0x80;
                b.append({ byte });
            } while (v != 0);
        }

        public static Gee.ArrayList<InkPoint> path(int64[] values, string[] dimensions, double scale_x, double scale_y) {
            var points = new Gee.ArrayList<InkPoint>();
            int dims = dimensions.length;
            int ix = -1, iy = -1;
            for (int i = 0; i < dims; i++) {
                if (dimensions[i] == DIM_X) ix = i;
                else if (dimensions[i] == DIM_Y) iy = i;
            }
            if (dims == 0) {
                dims = 2;
                ix = 0;
                iy = 1;
            }
            if (ix < 0 || iy < 0) return points;
            int per = values.length / dims;
            double x = 0, y = 0;
            for (int i = 0; i < per; i++) {
                x += values[ix * per + i];
                y += values[iy * per + i];
                points.add(new InkPoint(x * scale_x / HIMETRIC_PER_PX, y * scale_y / HIMETRIC_PER_PX));
            }
            return points;
        }

        public static string color(uint32 bgr) {
            return "#%02x%02x%02x".printf(bgr & 0xff, (bgr >> 8) & 0xff, (bgr >> 16) & 0xff);
        }

        public static void normalize(InkDoc doc) {
            double x0 = double.MAX, y0 = double.MAX, x1 = -double.MAX, y1 = -double.MAX, pad = 4;
            foreach (var s in doc.strokes) {
                pad = double.max(pad, s.width / 2 + 4);
                foreach (var p in s.points) {
                    x0 = double.min(x0, p.x);
                    y0 = double.min(y0, p.y);
                    x1 = double.max(x1, p.x);
                    y1 = double.max(y1, p.y);
                }
            }
            if (x0 > x1) return;
            foreach (var s in doc.strokes) s.translate(pad - x0, pad - y0);
            doc.width = (int) Math.ceil(x1 - x0 + 2 * pad);
            doc.height = (int) Math.ceil(y1 - y0 + 2 * pad);
        }
    }

    public class OneFile : Object {
        public string name = "";
        public Bytes data;

        public OneFile(string name, Bytes data) {
            this.name = name;
            this.data = data;
        }
    }

    public class OnePage : Object {
        public string title = "";
        public int64 created = 0;
        public int64 modified = 0;
        public Gee.ArrayList<Block> blocks = new Gee.ArrayList<Block>();
        public Gee.HashMap<Block, OneFile> files = new Gee.HashMap<Block, OneFile>();
        public Gee.HashMap<Block, InkDoc> inks = new Gee.HashMap<Block, InkDoc>();
        public Gee.ArrayList<Gee.ArrayList<Gee.ArrayList<string>>> recognized = new Gee.ArrayList<Gee.ArrayList<Gee.ArrayList<string>>>();

        public string recognized_text() {
            var lines = new Gee.ArrayList<string>();
            foreach (var line in recognized) {
                var words = new Gee.ArrayList<string>();
                foreach (var word in line) if (word.size > 0) words.add(word[0]);
                if (words.size > 0) lines.add(string.joinv(" ", words.to_array()));
            }
            return string.joinv("\n", lines.to_array());
        }

        public string plain_text() {
            var sb = new StringBuilder();
            foreach (var b in blocks) {
                if (b.kind == BlockKind.TABLE && b.table != null) {
                    foreach (var row in b.table.rows) foreach (string c in row) sb.append(RichText.plain(c)).append("\n");
                } else {
                    sb.append(b.plain_text()).append("\n");
                }
            }
            return sb.str;
        }
    }

    public class OneNoteImporter : Object {
        private const uint32 ELEMENT_CHILDREN = 0x1C20;
        private const uint32 CONTENT_CHILDREN = 0x1C1F;
        private const uint32 CHILD_SPACES = 0x1D63;
        private const uint32 RICH_TEXT = 0x1C22;
        private const uint32 ASCII_TEXT = 0x3498;
        private const int64 TIME32_EPOCH = 315532800;
        private const int64 FILETIME_EPOCH = 11644473600;

        private OneDocument doc;
        private OneSpace space;
        private OnePage page;
        private Gee.HashSet<string> active = new Gee.HashSet<string>();
        private int pictures = 0;

        public static Gee.List<OnePage> read(uint8[] data) throws Error {
            var doc = OneDocument.parse(data);
            var pages = new Gee.ArrayList<OnePage>();
            var ordered = new Gee.ArrayList<string>();
            var root = doc.spaces[doc.root_space];
            if (root != null) {
                var visited = new Gee.HashSet<string>();
                var roles = new Gee.ArrayList<uint>();
                roles.add_all(root.roots.keys);
                roles.sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
                foreach (uint role in roles) collect_spaces(root, root.roots[role], visited, ordered, 0);
            }
            var done = new Gee.HashSet<string>();
            foreach (string key in ordered) {
                if (done.contains(key)) continue;
                done.add(key);
                var p = convert(doc, key);
                if (p != null) pages.add(p);
            }
            if (pages.size == 0) {
                foreach (string key in doc.order) {
                    if (done.contains(key)) continue;
                    var p = convert(doc, key);
                    if (p != null) pages.add(p);
                }
            }
            return pages;
        }

        private static void collect_spaces(OneSpace root, string key, Gee.HashSet<string> visited, Gee.ArrayList<string> found, int level) {
            if (level > 64 || visited.contains(key)) return;
            visited.add(key);
            var obj = root.objects[key];
            if (obj == null) return;
            foreach (var p in obj.props) {
                if (p.kind == 0xA || p.kind == 0xB) {
                    found.add_all(p.refs);
                } else if (p.id == ELEMENT_CHILDREN) {
                    foreach (string child in p.refs) collect_spaces(root, child, visited, found, level + 1);
                }
            }
        }

        private static OnePage? convert(OneDocument doc, string key) {
            var space = doc.spaces[key];
            if (space == null) return null;
            OneObject? manifest = space.root(1);
            OneObject? page_node = null;
            if (manifest != null && manifest.kind == 0x0B) {
                page_node = manifest;
            } else if (manifest != null && manifest.kind == 0x37) {
                foreach (string k in manifest.refs(CONTENT_CHILDREN)) {
                    var o = space.objects[k];
                    if (o != null && o.kind == 0x0B) page_node = o;
                }
            }
            if (page_node == null) return null;
            var conv = new OneNoteImporter();
            conv.doc = doc;
            conv.space = space;
            conv.page = new OnePage();
            conv.build(page_node);
            if (conv.page.title == "") {
                string cached = manifest.text(0x1CF3);
                var meta = space.root(2);
                if (cached == "" && meta != null) cached = meta.text(0x1D3C);
                if (cached == "" && meta != null) cached = meta.text(0x1CF3);
                conv.page.title = cached != "" ? cached : _("Untitled page");
            }
            return conv.page;
        }

        private OneObject? get_obj(string key) {
            return space.objects[key];
        }

        private void stamp(OneObject o) {
            uint64 created = o.scalar(0x1D09);
            if (created > 0) {
                int64 t = (int64) created + TIME32_EPOCH;
                if (page.created == 0 || t < page.created) page.created = t;
            }
            uint64 modified = o.scalar(0x1D7A);
            if (modified > 0) page.modified = int64.max(page.modified, (int64) modified + TIME32_EPOCH);
            uint64 ft = o.scalar(0x1D77);
            if (ft > 0) page.modified = int64.max(page.modified, (int64) (ft / 10000000) - FILETIME_EPOCH);
        }

        private static float as_float(uint64 bits) {
            uint32 b = (uint32) bits;
            float* f = (float*) (&b);
            return *f;
        }

        private void build(OneObject node) {
            stamp(node);
            var children = new Gee.ArrayList<OneObject>();
            foreach (string k in node.refs(ELEMENT_CHILDREN)) {
                var o = get_obj(k);
                if (o == null) continue;
                if (o.kind == 0x2C) {
                    page.title = title_text(o);
                    continue;
                }
                children.add(o);
            }
            children.sort((a, b) => {
                float ay = as_float(a.scalar(0x1C15));
                float by = as_float(b.scalar(0x1C15));
                if (ay != by) return ay < by ? -1 : 1;
                float ax = as_float(a.scalar(0x1C14));
                float bx = as_float(b.scalar(0x1C14));
                return ax < bx ? -1 : ax > bx ? 1 : 0;
            });
            foreach (var o in children) element(o, 0, null);
            finish_ink();
            foreach (string k in node.refs(0x35D7)) {
                var root = get_obj(k);
                if (root == null || root.kind != 0x54) continue;
                foreach (string lk in root.refs(0x35D9)) {
                    var words = new Gee.ArrayList<Gee.ArrayList<string>>();
                    var line = get_obj(lk);
                    if (line != null) recognized_words(line, words, 0);
                    if (words.size > 0) page.recognized.add(words);
                }
            }
            while (page.blocks.size > 0 && page.blocks[page.blocks.size - 1].kind == BlockKind.PARAGRAPH && page.blocks[page.blocks.size - 1].plain_text().strip() == "") {
                page.blocks.remove_at(page.blocks.size - 1);
            }
        }

        private string title_text(OneObject title) {
            var parts = new Gee.ArrayList<string>();
            collect_title(title, parts, 0);
            return string.joinv(" ", parts.to_array()).strip();
        }

        private void collect_title(OneObject o, Gee.ArrayList<string> parts, int level) {
            if (level > 16) return;
            stamp(o);
            if (o.kind == 0x0E) {
                if (o.flag(0x1CB5) || o.flag(0x1C87)) return;
                string t = raw_text(o).replace("\n", " ").replace("\r", " ").replace("\u000b", " ").strip();
                if (t != "") parts.add(t);
                return;
            }
            foreach (uint32 id in new uint32[] { ELEMENT_CHILDREN, CONTENT_CHILDREN }) {
                foreach (string k in o.refs(id)) {
                    var c = get_obj(k);
                    if (c != null) collect_title(c, parts, level + 1);
                }
            }
        }

        private string raw_text(OneObject o) {
            if (o.has(RICH_TEXT)) return OneText.utf16(o.bytes(RICH_TEXT)).replace("\0", "");
            if (o.has(ASCII_TEXT)) return OneText.latin1(o.bytes(ASCII_TEXT)).replace("\0", "");
            return "";
        }

        private void element(OneObject o, int indent, Gee.List<Block>? cell_out) {
            if (active.size > 256 || active.contains("%p".printf(o))) return;
            string guard = "%p".printf(o);
            active.add(guard);
            stamp(o);
            switch (o.kind) {
                case 0x0C:
                case 0x19:
                    foreach (string k in o.refs(ELEMENT_CHILDREN)) {
                        var c = get_obj(k);
                        if (c != null) element(c, indent, cell_out);
                    }
                    break;
                case 0x0D:
                    outline_element(o, indent);
                    break;
                case 0x11:
                    picture(o);
                    break;
                case 0x35:
                    embedded_file(o);
                    break;
                case 0x14:
                    ink(o);
                    break;
                case 0x22:
                    table(o);
                    break;
                case 0x0E:
                    paragraphs(o, indent, BlockKind.PARAGRAPH);
                    break;
                default:
                    foreach (string k in o.refs(ELEMENT_CHILDREN)) {
                        var c = get_obj(k);
                        if (c != null) element(c, indent, cell_out);
                    }
                    break;
            }
            active.remove(guard);
        }

        private void outline_element(OneObject oe, int indent) {
            BlockKind list = BlockKind.PARAGRAPH;
            foreach (string k in oe.refs(0x1C26)) {
                var n = get_obj(k);
                if (n == null || n.kind != 0x12) continue;
                string fmt = OneText.utf16(n.bytes(0x1C1A));
                list = fmt.contains("�") ? BlockKind.NUMBERED : BlockKind.BULLET;
            }
            foreach (string k in oe.refs(CONTENT_CHILDREN)) {
                var c = get_obj(k);
                if (c == null) continue;
                stamp(c);
                if (c.kind == 0x0E) {
                    paragraphs(c, indent, list);
                    list = BlockKind.PARAGRAPH;
                } else {
                    element(c, indent, null);
                }
            }
            foreach (string k in oe.refs(ELEMENT_CHILDREN)) {
                var c = get_obj(k);
                if (c != null) element(c, indent + 1, null);
            }
        }

        private BlockKind style_kind(OneObject rich) {
            foreach (string k in rich.refs(0x342C)) {
                var s = get_obj(k);
                if (s == null) continue;
                string id = s.text(0x345A).down();
                if (id.length == 2 && id[0] == 'h' && id[1] >= '1' && id[1] <= '6') return BlockKind.heading((int) id[1] - (int) '0');
                if (id == "blockquote" || id == "quote") return BlockKind.QUOTE;
            }
            return BlockKind.PARAGRAPH;
        }

        private Gee.ArrayList<Gee.ArrayList<Span>> lines(OneObject rich) {
            var result = new Gee.ArrayList<Gee.ArrayList<Span>>();
            var current = new Gee.ArrayList<Span>();
            result.add(current);
            bool unicode = rich.has(RICH_TEXT);
            uint8[] raw = unicode ? rich.bytes(RICH_TEXT) : rich.bytes(ASCII_TEXT);
            int total = unicode ? raw.length / 2 : raw.length;
            uint8[] idx = rich.bytes(0x1E12);
            var styles = rich.refs(0x1E13);
            var bounds = new Gee.ArrayList<int>();
            for (int i = 0; i + 3 < idx.length; i += 4) {
                int v = (int) ((uint32) idx[i] | ((uint32) idx[i + 1] << 8) | ((uint32) idx[i + 2] << 16) | ((uint32) idx[i + 3] << 24));
                bounds.add(int.min(int.max(v, 0), total));
            }
            bounds.add(total);
            int start = 0;
            string pending_href = "";
            for (int run = 0; run < bounds.size; run++) {
                int end = int.max(bounds[run], start);
                string text = unicode ? OneText.utf16(raw, start, end) : OneText.latin1(raw, start, end);
                start = end;
                text = text.replace("\0", "");
                OneObject? style = run < styles.size ? get_obj(styles[run]) : null;
                bool bold = false, italic = false, underline = false, strike = false, hidden = false, link = false;
                string url = "";
                if (style != null) {
                    bold = style.flag(0x1C04);
                    italic = style.flag(0x1C05);
                    underline = style.flag(0x1C06);
                    strike = style.flag(0x1C07);
                    hidden = style.flag(0x1E16);
                    link = style.flag(0x1E14);
                    url = style.text(0x1E20);
                }
                int field = text.index_of("﷟");
                if (field >= 0) {
                    string rest = text.substring(field);
                    int q1 = rest.index_of("\"");
                    int q2 = q1 >= 0 ? rest.index_of("\"", q1 + 1) : -1;
                    if (q1 >= 0 && q2 > q1) {
                        pending_href = rest.substring(q1 + 1, q2 - q1 - 1);
                        text = text.substring(0, field) + rest.substring(q2 + 1);
                        link = text.strip() != "" || link;
                    } else {
                        text = text.substring(0, field);
                    }
                }
                if (hidden || text == "") continue;
                string href = url != "" ? url : link && pending_href != "" ? pending_href : "";
                if (!link && url == "") pending_href = "";
                string[] pieces = text.replace("\r\n", "\n").replace("\r", "\n").replace("\u000b", "\n").split("\n");
                for (int i = 0; i < pieces.length; i++) {
                    if (i > 0) {
                        current = new Gee.ArrayList<Span>();
                        result.add(current);
                    }
                    if (pieces[i] == "") continue;
                    var span = new Span(pieces[i], bold, italic, href);
                    span.underline = underline;
                    span.strike = strike;
                    current.add(span);
                }
            }
            return result;
        }

        private void paragraphs(OneObject rich, int indent, BlockKind list) {
            var all = lines(rich);
            BlockKind kind = list != BlockKind.PARAGRAPH ? list : style_kind(rich);
            bool first = true;
            foreach (var spans in all) {
                bool empty = true;
                foreach (var s in spans) if (s.text.strip() != "") empty = false;
                if (empty) continue;
                var b = new Block(first || !kind.is_list() ? kind : BlockKind.PARAGRAPH);
                if (!b.kind.is_list() && b.kind != BlockKind.PARAGRAPH) b.indent = 0;
                else b.indent = !first && kind.is_list() ? indent + 1 : indent;
                foreach (var s in spans) b.add(s);
                page.blocks.add(b);
                first = false;
            }
        }

        private string cell_text(OneObject o, Gee.List<OneObject> extras, int level) {
            if (level > 16) return "";
            stamp(o);
            var parts = new Gee.ArrayList<string>();
            if (o.kind == 0x0E) {
                foreach (var spans in lines(o)) {
                    var sb = new StringBuilder();
                    foreach (var span in spans) {
                        string text = span.text;
                        if (text.strip() == "" && span.href != "") text = span.href;
                        sb.append(text);
                    }
                    string t = single_line(sb.str);
                    if (t != "") parts.add(t);
                }
            } else if (o.kind == 0x11 || o.kind == 0x35) {
                extras.add(o);
            } else {
                foreach (uint32 id in new uint32[] { CONTENT_CHILDREN, ELEMENT_CHILDREN }) {
                    foreach (string k in o.refs(id)) {
                        var c = get_obj(k);
                        if (c == null) continue;
                        string t = cell_text(c, extras, level + 1);
                        if (t != "") parts.add(t);
                    }
                }
            }
            return string.joinv(" ", parts.to_array());
        }

        private void table(OneObject t) {
            var data = new TableData();
            var extras = new Gee.ArrayList<OneObject>();
            foreach (string rk in t.refs(ELEMENT_CHILDREN)) {
                var row = get_obj(rk);
                if (row == null || row.kind != 0x23) continue;
                stamp(row);
                var cells = new Gee.ArrayList<string>();
                foreach (string ck in row.refs(ELEMENT_CHILDREN)) {
                    var c = get_obj(ck);
                    if (c == null || c.kind != 0x24) continue;
                    cells.add(cell_text(c, extras, 0));
                }
                data.rows.add(cells);
            }
            data.normalize();
            for (int r = data.rows.size - 1; r >= 0; r--) {
                bool empty = true;
                foreach (string c in data.rows[r]) if (c != "") empty = false;
                if (empty) data.rows.remove_at(r);
            }
            for (int c = data.columns - 1; c >= 0 && data.rows.size > 0; c--) {
                bool empty = true;
                foreach (var row in data.rows) if (c < row.size && row[c] != "") empty = false;
                if (!empty) continue;
                foreach (var row in data.rows) if (c < row.size) row.remove_at(c);
            }
            if (data.rows.size == 0 || data.columns == 0) {
                foreach (var e in extras) element(e, 0, null);
                return;
            }
            data.aligns.clear();
            data.normalize();
            var b = new Block(BlockKind.TABLE);
            b.table = data;
            page.blocks.add(b);
            foreach (var e in extras) element(e, 0, null);
        }

        private static string sniff(Bytes bytes) {
            unowned uint8[] b = bytes.get_data();
            if (b.length >= 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return "png";
            if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return "jpg";
            if (b.length >= 4 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F' && b[3] == '8') return "gif";
            if (b.length >= 2 && b[0] == 'B' && b[1] == 'M') return "bmp";
            if (b.length >= 4 && ((b[0] == 'I' && b[1] == 'I' && b[2] == 42) || (b[0] == 'M' && b[1] == 'M' && b[3] == 42))) return "tif";
            if (b.length >= 44 && b[0] == 1 && b[1] == 0 && b[2] == 0 && b[3] == 0 && b[40] == ' ' && b[41] == 'E' && b[42] == 'M' && b[43] == 'F') return "emf";
            if (b.length >= 4 && b[0] == 0xD7 && b[1] == 0xCD && b[2] == 0xC6 && b[3] == 0x9A) return "wmf";
            if (b.length >= 4 && b[0] == 'P' && b[1] == 'K' && b[2] == 3 && b[3] == 4) return "zip";
            if (b.length >= 4 && b[0] == '%' && b[1] == 'P' && b[2] == 'D' && b[3] == 'F') return "pdf";
            return "bin";
        }

        private Bytes? container_bytes(OneObject o, uint32 prop, out string ext) {
            ext = "";
            foreach (string k in o.refs(prop)) {
                var c = get_obj(k);
                if (c == null) continue;
                var bytes = doc.file_for(c);
                if (bytes == null) continue;
                ext = c.extension.has_prefix(".") ? c.extension.substring(1).down() : c.extension.down();
                return bytes;
            }
            return null;
        }

        private static string with_extension(string name, string ext) {
            string clean = Path.get_basename(name.replace("\\", "/")).strip();
            if (ext == "" || ext == "bin") return clean;
            if (clean.down().has_suffix("." + ext) || (ext == "jpg" && clean.down().has_suffix(".jpeg")) || (ext == "tif" && clean.down().has_suffix(".tiff"))) return clean;
            int dot = clean.last_index_of(".");
            if (dot > 0 && ext != "zip") return clean.substring(0, dot) + "." + ext;
            if (dot > 0) return clean;
            return clean + "." + ext;
        }

        private static string single_line(string text) {
            var sb = new StringBuilder();
            foreach (string part in text.replace("\r", "\n").replace("\u000b", "\n").split("\n")) {
                string t = part.strip();
                if (t == "") continue;
                if (sb.len > 0) sb.append(" ");
                sb.append(t);
            }
            return sb.str;
        }

        private void picture(OneObject img) {
            string stored;
            var bytes = container_bytes(img, 0x1C3F, out stored);
            string alt = single_line(img.text(0x1E58));
            string name = single_line(img.text(0x1DD7));
            if (bytes == null) {
                string label = alt != "" ? alt : name;
                if (label != "") {
                    var b = new Block(BlockKind.PARAGRAPH);
                    b.add(new Span("[%s]".printf(label), false, true));
                    page.blocks.add(b);
                }
                return;
            }
            pictures++;
            string ext = sniff(bytes);
            if (ext == "bin" && stored != "") ext = stored;
            if (name == "") name = "picture-%d".printf(pictures);
            name = with_extension(name, ext);
            if (alt == "") alt = name;
            int width = 0;
            float w = as_float(img.scalar(0x34CD));
            if (w > 0 && w < 200) width = (int) (w * 48);
            Block b;
            if (Attachments.is_image(name)) {
                b = RichText.image_block(alt, "", width);
            } else {
                b = new Block(BlockKind.FILE);
                b.alt = name;
            }
            page.blocks.add(b);
            page.files[b] = new OneFile(name, bytes);
        }

        private void embedded_file(OneObject node) {
            string stored;
            var bytes = container_bytes(node, 0x1D9B, out stored);
            string name = node.text(0x1D9C);
            if (name == "") name = Path.get_basename(node.text(0x1D9D).replace("\\", "/"));
            if (bytes == null) {
                if (name != "") {
                    var b = new Block(BlockKind.PARAGRAPH);
                    b.add(new Span("[%s]".printf(name), false, true));
                    page.blocks.add(b);
                }
                return;
            }
            if (name == "" || name == ".") name = with_extension(_("Attachment"), stored != "" ? stored : sniff(bytes));
            var b = new Block(BlockKind.FILE);
            b.alt = name;
            page.blocks.add(b);
            page.files[b] = new OneFile(name, bytes);
        }

        private void ink_group(OneObject container, InkDoc doc, int level) {
            if (level > 16) return;
            stamp(container);
            double sx = container.has(0x1C46) ? as_float(container.scalar(0x1C46)) : 1;
            double sy = container.has(0x1C47) ? as_float(container.scalar(0x1C47)) : 1;
            if (sx <= 0 || sx > 1000) sx = 1;
            if (sy <= 0 || sy > 1000) sy = 1;
            double ox = container.has(0x1C14) ? as_float(container.scalar(0x1C14)) * 48 : 0;
            double oy = container.has(0x1C15) ? as_float(container.scalar(0x1C15)) * 48 : 0;
            foreach (string k in container.refs(0x3415)) {
                var data = get_obj(k);
                if (data == null) continue;
                foreach (string sk in data.refs(0x3416)) {
                    var node = get_obj(sk);
                    if (node == null) continue;
                    OneObject? props = null;
                    foreach (string pk in node.refs(0x3409)) props = get_obj(pk);
                    string[] dims = {};
                    var stroke = new Stroke();
                    stroke.color = "#000000";
                    stroke.width = 2;
                    if (props != null) {
                        uint8[] raw = props.bytes(0x340A);
                        for (int i = 0; i + 32 <= raw.length; i += 32) {
                            dims += "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x".printf(
                                (uint32) raw[i] | ((uint32) raw[i + 1] << 8) | ((uint32) raw[i + 2] << 16) | ((uint32) raw[i + 3] << 24),
                                raw[i + 4] | (raw[i + 5] << 8), raw[i + 6] | (raw[i + 7] << 8),
                                raw[i + 8], raw[i + 9], raw[i + 10], raw[i + 11], raw[i + 12], raw[i + 13], raw[i + 14], raw[i + 15]);
                        }
                        if (props.has(0x340F)) stroke.color = OneInk.color((uint32) props.scalar(0x340F));
                        double w = double.max(as_float(props.scalar(0x340D)), as_float(props.scalar(0x340C)));
                        if (w > 0 && w < 100000) stroke.width = double.max(0.5, w / OneInk.HIMETRIC_PER_PX);
                        uint64 transparency = props.scalar(0x3414);
                        if (transparency > 0) stroke.opacity = (255 - (double) uint64.min(transparency, 255)) / 255.0;
                        if (props.scalar(0x3413) == 9 || (props.scalar(0x3412) == 1 && transparency > 0)) stroke.tool = "highlighter";
                    }
                    var points = OneInk.path(OneInk.decode_signed(node.bytes(0x340B)), dims, sx, sy);
                    foreach (var p in points) {
                        p.x += ox;
                        p.y += oy;
                    }
                    if (points.size == 0) continue;
                    stroke.points = points;
                    doc.strokes.add(stroke);
                }
            }
            foreach (string k in container.refs(CONTENT_CHILDREN)) {
                var child = get_obj(k);
                if (child != null && child.kind == 0x14) ink_group(child, doc, level + 1);
            }
        }

        private void ink(OneObject container) {
            Block? last = page.blocks.size > 0 ? page.blocks[page.blocks.size - 1] : null;
            InkDoc? doc = last != null && last.kind == BlockKind.INK ? page.inks[last] : null;
            if (doc != null) {
                ink_group(container, doc, 0);
                return;
            }
            doc = new InkDoc();
            ink_group(container, doc, 0);
            if (doc.strokes.size == 0) return;
            var b = new Block(BlockKind.INK);
            b.alt = _("Handwriting");
            page.blocks.add(b);
            page.inks[b] = doc;
        }

        private void recognized_words(OneObject o, Gee.ArrayList<Gee.ArrayList<string>> words, int level) {
            if (level > 8) return;
            if (o.kind == 0x57) {
                uint8[] raw = o.bytes(0x35DA);
                var alternatives = new Gee.ArrayList<string>();
                int units = raw.length / 2;
                int start = 0;
                for (int i = 0; i <= units; i++) {
                    if (i < units && (raw[2 * i] | raw[2 * i + 1]) != 0) continue;
                    if (i > start) alternatives.add(OneText.utf16(raw, start, i));
                    start = i + 1;
                }
                if (alternatives.size > 0) words.add(alternatives);
                return;
            }
            foreach (string k in o.refs(0x35D9)) {
                var c = get_obj(k);
                if (c != null) recognized_words(c, words, level + 1);
            }
        }

        private void finish_ink() {
            foreach (var entry in page.inks.entries) {
                var doc = entry.value;
                OneInk.normalize(doc);
                entry.key.width = doc.width;
                string svg = doc.to_svg();
                page.files[entry.key] = new OneFile("ink-%s.svg".printf(Uuid.string_random().substring(0, 8)), new Bytes(svg.data));
            }
        }

        public static string render(OnePage page, string notes_dir, string note_id) throws Error {
            if (page.files.size > 0) {
                string dir = Attachments.dir_for(notes_dir, note_id);
                DirUtils.create_with_parents(dir, 0700);
                foreach (var b in page.blocks) {
                    var f = page.files[b];
                    if (f == null) continue;
                    string target = Attachments.unique_path(dir, f.name);
                    FileUtils.set_data(target, f.data.get_data());
                    FileUtils.chmod(target, 0600);
                    b.image = Attachments.relative(note_id, target);
                }
            }
            return RichText.render(page.blocks);
        }

        public static async Gee.List<ImportedNote> import_data(uint8[] data, Singularity.Notes.NoteStore store, string folder) throws Error {
            var pages = read(data);
            if (pages.size == 0) throw new IOError.INVALID_DATA(_("This OneNote section has no pages"));
            var list = new Gee.ArrayList<ImportedNote>();
            foreach (var page in pages) {
                var note = store.create("", folder);
                var imported = new ImportedNote();
                imported.title = page.title;
                imported.body = render(page, store.dir, note.id);
                imported.created = page.created;
                imported.modified = page.modified;
                var pd = new PageDoc();
                pd.title = imported.title;
                pd.body = imported.body;
                note.body = pd.serialize();
                if (imported.created > 0) note.created = imported.created;
                store.save(note, false);
                if (imported.modified > 0) {
                    note.modified = imported.modified;
                    store.save(note, false);
                }
                list.add(imported);
            }
            return list;
        }
    }
}
