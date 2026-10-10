#!/usr/bin/env python3
"""File-system and clipboard backend for the Mini Desktop DMS widget.

Every one-shot command prints a single JSON object on stdout:
    {"ok": true, ...}                       on success
    {"ok": false, "error": <code>, ...}     on failure (exit status 1)
`watch` instead streams one JSON object per line for as long as it runs.
"""

import argparse
import ctypes
import errno
import hashlib
import json
import locale
import os
import pathlib
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.parse

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

try:
    gi.require_version("GioUnix", "2.0")
    from gi.repository import GioUnix  # noqa: E402

    DesktopAppInfo = GioUnix.DesktopAppInfo
except (ValueError, ImportError):
    # GLib < 2.86 keeps DesktopAppInfo in Gio.
    DesktopAppInfo = Gio.DesktopAppInfo

DIRECT_IMAGE_TYPES = {
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/bmp",
    "image/svg+xml",
    "image/x-icon",
    "image/vnd.microsoft.icon",
}
DIRECT_IMAGE_MAX_BYTES = 64 * 1024 * 1024
COMPOUND_EXTENSIONS = (".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tar.lz4", ".tar.lzma")
FILE_QUERY = ",".join(
    [
        "standard::name",
        "standard::display-name",
        "standard::type",
        "standard::is-hidden",
        "standard::is-backup",
        "standard::is-symlink",
        "standard::symlink-target",
        "standard::content-type",
        "standard::icon",
        "standard::size",
        "time::modified",
        "access::can-execute",
    ]
)
THUMBNAIL_SIZE = 256
THUMBNAIL_TIMEOUT = 30
THUMBNAIL_WORKERS = 2


class HelperError(Exception):
    def __init__(self, code, message="", **extra):
        super().__init__(message or code)
        self.code = code
        self.message = message or code
        self.extra = extra


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# ---------------------------------------------------------------- naming ----


def split_name(name, is_dir):
    if is_dir:
        return name, ""
    lower = name.lower()
    for ext in COMPOUND_EXTENSIONS:
        if lower.endswith(ext) and len(name) > len(ext):
            return name[: -len(ext)], name[-len(ext):]
    dot = name.rfind(".")
    if dot <= 0:
        return name, ""
    return name[:dot], name[dot:]


def candidate_names(name, is_dir):
    yield name
    stem, ext = split_name(name, is_dir)
    n = 2
    while True:
        yield f"{stem} ({n}){ext}"
        n += 1


def validate_name(name):
    name = name.strip()
    if not name or name in (".", "..") or "/" in name or "\0" in name:
        raise HelperError("invalid-name")
    if len(name.encode("utf-8")) > 255:
        raise HelperError("name-too-long")
    return name


def require_dir(path):
    if not os.path.isdir(path):
        raise HelperError("not-found", path)
    return path


_libc = None


def _renameat2_noreplace(src, dst):
    """Atomic rename that refuses to replace an existing destination."""
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL(None, use_errno=True)
    if not hasattr(_libc, "renameat2"):
        raise OSError(errno.ENOSYS, "renameat2 unavailable")
    at_fdcwd = -100
    rename_noreplace = 1
    res = _libc.renameat2(at_fdcwd, os.fsencode(src), at_fdcwd, os.fsencode(dst), rename_noreplace)
    if res != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), dst)


def rename_noreplace(src, dst):
    try:
        _renameat2_noreplace(src, dst)
    except OSError as e:
        if e.errno in (errno.ENOSYS, errno.EINVAL):
            # Filesystems without RENAME_NOREPLACE support (some FUSE mounts).
            if os.path.lexists(dst):
                raise FileExistsError(errno.EEXIST, "exists", dst)
            os.rename(src, dst)
            return
        raise


def create_exclusive_file(directory, name, data=b""):
    for candidate in candidate_names(name, False):
        path = os.path.join(directory, candidate)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            continue
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        return path


def create_exclusive_dir(directory, name):
    for candidate in candidate_names(name, True):
        path = os.path.join(directory, candidate)
        try:
            os.mkdir(path)
        except FileExistsError:
            continue
        return path


def reserve_destination(directory, name, is_dir):
    """Claims a free name in `directory` so a following copy cannot clobber anything."""
    if is_dir:
        return create_exclusive_dir(directory, name)
    return create_exclusive_file(directory, name)


# ---------------------------------------------------------- desktop files ----


def keyfile_for(path):
    kf = GLib.KeyFile()
    kf.load_from_file(path, GLib.KeyFileFlags.KEEP_COMMENTS | GLib.KeyFileFlags.KEEP_TRANSLATIONS)
    return kf


def kf_get(kf, key, localized=False, default=""):
    try:
        if localized:
            return kf.get_locale_string("Desktop Entry", key, None)
        return kf.get_string("Desktop Entry", key)
    except GLib.Error:
        return default


