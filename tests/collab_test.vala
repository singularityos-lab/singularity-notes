using Singularity.Apps.Notes;

string random_text(int n) {
    string[] pieces = { "a", "b", "c", " ", "\n", "è", "ü", "# ", "- [ ] ", "€" };
    var sb = new StringBuilder();
    for (int i = 0; i < n; i++) sb.append(pieces[Random.int_range(0, pieces.length)]);
    return sb.str;
}

TextOperation random_op(string text) {
    var op = new TextOperation();
    int len = text.char_count();
    int left = len;
    while (left > 0) {
        int n = Random.int_range(1, int.min(left, 6) + 1);
        int r = Random.int_range(0, 4);
        if (r == 0) op.insert(random_text(Random.int_range(1, 5)));
        else if (r == 1) {
            op.delete(n);
            left -= n;
        } else {
            op.retain(n);
            left -= n;
        }
    }
    if (Random.boolean()) op.insert(random_text(2));
    return op;
}

void test_transform_converges() {
    Random.set_seed(42);
    for (int i = 0; i < 2000; i++) {
        string s = random_text(Random.int_range(0, 40));
        var a = random_op(s);
        var b = random_op(s);
        TextOperation a2, b2;
        try {
            TextOperation.transform(a, b, out a2, out b2);
            string left = b2.apply(a.apply(s));
            string right = a2.apply(b.apply(s));
            assert(left == right);
            var ab = TextOperation.compose(a, b2);
            assert(ab.apply(s) == left);
            var round = TextOperation.from_json(a.to_json());
            assert(round.apply(s) == a.apply(s));
        } catch (Error e) {
            error("%s", e.message);
        }
    }
}

void test_diff() {
    Random.set_seed(7);
    for (int i = 0; i < 1000; i++) {
        string s = random_text(Random.int_range(0, 30));
        string t = random_text(Random.int_range(0, 30));
        try {
            assert(TextOperation.diff(s, t).apply(s) == t);
        } catch (Error e) {
            error("%s", e.message);
        }
    }
    var op = TextOperation.diff("hello world", "hello brave world");
    assert(op.transform_position(8) == 14);
    assert(op.transform_position(2) == 2);
}

bool spin_until(owned SourceFunc done, int ms) {
    int64 end = get_monotonic_time() + ms * 1000;
    var ctx = MainContext.default();
    while (!done()) {
        if (get_monotonic_time() > end) return false;
        ctx.iteration(false);
        Thread.usleep(1000);
    }
    return true;
}

