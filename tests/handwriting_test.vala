using Singularity.Apps.Notes;

const string INK_FONT = "Z003";
const string PRINT_FONT = "Nimbus Sans";
const string[] TEMPLATE_FONTS = { "DejaVu Serif Italic", "DejaVu Sans Oblique", "Liberation Serif Italic" };
const string[] WORDS = { "hello", "world", "notes", "meeting", "budget", "friday", "garden", "project", "simple", "letter", "coffee", "window", "number", "morning", "summer", "travel" };
const string[] DISTRACTORS = { "yellow", "would", "nature", "melting", "bridge", "finally", "golden", "protect", "sample", "better", "office", "widow", "member", "warning", "summit", "gravel", "call", "cold", "tell", "me", "we", "to", "tomorrow", "borrow", "morrow", "calm", "cell", "mile" };
const string[] LINES = { "call me tomorrow", "hello garden world", "coffee meeting friday", "travel budget notes", "simple number window" };
const string UJI_SOURCE = "UJI Pen Characters (Version 2), UCI Machine Learning Repository, https://doi.org/10.24432/C5FG8S, https://archive.ics.uci.edu/dataset/177/uji+pen+characters+version+2";
const string UJI_LICENSE = "Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/";
const string INK_FIXTURE_LICENSE = "Mozilla Public License 2.0, from msiemens/onenote.rs, https://mozilla.org/MPL/2.0/";

HandwritingRecognizer make_recognizer() {
    var r = new HandwritingRecognizer();
    r.user_path = Path.build_filename(Environment.get_tmp_dir(), "notes-handwriting-test-%u.json".printf(Random.next_int()));
    FileUtils.unlink(r.user_path);
    r.set_fonts(TEMPLATE_FONTS);
    var lex = new Gee.ArrayList<string>();
    foreach (string w in WORDS) lex.add(w);
    foreach (string w in DISTRACTORS) lex.add(w);
    r.add_words(lex);
    r.use_dictionary = false;
    return r;
}

double run_words(HandwritingRecognizer r, bool connect, string font, double slant) {
    int ok = 0;
    uint32 seed = 7;
    foreach (string w in WORDS) {
        var ink = HandwritingRecognizer.synthesize(w, font, 48, slant, 1.2, connect, seed++);
        string got = r.recognize(ink);
        if (got == w) ok++;
        else print("  miss: %s read as %s\n", w, got);
    }
    return (double) ok / WORDS.length;
}

void test_cursive_words() {
    var r = make_recognizer();
    double acc = run_words(r, true, INK_FONT, 0.18);
    print("cursive word accuracy (ink %s, templates %s): %.0f%% of %d\n", INK_FONT, string.joinv(", ", TEMPLATE_FONTS), acc * 100, WORDS.length);
    assert(WORDS.length >= 10);
    assert(acc >= 0.8);
}

void test_cursive_lines() {
    var r = make_recognizer();
    int ok = 0;
    int words = 0;
    int word_ok = 0;
    double worst = 0;
    uint32 seed = 99;
    foreach (string line in LINES) {
        var ink = HandwritingRecognizer.synthesize(line, INK_FONT, 48, 0.15, 1.0, true, seed++);
        var timer = new Timer();
        string got = r.recognize(ink);
        worst = double.max(worst, timer.elapsed());
        if (got == line) ok++;
        var want = line.split(" ");
        var have = got.split(" ");
        for (int i = 0; i < want.length; i++) {
            words++;
            if (i < have.length && have[i] == want[i]) word_ok++;
        }
        print("  line \"%s\" read as \"%s\"\n", line, got);
    }
    print("cursive lines: %d of %d exact, words %d of %d, slowest %.2f s\n", ok, LINES.length, word_ok, words, worst);
    assert(ok >= 3);
    assert(word_ok >= words * 0.8);
    assert(worst < 2.0);
}

void test_two_lines() {
    var r = make_recognizer();
    var ink = HandwritingRecognizer.synthesize("hello world", INK_FONT, 48, 0.12, 1.0, true, 5);
    foreach (var s in HandwritingRecognizer.synthesize("garden project", INK_FONT, 48, 0.12, 1.0, true, 6)) {
        s.translate(0, 110);
        ink.add(s);
    }
    string got = r.recognize(ink);
    print("two lines read as \"%s\"\n", got.replace("\n", " / "));
    assert(got == "hello world\ngarden project");
}

