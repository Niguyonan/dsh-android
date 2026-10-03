package dev.dshd.app;

import android.content.Context;
import android.content.res.AssetManager;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Everything this app does on the device, it does through one command.
 *
 * <pre>
 *   S=/data/local/dsh/.stage; rm -rf "$S"; (umask 077; mkdir -p "$S")
 *     &amp;&amp; tar -xf - -C "$S"                       &lt;- the payload, on stdin
 *     &amp;&amp; exec sh "$S/bootstrap.sh" &lt;verb&gt; ...     &lt;- verify, install, hand over
 * </pre>
 *
 * <p>The {@code mkdir} runs in a subshell with {@code umask 077}, so the staging
 * directory — and {@code /data/local/dsh} above it, on a first run — is created
 * 0700 whatever umask the {@code su} shell was started with. That directory is
 * where root executes scripts from, and the first version of this command let it
 * be created by whatever the su shell happened to carry: on a real device that
 * was 0775, which the bootstrap then refused, which the app reported as a bad
 * payload. The bootstrap checks and fixes that mode as well; a directory that
 * decides what root runs should not be created permissive in the first place.
 *
 * <p>The payload is streamed in rather than read from the app's own directory on
 * purpose. Reading app-private files as root depends on SELinux letting a `su`
 * domain touch `app_data_file`, which differs between Magisk, KernelSU and
 * KernelSU-Next; a pipe does not. It also means the app carries no second copy
 * of anything: the scripts that run are the scripts in {@code assets/payload.tar},
 * verified file by file by the bootstrap before any of them is installed.
 *
 * <p>The command is a constant apart from two things: the verb, and a UID that
 * is checked to be digits before it is concatenated. Nothing else from the app
 * ever reaches a shell — no paths, no user text, no preferences. An app that
 * holds root cannot afford a second place where a string becomes a command.
 */
public final class Shell {

    /** Where the device-side runtime lives. The bootstrap defaults to this too. */
    public static final String BASE = "/data/local/dsh";
    public static final String STAGE = BASE + "/.stage";
    public static final String BOOTSTRAP = STAGE + "/bootstrap.sh";
    public static final String PAYLOAD_ASSET = "payload.tar";
    public static final String PAYLOAD_ID_ASSET = "payload.id";

    /**
     * su binaries, in the order that has worked across the three root solutions
     * — the same order {@code dshd}'s su_candidates() uses, and for the same
     * reason: PATH is not the same in every process. `su` first, because when the
     * root manager put it on PATH it is the one whose mount namespace this app
     * will inherit.
     */
    private static final String[] SU_CANDIDATES = {
        "su",
        "/data/adb/ksu/bin/su",
        "/debug_ramdisk/su",
        "/sbin/su",
        "/system/bin/su",
    };

    private static String suPath;
    private static String suProblem;

    /** A root prompt is answered by a person; two minutes is the patience. */
    private static final int ROOT_PROMPT_TIMEOUT_SECONDS = 120;

    private Shell() {
    }

    /** What a run reports back. Called from a worker thread, never the UI thread. */
    public interface Listener {
        /** One line of stdout: either a protocol line or ordinary output. */
        void onStdout(String line);

        /** One line of stderr. Kept apart so the log can say which is which. */
        void onStderr(String line);

        /** The verb ran and the shell exited. */
        void onExit(int status);

        /** The verb could not be started at all. */
        void onFailure(String message);
    }

    // ------------------------------------------------------------------
    // The command
    // ------------------------------------------------------------------

    /** `setup`, `setup --check`, `start`, `stop`, `url`, `status`, `logs`. */
    public static String bootstrapCommand(String verb) {
        return bootstrapCommand(verb, "");
    }