def kf_bool(kf, key):
    try:
        return kf.get_boolean("Desktop Entry", key)
    except GLib.Error:
        return False


def expand_exec(exec_line, icon, name, location):
    """Desktop Entry Spec 'Exec' expansion for a launch without file arguments."""
    try:
        ok, argv = GLib.shell_parse_argv(exec_line)
    except GLib.Error:
        return []
    if not ok:
        return []
    out = []
    for arg in argv:
        if arg in ("%f", "%F", "%u", "%U", "%d", "%D", "%n", "%N", "%v", "%m"):
            continue
        if arg == "%i":
            if icon:
                out.extend(["--icon", icon])
            continue
        result = []
        i = 0
        while i < len(arg):
            ch = arg[i]
            if ch == "%" and i + 1 < len(arg):
                code = arg[i + 1]
                if code == "%":
                    result.append("%")
                elif code == "c":
                    result.append(name)
                elif code == "k":
                    result.append(location)
                i += 2
                continue
            result.append(ch)
            i += 1
        out.append("".join(result))
    return out


def which_exec(program):
    if os.path.isabs(program):
        return os.access(program, os.X_OK)
    return shutil.which(program) is not None


def describe_desktop_file(path, item):
    try:
        kf = keyfile_for(path)
    except GLib.Error:
        return
    entry_type = kf_get(kf, "Type")
    label = kf_get(kf, "Name", localized=True)
    if label:
        item["label"] = label
    icon = kf_get(kf, "Icon", localized=True)
    item["desktopIcon"] = icon
    item["isDesktopFile"] = True
    if entry_type == "Link":
        item["kind"] = "link"
        item["url"] = kf_get(kf, "URL")
        if not icon:
            item["desktopIcon"] = "text-html"
        return
    if entry_type != "Application":
        return
    exec_line = kf_get(kf, "Exec")
    try_exec = kf_get(kf, "TryExec")
    argv = expand_exec(exec_line, icon, label or item["name"], path)
    available = bool(argv) and which_exec(argv[0]) and (not try_exec or which_exec(try_exec))
    item.update(
        {
            "kind": "app",
            "exec": argv,
            "terminal": kf_bool(kf, "Terminal"),
            "workdir": kf_get(kf, "Path"),
            "appId": item["name"][: -len(".desktop")],
            "available": available,
        }
    )
    if not icon:
        item["desktopIcon"] = "application-x-executable"


# ------------------------------------------------------------ thumbnails ----


def png_text_chunks(path):
    chunks = {}
    try:
        with open(path, "rb") as f:
            if f.read(8) != b"\x89PNG\r\n\x1a\n":
                return chunks
            while True:
                header = f.read(8)
                if len(header) < 8:
                    break
                length = int.from_bytes(header[:4], "big")
                ctype = header[4:8]
                if ctype == b"IDAT" or ctype == b"IEND":
                    break
                data = f.read(length)
                f.read(4)
                if ctype == b"tEXt" and b"\0" in data:
                    key, value = data.split(b"\0", 1)
                    chunks[key.decode("latin-1")] = value.decode("latin-1")
    except OSError:
        pass
    return chunks


class Thumbnailers:
    def __init__(self):
        self.by_mime = {}
        dirs = [os.path.join(GLib.get_user_data_dir(), "thumbnailers")]
        dirs += [os.path.join(d, "thumbnailers") for d in GLib.get_system_data_dirs()]
        for directory in dirs:
            try:
                names = sorted(os.listdir(directory))
            except OSError:
                continue
            for fname in names:
                if not fname.endswith(".thumbnailer"):
                    continue
                kf = GLib.KeyFile()
                try:
                    kf.load_from_file(os.path.join(directory, fname), GLib.KeyFileFlags.NONE)
                    exec_line = kf.get_string("Thumbnailer Entry", "Exec")
                    mimes = kf.get_string_list("Thumbnailer Entry", "MimeType")
                except GLib.Error:
                    continue
                try:
                    try_exec = kf.get_string("Thumbnailer Entry", "TryExec")
                except GLib.Error:
                    try_exec = ""
                if try_exec and not which_exec(try_exec):
                    continue
                for mime in mimes:
                    self.by_mime.setdefault(mime, exec_line)

    def command(self, mime, path, uri, out):
        exec_line = self.by_mime.get(mime)
        if not exec_line:
            return None
        try:
            ok, argv = GLib.shell_parse_argv(exec_line)
        except GLib.Error:
            return None
        repl = {"%s": str(THUMBNAIL_SIZE), "%u": uri, "%i": path, "%o": out, "%%": "%"}
        result = []
        for arg in argv:
            for key, value in repl.items():
                arg = arg.replace(key, value)
            result.append(arg)
        return result if result and which_exec(result[0]) else None


def thumbnail_cache_dir():
    path = os.path.join(GLib.get_user_cache_dir(), "minidesktop", "thumbnails")
    os.makedirs(path, exist_ok=True)
    return path


