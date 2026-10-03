package dev.dshd.app;

import android.os.Handler;
import android.os.Looper;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The one run in flight, and what the last one said.
 *
 * <p>The service runs the shell; the activity draws it. They are in the same
 * process, so the state between them is a static object rather than a binder,
 * a broadcast or a livedata — the smallest thing that works, with the one rule
 * that matters: the worker thread never touches a view, and the UI thread never
 * reads a mutable field. Everything crosses through {@link #snapshot()}.
 *
 * <p>The log is a bounded ring. A first install prints tens of thousands of
 * lines (a 1 GB download, then npm), and an app that keeps all of them is an app
 * the low-memory killer visits during the one operation that must not be
 * interrupted.
 */
public final class RunState {

    public interface Observer {
        void onChanged();
    }

    /** How many log lines are kept. The journal on the device keeps all of them. */
    private static final int LOG_LINES = 800;

    private static final Object LOCK = new Object();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Protocol.State STATE = new Protocol.State();
    private static final ArrayDeque<String> LOG = new ArrayDeque<String>();

    private static Observer observer;
    private static boolean busy;
    private static boolean finishing;
    private static String verb = "";
    private static String fallbackFailure;
    private static boolean renderPosted;

    private RunState() {
    }

    // ------------------------------------------------------------------
    // Writing (worker thread)
    // ------------------------------------------------------------------

    public static void begin(String runVerb) {
        synchronized (LOCK) {
            STATE.steps.clear();
            STATE.info.clear();
            STATE.url = null;
            STATE.doneOk = null;
            STATE.exitCode = null;
            STATE.failStep = null;
            STATE.failDetail = "";
            STATE.nonce = null;
            STATE.nonceConflict = false;
            LOG.clear();
            verb = runVerb;
            busy = true;
            finishing = false;
            fallbackFailure = null;
            log("== dshd " + runVerb + " ==");
        }
        notifyChanged();
    }

    public static void stdout(String line) {
        Protocol.Event event = Protocol.parse(line);
        synchronized (LOCK) {
            if (event != null) {
                STATE.accept(event);
            }
            log(line);
        }
        notifyChanged();
    }

    public static void stderr(String line) {
        synchronized (LOCK) {
            log("! " + line);
        }
        notifyChanged();
    }

    public static void failed(String message) {
        synchronized (LOCK) {
            fallbackFailure = message;
            busy = false;
            finishing = true;
            log("! " + message);
        }
        notifyChanged();
    }

    public static void exited(int status) {
        synchronized (LOCK) {
            STATE.exitCode = Integer.valueOf(status);
            busy = false;
            finishing = true;
        }
        notifyChanged();
    }

    private static void log(String line) {
        while (LOG.size() >= LOG_LINES) {
            LOG.removeFirst();
        }
        LOG.addLast(line);
    }

    // ------------------------------------------------------------------
    // Reading (UI thread)
    // ------------------------------------------------------------------

    /** An immutable view, built fresh: the UI never iterates a live collection. */
    public static final class View {
        public final boolean busy;
        public final boolean finished;
        public final boolean ok;
        public final String reason;
        public final String verb;
        public final String url;
        public final Map<String, String> info;
        public final List<Protocol.Step> steps;
        public final List<String> log;

        View(boolean busy, boolean finished, boolean ok, String reason, String verb,
             String url, Map<String, String> info, List<Protocol.Step> steps, List<String> log) {
            this.busy = busy;
            this.finished = finished;
            this.ok = ok;
            this.reason = reason;
            this.verb = verb;
            this.url = url;
            this.info = info;
            this.steps = steps;
            this.log = log;
        }

        public String info(String key) {
            String v = info.get(key);
            return v == null ? "" : v;
        }

        public boolean yes(String key) {
            return "yes".equals(info.get(key));
        }
    }

    public static View snapshot() {
        synchronized (LOCK) {
            List<Protocol.Step> steps = new ArrayList<Protocol.Step>(STATE.steps.size());
            for (int i = 0; i < STATE.steps.size(); i++) {
                Protocol.Step s = STATE.steps.get(i);
                Protocol.Step copy = new Protocol.Step(s.name, s.message);
                copy.state = s.state;
                steps.add(copy);
            }
            String reason = fallbackFailure;
            boolean ok = false;
            if (reason == null && finishing) {
                reason = STATE.failureReason();
                ok = STATE.succeeded();
            }
            return new View(busy, finishing, ok, reason, verb, STATE.url,
                    new LinkedHashMap<String, String>(STATE.info), steps,
                    new ArrayList<String>(LOG));
        }
    }

    /**
     * The step in progress, as one line, without copying anything: the
     * notification asks for this on every output line, so it must not walk the
     * log ring the way a snapshot does.
     */
    public static String currentStepText() {
        synchronized (LOCK) {
            for (int i = 0; i < STATE.steps.size(); i++) {
                Protocol.Step s = STATE.steps.get(i);
                if (!s.finished()) {
                    return s.message.isEmpty() ? s.name : s.name + " — " + s.message;
                }
            }
        }
        return "";
    }

    /** For copying into a bug report: the log plus what the run concluded. */
    public static String logText() {        View v = snapshot();
        StringBuilder b = new StringBuilder();
        b.append("# dshd ").append(v.verb).append('\n');
        for (Map.Entry<String, String> e : v.info.entrySet()) {
            b.append("# ").append(e.getKey()).append(" = ").append(e.getValue()).append('\n');
        }
        if (v.reason != null) {
            b.append("# result: ").append(v.reason).append('\n');
        }
        for (int i = 0; i < v.log.size(); i++) {
            b.append(v.log.get(i)).append('\n');
        }
        return b.toString();
    }

    // ------------------------------------------------------------------
    // Notification, coalesced: a download prints faster than the screen redraws
    // ------------------------------------------------------------------

    public static void setObserver(Observer o) {
        synchronized (LOCK) {
            observer = o;
        }
    }

    private static void notifyChanged() {
        synchronized (LOCK) {
            if (renderPosted) {
                return;
            }
            renderPosted = true;
        }
        MAIN.post(new Runnable() {
            public void run() {
                Observer o;
                synchronized (LOCK) {
                    renderPosted = false;
                    o = observer;
                }
                if (o != null) {
                    o.onChanged();
                }
            }
        });
    }
}
