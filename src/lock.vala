namespace Singularity.Apps.Notes {

    public class SectionLocks : Object {
        public const string MARKER = LOCKED_MARKER;
        public const uint ITERATIONS = 200000;
        private const string CHECK_TEXT = "singularity-notes-section-lock";

        public Notebooks notebooks { get; construct; }
        public signal void changed();

        private Gee.HashMap<string, Bytes> keys = new Gee.HashMap<string, Bytes>();
        private Gee.HashMap<string, int64?> last_use = new Gee.HashMap<string, int64?>();

        public SectionLocks(Notebooks notebooks) {
            Object(notebooks: notebooks);
        }

        public static bool is_locked_body(string body) {
            return body.contains(MARKER);
        }

        private static uint8[] derive(string password, uint8[] salt) {
            var key = new uint8[NotesCrypto.KEY_LEN];
            NotesCrypto.derive(password, salt, ITERATIONS, key);
            return key;
        }

        private static string seal(uint8[] key, string plain) {
            var nonce = new uint8[NotesCrypto.NONCE_LEN];
            NotesCrypto.random(nonce);
            var cipher = NotesCrypto.seal(key, nonce, plain.data);
            if (cipher == null) return "";
            var all = new ByteArray();
            all.append(nonce);
            all.append(cipher.get_data());
            return Base64.encode(all.data);
        }

        private static string cipher_text(string after_marker) {
            int c = after_marker.index_of("<!--");
            return c >= 0 ? after_marker.substring(0, c) : after_marker;
        }

        private static uint8[]? seal_bytes(uint8[] key, uint8[] plain) {
            var nonce = new uint8[NotesCrypto.NONCE_LEN];
            NotesCrypto.random(nonce);
            var cipher = NotesCrypto.seal(key, nonce, plain);
            if (cipher == null) return null;
            var all = new ByteArray();
            all.append(nonce);
            all.append(cipher.get_data());
            return all.steal();
        }

        private static uint8[]? unseal_bytes(uint8[] key, uint8[] raw) {
            if (raw.length < NotesCrypto.NONCE_LEN + 16) return null;
            uint8[] nonce = raw[0:NotesCrypto.NONCE_LEN];
            uint8[] body = raw[NotesCrypto.NONCE_LEN:raw.length];
            var opened = NotesCrypto.open(key, nonce, body);
            if (opened == null) return null;
            return opened.get_data();
        }

        public bool encrypt_file(string section, string src, string dst) {
            string? root = notebooks.lock_root(section);
            if (root == null || !keys.has_key(root)) return false;
            try {
                uint8[] data;
                FileUtils.get_data(src, out data);
                var sealed_data = seal_bytes(keys[root].get_data(), data);
                if (sealed_data == null) return false;
                FileUtils.set_data(dst, sealed_data);
                FileUtils.chmod(dst, 0600);
                return true;
            } catch (FileError e) {
                return false;
            }
        }

        public bool decrypt_file(string section, string src, string dst) {
            string? root = notebooks.lock_root(section);
            if (root == null || !keys.has_key(root)) return false;
            try {
                uint8[] data;
                FileUtils.get_data(src, out data);
                var plain = unseal_bytes(keys[root].get_data(), data);
                if (plain == null) return false;
                DirUtils.create_with_parents(Path.get_dirname(dst), 0700);
                FileUtils.set_data(dst, plain);
                FileUtils.chmod(dst, 0600);
                return true;
            } catch (FileError e) {
                return false;
            }
        }

        private static string? unseal(uint8[] key, string b64) {
            uint8[] raw = Base64.decode(cipher_text(b64).replace("\n", "").strip());
            if (raw.length < NotesCrypto.NONCE_LEN + 16) return null;
            uint8[] nonce = raw[0:NotesCrypto.NONCE_LEN];
            uint8[] body = raw[NotesCrypto.NONCE_LEN:raw.length];
            var opened = NotesCrypto.open(key, nonce, body);
            if (opened == null) return null;
            var sb = new StringBuilder.sized(opened.get_size() + 1);
            sb.append_len((string) opened.get_data(), (ssize_t) opened.get_size());
            return sb.str;
        }

        public bool has_password(string section) {
            return notebooks.lock_root(section) != null;
        }

        public bool is_unlocked(string section) {
            string? root = notebooks.lock_root(section);
            if (root == null) return true;
            bool ok = keys.has_key(root);
            if (ok) last_use[root] = get_monotonic_time();
            return ok;
        }

        public bool unlock(string section, string password) {
            string? root = notebooks.lock_root(section);
            if (root == null) return true;
            var info = notebooks.info(root);
            var key = derive(password, Base64.decode(info.lock_salt));
            if (unseal(key, info.lock_check) != CHECK_TEXT) return false;
            keys[root] = new Bytes(key);
            last_use[root] = get_monotonic_time();
            changed();
            return true;
        }

        public void lock_section(string section) {
            string? root = notebooks.lock_root(section) ?? section;
            keys.unset(root);
            changed();
        }

        public void lock_all() {
            if (keys.size == 0) return;
            keys.clear();
            changed();
        }

        public int lock_idle(int64 idle_seconds) {
            int n = 0;
            int64 now = get_monotonic_time();
            foreach (string root in keys.keys.to_array()) {
                int64 used = last_use.has_key(root) ? last_use[root] : 0;
                if (now - used > idle_seconds * 1000000) {
                    keys.unset(root);
                    n++;
                }
            }
            if (n > 0) changed();
            return n;
        }

        public void touch(string section) {
            string? root = notebooks.lock_root(section);
            if (root != null) last_use[root] = get_monotonic_time();
        }

        public void set_password(string section, string password) {
            var salt = new uint8[16];
            NotesCrypto.random(salt);
            var key = derive(password, salt);
            var info = notebooks.info(section);
            info.lock_salt = Base64.encode(salt);
            info.lock_check = seal(key, CHECK_TEXT);
            notebooks.save();
            keys[section] = new Bytes(key);
            last_use[section] = get_monotonic_time();
            changed();
        }

        public void clear_password(string section) {
            var info = notebooks.info(section);
            info.lock_salt = "";
            info.lock_check = "";
            notebooks.save();
            keys.unset(section);
            changed();
        }

        public string? encrypt(string section, string plain) {
            string? root = notebooks.lock_root(section);
            if (root == null || !keys.has_key(root)) return null;
            string cipher = seal(keys[root].get_data(), plain);
            var sb = new StringBuilder();
            sb.append("# ");
            sb.append(_("Locked Page"));
            sb.append("\n");
            sb.append(MARKER);
            sb.append("\n");
            for (int i = 0; i < cipher.length; i += 76) {
                sb.append(cipher.substring(i, int.min(76, cipher.length - i)));
                sb.append("\n");
            }
            return sb.str;
        }

        public string? decrypt(string section, string body) {
            string? root = notebooks.lock_root(section);
            if (root == null || !keys.has_key(root)) return null;
            int m = body.index_of(MARKER);
            if (m < 0) return body;
            return unseal(keys[root].get_data(), body.substring(m + MARKER.length));
        }

        public static string? decrypt_with_password(string password, string salt_b64, string body) {
            int m = body.index_of(MARKER);
            if (m < 0) return body;
            var key = derive(password, Base64.decode(salt_b64));
            return unseal(key, body.substring(m + MARKER.length));
        }
    }
}