void test_printed_words() {
    var r = make_recognizer();
    double acc = run_words(r, false, PRINT_FONT, 0.0);
    print("printed word accuracy (ink %s, separate letters): %.0f%%\n", PRINT_FONT, acc * 100);
    assert(acc >= 0.8);
}

void test_dictionary() {
    string dic = "/usr/share/hunspell/en_US.dic";
    if (!FileUtils.test(dic, FileTest.EXISTS)) {
        Test.skip("no en_US dictionary");
        return;
    }
    var r = new HandwritingRecognizer();
    r.set_fonts(TEMPLATE_FONTS);
    r.load_dic(dic);
    int top1 = 0;
    int top5 = 0;
    var timer = new Timer();
    uint32 seed = 3;
    string[] words = { "hello", "world", "garden", "coffee", "window", "number", "summer", "travel" };
    foreach (string w in words) {
        var ink = HandwritingRecognizer.synthesize(w, INK_FONT, 48, 0.15, 1.0, true, seed++);
        var cands = r.recognize_word_candidates(ink, 5);
        var names = new Gee.ArrayList<string>();
        foreach (var c in cands) names.add(c.text.down());
        if (names.size > 0 && names[0] == w) top1++;
        if (names.contains(w)) top5++;
    }
    print("dictionary only (%d words, no note lexicon): top1 %d of %d, top5 %d of %d, %.2f s\n", r.dictionary_size(), top1, words.length, top5, words.length, timer.elapsed());
    assert(r.dictionary_size() > 10000);
    assert(top1 >= 1);
}

Gee.ArrayList<Stroke> odd_shape(double jitter, uint32 seed) {
    var rand = new Rand.with_seed(seed);
    var s = new Stroke();
    for (int i = 0; i <= 60; i++) {
        double t = i / 60.0;
        double x = 10 + t * 120;
        double y = 40 + 25 * Math.sin(t * 5 * Math.PI) * (1 - t) + (i % 7 == 0 ? 12 : 0);
        s.points.add(new InkPoint(x + rand.double_range(-jitter, jitter), y + rand.double_range(-jitter, jitter)));
    }
    var list = new Gee.ArrayList<Stroke>();
    list.add(s);
    return list;
}

void test_learn() {
    var r = make_recognizer();
    string before = r.recognize(odd_shape(0.3, 1));
    r.learn(odd_shape(0, 2), "xyzzy");
    string after = r.recognize(odd_shape(0.5, 3));
    print("learned shape: before \"%s\", after \"%s\"\n", before, after);
    assert(before != "xyzzy");
    assert(after == "xyzzy");
    var r2 = new HandwritingRecognizer();
    r2.user_path = r.user_path;
    r2.set_fonts(TEMPLATE_FONTS);
    r2.reload_user();
    assert(r2.sample_count() == 1);
    assert(r2.recognize(odd_shape(0.5, 4)) == "xyzzy");
    FileUtils.unlink(r.user_path);
}

InkDoc? real_ink(out OnePage? page) {
    page = null;
    string path = Path.build_filename(Environment.get_variable("NOTES_FIXTURES") ?? "tests/fixtures", "one", "onenote-rs-handwriting.one");
    uint8[] data;
    try {
        FileUtils.get_data(path, out data);
        foreach (var p in OneNoteImporter.read(data)) {
            foreach (var e in p.inks.entries) {
                page = p;
                return e.value;
            }
        }
    } catch (Error e) {
        warning("%s: %s", path, e.message);
    }
    return null;
}

const string[] REAL_WORDS = { "hello", "world", "hallo", "welt", "this", "is", "a", "quick", "test" };
const double[,] REAL_BOXES = { { 20, 80, 100, 145 }, { 100, 80, 210, 145 }, { 270, 430, 430, 520 }, { 460, 430, 610, 520 }, { 210, 550, 310, 610 }, { 315, 550, 440, 610 } };

