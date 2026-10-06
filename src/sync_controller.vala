namespace Singularity.Apps.Notes {

    public enum SyncStatus {
        OFF,
        IDLE,
        SYNCING,
        DONE,
        FAILED,
        ATTENTION
    }

    public class SyncController : Object {
        public Singularity.Notes.NoteStore store { get; construct; }
        public GLib.Settings? settings { get; construct; }
        public SyncStatus status { get; private set; default = SyncStatus.OFF; }
        public string message { get; private set; default = ""; }
        public int64 last_sync { get; private set; default = 0; }
        public Singularity.Accounts.Account? account { get; private set; default = null; }

        public signal void changed();
        public signal void accounts_changed();
        public signal void meta_updated();

        private Singularity.Accounts.Manager? manager = null;
        private bool running = false;
        private bool again = false;
        private bool applying = false;
        private uint debounce = 0;
        private uint periodic = 0;
        private Cancellable? cancellable = null;

        public SyncController(Singularity.Notes.NoteStore store, GLib.Settings? settings) {
            Object(store: store, settings: settings);
        }

        public async void start() {
            manager = Singularity.Accounts.Manager.get_default();
            yield manager.load();
            manager.account_added.connect(() => on_accounts());
            manager.account_removed.connect(() => on_accounts());
            manager.account_changed.connect(() => on_accounts());
            if (settings != null) settings.changed["sync-account"].connect(() => on_accounts());
            store.changed.connect(() => {
                if (account == null && shared_notebooks().size == 0) return;
                if (applying) {
                    again = true;
                    return;
                }
                if (settings == null || settings.get_boolean("sync-on-edit")) schedule(3000);
            });
            if (settings != null) settings.changed["sync-interval"].connect(restart_periodic);
            restart_periodic();
            on_accounts();
        }

        private void restart_periodic() {
            if (periodic != 0) Source.remove(periodic);
            int minutes = settings != null ? settings.get_int("sync-interval") : 5;
            periodic = Timeout.add_seconds((uint) int.max(1, minutes) * 60, () => {
                if (account != null) sync_now();
                return Source.CONTINUE;
            });
        }

        public static bool eligible(Singularity.Accounts.Account a) {
            if (a.has_capability(Singularity.Accounts.Capability.NOTES) && a.get_endpoint("notes") != null) return true;
            return a.has_capability(Singularity.Accounts.Capability.FILES) && a.get_endpoint("webdav") != null;
        }

        public Gee.List<Singularity.Accounts.Account> accounts() {
            var list = new Gee.ArrayList<Singularity.Accounts.Account>();
            if (manager == null) return list;
            foreach (var a in manager.get_accounts()) if (eligible(a)) list.add(a);
            return list;
        }

        public string chosen_id() {
            return settings != null ? settings.get_string("sync-account") : "";
        }

        public void choose(string id) {
            if (settings != null) settings.set_string("sync-account", id);
        }

        public static string method_label(Singularity.Accounts.Account a) {
            if (a.has_capability(Singularity.Accounts.Capability.NOTES) && a.get_endpoint("notes") != null) return _("Nextcloud Notes");
            return _("Notes folder on WebDAV");
        }

        private void on_accounts() {
            accounts_changed();
            string id = chosen_id();
            Singularity.Accounts.Account? found = null;
            if (id != "" && manager != null) {
                var a = manager.get_account(id);
                if (a != null && eligible(a)) found = a;
            }
            if (found != account) {
                account = found;
                if (cancellable != null) cancellable.cancel();
                last_sync = 0;
            }
            if (account == null) {
                update_status(SyncStatus.OFF, "");
                return;
            }
            if (account.attention != "") {
                update_status(SyncStatus.ATTENTION, _("Sign in again in Settings to keep syncing"));
                return;
            }
            if (status == SyncStatus.OFF) update_status(SyncStatus.IDLE, "");
            schedule(500);
        }

        private void update_status(SyncStatus s, string msg) {
            status = s;
            message = msg;
            changed();
        }

        private void schedule(uint ms) {
            if (debounce != 0) Source.remove(debounce);
            debounce = Timeout.add(ms, () => {
                debounce = 0;
                sync_now();
                return Source.REMOVE;
            });
        }

        public void request() {
            if ((account == null && shared_notebooks().size == 0) || applying) return;
            if (settings == null || settings.get_boolean("sync-on-edit")) schedule(3000);
        }

        private NotesRemote remote_for(Singularity.Accounts.Account a) {
            if (a.has_capability(Singularity.Accounts.Capability.NOTES) && a.get_endpoint("notes") != null) return new NextcloudNotesRemote(a);
            return new WebDavNotesRemote(a);
        }

        public Notebooks? notebooks { get; set; default = null; }
        public string current_page { get; set; default = ""; }
        public string current_folder { get; set; default = ""; }
        public string me { get; set; default = ""; }
        public Gee.HashMap<string, Gee.List<Presence>> presence = new Gee.HashMap<string, Gee.List<Presence>>();
        public signal void presence_changed();
        private uint shared_poll = 0;

        public Gee.List<FolderInfo> shared_notebooks() {
            var list = new Gee.ArrayList<FolderInfo>();
            if (notebooks == null || manager == null) return list;
            foreach (var info in notebooks.shared()) {
                var acc = manager.get_account(info.share_account);
                if (acc != null && acc.has_capability(Singularity.Accounts.Capability.FILES) && acc.get_endpoint("webdav") != null) list.add(info);
            }
            return list;
        }

        public void watch_shared() {
            if (shared_poll != 0) return;
            shared_poll = Timeout.add_seconds(30, () => {
                if (shared_notebooks().size > 0 && !running) sync_now();
                return Source.CONTINUE;
            });
        }

        public void sync_now() {
            var shared = shared_notebooks();
            if (account == null && shared.size == 0) return;
            if (running) {
                again = true;
                return;
            }
            running = true;
            cancellable = new Cancellable();
            update_status(SyncStatus.SYNCING, "");
            applying = true;
            run_all.begin(account, shared, cancellable, (o, r) => {
                applying = false;
                running = false;
                try {
                    var report = run_all.end(r);
                    last_sync = get_real_time() / 1000000;
                    if (report.conflicts > 0) {
                        update_status(SyncStatus.DONE, ngettext("%d note changed on both sides; your version was kept as a copy",
                                                             "%d notes changed on both sides; your versions were kept as copies",
                                                             report.conflicts).printf(report.conflicts));
                    } else {
                        update_status(SyncStatus.DONE, "");
                    }
                } catch (IOError.CANCELLED e) {
                    update_status(account != null ? SyncStatus.IDLE : SyncStatus.OFF, "");
                } catch (Singularity.Accounts.AccountsError.NEEDS_REAUTH e) {
                    update_status(SyncStatus.ATTENTION, _("Sign in again in Settings to keep syncing"));
                } catch (Error e) {
                    warning("notes sync failed: %s", e.message);
                    update_status(SyncStatus.FAILED, e.message);
                }
                if (again) {
                    again = false;
                    schedule(1000);
                }
            });
        }

        private async SyncReport run_all(Singularity.Accounts.Account? main, Gee.List<FolderInfo> shared, Cancellable cancellable) throws Error {
            var total = new SyncReport();
            string[] excluded = {};
            foreach (var info in shared) excluded += info.path;
            if (main != null) {
                var engine = new SyncEngine(store, remote_for(main), SyncEngine.state_path_for(store, main.id));
                engine.exclude_prefixes = excluded;
                var report = yield engine.sync(cancellable);
                GLib.message("notes sync %s: %s", main.id, report.describe());
                if (engine.meta_changed) meta_updated();
                total.conflicts += report.conflicts;
            }
            foreach (var info in shared) {
                var acc = manager.get_account(info.share_account);
                if (acc == null) continue;
                string key = "%s-share-%s".printf(acc.id, Checksum.compute_for_string(ChecksumType.SHA1, info.share_path).substring(0, 12));
                var shared_remote = new WebDavNotesRemote(acc, info.share_path);
                var engine = new SyncEngine(store, shared_remote, SyncEngine.state_path_for(store, key));
                engine.include_prefix = info.path;
                engine.sync_notebooks = false;
                try {
                    var report = yield engine.sync(cancellable);
                    GLib.message("notes shared sync %s: %s", info.path, report.describe());
                    total.conflicts += report.conflicts;
                    string who = me != "" ? me : History.author_name();
                    bool here = SyncEngine.under(current_folder, info.path);
                    yield shared_remote.put_presence(who, here ? current_page : "", cancellable);
                    var others = new Gee.ArrayList<Presence>();
                    int64 now = get_real_time() / 1000000;
                    foreach (var p in yield shared_remote.list_presence(cancellable)) {
                        if (p.name == who || now - p.time > 150) continue;
                        others.add(p);
                    }
                    presence[info.path] = others;
                    presence_changed();
                } catch (IOError.CANCELLED e) {
                    throw e;
                } catch (Error e) {
                    warning("notes shared sync %s failed: %s", info.path, e.message);
                    if (main == null) throw e;
                }
            }
            return total;
        }

        public void stop() {
            if (debounce != 0) Source.remove(debounce);
            if (periodic != 0) Source.remove(periodic);
            if (shared_poll != 0) Source.remove(shared_poll);
            debounce = 0;
            periodic = 0;
            shared_poll = 0;
            if (cancellable != null) cancellable.cancel();
        }
    }
}
