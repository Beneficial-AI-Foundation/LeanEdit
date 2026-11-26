/* Thin Tcl/Tk + POSIX bridge. Editor behavior is in EditorLean.lean.
   Built against Lean 4.35.0-rc3's C ABI and Tcl/Tk 9.0.4. */
#include <lean/lean.h>
#include <tcl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <signal.h>
#include <mach-o/dyld.h>
extern int Tk_Init(Tcl_Interp *);
extern void Tk_MainLoop(void);
extern lean_object *editor_event(lean_object *);
static Tcl_Interp *interp;
static int diagnostics;
static int tracing_startup;
static int gui_test_mode;
static FILE *diagnostic_stream;
/* Log Finder launches beside the app when that directory is writable. This
   needs no Terminal and survives Tk replacing stdout/stderr with /dev/null. */
static void start_finder_diagnostics(const char *executable_directory) {
    if (diagnostics || isatty(STDIN_FILENO)) return;
    char path[PATH_MAX];
    if (snprintf(path,sizeof(path),"%s/../../../EditorLean-Finder-startup.log",
                 executable_directory) >= sizeof(path)) return;
    int fd = open(path,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC|O_NOFOLLOW,0600);
    if (fd < 0) return;
    diagnostic_stream = fdopen(fd,"w");
    if (!diagnostic_stream) { close(fd); return; }
    diagnostics = tracing_startup = 1;
}
static void trace_startup(const char *stage) {
    if (!diagnostics) return;
    fprintf(diagnostic_stream, "[EditorLean pid=%d main-thread=%d] %s\n",
            getpid(), pthread_main_np(), stage);
    fflush(diagnostic_stream);
}
/* Record why the app ended. Spontaneous closes left no crash report, so the
   log must say whether the app quit on request, lost its last window, was
   signalled, or exited some other way. Signal handlers use only write(). */
static char exit_prefix[2][64]; /* [0] off, [1] on the main thread; built ahead of time */
static void write_exit_line(const char *text) {
    if (!diagnostics) return;
    int fd = fileno(diagnostic_stream);
    const char *prefix = exit_prefix[pthread_main_np() != 0];
    (void)!write(fd, prefix, strlen(prefix));
    (void)!write(fd, text, strlen(text));
    (void)!write(fd, "\n", 1);
}
static void log_process_exit(void) { write_exit_line("process exiting"); }
static void log_fatal_signal(int sig) {
    write_exit_line(sig == SIGTERM ? "terminated by SIGTERM (another process ended the app)" :
                    sig == SIGHUP  ? "terminated by SIGHUP (its terminal or session closed)" :
                    sig == SIGINT  ? "terminated by SIGINT (Control-C)" :
                                     "terminated by a fatal signal (crash)");
    signal(sig, SIG_DFL);
    raise(sig);
}
static void install_exit_logging(void) {
    static int installed;
    if (!diagnostics || installed) return;
    installed = 1;
    for (int main_thread = 0; main_thread < 2; ++main_thread)
        snprintf(exit_prefix[main_thread], sizeof(exit_prefix[0]),
                 "[EditorLean pid=%d main-thread=%d] exit: ", getpid(), main_thread);
    atexit(log_process_exit);
    int signals[] = {SIGTERM, SIGHUP, SIGINT, SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE};
    for (size_t i = 0; i < sizeof(signals)/sizeof(*signals); ++i) signal(signals[i], log_fatal_signal);
}
lean_object *editor_log_event(b_lean_obj_arg message) {
    trace_startup(lean_string_cstr(message));
    return lean_io_result_mk_ok(lean_box(0));
}
/* Lean 4.35 normally moves main onto a large-stack worker. AppKit/Tk must
   instead run on the OS main thread. Set Lean's supported switch before its
   generated main executes; this also covers Finder launches with no shell. */
__attribute__((constructor)) static void editor_configure_main_thread(void) {
    setenv("LEAN_MAIN_USE_THREAD", "0", 1);
    diagnostics = getenv("EDITORLEAN_DIAGNOSTICS") != NULL;
    tracing_startup = diagnostics;
    if (diagnostics) {
        /* Keep a private copy: macOS Tk may replace the standard channels. */
        diagnostic_stream = fdopen(dup(STDERR_FILENO), "w");
        if (!diagnostic_stream) { diagnostics = 0; tracing_startup = 0; }
    }
    trace_startup("native executable entered (diagnostic build 1.0.4)");
}
/* The GUI self-test is not a Finder launch, even when stdin is /dev/null
   (CI, launchd, non-interactive shells). It must not overwrite the Finder
   startup log, and its PASS/FAIL output must survive Tk's stdio redirect. */