void test_live_session() {
    var server = new CollabServer("secret");
    try {
        server.listen(0, false);
    } catch (Error e) {
        error("%s", e.message);
    }
    string url = "ws://127.0.0.1:%u/live".printf(server.port);
    string link = CollabClient.make_link("127.0.0.1", server.port, "Work/Plan", "secret");
    string lurl, ldoc, ltoken;
    assert(CollabClient.parse_link(link, out lurl, out ldoc, out ltoken));
    assert(lurl == url && ldoc == "Work/Plan" && ltoken == "secret");

    string start = "# Plan\n\nFirst line\nSecond line\n";
    var clients = new CollabClient[3];
    string[] names = { "Ada", "Bob", "Cy" };
    for (int i = 0; i < 3; i++) {
        clients[i] = new CollabClient("Work/Plan", names[i], CollabClient.random_color());
        var c = clients[i];
        c.connect_to.begin(url, "secret", i == 0 ? start : null, (o, r) => {
            try {
                c.connect_to.end(r);
            } catch (Error e) {
                error("%s", e.message);
            }
        });
        assert(spin_until(() => c.connected, 5000));
    }
    assert(clients[1].text == start && clients[2].text == start);
    assert(spin_until(() => clients[0].peers.size == 2 && clients[1].peers.size == 2, 5000));

    clients[0].local_change("# Plan\n\nFirst line from Ada\nSecond line\n");
    clients[1].local_change("# Plan\n\nFirst line\nSecond line, Bob agrees\n");
    clients[2].local_change("# Plan for Monday\n\nFirst line\nSecond line\n");
    clients[0].local_change("# Plan\n\nFirst line from Ada!\nSecond line\n");
    Random.set_seed(3);
    for (int round = 0; round < 30; round++) {
        var c = clients[round % 3];
        string t = c.text;
        string edited;
        if (round % 4 == 3 && (t.has_suffix("x") || t.has_suffix("y") || t.has_suffix("z"))) edited = t.substring(0, t.length - 1);
        else edited = t + "xyz"[round % 3:round % 3 + 1];
        c.local_change(edited);
        if (round % 5 == 0) MainContext.default().iteration(false);
    }
    clients[1].send_cursor(0, 3, 7);
    assert(spin_until(() => {
        string? st = server.text_of("Work/Plan");
        return st != null && clients[0].text == st && clients[1].text == st && clients[2].text == st && clients[2].peers.has_key(clients[1].my_id) && clients[2].peers[clients[1].my_id].line == 3;
    }, 10000));
    string fin = server.text_of("Work/Plan");
    assert(fin.contains("First line from Ada!"));
    assert(fin.contains("Bob agrees"));
    assert(fin.contains("Plan for Monday"));
    var cp = clients[2].peers[clients[1].my_id];
    assert(cp.name == "Bob" && cp.column == 7);

    var intruder = new CollabClient("Work/Plan", "Eve", "#000000");
    bool refused = false;
    intruder.closed.connect(() => refused = true);
    intruder.connect_to.begin(url, "wrong", null, (o, r) => {
        try {
            intruder.connect_to.end(r);
        } catch (Error e) {
            refused = true;
        }
    });
    assert(spin_until(() => refused, 5000));
    assert(!intruder.connected);

    clients[2].disconnect_live();
    assert(spin_until(() => clients[0].peers.size == 1, 5000));
    foreach (var c in clients) c.disconnect_live();
    server.stop();
}

class Fetch : Object {
    public Soup.Session session = new Soup.Session();
    public uint status;
    public string body = "";
    public string location = "";

    public void run(string method, string url, string? form = null) {
        var msg = new Soup.Message(method, url);
        if (form != null) msg.set_request_body_from_bytes("application/x-www-form-urlencoded", new Bytes(form.data));
        bool done = false;
        session.send_and_read_async.begin(msg, Priority.DEFAULT, null, (o, r) => {
            try {
                var b = session.send_and_read_async.end(r);
                body = (string) b.get_data();
                if (body == null) body = "";
                body = body.make_valid((ssize_t) b.get_size());
            } catch (Error e) {
                body = "";
            }
            status = msg.get_status();
            location = msg.get_response_headers().get_one("Location") ?? "";
            done = true;
        });
        assert(spin_until(() => done, 10000));
    }
}