    /**
     * The one command template. {@code extra} is appended verbatim, so callers
     * pass only what they built themselves: {@link #setupCommand} and
     * {@link #checkCommand} are the only two, and neither takes user input.
     */
    public static String bootstrapCommand(String verb, String extra) {
        if (!isVerb(verb)) {
            throw new IllegalArgumentException("not a dshd verb: " + verb);
        }
        StringBuilder b = new StringBuilder();
        b.append("S=").append(STAGE).append("; rm -rf \"$S\"; (umask 077; mkdir -p \"$S\")")
         .append(" && tar -xf - -C \"$S\"")
         .append(" && exec sh \"").append(BOOTSTRAP).append("\" ").append(verb);
        if (extra != null && extra.length() > 0) {
            b.append(' ').append(extra);
        }
        return b.toString();
    }

    private static final String[] VERBS = {
        "setup", "start", "stop", "restart", "url", "status", "logs", "token", "mounts", "boot",
    };

    private static boolean isVerb(String verb) {
        for (int i = 0; i < VERBS.length; i++) {
            if (VERBS[i].equals(verb)) {
                return true;
            }
        }
        return false;
    }

    /** The whole install. The UID is the app's own, and the firewall's allow-list. */
    public static String setupCommand(int uid, boolean installAutostart) {
        if (uid < 0) {
            throw new IllegalArgumentException("uid must be non-negative");
        }
        String extra = "--app-uid " + uid + (installAutostart ? " --boot install" : "");
        return bootstrapCommand("setup", extra);
    }

    /**
     * What the app asks before it draws a screen. Cheap: it installs the payload
     * (idempotent, a few files) and then reports state without touching the
     * network or the rootfs.
     */
    public static String checkCommand() {
        return bootstrapCommand("setup", "--check");
    }

    // ------------------------------------------------------------------
    // su
    // ------------------------------------------------------------------

    /** The su that works on this device, or null. Probed once, then cached. */
    public static synchronized String suPath() {
        if (suPath != null || suProblem != null) {
            return suPath;
        }
        for (int i = 0; i < SU_CANDIDATES.length; i++) {
            String candidate = SU_CANDIDATES[i];
            Process p = null;
            try {
                p = new ProcessBuilder(candidate, "-c", "id -u")
                        .redirectErrorStream(true).start();
                p.getOutputStream().close();
                String out = readAll(p.getInputStream()).trim();
                if (!waitFor(p, ROOT_PROMPT_TIMEOUT_SECONDS)) {
                    p.destroy();
                    suProblem = "the root prompt from " + candidate
                            + " was not answered within " + ROOT_PROMPT_TIMEOUT_SECONDS + " seconds";
                    return null;
                }
                if (p.exitValue() == 0 && "0".equals(out)) {
                    suPath = candidate;
                    return suPath;
                }
                // It exists and it ran: whatever it answered, this is the su on
                // this device. Trying the next candidate would ask the user for
                // root again, and again, for the same answer.
                suProblem = candidate + " did not grant root (exit " + p.exitValue()
                        + (out.isEmpty() ? "" : ": " + firstLine(out)) + ")";
                return null;
            } catch (IOException e) {
                // Not there. Try the next one.
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                suProblem = "interrupted while asking for root";
                return null;
            }
        }
        suProblem = "no su binary answered (tried " + candidateList() + ")";
        return null;
    }

    /**
     * Bounded wait, by polling: {@code Process.waitFor(long, TimeUnit)} is Java 8
     * API that Android only grew in API 26, and this app runs on 24.
     */
    private static boolean waitFor(Process p, int seconds) throws InterruptedException {
        long deadline = System.currentTimeMillis() + seconds * 1000L;
        while (System.currentTimeMillis() < deadline) {
            try {
                p.exitValue();
                return true;
            } catch (IllegalThreadStateException stillRunning) {
                Thread.sleep(50);
            }
        }
        return false;
    }