Gee.ArrayList<Stroke> strokes_in(InkDoc doc, int box) {
    var ws = new Gee.ArrayList<Stroke>();
    foreach (var s in doc.strokes) {
        double x0, y0, x1, y1;
        s.bounds(out x0, out y0, out x1, out y1);
        double cx = (x0 + x1) / 2;
        double cy = (y0 + y1) / 2;
        if (cx > REAL_BOXES[box, 0] && cx < REAL_BOXES[box, 2] && cy > REAL_BOXES[box, 1] && cy < REAL_BOXES[box, 3]) ws.add(s);
    }
    return ws;
}

HandwritingRecognizer real_recognizer() {
    var r = make_recognizer();
    var lex = new Gee.ArrayList<string>();
    foreach (string w in REAL_WORDS) lex.add(w);
    r.add_words(lex);
    return r;
}

int count_word(string text, string word) {
    int n = 0;
    foreach (string w in text.replace("\n", " ").split(" ")) if (w.down() == word) n++;
    return n;
}

Gee.ArrayList<Stroke> real_line(InkDoc doc, double top, double bottom) {
    var ws = new Gee.ArrayList<Stroke>();
    foreach (var s in doc.strokes) {
        double x0, y0, x1, y1;
        s.bounds(out x0, out y0, out x1, out y1);
        double cy = (y0 + y1) / 2;
        if (cy > top && cy < bottom) ws.add(s);
    }
    return ws;
}

void test_real_handwriting() {
    OnePage? page;
    var doc = real_ink(out page);
    if (doc == null) {
        Test.skip("real handwriting fixture missing (%s)".printf(INK_FIXTURE_LICENSE));
        return;
    }
    assert(doc.strokes.size == 62);
    string dic = "/usr/share/hunspell/en_US.dic";
    var r = real_recognizer();
    r.use_dictionary = FileUtils.test(dic, FileTest.EXISTS);
    if (r.use_dictionary) r.load_dic(dic);
    var timer = new Timer();
    string got = r.recognize(doc.strokes);
    print("real page, untrained, small list plus %d dictionary words (OneNote reads \"%s\"): \"%s\" in %.2f s\n", r.dictionary_size(), page.recognized_text().replace("\n", " / "), got.replace("\n", " / "), timer.elapsed());
    int hits = 0;
    foreach (string w in REAL_WORDS) if (count_word(got, w) > 0) hits++;
    print("real page, untrained: hello %d of 3, world %d of 3, %d of 9 distinct written words found\n", count_word(got, "hello"), count_word(got, "world"), hits);
    int top1 = 0;
    int top3 = 0;
    r.use_dictionary = false;
    for (int b = 0; b < REAL_BOXES.length[0]; b++) {
        var cands = r.recognize_word_candidates(strokes_in(doc, b), 3, true);
        for (int k = 0; k < cands.size; k++) {
            if (cands[k].word != (b % 2 == 0 ? "hello" : "world")) continue;
            if (k == 0) top1++;
            top3++;
        }
    }
    print("real words with hand-cut boxes, untrained, small list: top1 %d of 6, top3 %d of 6\n", top1, top3);
    assert(got != "");
    int held = 0;
    int total = 0;
    int false_hits = 0;
    double[,] lines = { { 80, 145 }, { 430, 520 }, { 550, 610 } };
    var rl = r;
    for (int teach = 0; teach < 3; teach++) {
        rl.forget_samples();
        int learned = rl.learn_text(real_line(doc, lines[teach, 0], lines[teach, 1]), "Hello World");
        for (int other = 0; other < 3; other++) {
            if (other == teach) continue;
            string line = rl.recognize(real_line(doc, lines[other, 0], lines[other, 1]));
            total += 2;
            held += int.min(1, count_word(line, "hello")) + int.min(1, count_word(line, "world"));
        }
        double[,] others = { { 0, 75 }, { 160, 220 }, { 240, 300 }, { 355, 405 } };
        for (int o = 0; o < others.length[0]; o++) {
            string line = rl.recognize(real_line(doc, others[o, 0], others[o, 1]));
            false_hits += count_word(line, "hello") + count_word(line, "world");
        }
        print("after correcting line %d to \"Hello World\" (%d word samples learned)\n", teach + 1, learned);
    }
    FileUtils.unlink(rl.user_path);
    print("real words after one correction, held-out Hello World lines: %d of %d words, false Hello or World on the other 4 lines: %d over 3 runs\n", held, total, false_hits);
    assert(held * 2 >= total);
}