void test_web_access() {
    string dir;
    try {
        dir = DirUtils.make_tmp("notes-web-XXXXXX");
    } catch (Error e) {
        error("%s", e.message);
    }
    var store = new Singularity.Notes.NoteStore(dir);
    store.ensure_dir();
    var nb = new Notebooks(dir);
    nb.load();
    Singularity.Notes.Note page;
    try {
        page = store.create("# Shopping\n\n- [ ] Milk\n- [x] Bread\n\n**Bold** words and a <u>line</u>.\n", "Home/Lists");
        store.create("# Diary\n\n<!-- notes-locked v1 -->\nciphertext\n", "Private");
    } catch (Error e) {
        error("%s", e.message);
    }
    var web = new WebAccess(store, nb);
    try {
        web.start(0, false);
    } catch (Error e) {
        error("%s", e.message);
    }
    string base_url = "http://127.0.0.1:%u".printf(web.port);
    var f = new Fetch();
    f.run("GET", base_url + "/");
    assert(f.status == 401);
    assert(!f.body.contains("Shopping"));
    f.run("POST", base_url + "/login", "pin=000000x");
    assert(f.status == 403);

    var g = new Fetch();
    g.session.add_feature(new Soup.CookieJar());
    g.run("POST", base_url + "/login", "pin=" + web.pin);
    assert(g.status == 200);
    assert(g.body.contains("Shopping") && g.body.contains("Home / Lists"));
    assert(g.body.contains("Password protected"));

    var h = new Fetch();
    h.session.add_feature(new Soup.CookieJar());
    h.run("GET", web.link());
    assert(h.status == 200 && h.body.contains("Shopping"));
    h.run("GET", base_url + "/page?id=" + page.id);
    assert(h.status == 200);
    assert(h.body.contains("<strong>Bold</strong>") && h.body.contains("checkbox"));
    h.run("GET", base_url + "/?q=milk");
    assert(h.body.contains("Shopping") && !h.body.contains("Diary"));

    string base64 = Base64.encode(page.body.data);
    string mine = page.body.replace("Milk", "Oat milk");
    var remote = page.copy();
    remote.body = page.body + "\nAdded on the computer\n";
    try {
        store.save(remote);
    } catch (Error e) {
        error("%s", e.message);
    }
    h.run("POST", base_url + "/edit?id=" + page.id, "base=%s&body=%s".printf(Uri.escape_string(base64, null, false), Uri.escape_string(mine, null, false)));
    assert(h.status == 200);
    var saved = store.lookup(page.id);
    assert(saved.body.contains("Oat milk"));
    assert(saved.body.contains("Added on the computer"));

    foreach (var n in store.all()) if (n.title == "Diary") {
        h.run("GET", base_url + "/page?id=" + n.id);
        assert(h.body.contains("password-protected") && !h.body.contains("ciphertext"));
        h.run("GET", base_url + "/edit?id=" + n.id);
        assert(h.status == 404);
    }

    int before = store.all().size;
    h.run("GET", base_url + "/new?folder=" + Uri.escape_string("Home/Lists", null, false));
    assert(h.status == 200 && h.body.contains("textarea"));
    assert(store.all().size == before + 1);
    web.stop();
}

int run_bot(string link, string name, string typed, int seconds) {
    string url, doc, token;
    if (!CollabClient.parse_link(link, out url, out doc, out token)) return 2;
    var c = new CollabClient(doc, name, "#e01b24");
    var loop = new MainLoop();
    c.connect_to.begin(url, token, null, (o, r) => {
        try {
            c.connect_to.end(r);
        } catch (Error e) {
            printerr("%s\n", e.message);
            loop.quit();
        }
    });
    c.closed.connect(() => loop.quit());
    c.ready.connect((text) => {
        string[] lines = text.split("\n");
        int target = int.min(4, lines.length - 1);
        int at = 0;
        for (int i = 0; i < target; i++) at += lines[i].length + 1;
        int col = lines[target].char_count();
        int step = 0;
        int editor_line = int.max(0, target - 1);
        c.send_cursor(0, editor_line, col);
        Timeout.add(180, () => {
            if (step >= typed.char_count()) return Source.REMOVE;
            string t = c.text;
            string[] ls = t.split("\n");
            int pos = 0;
            for (int i = 0; i < target && i < ls.length; i++) pos += ls[i].length + 1;
            pos += lines[target].length + typed.substring(0, typed.index_of_nth_char(step)).length;
            string ch = typed.substring(typed.index_of_nth_char(step), typed.index_of_nth_char(step + 1) - typed.index_of_nth_char(step));
            if (pos <= t.length) c.local_change(t.substring(0, pos) + ch + t.substring(pos));
            step++;
            c.send_cursor(0, editor_line, col + step);
            return Source.CONTINUE;
        });
        Timeout.add_seconds(seconds, () => {
            print("%s", c.text);
            loop.quit();
            return Source.REMOVE;
        });
    });
    loop.run();
    c.disconnect_live();
    return 0;
}

public int main(string[] args) {
    if (args.length >= 5 && args[1] == "--bot") return run_bot(args[2], args[3], args[4], args.length > 5 ? int.parse(args[5]) : 20);
    Test.init(ref args);
    Test.add_func("/notes/collab/transform", test_transform_converges);
    Test.add_func("/notes/collab/diff", test_diff);
    Test.add_func("/notes/collab/live", test_live_session);
    Test.add_func("/notes/collab/web", test_web_access);
    return Test.run();
}
