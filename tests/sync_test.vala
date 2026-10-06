using Singularity.Apps.Notes;
using Singularity.Notes;

private NoteState st(string content, string folder = "", bool pinned = false) {
    return new NoteState(content, folder, pinned);
}

private void test_new_notes() {
    var up = SyncMerge.decide(null, st("a"), null);
    assert(up.create_remote && !up.write_local);
    var down = SyncMerge.decide(null, null, st("b"));
    assert(down.write_local && !down.create_remote);
    var same = SyncMerge.decide(null, st("c"), st("c"));
    assert(same.describe() == "none");
    var clash = SyncMerge.decide(null, st("mine"), st("theirs"));
    assert(clash.write_local && clash.conflict_copy == "mine" && clash.result.content == "theirs");
}

private void test_one_side_changed() {
    var b = st("Title\nbody");
    var l = SyncMerge.decide(b, st("Title\nbody changed"), b.copy());
    assert(l.write_remote && !l.write_local && l.result.content == "Title\nbody changed");
    var r = SyncMerge.decide(b, b.copy(), st("Title\nremote"));
    assert(r.write_local && !r.write_remote && r.result.content == "Title\nremote");
    var none = SyncMerge.decide(b, b.copy(), b.copy());
    assert(none.describe() == "none");
}

private void test_deletions() {
    var b = st("x");
    var ld = SyncMerge.decide(b, null, b.copy());
    assert(ld.delete_remote && ld.forget);
    var rd = SyncMerge.decide(b, b.copy(), null);
    assert(rd.delete_local && rd.forget);
    var restore = SyncMerge.decide(b, null, st("x edited"));
    assert(restore.write_local && !restore.delete_remote && restore.result.content == "x edited");
    var recreate = SyncMerge.decide(b, st("x mine"), null);
    assert(recreate.create_remote && !recreate.delete_local);
    var both = SyncMerge.decide(b, null, null);
    assert(both.forget && !both.delete_local && !both.delete_remote);
}

private void test_rename_and_move_merge() {
    var b = st("Old title\nline two\nline three", "Inbox", false);
    var local = st("New title\nline two\nline three", "Inbox", false);
    var remote = st("Old title\nline two\nline three", "Archive", true);
    var d = SyncMerge.decide(b, local, remote);
    assert(d.conflict_copy == null);
    assert(d.result.content == "New title\nline two\nline three");
    assert(d.result.folder == "Archive");
    assert(d.result.pinned);
    assert(d.write_local && d.write_remote);
    var both_moved = SyncMerge.decide(b, st(b.content, "Work"), st(b.content, "Home"));
    assert(both_moved.result.folder == "Home");
}

private void test_three_way_text() {
    string base_text = "a\nb\nc\nd\ne";
    assert(SyncMerge.merge_text(base_text, "A\nb\nc\nd\ne", "a\nb\nc\nd\nE") == "A\nb\nc\nd\nE");
    assert(SyncMerge.merge_text(base_text, "a\nb\nx\nc\nd\ne", "a\nb\nc\nd\ne\ny") == "a\nb\nx\nc\nd\ne\ny");
    assert(SyncMerge.merge_text(base_text, "a\nc\nd\ne", "a\nb\nc\nd\nE") == "a\nc\nd\nE");
    assert(SyncMerge.merge_text(base_text, "a\nB1\nc\nd\ne", "a\nB2\nc\nd\ne") == null);
    assert(SyncMerge.merge_text(base_text, "a\nSAME\nc\nd\ne", "a\nSAME\nc\nd\ne") == "a\nSAME\nc\nd\ne");
    var d = SyncMerge.decide(st(base_text), st("a\nmine\nc\nd\ne"), st("a\ntheirs\nc\nd\ne"));
    assert(d.conflict_copy == "a\nmine\nc\nd\ne");
    assert(d.result.content == "a\ntheirs\nc\nd\ne");
    assert(d.write_local && !d.write_remote);
}

public class MemoryRemote : Object, NotesRemote {
    public Gee.HashMap<string, RemoteNote> notes = new Gee.HashMap<string, RemoteNote>();
    public int next = 1;
    public int fetches = 0;
    public string kind { get { return "memory"; } }

    private string new_etag() {
        return Uuid.string_random().substring(0, 8);
    }

    public RemoteNote put_note(NoteState s) {
        var r = new RemoteNote();
        r.remote_id = "%d".printf(next++);
        r.etag = new_etag();
        r.state = s.copy();
        notes[r.remote_id] = r;
        return r;
    }

    public void edit(string id, NoteState s) {
        notes[id].state = s.copy();
        notes[id].etag = new_etag();
    }

    public async Gee.List<RemoteNote> list(Gee.Map<string, string> known_etags, Cancellable? cancellable) throws Error {
        var l = new Gee.ArrayList<RemoteNote>();
        foreach (var r in notes.values) {
            var c = new RemoteNote();
            c.remote_id = r.remote_id;
            c.etag = r.etag;
            if (known_etags[r.remote_id] != r.etag) {
                c.state = r.state.copy();
                fetches++;
            }
            l.add(c);
        }
        return l;
    }