def shared_thumbnail(uri, mtime):
    """Reuses a valid thumbnail another app already stored in the freedesktop cache."""
    digest = hashlib.md5(uri.encode("utf-8")).hexdigest() + ".png"
    base = os.path.join(GLib.get_user_cache_dir(), "thumbnails")
    for size in ("large", "x-large", "xx-large", "normal"):
        candidate = os.path.join(base, size, digest)
        if os.path.isfile(candidate):
            meta = png_text_chunks(candidate)
            if meta.get("Thumb::MTime") == str(mtime):
                return candidate
    return ""


def private_thumbnail_path(uri, mtime):
    key = hashlib.sha1(f"{uri}\n{mtime}".encode("utf-8")).hexdigest()
    return os.path.join(thumbnail_cache_dir(), key + ".png")


# ---------------------------------------------------------------- listing ----


def icon_names(gicon):
    if isinstance(gicon, Gio.ThemedIcon):
        return list(gicon.get_names())
    if isinstance(gicon, Gio.FileIcon):
        return [gicon.get_file().get_path() or ""]
    return []


def describe(directory, info):
    name = info.get_name()
    path = os.path.join(directory, name)
    ftype = info.get_file_type()
    is_symlink = info.get_is_symlink()
    mime = info.get_content_type() or "application/octet-stream"
    gicon = info.get_icon()
    if mime == "application/x-zerosize":
        # Empty files have no content to sniff; their name tells what they are.
        guessed, _uncertain = Gio.content_type_guess(name, None)
        if guessed and guessed != "application/octet-stream":
            mime = guessed
            gicon = Gio.content_type_get_icon(mime)
    modified = info.get_attribute_uint64("time::modified")
    item = {
        "name": name,
        "path": path,
        "uri": Gio.File.new_for_path(path).get_uri(),
        "label": info.get_display_name() or name,
        "kind": "folder" if ftype == Gio.FileType.DIRECTORY else "file",
        "mime": mime,
        "icons": icon_names(gicon) if gicon else [],
        "desktopIcon": "",
        "symlink": bool(is_symlink),
        "isDesktopFile": False,
        "image": False,
        "thumbnail": "",
        "modified": modified,
        "size": info.get_size(),
        "exec": [],
        "terminal": False,
        "workdir": "",
        "url": "",
        "appId": "",
        "available": True,
    }
    if ftype == Gio.FileType.SYMBOLIC_LINK:
        # Following the link failed: its target is gone.
        item["kind"] = "broken"
        item["available"] = False
        item["icons"] = ["emblem-unreadable", "text-x-generic"]
        return item
    if ftype == Gio.FileType.REGULAR and name.endswith(".desktop"):
        describe_desktop_file(path, item)
    if item["kind"] == "file" and mime in DIRECT_IMAGE_TYPES and item["size"] <= DIRECT_IMAGE_MAX_BYTES:
        item["image"] = True
    return item


def list_directory(directory, show_hidden=False):
    gdir = Gio.File.new_for_path(directory)
    enumerator = gdir.enumerate_children(FILE_QUERY, Gio.FileQueryInfoFlags.NONE, None)
    items = []
    while True:
        info = enumerator.next_file(None)
        if info is None:
            break
        if not show_hidden and (info.get_is_hidden() or info.get_is_backup()):
            continue
        items.append(describe(directory, info))
    enumerator.close(None)
    items.sort(
        key=lambda it: (
            0 if it["kind"] == "folder" else 1,
            GLib.utf8_collate_key_for_filename(it["label"], -1),
        )
    )
    return items


def unix_signal_add(signum, handler):
    try:
        gi.require_version("GLibUnix", "2.0")
        from gi.repository import GLibUnix

        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signum, handler)
    except (ValueError, ImportError, AttributeError):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, handler)


def exit_with_parent():
    """Asks the kernel to stop this watcher when the shell that started it dies."""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        pr_set_pdeathsig = 1
        libc.prctl(pr_set_pdeathsig, signal.SIGTERM, 0, 0, 0)
    except (OSError, AttributeError):
        pass
    if os.getppid() == 1:
        sys.exit(0)


