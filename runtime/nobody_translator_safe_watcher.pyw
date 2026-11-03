#!/usr/bin/env python
"""
SAFE permanent background watcher for "Nobody - The Turnaround" RU translation.
Distribution copy (v1.0): optional helpers are skipped if not present.

Unlike the old nobody_translator_watcher.pyw, this version does NOT run the
blanket uifix (font swap + global bestFit) that breaks the market. Instead it:
  1. waits for the game to start,
  2. injects the RU dictionary (lang dict patch, same as inject_patch.py dict),
  3. launches header_guard.pyw (targeted bestFit + text fixes) and
     hook_tooltips.py (set_text interceptor),
  4. keeps monitoring while the game runs, then waits for the next launch.

Logs to _watcher_safe.log.
Usage:
  pythonw nobody_translator_safe_watcher.pyw --launch "<game>\\Nobody.exe"
      session mode (used by the desktop shortcut): start the game, patch it,
      exit shortly after the game closes. Nothing stays in the background.
  pythonw nobody_translator_safe_watcher.pyw
      legacy mode: watch for the game forever (v1.0.0 autostart).
"""
import sys, json, frida, os, time, ctypes, subprocess
from ctypes import wintypes

BASE = os.path.dirname(os.path.abspath(__file__))
GLOSSARY = os.path.join(BASE, "cn_ru_glossary.json")
LOG = os.path.join(BASE, "_watcher_safe.log")
GAME_EXE = "nobody.exe"
PYW = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
GUARD = os.path.join(BASE, "header_guard.pyw")
HOOK = os.path.join(BASE, "hook_tooltips.py")
MARKER = os.path.join(BASE, "_patched_pid.txt")

with open(GLOSSARY, "r", encoding="utf-8") as f:
    GLOSSARY_DICT = json.load(f)
gloss_json = json.dumps(GLOSSARY_DICT, ensure_ascii=False)

