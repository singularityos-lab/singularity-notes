using Singularity.Apps.Notes;
using Singularity.Notes;

private int failures = 0;

private void check(bool ok, string what) {
    if (ok) {
        print("ok   %s\n", what);
    } else {
        print("FAIL %s\n", what);
        failures++;
    }
}

private NoteStore store_at(string dir) {
    var s = new NoteStore(dir);
    s.legacy_data_dir = dir + "/none";
    s.legacy_documents_dir = dir + "/none";
    s.load();
    return s;
}

private void write_png(string path, double r, double g, double b) {
    DirUtils.create_with_parents(Path.get_dirname(path), 0700);
    var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, 24, 12);
    var cr = new Cairo.Context(surface);
    cr.set_source_rgb(r, g, b);
    cr.paint();
    surface.write_to_png(path);
}

private Note? by_title(NoteStore s, string title, SectionLocks? locks = null) {
    foreach (var n in s.all()) {
        string body = n.body;
        if (locks != null && SectionLocks.is_locked_body(body)) body = locks.decrypt(n.folder, body) ?? body;
        if (PageDoc.title_of(body) == title) return n;
    }
    return null;
}

private async void run(string account_id, string root) throws Error {
    var mgr = Singularity.Accounts.Manager.get_default();
    yield mgr.load();
    var account = mgr.get_account(account_id);
    if (account == null) throw new IOError.NOT_FOUND("no account " + account_id);
    NotesRemote remote;
    if (account.has_capability(Singularity.Accounts.Capability.NOTES) && account.get_endpoint("notes") != null) remote = new NextcloudNotesRemote(account);
    else remote = new WebDavNotesRemote(account);
    print("remote %s for %s\n", remote.kind, account.display_name);

    string dir_a = Path.build_filename(root, "device-a");
    string dir_b = Path.build_filename(root, "device-b");
    var a = store_at(dir_a);
    var b = store_at(dir_b);

    var nb_a = new Notebooks(dir_a);
    nb_a.info("Work/Launch").kind_id = "section";
    nb_a.info("Work/Launch").color = "#e01b24";
    nb_a.custom_tags.add("custom-follow-up");
    nb_a.custom_tag_labels["custom-follow-up"] = "Follow up";
    nb_a.save();
    var locks_a = new SectionLocks(nb_a);
    locks_a.set_password("Private", "sesame");

    var plan = a.create("", "Work/Launch");
    string att = Attachments.dir_for(dir_a, plan.id);
    write_png(Path.build_filename(att, "chart.png"), 0.2, 0.4, 0.9);
    var ink = new InkDoc();
    var st = new Stroke();
    st.points.add(new InkPoint(1, 1));
    st.points.add(new InkPoint(40, 30));
    ink.strokes.add(st);
    ink.save(Path.build_filename(att, "ink-e2e.svg"));
    FileUtils.set_contents(Path.build_filename(att, "recording-e2e.ogg"), "OggS fake audio payload");
    var info = new RecordingInfo();
    info.path = Path.build_filename(att, "recording-e2e.ogg");
    info.mark(2.5, "Line written while recording");
    info.transcript = "hello from the recording";
    info.save();
    write_png(Path.build_filename(att, "equation-e2e.png"), 1, 1, 1);
    FileUtils.set_contents(Path.build_filename(att, "equation-e2e.mml"), "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</mi><mo>=</mo><mn>1</mn></math>");
    FileUtils.set_contents(Path.build_filename(att, "brief.pdf"), "%PDF-1.4 fake");
    string body = "# Launch plan\n[!important] Ship the **beta**\nLine written while recording\n- [ ] book call\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        + "![Chart](attachments/%s/chart.png)\n![Drawing](attachments/%s/ink-e2e.svg)\n[Audio recording](attachments/%s/recording-e2e.ogg)\n![x=1](attachments/%s/equation-e2e.png)\n[brief.pdf](attachments/%s/brief.pdf)\n<!-- page order=1 -->".printf(
        plan.id, plan.id, plan.id, plan.id, plan.id);
    plan.body = body;
    a.save(plan);
    var secret = a.create(locks_a.encrypt("Private", "# Diary\nsecret words") ?? "", "Private");
    var gone = a.create("# To be deleted\nbye", "Work/Launch");

    var eng_a = new SyncEngine(a, remote, Path.build_filename(root, "state-a.json"));
    var rep = yield eng_a.sync(null);
    print("device A first sync: %s\n", rep.describe());
    check(rep.uploaded == 3, "device A uploads three pages");

    var eng_b = new SyncEngine(b, remote, Path.build_filename(root, "state-b.json"));
    rep = yield eng_b.sync(null);
    print("device B first sync: %s\n", rep.describe());
    check(rep.downloaded >= 3, "device B downloads the three pages");
    var nb_b = new Notebooks(dir_b);
    check(nb_b.peek("Work/Launch") != null && nb_b.peek("Work/Launch").color == "#e01b24", "section color reaches device B");
    check(nb_b.custom_tags.contains("custom-follow-up"), "custom tag reaches device B");
    check(nb_b.peek("Private") != null && nb_b.peek("Private").lock_check != "", "section lock reaches device B");
    var locks_b = new SectionLocks(nb_b);
    check(!locks_b.unlock("Private", "wrong"), "wrong password refused on device B");
    check(locks_b.unlock("Private", "sesame"), "password unlocks on device B");
    var secret_b = by_title(b, "Diary", locks_b);
    check(secret_b != null && !secret_b.body.contains("secret words") && locks_b.decrypt(secret_b.folder, secret_b.body) == "# Diary\nsecret words", "locked page stays encrypted on the server and opens on device B");

    var plan_b = by_title(b, "Launch plan");
    check(plan_b != null && plan_b.folder == "Work/Launch", "page and section reach device B");
    if (plan_b != null) {
        var links = NoteAttachments.links(plan_b.body);
        int present = 0;
        foreach (string l in links) if (FileUtils.test(Path.build_filename(dir_b, l), FileTest.IS_REGULAR)) present++;
        check(links.size == 5 && present == 5, "picture, drawing, recording, equation and file reach device B (%d/%d)".printf(present, links.size));
        string rec = "";
        string mml = "";
        foreach (string l in links) {
            if (l.contains("recording-")) rec = Path.build_filename(dir_b, l);
            if (l.contains("equation-")) mml = EquationFiles.stem(Path.build_filename(dir_b, l)) + ".mml";
        }
        var rinfo = RecordingInfo.load(rec);
        check(rinfo.transcript == "hello from the recording" && rinfo.time_of("Line written while recording") == 2.5, "recording marks and transcript reach device B");
        check(FileUtils.test(mml, FileTest.IS_REGULAR), "equation MathML reaches device B");
        string ink_path = "";
        foreach (string l in links) if (l.contains("ink-")) ink_path = Path.build_filename(dir_b, l);
        check(InkDoc.load(ink_path).strokes.size == 1, "drawing strokes readable on device B");
        check(PageDoc.parse(plan_b.body).meta.order == 1 && plan_b.body.contains("[!important]"), "tags and page order survive the trip");

        plan_b.body = plan_b.body.replace("- [ ] book call", "- [x] book call");
        b.save(plan_b);
        rep = yield eng_b.sync(null);
        print("device B edit: %s\n", rep.describe());
        rep = yield eng_a.sync(null);
        print("device A pull: %s\n", rep.describe());
        var plan_a = a.lookup(plan.id);
        check(plan_a.body.contains("- [x] book call"), "edit on device B reaches device A");

        plan_a.body = plan_a.body.replace("Ship the **beta**", "Ship the **beta** in October");
        a.save(plan_a);
        plan_b = b.lookup(plan_b.id);
        plan_b.body = plan_b.body.replace("| 1 | 2 |", "| 1 | 3 |");
        b.save(plan_b);
        rep = yield eng_a.sync(null);
        rep = yield eng_b.sync(null);
        print("concurrent edits: %s\n", rep.describe());
        plan_b = b.lookup(plan_b.id);
        check(plan_b.body.contains("in October") && plan_b.body.contains("| 1 | 3 |"), "edits of different lines merge on device B");
        rep = yield eng_a.sync(null);
        check(a.lookup(plan.id).body.contains("| 1 | 3 |"), "merged page reaches device A");
    }

    a.remove(gone.id);
    rep = yield eng_a.sync(null);
    rep = yield eng_b.sync(null);
    check(by_title(b, "To be deleted") == null, "deletion on device A reaches device B");

    var secret_a = a.lookup(secret.id);
    secret_a.body = locks_a.encrypt("Private", "# Diary\nsecret words\nmore from A") ?? "";
    a.save(secret_a);
    secret_b = by_title(b, "Diary", locks_b);
    secret_b.body = locks_b.encrypt("Private", "# Diary\nsecret words\nmore from B") ?? "";
    b.save(secret_b);
    rep = yield eng_a.sync(null);
    rep = yield eng_b.sync(null);
    print("locked conflict: %s\n", rep.describe());
    int diaries = 0;
    foreach (var n in b.all()) {
        string plain = locks_b.decrypt(n.folder, n.body) ?? n.body;
        if (plain.contains("more from A") || plain.contains("more from B")) diaries++;
    }
    check(rep.conflicts >= 1 && diaries >= 1, "conflicting edits of a locked page keep a copy instead of mixing ciphertext");
}