class Watcher:
    def __init__(self, directory):
        self.directory = directory
        self.loop = GLib.MainLoop()
        self.monitor = None
        self.pending = 0
        self.thumbnailers = Thumbnailers()
        self.thumbs = {}  # path -> (mtime, thumbnail path or "" when it failed)
        self.queue = []
        self.running = 0
        self.last_items = []
        self.missing = False

    def start(self):
        self.attach()
        self.schedule(0)
        for signum in (signal.SIGTERM, signal.SIGINT):
            unix_signal_add(signum, self.quit)
        exit_with_parent()
        if stat.S_ISFIFO(os.fstat(sys.stdin.fileno()).st_mode):
            # The shell holds the other end; it closes when the shell goes away.
            channel = GLib.IOChannel.unix_new(sys.stdin.fileno())
            GLib.io_add_watch(channel, GLib.PRIORITY_DEFAULT, GLib.IOCondition.HUP | GLib.IOCondition.ERR, self.quit)
        self.loop.run()

    def quit(self, *_args):
        self.loop.quit()
        return False

    def attach(self):
        if self.monitor is not None:
            self.monitor.cancel()
            self.monitor = None
        gfile = Gio.File.new_for_path(self.directory)
        try:
            self.monitor = gfile.monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, None)
        except GLib.Error:
            self.monitor = None
            return
        self.monitor.set_rate_limit(200)
        self.monitor.connect("changed", lambda *_a: self.schedule(150))

    def schedule(self, delay):
        if self.pending:
            GLib.source_remove(self.pending)
        self.pending = GLib.timeout_add(delay, self.refresh)

    def refresh(self):
        self.pending = 0
        if not os.path.isdir(self.directory):
            if not self.missing:
                self.missing = True
                emit({"type": "error", "error": "not-found", "dir": self.directory})
            # Poll until the folder exists again (removed or on an unmounted drive).
            self.pending = GLib.timeout_add(2000, self.refresh)
            return False
        if self.missing:
            self.missing = False
            self.attach()
        try:
            items = list_directory(self.directory)
        except GLib.Error as e:
            emit({"type": "error", "error": "read-failed", "message": e.message, "dir": self.directory})
            return False
        for item in items:
            self.attach_thumbnail(item)
        self.last_items = items
        emit({"type": "list", "dir": self.directory, "items": items})
        return False

    def attach_thumbnail(self, item):
        if item["kind"] != "file" or item["image"]:
            return
        if item["mime"] not in self.thumbnailers.by_mime:
            return
        cached = self.thumbs.get(item["path"])
        if cached and cached[0] == item["modified"]:
            item["thumbnail"] = cached[1]
            return
        shared = shared_thumbnail(item["uri"], item["modified"])
        if shared:
            self.thumbs[item["path"]] = (item["modified"], shared)
            item["thumbnail"] = shared
            return
        private = private_thumbnail_path(item["uri"], item["modified"])
        if os.path.isfile(private):
            self.thumbs[item["path"]] = (item["modified"], private)
            item["thumbnail"] = private
            return
        if cached is None or cached[0] != item["modified"]:
            # Mark as in progress so later refreshes do not queue it twice.
            self.thumbs[item["path"]] = (item["modified"], "")
            self.queue.append(dict(item))
            self.pump()

    def pump(self):
        while self.running < THUMBNAIL_WORKERS and self.queue:
            item = self.queue.pop(0)
            out = private_thumbnail_path(item["uri"], item["modified"])
            tmp = out + ".part.png"
            cmd = self.thumbnailers.command(item["mime"], item["path"], item["uri"], tmp)
            if not cmd:
                continue
            try:
                proc = Gio.Subprocess.new(cmd, Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE)
            except GLib.Error:
                continue
            self.running += 1
            timeout = GLib.timeout_add_seconds(THUMBNAIL_TIMEOUT, lambda p=proc: (p.force_exit(), False)[1])
            proc.wait_async(None, self.thumbnail_done, (item, tmp, out, timeout))

    def thumbnail_done(self, proc, result, data):
        item, tmp, out, timeout = data
        GLib.source_remove(timeout)
        self.running -= 1
        try:
            proc.wait_finish(result)
            success = proc.get_successful() and os.path.isfile(tmp) and os.path.getsize(tmp) > 0
        except GLib.Error:
            success = False
        if success:
            os.replace(tmp, out)
            self.thumbs[item["path"]] = (item["modified"], out)
            self.schedule(50)
        else:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        self.pump()


# -------------------------------------------------------------- clipboard ----

FILE_MIME_PRIORITY = ("x-special/gnome-copied-files", "text/uri-list")
TEXT_MIME_PRIORITY = ("text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING")


def serve_clipboard(offers):
    """Owns the Wayland selection (ext-data-control) until another client replaces it."""
    from pywayland.client import Display
    from pywayland.protocol.ext_data_control_v1 import ExtDataControlManagerV1
    from pywayland.protocol.wayland import WlSeat

    display = Display()
    display.connect()
    found = {}

    def on_global(registry, name, interface, version):
        if interface == ExtDataControlManagerV1.name and "manager" not in found:
            found["manager"] = registry.bind(name, ExtDataControlManagerV1, 1)
        elif interface == WlSeat.name and "seat" not in found:
            found["seat"] = registry.bind(name, WlSeat, 1)

    registry = display.get_registry()
    registry.dispatcher["global"] = on_global
    display.roundtrip()
    if "manager" not in found or "seat" not in found:
        display.disconnect()
        raise HelperError("no-data-control")

    state = {"done": False}
    device = found["manager"].get_data_device(found["seat"])
    source = found["manager"].create_data_source()
    for mime in offers:
        source.offer(mime)

    def on_send(_source, mime, fd):
        data = offers.get(mime, b"")
        try:
            os.set_blocking(fd, True)
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
        except OSError:
            pass
        finally:
            os.close(fd)

    def on_cancelled(_source):
        state["done"] = True

    source.dispatcher["send"] = on_send
    source.dispatcher["cancelled"] = on_cancelled
    device.set_selection(source)
    display.roundtrip()
    return display, state