DICT_JS = r"""
'use strict';
var E={};
try{Process.findModuleByName('GameAssembly.dll').enumerateExports().forEach(function(e){E[e.name]=e.address;});}catch(x){send(JSON.stringify({error:'no GA module'}));}
function W(n,r,a){return new NativeFunction(E[n],r,a);}
var fDomainGet=W('il2cpp_domain_get','pointer',[]);
var fGetAsm=W('il2cpp_domain_get_assemblies','pointer',['pointer','pointer']);
var fClsName=W('il2cpp_class_from_name','pointer',['pointer','pointer','pointer']);
var fClsMethods=W('il2cpp_class_get_methods','pointer',['pointer','pointer']);
var fMetName=W('il2cpp_method_get_name','pointer',['pointer']);
var fImgName=W('il2cpp_image_get_name','pointer',['pointer']);
var fStrLen=W('il2cpp_string_length','int',['pointer']);
var fStrChars=W('il2cpp_string_chars','pointer',['pointer']);
var fStrNew=W('il2cpp_string_new','pointer',['pointer']);
var fThreadAttach=W('il2cpp_thread_attach','void',['pointer']);
var fFldName=W('il2cpp_class_get_field_from_name','pointer',['pointer','pointer']);
var fFldOff=W('il2cpp_field_get_offset','int',['pointer']);

var domain=fDomainGet();fThreadAttach(domain);
var nBuf=Memory.alloc(4);var asmArr=fGetAsm(domain,nBuf);var nAsm=nBuf.readU32();
var imgs=[];
for(var i=0;i<nAsm;i++){var a=asmArr.add(i*8).readPointer();var im=a.readPointer();imgs.push({p:im,n:fImgName(im).readUtf8String()});}
function findCls(name){for(var i=0;i<imgs.length;i++){var k=fClsName(imgs[i].p,Memory.allocUtf8String(''),Memory.allocUtf8String(name));if(!k.isNull())return k;}return null;}
function rStr(p){if(!p||p.isNull())return null;try{var l=fStrLen(p);if(l>0&&l<10000)return fStrChars(p).readUtf16String(l);return null;}catch(e){return null;}}

var GLOSS = %GLOSS_JSON%;
var SKIP_KEYS = {};

// Attach once and wait inside the game until the dictionary is fully loaded:
// it is patched when its size is non-zero and unchanged for one poll interval.
var POLL_MS=1000, MAX_POLLS=120, polls=0, lastCount=-1;
function retry(reason){
    if(++polls>=MAX_POLLS){send(JSON.stringify({error:'timeout: '+reason}));return;}
    setTimeout(attemptPatch,POLL_MS);
}
function attemptPatch(){
    var cls=findCls('LanguageTools');
    if(!cls){retry('no LT');return;}
    var it=Memory.alloc(8);var m=fClsMethods(cls,it);
    var inst=null;
    while(m&&!m.isNull()){var nm=fMetName(m).readUtf8String();if(nm==='get_Inst'){inst=new NativeFunction(m.readPointer(),'pointer',['pointer','pointer'])(ptr(0),ptr(0));break;}m=fClsMethods(cls,it);}
    if(!inst||inst.isNull()){retry('no inst');return;}

    var lcdF=fFldName(cls,Memory.allocUtf8String('LanguageConfigDic'));
    var dlcF=fFldName(cls,Memory.allocUtf8String('DialogLanguageConfigDic'));
    var lcdOff=fFldOff(lcdF);
    var dlcOff=dlcF&&!dlcF.isNull()?fFldOff(dlcF):-1;
    var lcdPtr=inst.add(lcdOff).readPointer();
    var dlcPtr=dlcOff>=0?inst.add(dlcOff).readPointer():ptr(0);
    var count=(lcdPtr&&!lcdPtr.isNull())?lcdPtr.add(0x20).readS32():0;
    if(count<=0||count!==lastCount){lastCount=count;retry('dict loading ('+count+')');return;}

    var patched=0, noGloss=0;
    function processDict(dictPtr){
        if(!dictPtr||dictPtr.isNull()) return;
        var count=dictPtr.add(0x20).readS32();
        if(count<=0||count>200000) return;
        var base=dictPtr.add(0x18).readPointer().add(0x20);
        for(var i=0;i<count;i++){
            var entry=base.add(i*24);
            var key=rStr(entry.add(8).readPointer());
            if(!key) continue;
            var vp=entry.add(0x10).readPointer();
            if(!vp||vp.isNull()) continue;
            var ru=GLOSS[key];
            if(!ru){noGloss++;continue;}
            if(SKIP_KEYS[key]) continue;
            var ruStr=fStrNew(Memory.allocUtf8String(ru));
            vp.add(0x18).writePointer(ruStr);
            patched++;
        }
    }
    processDict(lcdPtr);
    if(!dlcPtr.isNull()) processDict(dlcPtr);
    send(JSON.stringify({done:true,patched:patched,noGloss:noGloss,polls:polls}));
}
attemptPatch();
"""
DICT_JS = DICT_JS.replace("%GLOSS_JSON%", gloss_json)


def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


def find_game_pid():
    try:
        snap = ctypes.windll.kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
        if snap == -1:
            return None
        try:
            class P(ctypes.Structure):
                _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                            ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                            ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                            ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", wintypes.LONG),
                            ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_char * 260)]
            pe = P(); pe.dwSize = ctypes.sizeof(P)
            ok = ctypes.windll.kernel32.Process32First(snap, ctypes.byref(pe))
            while ok:
                if pe.szExeFile.decode("utf-8", "ignore").lower() == GAME_EXE:
                    return int(pe.th32ProcessID)
                ok = ctypes.windll.kernel32.Process32Next(snap, ctypes.byref(pe))
            return None
        finally:
            ctypes.windll.kernel32.CloseHandle(snap)
    except Exception:
        return None


def process_alive(pid):
    if not pid:
        return False
    try:
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
        if not h:
            return False
        ctypes.windll.kernel32.CloseHandle(h)
        return True
    except Exception:
        return False


