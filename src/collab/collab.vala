namespace Singularity.Apps.Notes {

    public errordomain CollabError {
        INVALID,
        REFUSED
    }

    public class OpPart {
        public int kind;
        public int n;
        public string text;

        public const int RETAIN = 0;
        public const int INSERT = 1;
        public const int DELETE = 2;

        public OpPart(int kind, int n, string text = "") {
            this.kind = kind;
            this.n = n;
            this.text = text;
        }
    }

    public class TextOperation : Object {
        public Gee.ArrayList<OpPart> parts = new Gee.ArrayList<OpPart>();
        public int base_length { get; private set; default = 0; }
        public int target_length { get; private set; default = 0; }

        public TextOperation retain(int n) {
            if (n <= 0) return this;
            base_length += n;
            target_length += n;
            if (parts.size > 0 && parts[parts.size - 1].kind == OpPart.RETAIN) parts[parts.size - 1].n += n;
            else parts.add(new OpPart(OpPart.RETAIN, n));
            return this;
        }

        public TextOperation insert(string s) {
            if (s == "") return this;
            int len = s.char_count();
            target_length += len;
            int last = parts.size - 1;
            if (last >= 0 && parts[last].kind == OpPart.INSERT) {
                parts[last].text += s;
                parts[last].n += len;
            } else if (last >= 0 && parts[last].kind == OpPart.DELETE) {
                if (last > 0 && parts[last - 1].kind == OpPart.INSERT) {
                    parts[last - 1].text += s;
                    parts[last - 1].n += len;
                } else {
                    parts.insert(last, new OpPart(OpPart.INSERT, len, s));
                }
            } else {
                parts.add(new OpPart(OpPart.INSERT, len, s));
            }
            return this;
        }

        public TextOperation delete(int n) {
            if (n <= 0) return this;
            base_length += n;
            if (parts.size > 0 && parts[parts.size - 1].kind == OpPart.DELETE) parts[parts.size - 1].n += n;
            else parts.add(new OpPart(OpPart.DELETE, n));
            return this;
        }

        public bool is_noop() {
            return parts.size == 0 || (parts.size == 1 && parts[0].kind == OpPart.RETAIN);
        }

        private static string slice(string s, int from_char, int count) {
            long start = s.index_of_nth_char(from_char);
            long end = s.index_of_nth_char(from_char + count);
            return s.substring(start, end - start);
        }

        public string apply(string text) throws CollabError {
            if (text.char_count() != base_length) throw new CollabError.INVALID("the operation does not fit the text");
            var sb = new StringBuilder();
            int pos = 0;
            foreach (var p in parts) {
                if (p.kind == OpPart.RETAIN) {
                    sb.append(slice(text, pos, p.n));
                    pos += p.n;
                } else if (p.kind == OpPart.INSERT) {
                    sb.append(p.text);
                } else {
                    pos += p.n;
                }
            }
            return sb.str;
        }

        public static TextOperation diff(string old_text, string new_text) {
            var op = new TextOperation();
            int ol = old_text.char_count();
            int nl = new_text.char_count();
            int prefix = 0;
            int oi = 0;
            int ni = 0;
            unichar oc, nc;
            while (prefix < ol && prefix < nl) {
                int so = oi, sn = ni;
                old_text.get_next_char(ref so, out oc);
                new_text.get_next_char(ref sn, out nc);
                if (oc != nc) break;
                oi = so;
                ni = sn;
                prefix++;
            }
            int suffix = 0;
            string ro = old_text.substring(oi);
            string rn = new_text.substring(ni);
            int rol = ol - prefix;
            int rnl = nl - prefix;
            while (suffix < rol && suffix < rnl) {
                string a = slice(ro, rol - suffix - 1, 1);
                string b = slice(rn, rnl - suffix - 1, 1);
                if (a != b) break;
                suffix++;
            }
            op.retain(prefix);
            op.delete(rol - suffix);
            op.insert(slice(rn, 0, rnl - suffix));
            op.retain(suffix);
            return op;
        }

        private static Gee.ArrayList<OpPart> copy_parts(Gee.List<OpPart> list) {
            var out_list = new Gee.ArrayList<OpPart>();
            foreach (var p in list) out_list.add(new OpPart(p.kind, p.n, p.text));
            return out_list;
        }

        public static TextOperation compose(TextOperation a, TextOperation b) throws CollabError {
            if (a.target_length != b.base_length) throw new CollabError.INVALID("the operations cannot be composed");
            var result = new TextOperation();
            var pa = copy_parts(a.parts);
            var pb = copy_parts(b.parts);
            int i = 0, j = 0;
            OpPart? x = i < pa.size ? pa[i++] : null;
            OpPart? y = j < pb.size ? pb[j++] : null;
            while (x != null || y != null) {
                if (x != null && x.kind == OpPart.DELETE) {
                    result.delete(x.n);
                    x = i < pa.size ? pa[i++] : null;
                    continue;
                }
                if (y != null && y.kind == OpPart.INSERT) {
                    result.insert(y.text);
                    y = j < pb.size ? pb[j++] : null;
                    continue;
                }
                if (x == null || y == null) throw new CollabError.INVALID("the operations do not match");
                if (x.kind == OpPart.RETAIN && y.kind == OpPart.RETAIN) {
                    int m = int.min(x.n, y.n);
                    result.retain(m);
                    x.n -= m;
                    y.n -= m;
                } else if (x.kind == OpPart.INSERT && y.kind == OpPart.DELETE) {
                    int m = int.min(x.n, y.n);
                    x.text = slice(x.text, m, x.n - m);
                    x.n -= m;
                    y.n -= m;
                } else if (x.kind == OpPart.INSERT && y.kind == OpPart.RETAIN) {
                    int m = int.min(x.n, y.n);
                    result.insert(slice(x.text, 0, m));
                    x.text = slice(x.text, m, x.n - m);
                    x.n -= m;
                    y.n -= m;
                } else if (x.kind == OpPart.RETAIN && y.kind == OpPart.DELETE) {
                    int m = int.min(x.n, y.n);
                    result.delete(m);
                    x.n -= m;
                    y.n -= m;
                }
                if (x.n == 0) x = i < pa.size ? pa[i++] : null;
                if (y.n == 0) y = j < pb.size ? pb[j++] : null;
            }
            return result;
        }

        public static void transform(TextOperation a, TextOperation b, out TextOperation a_prime, out TextOperation b_prime) throws CollabError {
            if (a.base_length != b.base_length) throw new CollabError.INVALID("the operations start from different texts");
            var ap = new TextOperation();
            var bp = new TextOperation();
            var pa = copy_parts(a.parts);
            var pb = copy_parts(b.parts);
            int i = 0, j = 0;
            OpPart? x = i < pa.size ? pa[i++] : null;
            OpPart? y = j < pb.size ? pb[j++] : null;
            while (x != null || y != null) {
                if (x != null && x.kind == OpPart.INSERT) {
                    ap.insert(x.text);
                    bp.retain(x.n);
                    x = i < pa.size ? pa[i++] : null;
                    continue;
                }
                if (y != null && y.kind == OpPart.INSERT) {
                    ap.retain(y.n);
                    bp.insert(y.text);
                    y = j < pb.size ? pb[j++] : null;
                    continue;
                }
                if (x == null || y == null) throw new CollabError.INVALID("the operations do not match");
                int m = int.min(x.n, y.n);
                if (x.kind == OpPart.RETAIN && y.kind == OpPart.RETAIN) {
                    ap.retain(m);
                    bp.retain(m);
                } else if (x.kind == OpPart.DELETE && y.kind == OpPart.RETAIN) {
                    ap.delete(m);
                } else if (x.kind == OpPart.RETAIN && y.kind == OpPart.DELETE) {
                    bp.delete(m);
                }
                x.n -= m;
                y.n -= m;
                if (x.n == 0) x = i < pa.size ? pa[i++] : null;
                if (y.n == 0) y = j < pb.size ? pb[j++] : null;
            }
            a_prime = ap;
            b_prime = bp;
        }

        public int transform_position(int pos) {
            int index = 0;
            int result = pos;
            foreach (var p in parts) {
                if (index > pos) break;
                if (p.kind == OpPart.RETAIN) index += p.n;
                else if (p.kind == OpPart.INSERT) result += p.n;
                else {
                    result -= int.min(p.n, pos - index);
                    index += p.n;
                }
            }
            return result;
        }

        public Json.Node to_json() {
            var arr = new Json.Array();
            foreach (var p in parts) {
                if (p.kind == OpPart.RETAIN) arr.add_int_element(p.n);
                else if (p.kind == OpPart.DELETE) arr.add_int_element(-p.n);
                else arr.add_string_element(p.text);
            }
            var node = new Json.Node(Json.NodeType.ARRAY);
            node.set_array(arr);
            return node;
        }

        public static TextOperation from_json(Json.Node node) throws CollabError {
            if (node.get_node_type() != Json.NodeType.ARRAY) throw new CollabError.INVALID("not an operation");
            var op = new TextOperation();
            foreach (var e in node.get_array().get_elements()) {
                if (e.get_value_type() == typeof(string)) op.insert(e.get_string());
                else {
                    int64 v = e.get_int();
                    if (v > 0) op.retain((int) v);
                    else if (v < 0) op.delete((int) (-v));
                }
            }
            return op;
        }
    }

    public class CollabPeer : Object {
        public string id { get; construct; }
        public string name { get; set; default = ""; }
        public string color { get; set; default = "#1c71d8"; }
        public int editor { get; set; default = 0; }
        public int line { get; set; default = -1; }
        public int column { get; set; default = 0; }

        public CollabPeer(string id) {
            Object(id: id);
        }
    }

    public class CollabDoc : Object {
        public string text = "";
        public int revision = 0;
        public Gee.ArrayList<TextOperation> history = new Gee.ArrayList<TextOperation>();
        public Gee.HashMap<string, Soup.WebsocketConnection> sockets = new Gee.HashMap<string, Soup.WebsocketConnection>();
        public Gee.HashMap<string, CollabPeer> peers = new Gee.HashMap<string, CollabPeer>();
        public bool started = false;
    }

    public class CollabServer : Object {
        public string token { get; private set; }
        public uint port { get; private set; default = 0; }
        public signal void document_changed(string doc, string text);

        private Soup.Server server;
        private Gee.HashMap<string, CollabDoc> docs = new Gee.HashMap<string, CollabDoc>();
        private int next_id = 1;

        public CollabServer(string? token = null) {
            this.token = token ?? Uuid.string_random().replace("-", "").substring(0, 20);
            server = new Soup.Server("server-header", "SingularityNotesLive");
            server.add_websocket_handler("/live", null, null, on_socket);
        }

        public void listen(uint want, bool lan) throws Error {
            if (lan) server.listen_all(want, Soup.ServerListenOptions.IPV4_ONLY);
            else server.listen_local(want, Soup.ServerListenOptions.IPV4_ONLY);
            foreach (var uri in server.get_uris()) port = uri.get_port();
        }

        public Soup.Server soup {
            get { return server; }
        }

        public void stop() {
            foreach (var d in docs.values) foreach (var s in d.sockets.values) {
                if (s.state == Soup.WebsocketState.OPEN) s.close(Soup.WebsocketCloseCode.GOING_AWAY, null);
            }
            server.disconnect();
        }

        public string? text_of(string doc) {
            var d = docs[doc];
            return d != null ? d.text : null;
        }

        private static string encode(Json.Object o) {
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            return Json.to_string(node, false);
        }

        private void send(Soup.WebsocketConnection ws, Json.Object o) {
            if (ws.state == Soup.WebsocketState.OPEN) ws.send_text(encode(o));
        }

        private void broadcast(CollabDoc d, Json.Object o, string? except) {
            foreach (var e in d.sockets.entries) if (e.key != except) send(e.value, o);
        }

        private Json.Object peer_json(CollabPeer p) {
            var o = new Json.Object();
            o.set_string_member("id", p.id);
            o.set_string_member("name", p.name);
            o.set_string_member("color", p.color);
            o.set_int_member("editor", p.editor);
            o.set_int_member("line", p.line);
            o.set_int_member("column", p.column);
            return o;
        }

        private void on_socket(Soup.Server srv, Soup.ServerMessage msg, string path, Soup.WebsocketConnection ws) {
            string cid = "c%d".printf(next_id++);
            string? doc_id = null;
            ws.message.connect((type, bytes) => {
                if (type != Soup.WebsocketDataType.TEXT) return;
                string text = ((string) bytes.get_data()).make_valid((ssize_t) bytes.get_size());
                Json.Object o;
                try {
                    var parser = new Json.Parser();
                    parser.load_from_data(text);
                    o = parser.get_root().get_object();
                } catch (Error e) {
                    return;
                }
                string kind = o.has_member("type") ? o.get_string_member("type") : "";
                if (kind == "hello") {
                    if (!o.has_member("token") || o.get_string_member("token") != token) {
                        var err = new Json.Object();
                        err.set_string_member("type", "refused");
                        send(ws, err);
                        ws.close(Soup.WebsocketCloseCode.POLICY_VIOLATION, null);
                        return;
                    }
                    doc_id = o.get_string_member("doc");
                    var d = docs[doc_id];
                    if (d == null) {
                        d = new CollabDoc();
                        docs[doc_id] = d;
                    }
                    if (!d.started && o.has_member("text")) {
                        d.text = o.get_string_member("text");
                        d.started = true;
                    }
                    var peer = new CollabPeer(cid);
                    peer.name = o.has_member("name") ? o.get_string_member("name") : cid;
                    peer.color = o.has_member("color") ? o.get_string_member("color") : "#1c71d8";
                    d.peers[cid] = peer;
                    d.sockets[cid] = ws;
                    var welcome = new Json.Object();
                    welcome.set_string_member("type", "doc");
                    welcome.set_string_member("id", cid);
                    welcome.set_string_member("text", d.text);
                    welcome.set_int_member("rev", d.revision);
                    var arr = new Json.Array();
                    foreach (var p in d.peers.values) if (p.id != cid) arr.add_object_element(peer_json(p));
                    welcome.set_array_member("peers", arr);
                    send(ws, welcome);
                    var joined = new Json.Object();
                    joined.set_string_member("type", "join");
                    joined.set_object_member("peer", peer_json(peer));
                    broadcast(d, joined, cid);
                    return;
                }
                if (doc_id == null) return;
                var d = docs[doc_id];
                if (kind == "op") {
                    try {
                        int rev = (int) o.get_int_member("rev");
                        var op = TextOperation.from_json(o.get_member("op"));
                        if (rev < 0 || rev > d.revision) throw new CollabError.INVALID("bad revision");
                        for (int k = rev; k < d.history.size; k++) {
                            TextOperation a2, b2;
                            TextOperation.transform(op, d.history[k], out a2, out b2);
                            op = a2;
                        }
                        d.text = op.apply(d.text);
                        d.history.add(op);
                        d.revision++;
                        var ack = new Json.Object();
                        ack.set_string_member("type", "ack");
                        ack.set_int_member("rev", d.revision);
                        send(ws, ack);
                        var out_msg = new Json.Object();
                        out_msg.set_string_member("type", "op");
                        out_msg.set_string_member("from", cid);
                        out_msg.set_int_member("rev", d.revision);
                        out_msg.set_member("op", op.to_json());
                        broadcast(d, out_msg, cid);
                        document_changed(doc_id, d.text);
                    } catch (Error e) {
                        var err = new Json.Object();
                        err.set_string_member("type", "resync");
                        err.set_string_member("text", d.text);
                        err.set_int_member("rev", d.revision);
                        send(ws, err);
                    }
                    return;
                }
                if (kind == "cursor") {
                    var p = d.peers[cid];
                    if (p == null) return;
                    p.editor = (int) o.get_int_member("editor");
                    p.line = (int) o.get_int_member("line");
                    p.column = (int) o.get_int_member("column");
                    var c = new Json.Object();
                    c.set_string_member("type", "cursor");
                    c.set_object_member("peer", peer_json(p));
                    broadcast(d, c, cid);
                }
            });
            ws.closed.connect(() => {
                if (doc_id == null) return;
                var d = docs[doc_id];
                if (d == null) return;
                d.sockets.unset(cid);
                d.peers.unset(cid);
                var left = new Json.Object();
                left.set_string_member("type", "leave");
                left.set_string_member("id", cid);
                broadcast(d, left, null);
            });
        }
    }

    public class CollabClient : Object {
        public signal void ready(string text);
        public signal void remote_text(string text, TextOperation op);
        public signal void peers_changed();
        public signal void closed(string reason);

        public string doc { get; construct; }
        public string name { get; construct; }
        public string color { get; construct; }
        public string my_id { get; private set; default = ""; }
        public bool connected { get; private set; default = false; }
        public string text { get; private set; default = ""; }
        public Gee.HashMap<string, CollabPeer> peers = new Gee.HashMap<string, CollabPeer>();

        private Soup.WebsocketConnection? ws = null;
        private int revision = 0;
        private TextOperation? outstanding = null;
        private TextOperation? buffer = null;

        public CollabClient(string doc, string name, string color) {
            Object(doc: doc, name: name, color: color);
        }

        public static string random_color() {
            string[] colors = { "#e01b24", "#2ec27e", "#9141ac", "#ff7800", "#1c71d8", "#c64600", "#26a269", "#813d9c" };
            return colors[Random.int_range(0, colors.length)];
        }

        public static bool parse_link(string link, out string url, out string doc, out string token) {
            url = "";
            doc = "";
            token = "";
            string l = link.strip();
            if (l.has_prefix("notes-live://")) l = "ws://" + l.substring(13);
            try {
                var uri = Uri.parse(l, UriFlags.NONE);
                string? q = uri.get_query();
                if (q == null) return false;
                var p = Uri.parse_params(q, -1, "&", UriParamsFlags.NONE);
                doc = p["doc"] ?? "";
                token = p["token"] ?? "";
                string scheme = uri.get_scheme() == "wss" ? "wss" : "ws";
                url = "%s://%s:%d/live".printf(scheme, uri.get_host(), uri.get_port() > 0 ? uri.get_port() : 7780);
                return doc != "" && token != "";
            } catch (Error e) {
                return false;
            }
        }

        public static string make_link(string host, uint port, string doc, string token) {
            return "notes-live://%s:%u/?doc=%s&token=%s".printf(host, port, Uri.escape_string(doc, null, false), token);
        }

        public async void connect_to(string url, string token, string? initial_text) throws Error {
            var session = new Soup.Session();
            var msg = new Soup.Message("GET", url);
            ws = yield session.websocket_connect_async(msg, null, null, Priority.DEFAULT, null);
            ws.max_incoming_payload_size = 64 * 1024 * 1024;
            ws.message.connect(on_message);
            ws.closed.connect(() => {
                connected = false;
                closed(_("The live session ended"));
            });
            var hello = new Json.Object();
            hello.set_string_member("type", "hello");
            hello.set_string_member("doc", doc);
            hello.set_string_member("token", token);
            hello.set_string_member("name", name);
            hello.set_string_member("color", color);
            if (initial_text != null) hello.set_string_member("text", initial_text);
            send(hello);
        }

        public void disconnect_live() {
            if (ws != null && ws.state == Soup.WebsocketState.OPEN) ws.close(Soup.WebsocketCloseCode.NORMAL, null);
            ws = null;
            connected = false;
        }

        private void send(Json.Object o) {
            if (ws == null || ws.state != Soup.WebsocketState.OPEN) return;
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(o);
            ws.send_text(Json.to_string(node, false));
        }

        private void send_op(TextOperation op) {
            var o = new Json.Object();
            o.set_string_member("type", "op");
            o.set_int_member("rev", revision);
            o.set_member("op", op.to_json());
            send(o);
        }

        public void local_change(string new_text) {
            if (!connected || new_text == text) return;
            var op = TextOperation.diff(text, new_text);
            text = new_text;
            try {
                if (outstanding == null) {
                    outstanding = op;
                    send_op(op);
                } else if (buffer == null) {
                    buffer = op;
                } else {
                    buffer = TextOperation.compose(buffer, op);
                }
            } catch (Error e) {
                warning("notes live: %s", e.message);
            }
        }

        public void send_cursor(int editor, int line, int column) {
            var o = new Json.Object();
            o.set_string_member("type", "cursor");
            o.set_int_member("editor", editor);
            o.set_int_member("line", line);
            o.set_int_member("column", column);
            send(o);
        }

        private CollabPeer peer_from(Json.Object o) {
            string id = o.get_string_member("id");
            var p = peers[id] ?? new CollabPeer(id);
            p.name = o.get_string_member("name");
            p.color = o.get_string_member("color");
            p.editor = (int) o.get_int_member("editor");
            p.line = (int) o.get_int_member("line");
            p.column = (int) o.get_int_member("column");
            peers[id] = p;
            return p;
        }

        private void on_message(int type, Bytes bytes) {
            if (type != Soup.WebsocketDataType.TEXT) return;
            Json.Object o;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(((string) bytes.get_data()).make_valid((ssize_t) bytes.get_size()));
                o = parser.get_root().get_object();
            } catch (Error e) {
                return;
            }
            string kind = o.get_string_member("type");
            try {
                switch (kind) {
                    case "doc":
                        my_id = o.get_string_member("id");
                        text = o.get_string_member("text");
                        revision = (int) o.get_int_member("rev");
                        peers.clear();
                        foreach (var e in o.get_array_member("peers").get_elements()) peer_from(e.get_object());
                        connected = true;
                        ready(text);
                        peers_changed();
                        break;
                    case "refused":
                        closed(_("The live session link is not valid"));
                        break;
                    case "ack":
                        revision = (int) o.get_int_member("rev");
                        outstanding = buffer;
                        buffer = null;
                        if (outstanding != null) send_op(outstanding);
                        break;
                    case "op":
                        var op = TextOperation.from_json(o.get_member("op"));
                        revision = (int) o.get_int_member("rev");
                        if (outstanding != null) {
                            TextOperation a2, b2;
                            TextOperation.transform(outstanding, op, out a2, out b2);
                            outstanding = a2;
                            op = b2;
                            if (buffer != null) {
                                TextOperation c2, d2;
                                TextOperation.transform(buffer, op, out c2, out d2);
                                buffer = c2;
                                op = d2;
                            }
                        }
                        text = op.apply(text);
                        remote_text(text, op);
                        break;
                    case "resync":
                        text = o.get_string_member("text");
                        revision = (int) o.get_int_member("rev");
                        outstanding = null;
                        buffer = null;
                        remote_text(text, new TextOperation());
                        break;
                    case "join":
                    case "cursor":
                        peer_from(o.get_object_member("peer"));
                        peers_changed();
                        break;
                    case "leave":
                        peers.unset(o.get_string_member("id"));
                        peers_changed();
                        break;
                    default:
                        break;
                }
            } catch (Error e) {
                warning("notes live: %s", e.message);
            }
        }
    }
}