def copy_to_clipboard(paths, cut):
    uris = [pathlib.Path(p).as_uri() for p in paths]
    plain = "\n".join(paths)
    offers = {
        "x-special/gnome-copied-files": ("cut" if cut else "copy") + "\n" + "\n".join(uris),
        "text/uri-list": "\r\n".join(uris) + "\r\n",
        "application/x-kde-cutselection": "1" if cut else "0",
        "text/plain;charset=utf-8": plain,
        "text/plain": plain,
        "UTF8_STRING": plain,
    }
    # The selection owner must outlive this command, so it runs as its own
    # session; it reports readiness on stdout and then detaches from the pipe.
    try:
        owner = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "serve-clipboard"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        raise HelperError("clipboard-failed")
    owner.stdin.write(json.dumps(offers).encode("utf-8"))
    owner.stdin.close()
    status = owner.stdout.readline().decode().strip() or "error:clipboard-failed"
    owner.stdout.close()
    if status != "ok":
        owner.wait(timeout=5)
        raise HelperError(status.split(":", 1)[1])


def cmd_serve_clipboard(_args):
    offers = {k: v.encode("utf-8") for k, v in json.loads(sys.stdin.read()).items()}
    try:
        display, state = serve_clipboard(offers)
    except HelperError as e:
        print(f"error:{e.code}", flush=True)
        return None
    except Exception:
        print("error:clipboard-failed", flush=True)
        return None
    print("ok", flush=True)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1):
        os.dup2(devnull, fd)
    try:
        while not state["done"]:
            if display.dispatch(block=True) == -1:
                break
    finally:
        display.disconnect()
    return None