def module_loaded(pid, name_prefix):
    """True if the given process already has a module whose name starts with
    name_prefix (e.g. 'frida-agent'). Used to avoid re-injecting frida into a
    process that is already hooked by a previous watcher/guard/hook run —
    a second attach crashes the game (BEX64 in frida-agent.dll)."""
    try:
        if not process_alive(pid):
            return False
        snap = ctypes.windll.kernel32.CreateToolhelp32Snapshot(0x00000008, pid)
        if snap == -1:
            return False
        try:
            class M(ctypes.Structure):
                _fields_ = [("dwSize", wintypes.DWORD), ("th32ModuleID", wintypes.DWORD),
                            ("th32ProcessID", wintypes.DWORD), ("GlblcntUsage", wintypes.DWORD),
                            ("ProccntUsage", wintypes.DWORD), ("modBaseAddr", ctypes.c_void_p),
                            ("modBaseSize", wintypes.DWORD), ("hModule", ctypes.c_void_p),
                            ("szModule", ctypes.c_char * 256), ("szExePath", ctypes.c_char * 260)]
            m = M(); m.dwSize = ctypes.sizeof(M)
            ok = ctypes.windll.kernel32.Module32First(snap, ctypes.byref(m))
            while ok:
                name = m.szModule.decode("utf-8", "ignore").lower()
                if name.startswith(name_prefix.lower()):
                    return True
                ok = ctypes.windll.kernel32.Module32Next(snap, ctypes.byref(m))
            return False
        finally:
            ctypes.windll.kernel32.CloseHandle(snap)
    except Exception:
        return True  # on error, assume hooked: never re-inject blindly


def game_ready(pid):
    """Game is 'ready' when GameAssembly.dll is loaded (lang table exists)."""
    try:
        if not process_alive(pid):
            return False
        snap = ctypes.windll.kernel32.CreateToolhelp32Snapshot(0x00000008, pid)
        if snap == -1:
            return False
        try:
            class M(ctypes.Structure):
                _fields_ = [("dwSize", wintypes.DWORD), ("th32ModuleID", wintypes.DWORD),
                            ("th32ProcessID", wintypes.DWORD), ("GlblcntUsage", wintypes.DWORD),
                            ("ProccntUsage", wintypes.DWORD), ("modBaseAddr", ctypes.c_void_p),
                            ("modBaseSize", wintypes.DWORD), ("hModule", ctypes.c_void_p),
                            ("szModule", ctypes.c_char * 256), ("szExePath", ctypes.c_char * 260)]
            m = M(); m.dwSize = ctypes.sizeof(M)
            ok = ctypes.windll.kernel32.Module32First(snap, ctypes.byref(m))
            while ok:
                name = m.szModule.decode("utf-8", "ignore").lower()
                if name == "gameassembly.dll":
                    return True
                ok = ctypes.windll.kernel32.Module32Next(snap, ctypes.byref(m))
            return False
        finally:
            ctypes.windll.kernel32.CloseHandle(snap)
    except Exception:
        return True


def apply_dict_patch(pid):
    """Inject the dictionary once; True on patched>0."""
    session = None
    script = None
    try:
        session = frida.attach(pid)
    except Exception as e:
        log(f"attach fail pid={pid}: {e}")
        return False
    final = [None]
    def on_msg(msg, data):
        if msg['type'] == 'send':
            try:
                d = json.loads(msg['payload'])
                if d.get('done') or d.get('error'):
                    final[0] = d
            except Exception:
                pass
        elif msg['type'] == 'error':
            final[0] = {'error': msg.get('description', '')}
    try:
        script = session.create_script(DICT_JS)
        script.on('message', on_msg)
        script.load()
        deadline = time.time() + 150  # the script itself polls for up to 120 s
        while time.time() < deadline and not final[0]:
            time.sleep(0.3)
        r = final[0]
        if not r:
            log(f"DICT pid={pid} TIMEOUT")
            return False
        log(f"dict pid={pid} ok={r.get('done')} patched={r.get('patched')} polls={r.get('polls')} {r.get('error', '')}")
        if r.get('error'):
            return False
        return bool(r.get('done') and r.get('patched', 0) > 0)
    except Exception as e:
        log(f"dict error pid={pid}: {e}")
        return False
    finally:
        try:
            if script is not None:
                script.unload()
        except Exception:
            pass
        try:
            if session is not None:
                session.detach()
        except Exception:
            pass


def read_marker():
    """Pid of the last game process whose dict was successfully patched."""
    try:
        with open(MARKER, "r", encoding="utf-8") as f:
            v = f.read().strip()
        return int(v) if v.isdigit() else None
    except Exception:
        return None


def write_marker(pid):
    try:
        with open(MARKER, "w", encoding="utf-8") as f:
            f.write(str(pid))
    except Exception:
        pass