string fold(string ch) {
    string c = ch.down();
    return c == "0" ? "o" : c;
}

void test_uji_heldout() {
    string path = Path.build_filename(Environment.get_variable("NOTES_FIXTURES") ?? "tests/fixtures", "uji", "heldout.json");
    var r = new HandwritingRecognizer();
    if (r.letter_count() == 0) {
        Test.skip("letters data missing");
        return;
    }
    var parser = new Json.Parser();
    try {
        parser.load_from_file(path);
    } catch (Error e) {
        error("%s: %s (%s, %s)", path, e.message, UJI_SOURCE, UJI_LICENSE);
    }
    var root = parser.get_root().get_object();
    assert(root.get_string_member("writers") == "51-60");
    int total = 0, exact = 0, folded = 0, lower_total = 0, lower_ok = 0;
    var writers = new Gee.HashSet<int>();
    var timer = new Timer();
    foreach (var n in root.get_array_member("samples").get_elements()) {
        var o = n.get_object();
        string ch = o.get_string_member("ch");
        writers.add((int) o.get_int_member("writer"));
        var strokes = HandwritingRecognizer.decode_strokes(o.get_array_member("strokes"));
        string got = r.classify_letter(strokes, 0, 1);
        total++;
        if (got == ch) exact++;
        if (fold(got) == fold(ch)) folded++;
        if (ch.get_char(0).islower()) {
            lower_total++;
            if (got == ch) lower_ok++;
        }
    }
    print("UJI held-out writers %d (51-60), %d samples, prototypes %d from writers 1-50: exact %.1f%%, case-folded %.1f%%, lowercase %.1f%% in %.1f s\n", writers.size, total, r.letter_count(), 100.0 * exact / total, 100.0 * folded / total, 100.0 * lower_ok / lower_total, timer.elapsed());
    assert(writers.size == 10 && !writers.contains(50));
    assert(folded >= total * 0.75);
}

Gee.HashMap<string, Gee.ArrayList<Gee.ArrayList<Stroke>>> uji_heldout_letters(out int writers) {
    writers = 0;
    var map = new Gee.HashMap<string, Gee.ArrayList<Gee.ArrayList<Stroke>>>();
    string path = Path.build_filename(Environment.get_variable("NOTES_FIXTURES") ?? "tests/fixtures", "uji", "heldout.json");
    var parser = new Json.Parser();
    try {
        parser.load_from_file(path);
    } catch (Error e) {
        error("%s: %s", path, e.message);
    }
    var seen = new Gee.HashSet<int>();
    foreach (var n in parser.get_root().get_object().get_array_member("samples").get_elements()) {
        var o = n.get_object();
        int w = (int) o.get_int_member("writer");
        seen.add(w);
        string key = "%d:%s".printf(w, o.get_string_member("ch"));
        if (!map.has_key(key)) map[key] = new Gee.ArrayList<Gee.ArrayList<Stroke>>();
        map[key].add(HandwritingRecognizer.decode_strokes(o.get_array_member("strokes")));
    }
    writers = seen.size;
    return map;
}

Gee.ArrayList<Stroke>? compose_word(string word, int writer, Gee.HashMap<string, Gee.ArrayList<Gee.ArrayList<Stroke>>> letters, Rand rand) {
    var out = new Gee.ArrayList<Stroke>();
    double x = 0;
    int i = 0;
    unichar c;
    while (word.get_next_char(ref i, out c)) {
        var opts = letters["%d:%s".printf(writer, c.to_string())];
        if (opts == null || opts.size == 0) return null;
        var pick = opts[rand.int_range(0, opts.size)];
        double x0 = double.MAX, x1 = -double.MAX;
        foreach (var s in pick) foreach (var p in s.points) {
            x0 = double.min(x0, p.x);
            x1 = double.max(x1, p.x);
        }
        double dy = rand.double_range(-0.04, 0.04);
        foreach (var s in pick) {
            var t = new Stroke();
            foreach (var p in s.points) t.points.add(new InkPoint((p.x - x0 + x) * 100, (p.y + dy) * 100));
            out.add(t);
        }
        x += double.max(x1 - x0, 0.08) + rand.double_range(0.08, 0.4);
    }
    return out;
}