def wl_paste_types():
    try:
        out = subprocess.run(["wl-paste", "--list-types"], capture_output=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        raise HelperError("clipboard-failed")
    if out.returncode != 0:
        return []
    return [t for t in out.stdout.decode("utf-8", "replace").splitlines() if t]


def wl_paste(mime):
    try:
        out = subprocess.run(["wl-paste", "--no-newline", "--type", mime], capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        raise HelperError("clipboard-failed")
    if out.returncode != 0:
        raise HelperError("clipboard-failed")
    return out.stdout


def uris_to_paths(lines):
    paths, others = [], []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("file://"):
            path = Gio.File.new_for_uri(line).get_path()
            if path:
                paths.append(path)
        elif line.startswith("/"):
            paths.append(line)
        else:
            others.append(line)
    return paths, others


# -------------------------------------------------------- transfer logic ----


def transfer(sources, directory, mode):
    """Copies or moves `sources` into `directory`; mode is copy, move or auto."""
    require_dir(directory)
    try:
        target_dev = os.stat(directory).st_dev
    except OSError as e:
        raise HelperError("not-found", str(e))
    real_dir = os.path.realpath(directory)
    created, errors = [], []
    for src in sources:
        src = os.path.abspath(src)
        if not os.path.lexists(src):
            errors.append({"path": src, "error": "not-found"})
            continue
        is_dir = os.path.isdir(src) and not os.path.islink(src)
        name = os.path.basename(src.rstrip("/")) or "root"
        if is_dir and (real_dir + "/").startswith(os.path.realpath(src) + "/"):
            errors.append({"path": src, "error": "into-itself"})
            continue
        op = mode
        if op == "auto":
            op = "move" if os.lstat(src).st_dev == target_dev else "copy"
        same_parent = os.path.realpath(os.path.dirname(src)) == real_dir
        try:
            if op == "move":
                if same_parent:
                    continue
                created.append(move_into(src, directory, name, is_dir))
            else:
                created.append(copy_into(src, directory, name, is_dir))
        except HelperError as e:
            errors.append({"path": src, "error": e.code, "message": e.message})
        except OSError as e:
            errors.append({"path": src, "error": os_error_code(e), "message": str(e)})
    return created, errors


def copy_into(src, directory, name, is_dir):
    if os.path.islink(src):
        for candidate in candidate_names(name, False):
            dst = os.path.join(directory, candidate)
            try:
                os.symlink(os.readlink(src), dst)
                return dst
            except FileExistsError:
                continue
    dst = reserve_destination(directory, name, is_dir)
    try:
        if is_dir:
            shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=True)
            shutil.copystat(src, dst)
        else:
            shutil.copyfile(src, dst)
            shutil.copystat(src, dst)
    except BaseException:
        # Leave nothing half-copied behind.
        if is_dir:
            shutil.rmtree(dst, ignore_errors=True)
        else:
            try:
                os.unlink(dst)
            except OSError:
                pass
        raise
    return dst


def move_into(src, directory, name, is_dir):
    if os.lstat(src).st_dev == os.stat(directory).st_dev:
        for candidate in candidate_names(name, is_dir):
            dst = os.path.join(directory, candidate)
            try:
                rename_noreplace(src, dst)
                return dst
            except FileExistsError:
                continue
            except OSError as e:
                if e.errno == errno.EEXIST:
                    continue
                raise
    dst = copy_into(src, directory, name, is_dir)
    if is_dir:
        shutil.rmtree(src)
    else:
        os.unlink(src)
    return dst


def os_error_code(e):
    if isinstance(e, PermissionError):
        return "permission"
    if isinstance(e, FileNotFoundError):
        return "not-found"
    if isinstance(e, FileExistsError):
        return "exists"
    if getattr(e, "errno", None) == errno.ENOSPC:
        return "no-space"
    return "io"


def sanitize_filename(name, fallback):
    name = name.replace("/", "-").replace("\0", "").strip()
    name = name.strip(".") or fallback
    encoded = name.encode("utf-8")[:200]
    return encoded.decode("utf-8", "ignore") or fallback


def write_desktop_link(directory, url, name):
    kf = GLib.KeyFile()
    kf.set_string("Desktop Entry", "Version", "1.0")
    kf.set_string("Desktop Entry", "Type", "Link")
    kf.set_string("Desktop Entry", "Name", name)
    kf.set_string("Desktop Entry", "URL", url)
    kf.set_string("Desktop Entry", "Icon", "text-html")
    data = kf.to_data()[0].encode("utf-8")
    path = create_exclusive_file(directory, sanitize_filename(name, "link") + ".desktop", data)
    mark_trusted_launcher(path)
    return path


def mark_trusted_launcher(path):
    os.chmod(path, 0o755)
    # Nemo/Nautilus launch untrusted .desktop files only after a prompt.
    try:
        Gio.File.new_for_path(path).set_attribute_string(
            "metadata::trusted", "true", Gio.FileQueryInfoFlags.NONE, None
        )
    except GLib.Error:
        pass


def url_name(url):
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    if host.startswith("www."):
        host = host[4:]
    return host or url


# ---------------------------------------------------------------- commands ----


def cmd_watch(args):
    Watcher(os.path.abspath(args.dir)).start()
    return None


def cmd_list(args):
    directory = require_dir(os.path.abspath(args.dir))
    return {"items": list_directory(directory)}


def cmd_new_file(args):
    directory = require_dir(args.dir)
    name = validate_name(args.name)
    return {"path": create_exclusive_file(directory, name)}


def cmd_new_folder(args):
    directory = require_dir(args.dir)
    name = validate_name(args.name)
    return {"path": create_exclusive_dir(directory, name)}


def cmd_ensure_dir(args):
    path = os.path.abspath(args.dir)
    if os.path.lexists(path) and not os.path.isdir(path):
        raise HelperError("exists", path)
    os.makedirs(path, exist_ok=True)
    return {"path": path}


def cmd_templates(args):
    tdir = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_TEMPLATES)
    home = os.path.expanduser("~")
    templates = []
    if tdir and os.path.realpath(tdir) != os.path.realpath(home) and os.path.isdir(tdir):
        for item in list_directory(tdir):
            if item["kind"] not in ("file", "folder"):
                continue
            stem, _ext = split_name(item["label"], item["kind"] == "folder")
            item["templateLabel"] = stem
            templates.append(item)
    return {"dir": tdir or "", "templates": templates}


def cmd_from_template(args):
    directory = require_dir(args.dir)
    template = os.path.abspath(args.template)
    if not os.path.exists(template):
        raise HelperError("not-found", template)
    is_dir = os.path.isdir(template)
    return {"path": copy_into(template, directory, os.path.basename(template), is_dir)}


def cmd_app_shortcut(args):
    directory = require_dir(args.dir)
    info = DesktopAppInfo.new(args.app_id if args.app_id.endswith(".desktop") else args.app_id + ".desktop")
    if info is None or not info.get_filename():
        raise HelperError("app-not-found", args.app_id)
    with open(info.get_filename(), "rb") as f:
        data = f.read()
    name = os.path.basename(info.get_filename())
    path = create_exclusive_file(directory, name, data)
    mark_trusted_launcher(path)
    return {"path": path}


def cmd_file_link(args):
    directory = require_dir(args.dir)
    target = os.path.abspath(args.target)
    if not os.path.exists(target):
        raise HelperError("not-found", target)
    name = os.path.basename(target.rstrip("/")) or "root"
    for candidate in candidate_names(name, os.path.isdir(target)):
        dst = os.path.join(directory, candidate)
        try:
            os.symlink(target, dst)
            return {"path": dst}
        except FileExistsError:
            continue