    public async RemoteNote create(string local_id, NoteState state, int64 modified, Cancellable? cancellable) throws Error {
        return put_note(state);
    }

    public async RemoteNote update(string remote_id, string etag, NoteState state, int64 modified, Cancellable? cancellable) throws Error {
        var r = notes[remote_id];
        if (r == null) throw new RemoteError.FAILED("gone");
        if (r.etag != etag) throw new RemoteError.CHANGED("changed");
        edit(remote_id, state);
        return notes[remote_id];
    }

    public async void remove(string remote_id, string etag, Cancellable? cancellable) throws Error {
        notes.unset(remote_id);
    }
}

private SyncReport run_sync(SyncEngine engine) {
    var loop = new MainLoop();
    SyncReport? report = null;
    Error? failure = null;
    engine.sync.begin(null, (o, res) => {
        try {
            report = engine.sync.end(res);
        } catch (Error e) {
            failure = e;
        }
        loop.quit();
    });
    loop.run();
    if (failure != null) error("sync failed: %s", failure.message);
    return report;
}

private void test_engine_round_trip() {
    string dir;
    try {
        dir = DirUtils.make_tmp("notes-sync-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
    var store = new NoteStore(dir);
    var remote = new MemoryRemote();
    remote.put_note(st("Shopping\n- bread", "", false));
    var ideas = remote.put_note(st("Ideas\nfirst", "Work", true));
    Note local_note;
    try {
        local_note = store.create("Local only\ntext", "Home");
    } catch (Error e) {
        error("%s", e.message);
    }
    string state_path = SyncEngine.state_path_for(store, "acct");
    var engine = new SyncEngine(store, remote, state_path);

    var r1 = run_sync(engine);
    assert(r1.uploaded == 1 && r1.downloaded == 2);
    assert(store.all().size == 3 && remote.notes.size == 3);
    Note? local_ideas = null;
    foreach (var n in store.all()) if (n.title == "Ideas") local_ideas = n;
    assert(local_ideas != null && local_ideas.folder == "Work" && local_ideas.pinned);

    var r2 = run_sync(new SyncEngine(store, remote, state_path));
    assert(r2.describe() == "up=0 down=0 del-local=0 del-remote=0 merged=0 conflicts=0");

    remote.edit(ideas.remote_id, st("Ideas\nfirst\nsecond from server", "Work", true));
    local_ideas.body = "Ideas renamed\nfirst";
    try {
        store.save(local_ideas);
    } catch (Error e) {
        error("%s", e.message);
    }
    var r3 = run_sync(engine);
    assert(r3.merged == 1 && r3.conflicts == 0);
    assert(store.lookup(local_ideas.id).body == "Ideas renamed\nfirst\nsecond from server");
    assert(remote.notes[ideas.remote_id].state.content == "Ideas renamed\nfirst\nsecond from server");

    remote.edit(ideas.remote_id, st("Ideas renamed\nserver wins\nsecond from server", "Work", true));
    var mine = store.lookup(local_ideas.id);
    mine.body = "Ideas renamed\nlocal wins\nsecond from server";
    try {
        store.save(mine);
    } catch (Error e) {
        error("%s", e.message);
    }
    int before = remote.notes.size;
    var r4 = run_sync(engine);
    assert(r4.conflicts == 1);
    assert(store.lookup(local_ideas.id).body == "Ideas renamed\nserver wins\nsecond from server");
    bool copy_found = false;
    foreach (var n in store.all()) {
        if (n.body == "Ideas renamed (Conflicted Copy)\nlocal wins\nsecond from server") copy_found = true;
    }
    assert(copy_found);
    assert(remote.notes.size == before + 1);

    try {
        store.remove(local_note.id);
    } catch (Error e) {
        error("%s", e.message);
    }
    string shopping_remote = "";
    foreach (var r in remote.notes.values) if (r.state.content.has_prefix("Shopping")) shopping_remote = r.remote_id;
    remote.notes.unset(shopping_remote);
    int local_before = store.all().size;
    var r5 = run_sync(engine);
    assert(r5.deleted_remote == 1 && r5.deleted_local == 1);
    assert(store.all().size == local_before - 1);
    foreach (var r in remote.notes.values) assert(!r.state.content.has_prefix("Local only"));
    assert(remote.notes.size == store.all().size);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/sync/new-notes", test_new_notes);
    Test.add_func("/sync/one-side-changed", test_one_side_changed);
    Test.add_func("/sync/deletions", test_deletions);
    Test.add_func("/sync/rename-and-move", test_rename_and_move_merge);
    Test.add_func("/sync/three-way-text", test_three_way_text);
    Test.add_func("/sync/engine-round-trip", test_engine_round_trip);
    return Test.run();
}
