using Singularity.Apps.Notes;
using Singularity.Notes;

private string scratch() {
    try {
        return DirUtils.make_tmp("notes-format-XXXXXX");
    } catch (FileError e) {
        error("%s", e.message);
    }
}

private string fixture(string name) {
    return Path.build_filename(Environment.get_variable("NOTES_FIXTURES") ?? "tests/fixtures", name);
}

private NoteStore open_store(string dir) {
    var store = new NoteStore(dir);
    store.legacy_data_dir = dir + "/none";
    store.legacy_documents_dir = dir + "/none";
    store.load();
    return store;
}

private void same(string md) {
    string back = RichText.render(RichText.parse(md));
    if (back != md) error("round trip failed:\n[%s]\n[%s]", md, back);
}

private void test_rich_round_trip() {
    same("#### Four\n##### Five\n###### Six");
    same("> a quote with **bold**\n```vala\nint x = 1;\n  indented\n```\nafter");
    same("1. one\n2. two\n    - nested bullet\n    1. nested number\n3. three");
    same("- [ ] [!important] call **Anna**\n[!question] [!idea] why not <a id=\"p-1a2b3c4d\"></a>");
    same("<u>under</u> ~~gone~~ ==marked== <mark style=\"background:#8ff0a4\">green</mark> `mono`");
    same("<span style=\"color:#e01b24;font-family:Serif;font-size:18pt\">red serif</span> plain");
    same("&emsp;&emsp;indented paragraph");
    same("[file.pdf](attachments/n1/file.pdf)\n[Audio recording](attachments/n1/recording-1.ogg)\n---");
    same("<img src=\"attachments/n1/photo.png\" alt=\"A &quot;cat&quot;\" width=\"240\">\n![Drawing](attachments/n1/ink-abc.svg)\n![x^2](attachments/n1/equation-1.png)");
    same("<!-- table shading=\"0:0:#fff3bf,1:1:#d0ebff\" -->\n| A | B \\| C |\n| --- | :---: |\n| 1 | 2<br>3 |");
    same("see [the page](note:abc#p-12345678) and [section](section:Work/Ideas)");
    same("a \\<b> not html and 2 \\== 3 and a\\~~b");
    same("1\\. not a list\n\\> not a quote\n\\| not a table");
}

private void test_rich_blocks() {
    var b = RichText.parse("  - [x] [!critical] done <a id=\"p-9\"></a>");
    assert(b.size == 1);
    assert(b[0].kind == BlockKind.CHECK && b[0].checked);
    assert(b[0].tags.length == 1 && b[0].tags[0] == "critical");
    assert(b[0].anchor == "p-9");
    assert(b[0].plain_text() == "done");
    var t = RichText.parse("| x | y |\n| --- | --- |\n| 10 | b |\n| 2 | a |")[0];
    assert(t.kind == BlockKind.TABLE && t.table.rows.size == 3 && t.table.columns == 2);
    t.table.sort_by(0, false, true);
    assert(t.table.cell(1, 0) == "2" && t.table.cell(2, 0) == "10");
    var s = RichText.parse("**b** <span style=\"color:#123456\">c</span>")[0];
    assert(s.spans[0].bold && s.spans[2].color == "#123456");
    var ink = RichText.parse("![Drawing](attachments/a/ink-1.svg)")[0];
    assert(ink.kind == BlockKind.INK);
    var nums = RichText.parse("1. a\n1. b\n    1. c\n1. d");
    int[] n = RichText.numbering(nums);
    assert(n[0] == 1 && n[1] == 2 && n[2] == 1 && n[3] == 3);
}