def launch_aux(script):
    # Distribution build: auxiliary scripts (header_guard.pyw / hook_tooltips.py)
    # are optional and may be absent from a release package.
    try:
        if not os.path.exists(script):
            log(f"skip optional helper (not present): {os.path.basename(script)}")
            return False
        subprocess.Popen([PYW, script], cwd=BASE,
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return True
    except Exception as e:
        log(f"launch {os.path.basename(script)} failed: {e}")
        return False


def handle_game(pid):
    log(f"game found pid={pid}, waiting for GameAssembly.dll...")
    t0 = time.time()
    while time.time() - t0 < 90:
        if not process_alive(pid):
            log(f"pid={pid} exited while waiting")
            return False
        if game_ready(pid):
            break
        time.sleep(3)
    time.sleep(2)  # il2cpp itself; the dictionary readiness is polled inside the script
    marked = read_marker()
    if module_loaded(pid, "frida-agent") and marked == pid:
        log(f"pid={pid} already hooked AND dict marked (pid={marked}); ensuring aux only")
        launch_aux(GUARD)
        launch_aux(HOOK)
        return True
    if module_loaded(pid, "frida-agent") and marked != pid:
        log(f"pid={pid} frida-agent present but marker={marked} != pid; stale guard attach, will patch dict")
    success = False
    for attempt in range(1, 3):
        if not process_alive(pid):
            log(f"pid={pid} exited before patch")
            return False
        log(f"pid={pid} dict attempt {attempt}/2")
        if apply_dict_patch(pid):
            success = True
            break
        time.sleep(5)
    if not success:
        log(f"pid={pid} dict patch FAILED after 2 attempts")
        return False
    log(f"pid={pid} PATCH SUCCESS, writing dict marker")
    write_marker(pid)
    launch_aux(GUARD)
    time.sleep(1)
    launch_aux(HOOK)
    log(f"pid={pid} guard+hook launched (no kill: avoids BEX64)")
    return True


SESSION_WAIT_START = 300  # s to wait for the game window after launching it
SESSION_GRACE = 30        # s without a game process before the session ends
                          # (covers a Steam DRM relaunch, which gets a new pid)


def run_session(game_exe):
    """Start the game, patch every game process that appears, exit when it is gone."""
    log(f"=== session started pid={os.getpid()} game={game_exe} ===")
    if not find_game_pid():
        try:
            subprocess.Popen([game_exe], cwd=os.path.dirname(game_exe))
        except Exception as e:
            log(f"cannot start the game: {e}")
            ctypes.windll.user32.MessageBoxW(
                None, f"Не удалось запустить игру:\n{game_exe}\n\n{e}",
                "Nobody RU", 0x10)
            return
    handled = set()
    started = time.time()
    last_seen = None
    while True:
        pid = find_game_pid()
        now = time.time()
        if pid is not None:
            last_seen = now
            if pid not in handled:
                handled.add(pid)
                try:
                    handle_game(pid)
                except Exception as e:
                    log(f"handle_game error pid={pid}: {e}")
        elif last_seen is None and now - started > SESSION_WAIT_START:
            log("game did not start, session ends")
            return
        elif last_seen is not None and now - last_seen > SESSION_GRACE:
            log("game closed, session ends")
            return
        time.sleep(3)


def main():
    log(f"=== safe watcher started pid={os.getpid()} ===")
    handled = {}
    while True:
        pid = find_game_pid()
        if pid is not None and pid not in handled:
            handled[pid] = time.time()
            try:
                handle_game(pid)
            except Exception as e:
                log(f"handle_game error pid={pid}: {e}")
        handled = {p: t for p, t in handled.items() if process_alive(p)}
        time.sleep(3)


if __name__ == '__main__':
    try:
        _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        _k32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
        _k32.CreateMutexW.restype = ctypes.c_void_p
        launch = sys.argv[sys.argv.index("--launch") + 1] if "--launch" in sys.argv[:-1] else None
        m = _k32.CreateMutexW(None, False, "Local\\NobodyTranslatorSafeWatcher")
        if m == 0 or ctypes.get_last_error() == 183:
            log("another instance already running, exiting")
            if launch and not find_game_pid():
                # The running instance patches the game; just start it.
                subprocess.Popen([launch], cwd=os.path.dirname(launch))
            raise SystemExit(0)
        if launch:
            run_session(launch)
        else:
            main()
    except SystemExit:
        pass
    except Exception as e:
        log(f"safe watcher crashed: {e}")
        time.sleep(5)