private async void run_shared(string account_id, string root) throws Error {
    var mgr = Singularity.Accounts.Manager.get_default();
    var account = mgr.get_account(account_id);
    string dir_a = Path.build_filename(root, "shared-a");
    string dir_c = Path.build_filename(root, "shared-c");
    var a = store_at(dir_a);
    var c = store_at(dir_c);
    var mine = a.create("# Private idea\nonly mine", "Personal");
    var team = a.create("# Team agenda\n- [ ] budget\n- [ ] hiring", "Team/Planning");
    var main_a = new SyncEngine(a, new WebDavNotesRemote(account), Path.build_filename(root, "shared-main-a.json"));
    main_a.exclude_prefixes = { "Team" };
    var share_a = new SyncEngine(a, new WebDavNotesRemote(account, "Shared Notebooks/Team"), Path.build_filename(root, "shared-team-a.json"));
    share_a.include_prefix = "Team";
    share_a.sync_notebooks = false;
    yield main_a.sync(null);
    var rep = yield share_a.sync(null);
    check(rep.uploaded == 1, "shared notebook uploads only its own page");
    var share_c = new SyncEngine(c, new WebDavNotesRemote(account, "Shared Notebooks/Team"), Path.build_filename(root, "shared-team-c.json"));
    share_c.include_prefix = "Team";
    share_c.sync_notebooks = false;
    rep = yield share_c.sync(null);
    var got = by_title(c, "Team agenda");
    check(rep.downloaded == 1 && got != null && got.folder == "Team/Planning", "a second person opens the shared notebook");
    check(by_title(c, "Private idea") == null, "private pages stay out of the shared notebook");
    got.body = got.body.replace("- [ ] budget", "- [x] budget");
    c.save(got);
    Thread.usleep(1100000);
    yield share_c.sync(null);
    yield share_a.sync(null);
    check(a.lookup(team.id).body.contains("- [x] budget"), "an edit by the second person reaches the owner");
    var moved = a.lookup(mine.id);
    moved.folder = "Team/Planning";
    a.save(moved);
    yield main_a.sync(null);
    yield share_a.sync(null);
    yield share_c.sync(null);
    check(by_title(c, "Private idea") != null, "a page moved into the shared notebook reaches the second person");
    var remote_a = new WebDavNotesRemote(account, "Shared Notebooks/Team");
    var remote_c = new WebDavNotesRemote(account, "Shared Notebooks/Team");
    yield remote_a.put_presence("Anna Rossi", team.id, null);
    yield remote_c.put_presence("Luca Bianchi", got.id, null);
    var seen = yield remote_c.list_presence(null);
    bool anna = false;
    foreach (var p in seen) if (p.name == "Anna Rossi" && p.page == team.id && (get_real_time() / 1000000 - p.time) < 60) anna = true;
    check(anna && seen.size == 2, "presence: the second person sees who is on which page");
}

public int main(string[] args) {
    string? id = Environment.get_variable("NOTES_E2E_ACCOUNT");
    string? root = Environment.get_variable("NOTES_E2E_DIR");
    if (id == null || root == null) {
        print("skip: set NOTES_E2E_ACCOUNT and NOTES_E2E_DIR\n");
        return 77;
    }
    var loop = new MainLoop();
    Error? err = null;
    run.begin(id, root, (o, r) => {
        try {
            run.end(r);
        } catch (Error e) {
            err = e;
        }
        if (err != null || Environment.get_variable("NOTES_E2E_SHARED") != "1") {
            loop.quit();
            return;
        }
        run_shared.begin(id, root, (o2, r2) => {
            try {
                run_shared.end(r2);
            } catch (Error e) {
                err = e;
            }
            loop.quit();
        });
    });
    loop.run();
    if (err != null) {
        print("ERROR %s\n", err.message);
        return 1;
    }
    print("%s\n", failures == 0 ? "ALL PASSED" : "%d FAILED".printf(failures));
    return failures == 0 ? 0 : 1;
}