private void test_page_doc() {
    string text = "# Plan\nbody line\n<!-- page level=1 order=3 bg=yellow rule=grid -->";
    var d = PageDoc.parse(text);
    assert(d.title == "Plan");
    assert(d.body == "body line");
    assert(d.meta.level == 1 && d.meta.order == 3 && d.meta.background == "yellow" && d.meta.rule == "grid");
    assert(d.serialize() == text);
    string canvas = "# Board\n<!-- block x=\"40\" y=\"30\" w=\"300\" -->\nfirst\n<!-- /block -->\n<!-- block x=\"400\" y=\"10\" w=\"200\" -->\n- second\n<!-- /block -->\n<!-- page layout=canvas ink=attachments/n/ink-1.svg -->";
    var c = PageDoc.parse(canvas);
    assert(c.meta.is_canvas && c.containers.size == 2);
    assert(c.containers[1].x == 400 && c.containers[1].markdown == "- second");
    assert(c.serialize() == canvas);
    assert(c.flow_markdown() == "- second\n\nfirst");
    assert(PageDoc.title_of("plain first line\nsecond") == "plain first line");
    assert(PageDoc.snippet_of("# T\n**bold** text\n<!-- page level=2 -->") == "bold text");
}

private void test_notebooks_tree_and_merge() {
    string dir = scratch();
    var nb = new Notebooks(dir);
    var folders = new Gee.ArrayList<string>();
    folders.add("Work/Projects/Alpha");
    folders.add("Work/Inbox");
    folders.add("Home");
    var tree = nb.tree(folders);
    assert(tree.size == 2);
    FolderNode? work = null;
    foreach (var n in tree) if (n.path == "Work") work = n;
    assert(work != null && work.kind == FolderKind.NOTEBOOK);
    FolderNode? projects = null;
    foreach (var n in work.children) if (n.path == "Work/Projects") projects = n;
    assert(projects != null && projects.kind == FolderKind.GROUP);
    assert(projects.children[0].kind == FolderKind.SECTION);
    nb.set_color("Work/Inbox", "#e01b24");
    nb.reorder(new Gee.ArrayList<string>.wrap({ "Work/Projects", "Work/Inbox" }));
    tree = nb.tree(folders);
    foreach (var n in tree) if (n.path == "Work") assert(n.children[0].path == "Work/Projects");
    nb.rename_prefix("Work", "Job");
    assert(nb.peek("Job/Inbox") != null && nb.peek("Job/Inbox").color == "#e01b24" && nb.peek("Work/Inbox") == null);
    string local = "{\"folders\":{\"A\":{\"color\":\"#111111\"}},\"tags\":[{\"id\":\"custom-x\",\"label\":\"X\"}]}";
    string remote = "{\"folders\":{\"A\":{\"lock\":{\"salt\":\"s\",\"check\":\"c\"}},\"B\":{\"order\":2}},\"tags\":[{\"id\":\"custom-y\",\"label\":\"Y\"}]}";
    string merged = Notebooks.merge_json(local, remote);
    assert(merged.contains("\"B\"") && merged.contains("\"lock\"") && merged.contains("custom-x") && merged.contains("custom-y"));
}

private void test_tags_index() {
    var hits = TagIndex.scan("n1", "# T\n- [ ] open task\n- [x] closed\n[!important] key point\n[!question] [!idea] hmm");
    int todo = 0, open = 0, important = 0, idea = 0;
    foreach (var h in hits) {
        if (h.tag == "todo") {
            todo++;
            if (!h.done) open++;
        }
        if (h.tag == "important") important++;
        if (h.tag == "idea") idea++;
    }
    assert(todo == 2 && open == 1 && important == 1 && idea == 1);
}