lean_object *editor_enable_gui_test_mode(void) {
    gui_test_mode = 1;
    return lean_io_result_mk_ok(lean_box(0));
}
lean_object *editor_is_main_thread(void) {
    return lean_io_result_mk_ok(lean_box(pthread_main_np() != 0));
}
uint8_t editor_is_word(uint32_t c) {
    return c == '_' || Tcl_UniCharIsAlnum((int)c);
}
static lean_object *failure(const char *message) {
    return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(message)));
}
static lean_object *result(int code) {
    Tcl_Size n; const char *s = Tcl_GetStringFromObj(Tcl_GetObjResult(interp), &n);
    lean_object *value = lean_mk_string_from_bytes(s, (size_t)n);
    if (code != TCL_OK && tracing_startup) trace_startup(s);
    return code == TCL_OK ? lean_io_result_mk_ok(value) : lean_io_result_mk_error(lean_mk_io_user_error(value));
}
static int event_callback(void *unused, Tcl_Interp *ip, Tcl_Size count, Tcl_Obj *const words[]) {
    (void)unused;
    lean_object *args = lean_mk_empty_array();
    for (Tcl_Size i=1; i<count; ++i) {
        Tcl_Size n; const char *s = Tcl_GetStringFromObj(words[i], &n);
        args = lean_array_push(args, lean_mk_string_from_bytes(s, (size_t)n));
    }
    lean_object *answer = editor_event(args);
    int code = lean_io_result_is_ok(answer) ? TCL_OK : TCL_ERROR;
    if (code != TCL_OK) {
        lean_io_result_show_error(answer);
        Tcl_SetObjResult(ip, Tcl_NewStringObj("Editor action failed; see diagnostic output.", -1));
    } else Tcl_ResetResult(ip);
    lean_dec(answer);
    return code;
}
lean_object *editor_tk_init(uint8_t gui) {
    if (gui && !pthread_main_np())
        return failure("EditorLean must initialize its macOS GUI on the main thread.");
    char exe[PATH_MAX]; uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe,&size) != 0) return failure("Executable path is too long.");
    char resolved[PATH_MAX], library[PATH_MAX], startup[PATH_MAX] = "";
    if (realpath(exe, resolved)) {
        char *slash = strrchr(resolved, '/');
        if (slash) {
            *slash = 0;
            if (gui) {
                if (!gui_test_mode) start_finder_diagnostics(resolved);
                trace_startup("native GUI startup: EditorLean 1.0.4");
            }
            snprintf(library,sizeof(library),"%s/../Resources/tcl9.0",resolved);
            if (access(library,R_OK)==0) setenv("TCL_LIBRARY",library,1);
            snprintf(library,sizeof(library),"%s/../Resources/tk9.0",resolved);
            if (access(library,R_OK)==0) setenv("TK_LIBRARY",library,1);
            snprintf(startup,sizeof(startup),"%s/../Resources/native-startup.tcl",resolved);
        }
    }
    trace_startup("initializing Tcl");
    Tcl_FindExecutable(exe);
    interp = Tcl_CreateInterp();
    /* Finder supplies /dev/null as stdin. Without a startup script Tk treats
       this as an interactive Wish session and creates a second interpreter
       and console. Our native Lean main owns startup instead. */
    if (!startup[0] || access(startup,R_OK) != 0)
        return failure("The app is missing Resources/native-startup.tcl. Rebuild the complete app bundle.");
    Tcl_SetStartupScript(Tcl_NewStringObj(startup,-1),"utf-8");
    unsetenv("TK_CONSOLE");
    Tcl_SetVar(interp,"tcl_interactive","0",TCL_GLOBAL_ONLY);
    Tcl_SetVar(interp,"argv0",exe,TCL_GLOBAL_ONLY);
    Tcl_SetVar(interp,"argc","0",TCL_GLOBAL_ONLY);
    Tcl_SetVar(interp,"argv","",TCL_GLOBAL_ONLY);
    trace_startup("configured native noninteractive startup (no Wish console)");
    if (Tcl_Init(interp) != TCL_OK) return result(TCL_ERROR);
    trace_startup("Tcl initialized");
    install_exit_logging();
    Tcl_CreateObjCommand2(interp,"editor",event_callback,NULL,NULL);
    if (gui) {
        trace_startup("initializing macOS Tk");
        /* With stdin at /dev/null, macOS Tk sends stdout/stderr to /dev/null.
           Restore them in test mode so results and failures stay visible. */
        int saved_out = -1, saved_err = -1;
        if (gui_test_mode) {
            fflush(stdout); fflush(stderr);
            saved_out = dup(STDOUT_FILENO); saved_err = dup(STDERR_FILENO);
        }
        int code = Tk_Init(interp);
        if (saved_out >= 0) { fflush(stdout); dup2(saved_out, STDOUT_FILENO); close(saved_out); }
        if (saved_err >= 0) { fflush(stderr); dup2(saved_err, STDERR_FILENO); close(saved_err); }
        if (code != TCL_OK) return result(TCL_ERROR);
        trace_startup("macOS Tk initialized");
    }
    return lean_io_result_mk_ok(lean_box(0));
}
lean_object *editor_startup_configured(void) {
    Tcl_Obj *startup = Tcl_GetStartupScript(NULL);
    const char *interactive = Tcl_GetVar(interp,"tcl_interactive",TCL_GLOBAL_ONLY);
    int ready = startup && access(Tcl_GetString(startup),R_OK)==0 &&
                interactive && strcmp(interactive,"0")==0 && !getenv("TK_CONSOLE");
    return lean_io_result_mk_ok(lean_box(ready));
}
lean_object *editor_tk_call(b_lean_obj_arg args) {
    size_t count = lean_array_size(args);
    if (tracing_startup && count) {
        /* Only command names; never document text or command arguments. */
        trace_startup(lean_string_cstr(lean_array_get_core(args,0)));
    }
    Tcl_Obj **words = calloc(count ? count : 1,sizeof(*words));
    if (!words) return failure("Out of memory.");
    for (size_t i=0;i<count;++i) {
        lean_object *s = lean_array_get_core(args,i);
        words[i] = Tcl_NewStringObj(lean_string_cstr(s),(Tcl_Size)lean_string_size(s)-1);
        Tcl_IncrRefCount(words[i]);
    }
    int code = Tcl_EvalObjv(interp,(Tcl_Size)count,words,TCL_EVAL_GLOBAL);
    lean_object *answer = result(code);
    for (size_t i=0;i<count;++i) Tcl_DecrRefCount(words[i]);
    free(words); return answer;
}
lean_object *editor_tk_eval(b_lean_obj_arg script) {
    return result(Tcl_EvalEx(interp,lean_string_cstr(script),(Tcl_Size)lean_string_size(script)-1,TCL_EVAL_GLOBAL));
}
lean_object *editor_tk_words(b_lean_obj_arg value) {
    Tcl_Obj *object = Tcl_NewStringObj(lean_string_cstr(value),(Tcl_Size)lean_string_size(value)-1);
    Tcl_IncrRefCount(object);
    Tcl_Size count; Tcl_Obj **words;
    if (Tcl_ListObjGetElements(interp,object,&count,&words) != TCL_OK) { Tcl_DecrRefCount(object); return result(TCL_ERROR); }
    lean_object *args = lean_mk_empty_array();
    for (Tcl_Size i=0;i<count;++i) {
        Tcl_Size n; const char *s = Tcl_GetStringFromObj(words[i],&n);
        args = lean_array_push(args,lean_mk_string_from_bytes(s,(size_t)n));
    }
    Tcl_DecrRefCount(object);
    return lean_io_result_mk_ok(args);
}
lean_object *editor_tk_loop(void) {
    trace_startup("window construction finished; entering GUI event loop");
    tracing_startup = 0;
    Tk_MainLoop();
    trace_startup("GUI event loop exited");
    return lean_io_result_mk_ok(lean_box(0));
}
lean_object *editor_atomic_write(b_lean_obj_arg path, b_lean_obj_arg bytes) {
    const char *target = lean_string_cstr(path);
    char temp[PATH_MAX];
    if (snprintf(temp,sizeof(temp),"%s.editor-XXXXXX",target) >= sizeof(temp)) return failure("Filename too long.");
    int fd = mkstemp(temp);
    if (fd < 0) return failure(strerror(errno));
    struct stat st;
    if (stat(target,&st)==0 && fchmod(fd,st.st_mode & 0777)<0) goto fail;
    size_t size = lean_sarray_size(bytes), done=0;
    while (done<size) {
        ssize_t n = write(fd,lean_sarray_cptr(bytes)+done,size-done);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) goto fail;
        done+=(size_t)n;
    }
    if (fsync(fd)<0) goto fail;
    if (close(fd)<0) { fd=-1; goto fail; }
    fd=-1;
    if (rename(temp,target)<0) goto fail;
    return lean_io_result_mk_ok(lean_box(0));
fail:;
    int error=errno;
    if (fd>=0) close(fd);
    unlink(temp);
    return failure(strerror(error));
}