Gee.ArrayList<string> dictionary_sample(string dic, int count, uint32 seed) {
    var words = new Gee.ArrayList<string>();
    string text;
    try {
        FileUtils.get_contents(dic, out text);
    } catch (Error e) {
        return words;
    }
    var all = new Gee.ArrayList<string>();
    foreach (string line in text.split("\n")) {
        if (line.strip() == "") continue;
        string w = line.split("/")[0].strip();
        if (w.length < 3 || w.length > 9) continue;
        bool ok = true;
        for (int i = 0; i < w.length; i++) if (w[i] < 'a' || w[i] > 'z') ok = false;
        if (ok) all.add(w);
    }
    var rand = new Rand.with_seed(seed);
    while (words.size < count && all.size > 0) words.add(all[rand.int_range(0, all.size)]);
    return words;
}

void test_net_parity() {
    string? model = HwNet.find_model();
    if (model == null) {
        Test.skip("handwriting model missing");
        return;
    }
    var net = HwNet.load(model);
    assert(net != null);
    string path = Path.build_filename(Environment.get_variable("NOTES_FIXTURES") ?? "tests/fixtures", "handwriting", "parity.json");
    var parser = new Json.Parser();
    try {
        parser.load_from_file(path);
    } catch (Error e) {
        error("%s: %s", path, e.message);
    }
    double worst = 0;
    int n = 0;
    foreach (var node in parser.get_root().get_object().get_array_member("samples").get_elements()) {
        var o = node.get_object();
        var strokes = new Gee.ArrayList<Stroke>();
        foreach (var sn in o.get_array_member("strokes").get_elements()) {
            var arr = sn.get_array();
            var st = new Stroke();
            for (uint i = 0; i + 1 < arr.get_length(); i += 2) st.points.add(new InkPoint(arr.get_double_element(i), arr.get_double_element(i + 1)));
            strokes.add(st);
        }
        int width;
        var img = HwNet.render(strokes, out width);
        double ink = 0;
        foreach (float v in img) ink += v;
        assert(width == (int) o.get_int_member("width"));
        assert(Math.fabs(ink - o.get_double_member("ink")) < 0.5);
        int T;
        var lp = net.forward(img, width, out T);
        assert(T == (int) o.get_int_member("steps"));
        var want = o.get_array_member("logprob");
        assert(want.get_length() == lp.length);
        for (int i = 0; i < lp.length; i++) worst = double.max(worst, Math.fabs(lp[i] - want.get_double_element(i)));
        assert(net.greedy(lp, T) == o.get_string_member("greedy"));
        n++;
    }
    print("network parity with the training code on %d words: largest log-probability difference %.4f\n", n, worst);
    assert(n > 0);
    assert(worst < 0.05);
}

void test_net_uji_words() {
    var r = new HandwritingRecognizer();
    if (!r.has_net()) {
        Test.skip("handwriting model missing");
        return;
    }
    string dic = "/usr/share/hunspell/en_US.dic";
    if (!FileUtils.test(dic, FileTest.EXISTS)) {
        Test.skip("no en_US dictionary");
        return;
    }
    r.user_path = Path.build_filename(Environment.get_tmp_dir(), "notes-handwriting-net-%u.json".printf(Random.next_int()));
    r.load_dic(dic);
    int writers;
    var letters = uji_heldout_letters(out writers);
    var words = dictionary_sample(dic, 300, 11);
    var rand = new Rand.with_seed(5);
    int total = 0, ok = 0;
    var timer = new Timer();
    foreach (string w in words) {
        int writer = rand.int_range(51, 61);
        var ink = compose_word(w, writer, letters, rand);
        if (ink == null) continue;
        total++;
        string got = r.recognize(ink);
        if (got.down() == w) ok++;
        else if (total - ok <= 12) print("  miss (writer %d): %s read as %s\n", writer, w, got);
    }
    print("UJI writers 51-60 (never seen in training), %d dictionary words written letter by letter, %d dictionary entries: %.1f%% of words read exactly, %.1f s\n", total, r.dictionary_size(), 100.0 * ok / total, timer.elapsed());
    FileUtils.unlink(r.user_path);
    assert(writers == 10);
    assert(total >= 250);
    assert(ok >= total * 0.85);
}