private void test_ink_svg_and_shapes() {
    var doc = new InkDoc();
    var s = new Stroke();
    s.color = "#1c71d8";
    s.width = 3;
    for (int i = 0; i <= 20; i++) s.points.add(new InkPoint(10 + i * 5, 20 + i * 5.02));
    doc.strokes.add(s);
    var h = new Stroke();
    h.tool = "highlighter";
    h.opacity = 0.4;
    h.width = 16;
    h.points.add(new InkPoint(1, 1));
    h.points.add(new InkPoint(50, 1));
    doc.strokes.add(h);
    var back = InkDoc.parse(doc.to_svg());
    assert(back.strokes.size == 2);
    assert(back.strokes[0].points.size == 21 && back.strokes[1].tool == "highlighter");
    assert((back.strokes[1].opacity - 0.4).abs() < 0.01);
    var line = ShapeRecognizer.recognize(back.strokes[0]);
    assert(line != null && line.shape == "line");
    var circle = new Stroke();
    for (int i = 0; i <= 60; i++) {
        double a = 2 * Math.PI * i / 60;
        circle.points.add(new InkPoint(100 + 40 * Math.cos(a), 100 + 30 * Math.sin(a)));
    }
    var e = ShapeRecognizer.recognize(circle);
    assert(e != null && e.shape == "ellipse");
    var square = new Stroke();
    double[,] corners = { { 0, 0 }, { 80, 0 }, { 80, 80 }, { 0, 80 }, { 0, 0 } };
    for (int c = 0; c < 4; c++) {
        for (int k = 0; k < 20; k++) {
            double t = k / 20.0;
            square.points.add(new InkPoint(corners[c, 0] + (corners[c + 1, 0] - corners[c, 0]) * t, corners[c, 1] + (corners[c + 1, 1] - corners[c, 1]) * t));
        }
    }
    square.points.add(new InkPoint(0, 1));
    var r = ShapeRecognizer.recognize(square);
    assert(r != null && r.shape == "rect");
    var tri = new Stroke();
    double[,] tc = { { 50, 0 }, { 100, 90 }, { 0, 90 }, { 50, 0 } };
    for (int c = 0; c < 3; c++) {
        for (int k = 0; k < 20; k++) {
            double t = k / 20.0;
            tri.points.add(new InkPoint(tc[c, 0] + (tc[c + 1, 0] - tc[c, 0]) * t, tc[c, 1] + (tc[c + 1, 1] - tc[c, 1]) * t));
        }
    }
    tri.points.add(new InkPoint(50, 1));
    var tr = ShapeRecognizer.recognize(tri);
    assert(tr != null && tr.shape == "triangle");
    assert(ShapeRecognizer.point_in_polygon(5, 5, new Gee.ArrayList<InkPoint>.wrap({ new InkPoint(0, 0), new InkPoint(10, 0), new InkPoint(10, 10), new InkPoint(0, 10) })));
}

private void test_math() {
    try {
        var a = MathSolver.solve("2x + 3 = 11");
        assert(a.answer == "x = 4");
        var q = MathSolver.solve("x^2 - 5x + 6 = 0");
        assert(q.roots.size == 2 && q.answer.contains("2") && q.answer.contains("3"));
        var v = MathSolver.solve("\\frac{1}{2} + 2*3");
        assert(v.answer.has_suffix("= 6.5"));
        var s = MathSolver.solve("sin(x) = 0.5");
        bool found = false;
        foreach (var r in s.roots) if ((r - Math.PI / 6).abs() < 1e-6) found = true;
        assert(found);
        var f = MathSolver.solve("x^2 - 4");
        assert(f.function != null && f.roots.size == 2);
        var img = MathSolver.plot(f.function, f.roots, 200, 120);
        assert(img.get_width() == 200);
        var complex = MathSolver.solve("x^2 + 1 = 0");
        assert(complex.answer.contains("i"));
    } catch (MathError e) {
        error("%s", e.message);
    }
}

private void test_locks() {
    string dir = scratch();
    var nb = new Notebooks(dir);
    var locks = new SectionLocks(nb);
    locks.set_password("Secret", "correct horse");
    string sealed_body = locks.encrypt("Secret/Sub", "# Diary\nprivate words") ?? "";
    assert(SectionLocks.is_locked_body(sealed_body));
    assert(!sealed_body.contains("private words"));
    assert(locks.decrypt("Secret/Sub", sealed_body) == "# Diary\nprivate words");
    locks.lock_all();
    assert(!locks.is_unlocked("Secret"));
    assert(locks.decrypt("Secret", sealed_body) == null);
    assert(!locks.unlock("Secret", "wrong"));
    assert(locks.unlock("Secret", "correct horse"));
    assert(locks.decrypt("Secret", sealed_body) == "# Diary\nprivate words");
    var again = new SectionLocks(new Notebooks(dir));
    assert(again.unlock("Secret", "correct horse"));
    assert(SectionLocks.decrypt_with_password("correct horse", nb.info("Secret").lock_salt, sealed_body) == "# Diary\nprivate words");
    string other = locks.encrypt("Secret", "# Diary\nchanged elsewhere") ?? "";
    string mine = locks.encrypt("Secret", "# Diary\nchanged here") ?? "";
    assert(SyncMerge.merge_text(sealed_body, sealed_body, other) == other);
    assert(SyncMerge.merge_text(sealed_body, mine, sealed_body) == mine);
    assert(SyncMerge.merge_text(sealed_body, mine, other) == null);
}