    private static String candidateList() {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < SU_CANDIDATES.length; i++) {
            if (i > 0) {
                b.append(", ");
            }
            b.append(SU_CANDIDATES[i]);
        }
        return b.toString();
    }

    /** Why {@link #suPath()} returned null, for the screen that explains it. */
    public static synchronized String suProblem() {
        return suProblem;
    }

    public static synchronized void forgetSu() {
        suPath = null;
        suProblem = null;
    }

    // ------------------------------------------------------------------
    // Running
    // ------------------------------------------------------------------

    /**
     * Runs one verb, streaming the payload to its stdin.
     *
     * <p>Blocking: call it from a worker thread. stdout and stderr are read on
     * their own threads, so a long download cannot fill a pipe and stall while
     * the app waits for it to finish talking.
     */
    public static void run(Context context, String command, Listener listener) {
        String su = suPath();
        if (su == null) {
            listener.onFailure(suProblem == null ? "no root" : suProblem);
            return;
        }
        Process process = null;
        try {
            process = new ProcessBuilder(su, "-c", command)
                    .redirectErrorStream(false).start();
        } catch (IOException e) {
            listener.onFailure("cannot run " + su + ": " + e.getMessage());
            return;
        }

        final Process p = process;
        Thread stdout = pump(p.getInputStream(), true, listener);
        Thread stderr = pump(p.getErrorStream(), false, listener);
        Thread stdin = new Thread(new Runnable() {
            public void run() {
                OutputStream out = p.getOutputStream();
                try {
                    copy(context.getAssets(), PAYLOAD_ASSET, out);
                } catch (IOException e) {
                    // Closing stdin is what ends tar's read: the bootstrap then
                    // fails on its own terms, in its own words, with its own exit
                    // code, instead of waiting forever for bytes that will never
                    // come.
                } finally {
                    try {
                        out.close();
                    } catch (IOException ignored) {
                        // nothing useful to do
                    }
                }
            }
        }, "dshd-payload");
        stdin.setDaemon(true);
        stdin.start();

        int status;
        try {
            status = p.waitFor();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            p.destroy();
            listener.onFailure("interrupted");
            return;
        }
        join(stdout);
        join(stderr);
        listener.onExit(status);
    }

    private static Thread pump(final InputStream in, final boolean isStdout, final Listener listener) {
        Thread t = new Thread(new Runnable() {
            public void run() {
                BufferedReader reader = null;
                try {
                    reader = new BufferedReader(new InputStreamReader(in, "UTF-8"));
                    String line;
                    while ((line = reader.readLine()) != null) {
                        if (isStdout) {
                            listener.onStdout(line);
                        } else {
                            listener.onStderr(line);
                        }
                    }
                } catch (IOException e) {
                    // The pipe closed. The exit status is the answer that counts.
                } finally {
                    if (reader != null) {
                        try {
                            reader.close();
                        } catch (IOException ignored) {
                            // nothing useful to do
                        }
                    }
                }
            }
        }, isStdout ? "dshd-stdout" : "dshd-stderr");
        t.setDaemon(true);
        t.start();
        return t;
    }

    private static void join(Thread t) {
        try {
            t.join(5000);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static void copy(AssetManager assets, String name, OutputStream out) throws IOException {
        InputStream in = assets.open(name, AssetManager.ACCESS_STREAMING);
        try {
            byte[] buffer = new byte[64 * 1024];
            int n;
            while ((n = in.read(buffer)) > 0) {
                out.write(buffer, 0, n);
            }
            out.flush();
        } finally {
            in.close();
        }
    }

    /** The payload's build-time identity, or "" — see tools/mkpayload.sh. */
    public static String payloadId(Context context) {
        InputStream in = null;
        try {
            in = context.getAssets().open(PAYLOAD_ID_ASSET);
            return readAll(in).trim();
        } catch (IOException e) {
            return "";
        } finally {
            if (in != null) {
                try {
                    in.close();
                } catch (IOException ignored) {
                    // nothing useful to do
                }
            }
        }
    }

    private static String readAll(InputStream in) throws IOException {
        BufferedReader reader = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        StringBuilder b = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            b.append(line).append('\n');
        }
        return b.toString();
    }

    private static String firstLine(String text) {
        int nl = text.indexOf('\n');
        String line = nl < 0 ? text : text.substring(0, nl);
        return line.length() > 200 ? line.substring(0, 200) + "…" : line;
    }

    /** For the log pane: the command, with nothing secret in it. */
    public static List<String> describe(String command) {
        List<String> out = new ArrayList<String>();
        out.add("su -c '" + command + "'");
        return out;
    }
}