def cmd_url_link(args):
    directory = require_dir(args.dir)
    url = args.url.strip()
    parsed = urllib.parse.urlparse(url)
    if not parsed.scheme:
        url = "https://" + url
        parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https", "ftp", "mailto", "file") or (parsed.scheme != "mailto" and not parsed.netloc and parsed.scheme != "file"):
        raise HelperError("invalid-url")
    name = (args.name or "").strip() or url_name(url)
    return {"path": write_desktop_link(directory, url, name)}


def cmd_rename(args):
    path = os.path.abspath(args.path)
    if not os.path.lexists(path):
        raise HelperError("not-found", path)
    new_name = validate_name(args.name)
    if path.endswith(".desktop") and os.path.isfile(path) and not os.path.islink(path):
        try:
            kf = keyfile_for(path)
            entry_type = kf_get(kf, "Type")
        except GLib.Error:
            entry_type = ""
        if entry_type in ("Application", "Link"):
            # Launchers are renamed by their visible Name, like Nemo does.
            key = "Name"
            for lang in GLib.get_language_names():
                if lang != "C" and f"Name[{lang}]" in kf.get_keys("Desktop Entry")[0]:
                    key = f"Name[{lang}]"
                    break
            kf.set_string("Desktop Entry", key, new_name)
            tmp = path + ".minidesktop-tmp"
            mode = os.stat(path).st_mode & 0o7777
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(kf.to_data()[0])
            os.chmod(tmp, mode)
            os.replace(tmp, path)
            return {"path": path}
    dst = os.path.join(os.path.dirname(path), new_name)
    if dst == path:
        return {"path": path}
    if os.path.lexists(dst) and os.path.normcase(dst) != os.path.normcase(path):
        raise HelperError("exists", new_name)
    try:
        rename_noreplace(path, dst)
    except FileExistsError:
        raise HelperError("exists", new_name)
    return {"path": dst}


def cmd_trash(args):
    trashed, errors = [], []
    for p in args.paths:
        gfile = Gio.File.new_for_path(os.path.abspath(p))
        try:
            gfile.trash(None)
            trashed.append(p)
        except GLib.Error as e:
            code = "trash-unsupported" if e.matches(Gio.io_error_quark(), Gio.IOErrorEnum.NOT_SUPPORTED) else "trash-failed"
            errors.append({"path": p, "error": code, "message": e.message})
    result = {"trashed": trashed, "errors": errors}
    if errors and not trashed:
        raise HelperError(errors[0]["error"], errors[0]["message"], **result)
    return result


def cmd_copy(args):
    paths = [os.path.abspath(p) for p in args.paths if os.path.lexists(p)]
    if not paths:
        raise HelperError("not-found")
    copy_to_clipboard(paths, args.cut)
    return {"count": len(paths), "cut": args.cut}


def cmd_paste_info(_args):
    types = wl_paste_types()
    if any(t in types for t in FILE_MIME_PRIORITY):
        return {"available": True, "kind": "files"}
    if any(t.startswith("image/") for t in types):
        return {"available": True, "kind": "image"}
    if any(t in types for t in TEXT_MIME_PRIORITY):
        return {"available": True, "kind": "text"}
    return {"available": False, "kind": ""}


def cmd_paste(args):
    directory = require_dir(args.dir)
    types = wl_paste_types()
    if not types:
        raise HelperError("clipboard-empty")
    if "x-special/gnome-copied-files" in types:
        lines = wl_paste("x-special/gnome-copied-files").decode("utf-8", "replace").splitlines()
        action = lines[0].strip() if lines else "copy"
        paths, _ = uris_to_paths(lines[1:])
        created, errors = transfer(paths, directory, "move" if action == "cut" else "copy")
        return {"created": created, "errors": errors, "kind": "files"}
    if "text/uri-list" in types:
        paths, others = uris_to_paths(wl_paste("text/uri-list").decode("utf-8", "replace").splitlines())
        if paths:
            cut = "application/x-kde-cutselection" in types and wl_paste("application/x-kde-cutselection").strip() == b"1"
            created, errors = transfer(paths, directory, "move" if cut else "copy")
            return {"created": created, "errors": errors, "kind": "files"}
        if others:
            created = [write_desktop_link(directory, u, url_name(u)) for u in others if urllib.parse.urlparse(u).scheme in ("http", "https")]
            if created:
                return {"created": created, "errors": [], "kind": "links"}
    image_types = [t for t in types if t.startswith("image/")]
    if image_types:
        mime = "image/png" if "image/png" in image_types else image_types[0]
        data = wl_paste(mime)
        ext = {"jpeg": "jpg", "svg+xml": "svg"}.get(mime.split("/", 1)[1], mime.split("/", 1)[1].split("+")[0])
        stamp = time.strftime("%Y-%m-%d %H.%M.%S")
        path = create_exclusive_file(directory, f"{args.image_name} {stamp}.{ext}", data)
        return {"created": [path], "errors": [], "kind": "image"}
    for mime in TEXT_MIME_PRIORITY:
        if mime in types:
            text = wl_paste(mime).decode("utf-8", "replace")
            stripped = text.strip()
            if stripped and "\n" not in stripped and urllib.parse.urlparse(stripped).scheme in ("http", "https"):
                return {"created": [write_desktop_link(directory, stripped, url_name(stripped))], "errors": [], "kind": "links"}
            path = create_exclusive_file(directory, args.text_name, text.encode("utf-8"))
            return {"created": [path], "errors": [], "kind": "text"}
    raise HelperError("clipboard-unsupported")