private void test_locked_attachments() {
    string dir = scratch();
    var nb = new Notebooks(dir);
    var locks = new SectionLocks(nb);
    locks.set_password("Vault", "pw");
    string att = Path.build_filename(dir, "attachments", "n1");
    DirUtils.create_with_parents(att, 0700);
    try {
        FileUtils.set_contents(Path.build_filename(att, "secret.png"), "PNGDATA secret pixels");
        FileUtils.set_contents(Path.build_filename(att, "recording-1.ogg"), "audio");
        FileUtils.set_contents(Path.build_filename(att, "recording-1.ogg.json"), "{\"transcript\": \"private words\"}");
    } catch (FileError e) {
        error("%s", e.message);
    }
    string plain = "# Vault page\n![s](attachments/n1/secret.png)\n[Audio](attachments/n1/recording-1.ogg)";
    var files = new LockedFiles(locks, dir);
    string suffix = files.commit("Vault", "n1", plain);
    assert(suffix.contains("locked=attachments/n1/secret.png.locked") && suffix.contains("recording-1.ogg.json.locked"));
    assert(!FileUtils.test(Path.build_filename(att, "secret.png"), FileTest.EXISTS));
    assert(!FileUtils.test(Path.build_filename(att, "recording-1.ogg.json"), FileTest.EXISTS));
    string sealed_raw;
    try {
        FileUtils.get_contents(Path.build_filename(att, "secret.png.locked"), out sealed_raw);
    } catch (FileError e) {
        error("%s", e.message);
    }
    assert(!sealed_raw.contains("secret pixels"));
    string body = (locks.encrypt("Vault", plain) ?? "") + suffix;
    assert(locks.decrypt("Vault", body) == plain);
    var links = NoteAttachments.links(body);
    assert(links.contains("attachments/n1/secret.png.locked") && links.contains("attachments/n1/recording-1.ogg.locked"));
    files.prepare("Vault", "n1", plain);
    string opened;
    try {
        FileUtils.get_contents(Path.build_filename(files.root, "attachments", "n1", "secret.png"), out opened);
    } catch (FileError e) {
        error("%s", e.message);
    }
    assert(opened == "PNGDATA secret pixels");
    assert(FileUtils.test(Path.build_filename(files.root, "attachments", "n1", "recording-1.ogg.json"), FileTest.EXISTS));
    files.wipe();
    assert(!FileUtils.test(Path.build_filename(files.root, "attachments"), FileTest.EXISTS));
    locks.lock_all();
    files.prepare("Vault", "n1", plain);
    assert(!FileUtils.test(Path.build_filename(files.root, "attachments", "n1", "secret.png"), FileTest.EXISTS));
    assert(locks.unlock("Vault", "pw"));
    files.unprotect("Vault", "n1", plain);
    assert(FileUtils.test(Path.build_filename(att, "secret.png"), FileTest.EXISTS) && !FileUtils.test(Path.build_filename(att, "secret.png.locked"), FileTest.EXISTS));
    files.destroy_all();
}

private void test_history_and_trash() {
    string dir = scratch();
    var store = open_store(dir);
    try {
        var n = store.create("# One\nfirst", "S");
        var h = new History(dir);
        assert(h.record(n.id, n.serialize(), true));
        Thread.usleep(1100000);
        n.body = "# One\nsecond";
        store.save(n);
        assert(h.record(n.id, n.serialize(), true));
        var versions = h.list(n.id);
        assert(versions.size == 2);
        assert(versions[0].text().contains("second") && versions[1].text().contains("first"));
        assert(versions[0].author != "");
        var trash = new Trash(dir);
        trash.put(n);
        store.remove(n.id);
        assert(store.lookup(n.id) == null);
        var items = trash.items();
        assert(items.size == 1 && items[0].title() == "One" && items[0].folder == "S");
        var restored = trash.restore(n.id, store);
        assert(restored != null && store.lookup(n.id) != null && trash.items().size == 0);
        trash.put(store.lookup(n.id));
        store.remove(n.id);
        trash.delete_forever(n.id);
        assert(trash.items().size == 0 && h.list(n.id).size == 0);
    } catch (Error e) {
        error("%s", e.message);
    }
}