namespace Singularity.Apps.Notes {

    public class LockedFiles : Object {
        public const string SUFFIX = ".locked";

        public SectionLocks locks { get; construct; }
        public string store_dir { get; construct; }
        public string root { get; private set; }

        public LockedFiles(SectionLocks locks, string store_dir) {
            Object(locks: locks, store_dir: store_dir);
            string base_dir = Environment.get_user_runtime_dir();
            if (base_dir == null || base_dir == "" || !FileUtils.test(base_dir, FileTest.IS_DIR)) base_dir = Environment.get_user_cache_dir();
            root = Path.build_filename(base_dir, "singularity-notes-locked", "open-" + Uuid.string_random().substring(0, 12));
            DirUtils.create_with_parents(root, 0700);
            FileUtils.chmod(Path.get_dirname(root), 0700);
        }

        private string sealed_for(string rel, string note_id) {
            string direct = Path.build_filename(store_dir, rel + SUFFIX);
            if (FileUtils.test(direct, FileTest.IS_REGULAR) || note_id == "") return direct;
            string local = Path.build_filename(store_dir, "attachments", note_id, Path.get_basename(rel) + SUFFIX);
            return FileUtils.test(local, FileTest.IS_REGULAR) ? local : direct;
        }

        private static Gee.List<string> files_of(string plain_body) {
            var list = new Gee.ArrayList<string>();
            foreach (string target in NoteAttachments.links(plain_body)) {
                string id;
                string name;
                if (NoteAttachments.local_link(target, out id, out name) == null) continue;
                list.add("attachments/%s/%s".printf(id, name));
                foreach (string side in NoteAttachments.sidecars(name)) list.add("attachments/%s/%s".printf(id, side));
                if (name.has_prefix("equation-")) {
                    int dot = name.last_index_of(".");
                    string stem = dot > 0 ? name.substring(0, dot) : name;
                    list.add("attachments/%s/%s.tex".printf(id, stem));
                    list.add("attachments/%s/%s.mml".printf(id, stem));
                }
            }
            return list;
        }