void test_net_onhw() {
    string? paths = Environment.get_variable("NOTES_ONHW_JSON");
    var r = new HandwritingRecognizer();
    bool baseline = Environment.get_variable("NOTES_ONHW_BASELINE") != null;
    if (paths == null || (!r.has_net() && !baseline)) {
        Test.skip("set NOTES_ONHW_JSON to OnHW-wordsTraj exports to measure real cursive words");
        return;
    }
    int limit = int.parse(Environment.get_variable("NOTES_ONHW_LIMIT") ?? "0");
    string? lexicon = Environment.get_variable("NOTES_ONHW_LEXICON");
    foreach (string path in paths.split(":")) {
        var parser = new Json.Parser();
        try {
            parser.load_from_file(path);
        } catch (Error e) {
            error("%s: %s", path, e.message);
        }
        var samples = parser.get_root().get_object().get_array_member("samples");
        var rec = new HandwritingRecognizer();
        rec.user_path = Path.build_filename(Environment.get_tmp_dir(), "notes-onhw-%u.json".printf(Random.next_int()));
        var dict = new Gee.ArrayList<string>();
        foreach (var n in samples.get_elements()) dict.add(n.get_object().get_string_member("word"));
        int test_words = dict.size;
        if (lexicon != null) {
            string text;
            try {
                FileUtils.get_contents(lexicon, out text);
                foreach (string line in text.split("\n")) {
                    if (line.strip() == "") continue;
                    string w = line.split(" ")[0].strip();
                    if (w != "") dict.add(w);
                }
            } catch (Error e) {
                error("%s", e.message);
            }
        }
        rec.add_dictionary_words(dict);
        rec.use_net = !baseline;
        rec.use_dictionary = true;
        int total = 0, exact = 0, folded = 0;
        var timer = new Timer();
        foreach (var n in samples.get_elements()) {
            if (limit > 0 && total >= limit) break;
            var o = n.get_object();
            string want = o.get_string_member("word");
            var strokes = new Gee.ArrayList<Stroke>();
            foreach (var sn in o.get_array_member("strokes").get_elements()) {
                var arr = sn.get_array();
                var st = new Stroke();
                for (uint i = 0; i + 1 < arr.get_length(); i += 2) st.points.add(new InkPoint(arr.get_double_element(i), arr.get_double_element(i + 1)));
                strokes.add(st);
            }
            var cands = rec.recognize_word_candidates(strokes, 1, false, true);
            string got = cands.size > 0 ? cands[0].text : "";
            total++;
            if (got == want) exact++;
            if (got.down() == want.down()) folded++;
            else if (total - folded <= 8) print("  miss: %s read as %s\n", want, got);
        }
        print("%s%s: %d real cursive words, %d test words plus %d lexicon entries (dictionary %d): exact %.1f%%, ignoring case %.1f%%, %.2f s per word\n", baseline ? "template recognizer, " : "", Path.get_basename(path), total, test_words, dict.size - test_words, rec.dictionary_size(), 100.0 * exact / total, 100.0 * folded / total, timer.elapsed() / total);
        FileUtils.unlink(rec.user_path);
    }
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/notes/handwriting/cursive-words", test_cursive_words);
    Test.add_func("/notes/handwriting/cursive-lines", test_cursive_lines);
    Test.add_func("/notes/handwriting/two-lines", test_two_lines);
    Test.add_func("/notes/handwriting/printed-words", test_printed_words);
    Test.add_func("/notes/handwriting/dictionary", test_dictionary);
    Test.add_func("/notes/handwriting/learn", test_learn);
    Test.add_func("/notes/handwriting/uji-heldout", test_uji_heldout);
    Test.add_func("/notes/handwriting/real", test_real_handwriting);
    Test.add_func("/notes/handwriting/net-parity", test_net_parity);
    Test.add_func("/notes/handwriting/net-uji-words", test_net_uji_words);
    Test.add_func("/notes/handwriting/net-onhw", test_net_onhw);
    return Test.run();
}