private string pandoc_markdown(string path) {
    string? pandoc = Environment.find_program_in_path("pandoc");
    if (pandoc == null) return "";
    string out_text;
    int status;
    try {
        Process.spawn_sync(null, { pandoc, "-t", "plain", path }, null, SpawnFlags.STDERR_TO_DEV_NULL, null, out out_text, null, out status);
    } catch (Error e) {
        return "";
    }
    return status == 0 ? out_text : "";
}

private Exporter sample_export(string dir) throws Error {
    var store = open_store(dir);
    var n = store.create("", "S");
    string att = Path.build_filename(dir, "attachments", n.id);
    DirUtils.create_with_parents(att, 0700);
    var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, 40, 20);
    var cr = new Cairo.Context(surface);
    cr.set_source_rgb(0.2, 0.5, 0.9);
    cr.paint();
    surface.write_to_png(Path.build_filename(att, "pic.png"));
    surface.write_to_png(Path.build_filename(att, "equation-1.png"));
    FileUtils.set_contents(Path.build_filename(att, "equation-1.mml"), "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><msup><mi>x</mi><mn>2</mn></msup><mo>=</mo><mn>4</mn></math>");
    var ink = new InkDoc();
    var s = new Stroke();
    s.points.add(new InkPoint(2, 2));
    s.points.add(new InkPoint(30, 30));
    ink.strokes.add(s);
    ink.save(Path.build_filename(att, "ink-a.svg"));
    string body = "# Export Me\n## Heading\nSome **bold** and *italic* and <u>under</u> and ~~strike~~ and [a link](https://example.org).\n- bullet one\n    - nested\n1. first\n2. second\n- [x] done task\n[!important] tagged line\n> quoted text\n| Name | Value |\n| --- | --- |\n| Alpha | 1 |\n![Blue](attachments/%s/pic.png)\n![Drawing](attachments/%s/ink-a.svg)\n![x^2=4](attachments/%s/equation-1.png)\n```\ncode line\n```".printf(n.id, n.id, n.id);
    var ex = new Exporter(dir);
    ex.pages.add(new ExportPage(n.id, "Export Me", 1790000000, body));
    ex.pages.add(new ExportPage("p2", "Second Page", 1790000100, "# Second Page\njust text"));
    return ex;
}