        public void prepare(string folder, string note_id, string plain_body) {
            foreach (string rel in files_of(plain_body)) {
                string cached = Path.build_filename(root, rel);
                if (FileUtils.test(cached, FileTest.EXISTS)) continue;
                string sealed_path = sealed_for(rel, note_id);
                string plain_path = Path.build_filename(store_dir, rel);
                if (FileUtils.test(sealed_path, FileTest.IS_REGULAR)) {
                    locks.decrypt_file(folder, sealed_path, cached);
                } else if (FileUtils.test(plain_path, FileTest.IS_REGULAR)) {
                    try {
                        DirUtils.create_with_parents(Path.get_dirname(cached), 0700);
                        File.new_for_path(plain_path).copy(File.new_for_path(cached), FileCopyFlags.OVERWRITE);
                    } catch (Error e) {
                    }
                }
            }
        }

        public string commit(string folder, string note_id, string plain_body) {
            var names = new Gee.ArrayList<string>();
            foreach (string rel in files_of(plain_body)) {
                string cached = Path.build_filename(root, rel);
                string sealed_path = sealed_for(rel, note_id);
                string plain_path = Path.build_filename(store_dir, rel);
                if (FileUtils.test(cached, FileTest.IS_REGULAR)) {
                    if (!FileUtils.test(sealed_path, FileTest.IS_REGULAR) || modified(cached) > modified(sealed_path)) {
                        DirUtils.create_with_parents(Path.get_dirname(sealed_path), 0700);
                        locks.encrypt_file(folder, cached, sealed_path);
                    }
                } else if (FileUtils.test(plain_path, FileTest.IS_REGULAR) && !FileUtils.test(sealed_path, FileTest.IS_REGULAR)) {
                    locks.encrypt_file(folder, plain_path, sealed_path);
                }
                if (FileUtils.test(sealed_path, FileTest.IS_REGULAR)) {
                    FileUtils.unlink(plain_path);
                    names.add(sealed_path.substring(store_dir.length + 1));
                }
            }
            if (names.size == 0) return "";
            var sb = new StringBuilder("<!-- locked-files");
            foreach (string n in names) sb.append(" locked=" + n);
            sb.append(" -->\n");
            return sb.str;
        }

        public void unprotect(string folder, string note_id, string plain_body) {
            foreach (string rel in files_of(plain_body)) {
                string sealed_path = sealed_for(rel, note_id);
                string plain_path = Path.build_filename(store_dir, rel);
                if (!FileUtils.test(sealed_path, FileTest.IS_REGULAR)) continue;
                if (locks.decrypt_file(folder, sealed_path, plain_path)) FileUtils.unlink(sealed_path);
            }
        }

        private static int64 modified(string path) {
            try {
                var info = File.new_for_path(path).query_info(FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                return (int64) info.get_attribute_uint64(FileAttribute.TIME_MODIFIED) * 1000000 + info.get_attribute_uint32(FileAttribute.TIME_MODIFIED_USEC);
            } catch (Error e) {
                return 0;
            }
        }

        public void wipe() {
            Trash.remove_tree(Path.build_filename(root, "attachments"));
        }

        public void destroy_all() {
            Trash.remove_tree(root);
        }
    }
}