def cmd_drop(args):
    directory = require_dir(args.dir)
    paths, others = uris_to_paths(args.uris)
    created, errors = transfer(paths, directory, args.mode)
    for url in others:
        if urllib.parse.urlparse(url).scheme in ("http", "https"):
            created.append(write_desktop_link(directory, url, url_name(url)))
    return {"created": created, "errors": errors}


def cmd_drop_text(args):
    directory = require_dir(args.dir)
    text = args.text
    stripped = text.strip()
    if stripped and "\n" not in stripped and urllib.parse.urlparse(stripped).scheme in ("http", "https"):
        return {"created": [write_desktop_link(directory, stripped, url_name(stripped))]}
    return {"created": [create_exclusive_file(directory, args.text_name, text.encode("utf-8"))]}


def build_parser():
    parser = argparse.ArgumentParser(prog="minidesktop")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("watch")
    p.add_argument("dir")
    p.set_defaults(func=cmd_watch)

    p = sub.add_parser("list")
    p.add_argument("dir")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("new-file")
    p.add_argument("dir")
    p.add_argument("name")
    p.set_defaults(func=cmd_new_file)

    p = sub.add_parser("new-folder")
    p.add_argument("dir")
    p.add_argument("name")
    p.set_defaults(func=cmd_new_folder)

    p = sub.add_parser("ensure-dir")
    p.add_argument("dir")
    p.set_defaults(func=cmd_ensure_dir)

    p = sub.add_parser("templates")
    p.set_defaults(func=cmd_templates)

    p = sub.add_parser("from-template")
    p.add_argument("dir")
    p.add_argument("template")
    p.set_defaults(func=cmd_from_template)

    p = sub.add_parser("app-shortcut")
    p.add_argument("dir")
    p.add_argument("app_id")
    p.set_defaults(func=cmd_app_shortcut)

    p = sub.add_parser("file-link")
    p.add_argument("dir")
    p.add_argument("target")
    p.set_defaults(func=cmd_file_link)

    p = sub.add_parser("url-link")
    p.add_argument("dir")
    p.add_argument("url")
    p.add_argument("--name", default="")
    p.set_defaults(func=cmd_url_link)

    p = sub.add_parser("rename")
    p.add_argument("path")
    p.add_argument("name")
    p.set_defaults(func=cmd_rename)

    p = sub.add_parser("trash")
    p.add_argument("paths", nargs="+")
    p.set_defaults(func=cmd_trash)

    p = sub.add_parser("copy")
    p.add_argument("--cut", action="store_true")
    p.add_argument("paths", nargs="+")
    p.set_defaults(func=cmd_copy)

    p = sub.add_parser("serve-clipboard")
    p.set_defaults(func=cmd_serve_clipboard)

    p = sub.add_parser("paste-info")
    p.set_defaults(func=cmd_paste_info)

    p = sub.add_parser("paste")
    p.add_argument("dir")
    p.add_argument("--text-name", default="Pasted Text.txt")
    p.add_argument("--image-name", default="Pasted Image")
    p.set_defaults(func=cmd_paste)

    p = sub.add_parser("drop")
    p.add_argument("dir")
    p.add_argument("mode", choices=["copy", "move", "auto"])
    p.add_argument("uris", nargs="+")
    p.set_defaults(func=cmd_drop)

    p = sub.add_parser("drop-text")
    p.add_argument("dir")
    p.add_argument("text")
    p.add_argument("--text-name", default="Dropped Text.txt")
    p.set_defaults(func=cmd_drop_text)
    return parser


def main():
    # Collation (sort order) and localized .desktop names follow the user's locale.
    try:
        locale.setlocale(locale.LC_ALL, "")
    except locale.Error:
        pass
    args = build_parser().parse_args()
    try:
        result = args.func(args)
    except HelperError as e:
        emit({"ok": False, "error": e.code, "message": e.message, **e.extra})
        return 1
    except OSError as e:
        emit({"ok": False, "error": os_error_code(e), "message": str(e)})
        return 1
    except GLib.Error as e:
        emit({"ok": False, "error": "io", "message": e.message})
        return 1
    if result is not None:
        emit({"ok": True, **result})
    return 0


if __name__ == "__main__":
    sys.exit(main())