private void test_export_formats() {
    string dir = scratch();
    try {
        var ex = sample_export(dir);
        string pdf = Path.build_filename(dir, "out.pdf");
        ex.write(ExportFormat.PDF, pdf);
        uint8[] data;
        FileUtils.get_data(pdf, out data);
        assert(data.length > 1000 && data[0] == '%' && data[1] == 'P' && data[2] == 'D' && data[3] == 'F');
        var doc = new Poppler.Document.from_gfile(File.new_for_path(pdf), null, null);
        assert(doc.get_n_pages() == 2);
        string text = doc.get_page(0).get_text();
        assert(text.contains("Export Me") && text.contains("Alpha") && text.contains("Important"));
        string html = Path.build_filename(dir, "out.html");
        ex.write(ExportFormat.HTML, html);
        string h;
        FileUtils.get_contents(html, out h);
        assert(h.contains("<strong>bold</strong>") && h.contains("<table>") && h.contains("data:image/png;base64,") && h.contains("<ol>") && h.contains("checkbox"));
        assert(h.contains("<math") && h.contains("<msup>"));
        string md = Path.build_filename(dir, "out.md");
        ex.write(ExportFormat.MARKDOWN, md);
        string m;
        FileUtils.get_contents(md, out m);
        assert(m.contains("out_files/pic.png") && FileUtils.test(Path.build_filename(dir, "out_files", "pic.png"), FileTest.EXISTS));
        string odt = Path.build_filename(dir, "out.odt");
        ex.write(ExportFormat.ODT, odt);
        FileUtils.get_data(odt, out data);
        var zip = new ZipReader(data);
        assert(zip.read_text("mimetype") == "application/vnd.oasis.opendocument.text");
        string content = zip.read_text("content.xml");
        assert(content.contains("Export Me") && content.contains("table:table") && content.contains("draw:image"));
        assert(content.contains("draw:object xlink:href=\"./Object 1\"") && zip.read_text("Object 1/content.xml").contains("<msup>"));
        assert(zip.read_text("META-INF/manifest.xml").contains("application/vnd.oasis.opendocument.formula"));
        Xml.Doc* x = Xml.Parser.read_memory(content, content.length);
        assert(x != null);
        delete x;
        string docx = Path.build_filename(dir, "out.docx");
        ex.write(ExportFormat.DOCX, docx);
        FileUtils.get_data(docx, out data);
        zip = new ZipReader(data);
        string wdoc = zip.read_text("word/document.xml");
        assert(wdoc.contains("Export Me") && wdoc.contains("<w:tbl>") && wdoc.contains("w:drawing") && wdoc.contains("<w:b/>"));
        assert(wdoc.contains("m:oMath") && wdoc.contains("m:sSup"));
        x = Xml.Parser.read_memory(wdoc, wdoc.length);
        assert(x != null);
        delete x;
        string numbering = zip.read_text("word/numbering.xml");
        assert(numbering.contains("decimal"));
        string p1 = pandoc_markdown(docx);
        if (p1 != "") assert(p1.contains("Heading") && p1.contains("Alpha") && p1.contains("bold") && p1.contains("1.  first") && p1.contains("x²"));
        string p2 = pandoc_markdown(odt);
        if (p2 != "") assert(p2.contains("Export Me") && p2.contains("Alpha") && p2.contains("quoted text") && p2.contains("1.  first"));
        string back = Importer.docx_to_markdown(data, dir, "imp");
        assert(back.contains("Export Me") && back.contains("**bold**") && back.contains("| Alpha | 1 |"));
        string png = Path.build_filename(dir, "out.png");
        ex.write(ExportFormat.PNG, png);
        var pix = new Gdk.Pixbuf.from_file(Path.build_filename(dir, "out-1.png"));
        assert(pix.width == 1190 && FileUtils.test(Path.build_filename(dir, "out-2.png"), FileTest.EXISTS));
        ex.cleanup();
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_print_pagination() {
    string dir = scratch();
    var r = new NoteRenderer(dir);
    var sb = new StringBuilder("# Long\n");
    for (int i = 0; i < 400; i++) sb.append("Line number %d with some words to wrap around the page width\n".printf(i));
    r.pages.add(new ExportPage("x", "Long", 0, sb.str));
    int pages = r.paginate(595, 842, 56, 56, 56, 56);
    assert(pages > 5);
    var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, 595, 842);
    r.render_page(new Cairo.Context(surface), pages - 1);
}

private void test_import_real_files() {
    string dir = scratch();
    var store = open_store(dir);
    var loop = new MainLoop();
    Gee.List<ImportedNote>? got = null;
    Error? err = null;
    Importer.import_file.begin(File.new_for_path(fixture("sample.enex")), store, "Imported", (o, r) => {
        try {
            got = Importer.import_file.end(r);
        } catch (Error e) {
            err = e;
        }
        loop.quit();
    });
    loop.run();
    if (err != null) error("%s", err.message);
    assert(got.size == 2);
    Note? trip = null;
    foreach (var n in store.all()) if (PageDoc.title_of(n.body) == "Trip checklist") trip = n;
    assert(trip != null && trip.folder == "Imported");
    assert(trip.body.contains("- [x] Book the hotel") && trip.body.contains("- [ ] Pack the **charger**"));
    assert(trip.body.contains("[the map](https://example.org/map)"));
    assert(trip.body.contains("![") && trip.body.contains("attachments/" + trip.id + "/red.png"));
    assert(FileUtils.test(Path.build_filename(dir, "attachments", trip.id, "red.png"), FileTest.EXISTS));
    assert(trip.body.contains("| Day | City |"));
    assert(trip.body.contains("Tags: travel, todo"));
    assert(new DateTime.from_unix_utc(trip.created).get_day_of_month() == 10);
    uint8[] data;
    try {
        FileUtils.get_data(fixture("pandoc-sample.docx"), out data);
        string md = Importer.docx_to_markdown(data, dir, "d1");
        assert(md.contains("## Introduction") && md.contains("**bold**") && md.contains("First bullet") && md.contains("| Alpha | 1 |"));
        FileUtils.get_data(fixture("pandoc-sample.odt"), out data);
        string om = Importer.odt_to_markdown(data, dir, "o1");
        assert(om.contains("Introduction") && om.contains("First bullet") && om.contains("Alpha"));
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_html_to_markdown() {
    string html = "<html><head><title>Clip Title</title><script>bad()</script></head><body><nav>menu</nav><article><h1>Main</h1><p>Hello <b>world</b> and <a href=\"/rel\">rel link</a>.</p><ul><li>one<ul><li>two</li></ul></li></ul><pre><code>x = 1\ny = 2</code></pre><img src=\"pic.png\" alt=\"P\"><blockquote>Q</blockquote></article><footer>foot</footer></body></html>";
    var c = new HtmlConverter();
    c.base_url = "https://site.test/a/page.html";
    c.convert(html, true);
    string md = RichText.render(c.blocks);
    assert(c.title == "Clip Title");
    assert(!md.contains("bad()") && !md.contains("menu") && !md.contains("foot"));
    assert(md.contains("## Main") && md.contains("Hello **world**") && md.contains("[rel link](https://site.test/rel)"));
    assert(md.contains("- one") && md.contains("    - two"));
    assert(md.contains("```\nx = 1\ny = 2\n```"));
    assert(md.contains("> Q"));
    assert(c.images.size == 1 && c.images[0].src == "https://site.test/a/pic.png");
}

private void test_templates() {
    string dir = scratch();
    var t = new Templates(dir);
    assert(t.builtin().size >= 8);
    foreach (var tpl in t.builtin()) {
        var d = PageDoc.parse(tpl.instantiate());
        assert(d.title != "");
    }
    try {
        t.save("My Weekly", "# My Weekly\n- [ ] review");
    } catch (Error e) {
        error("%s", e.message);
    }
    var custom = t.custom();
    assert(custom.size == 1 && custom[0].name == "My Weekly" && custom[0].custom);
    t.remove(custom[0]);
    assert(t.custom().size == 0);
    var canvas = PageDoc.parse(t.builtin()[7].instantiate());
    assert(canvas.meta.is_canvas && canvas.containers.size == 2);
}

private void test_attachment_links() {
    var l = NoteAttachments.links("![a](attachments/n/a.png)\n[f.pdf](attachments/n/f.pdf)\n<img src=\"attachments/n/b.png\" width=\"9\">\n<!-- page ink=attachments/n/ink-1.svg -->");
    assert(l.contains("attachments/n/a.png") && l.contains("attachments/n/f.pdf") && l.contains("attachments/n/b.png") && l.contains("attachments/n/ink-1.svg"));
    string[] side = NoteAttachments.sidecars("recording-1.ogg");
    assert(side.length == 1 && side[0] == "recording-1.ogg.json");
    string replaced = NoteAttachments.replace_link("<img src=\"attachments/n/b.png\">", "attachments/n/b.png", ".attachments.7/b.png");
    assert(replaced == "<img src=\".attachments.7/b.png\">");
}

private void test_recording_info() {
    string dir = scratch();
    string media = Path.build_filename(dir, "recording-1.ogg");
    var info = new RecordingInfo();
    info.path = media;
    info.mark(1.5, "first line");
    info.mark(4.0, "second line");
    info.mark(5.0, "first line");
    info.transcript = "hello world";
    info.save();
    var back = RecordingInfo.load(media);
    assert(back.marks.size == 2 && back.transcript == "hello world");
    assert(back.time_of("second line") == 4.0);
    assert(back.texts_until(4.5, 6).size == 2);
    assert(back.texts_until(2.0, 6).size == 1);
}

private void test_pdf_printout() {
    string dir = scratch();
    try {
        var ex = new Exporter(dir);
        ex.pages.add(new ExportPage("a", "Printed", 0, "# Printed\nhello printout"));
        string pdf = Path.build_filename(dir, "in.pdf");
        ex.write(ExportFormat.PDF, pdf);
        var pages = Attachments.pdf_printout(dir, "note1", pdf);
        assert(pages.size == 1 && pages[0].has_prefix("attachments/note1/printout-in-1"));
        var pix = new Gdk.Pixbuf.from_file(Path.build_filename(dir, pages[0]));
        assert(pix.width > 500);
        assert(Attachments.pdf_text(pdf).contains("hello printout"));
        var doc_pages = Attachments.document_printout(dir, "note2", fixture("pandoc-sample.docx"));
        assert(doc_pages.size >= 1 && doc_pages[0].has_prefix("attachments/note2/printout-pandoc-sample-1"));
        var dpix = new Gdk.Pixbuf.from_file(Path.build_filename(dir, doc_pages[0]));
        assert(dpix.width > 800);
    } catch (Error e) {
        error("%s", e.message);
    }
}

private void test_ocr() {
    if (!OcrIndex.get_default().available) {
        Test.skip("no text recognition engine");
        return;
    }
    string dir = scratch();
    string att = Path.build_filename(dir, "attachments", "o1");
    DirUtils.create_with_parents(att, 0700);
    string img = Path.build_filename(att, "scan.png");
    var surface = new Cairo.ImageSurface(Cairo.Format.RGB24, 900, 200);
    var cr = new Cairo.Context(surface);
    cr.set_source_rgb(1, 1, 1);
    cr.paint();
    cr.set_source_rgb(0, 0, 0);
    cr.select_font_face("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
    cr.set_font_size(48);
    cr.move_to(30, 120);
    cr.show_text("Quarterly Revenue Report");
    surface.write_to_png(img);
    var loop = new MainLoop();
    string? text = null;
    OcrIndex.get_default().recognize.begin(img, (o, r) => {
        text = OcrIndex.get_default().recognize.end(r);
        loop.quit();
    });
    loop.run();
    assert(text != null && text.contains("Quarterly") && text.contains("Revenue"));
    assert(OcrIndex.cached_text(img) == text);
    string body = "# Scan\n![scan](attachments/o1/scan.png)";
    assert(OcrIndex.media_text(dir, body).contains("Revenue"));
    var ink = new InkDoc();
    var stroke = new Stroke();
    stroke.points.add(new InkPoint(10, 10));
    stroke.points.add(new InkPoint(10, 60));
    ink.strokes.add(stroke);
    double ox, oy;
    var rendered = ink.render(null, 2.0, out ox, out oy);
    assert(rendered.get_width() > 20);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/format/rich-round-trip", test_rich_round_trip);
    Test.add_func("/format/rich-blocks", test_rich_blocks);
    Test.add_func("/format/page-doc", test_page_doc);
    Test.add_func("/format/notebooks", test_notebooks_tree_and_merge);
    Test.add_func("/format/tags", test_tags_index);
    Test.add_func("/format/ink", test_ink_svg_and_shapes);
    Test.add_func("/format/math", test_math);
    Test.add_func("/format/locks", test_locks);
    Test.add_func("/format/locked-attachments", test_locked_attachments);
    Test.add_func("/format/history-trash", test_history_and_trash);
    Test.add_func("/format/export", test_export_formats);
    Test.add_func("/format/print-pagination", test_print_pagination);
    Test.add_func("/format/import", test_import_real_files);
    Test.add_func("/format/html", test_html_to_markdown);
    Test.add_func("/format/templates", test_templates);
    Test.add_func("/format/attachment-links", test_attachment_links);
    Test.add_func("/format/recording-info", test_recording_info);
    Test.add_func("/format/pdf-printout", test_pdf_printout);
    Test.add_func("/format/ocr", test_ocr);
    return Test.run();
}
