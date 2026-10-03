package dev.dshd.app;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The {@code ##dshd} line protocol, as emitted by {@code bin/dshd setup} and by
 * {@code android/payload/bootstrap.sh}.
 *
 * <pre>
 *   ##dshd &lt;nonce&gt; begin &lt;k=v&gt;...
 *   ##dshd &lt;nonce&gt; step &lt;name&gt; &lt;message&gt;
 *   ##dshd &lt;nonce&gt; ok|skip|fail &lt;name&gt; [detail]
 *   ##dshd &lt;nonce&gt; note &lt;message&gt;
 *   ##dshd &lt;nonce&gt; url &lt;url&gt;
 *   ##dshd &lt;nonce&gt; done ok|fail
 *   ##dshd &lt;nonce&gt; info &lt;key&gt; &lt;value&gt;      (setup --check)
 * </pre>
 *
 * <p>This class deliberately has no Android dependency at all: it is the one
 * part of the app whose correctness a development host can check, so
 * {@code tests/apk.test.sh} compiles it with plain javac and feeds it the output
 * of the real {@code dshd setup} running against stubs. Everything else in
 * {@code android/src} needs a device; this needs a shell.
 *
 * <p>Two deliberate choices:
 *
 * <ul>
 *   <li>Nothing is thrown away when a line does not parse. An unrecognised event
 *       kind is kept with its raw text, because a newer device-side dshd talking
 *       to an older app is a normal situation, and silently dropping the lines it
 *       does not understand is how the app ends up showing a spinner forever.
 *   <li>The nonce is tracked, and a stream carrying two different nonces is
 *       flagged rather than merged. Two writers on one pipe means something
 *       other than this app's own run is writing to it, and that is worth
 *       surfacing instead of rendering as one confused progress list.
 * </ul>
 */
public final class Protocol {

    public static final String PREFIX = "##dshd ";

    /** Event kinds this app renders. Unknown kinds are kept as raw events. */
    public static final String BEGIN = "begin";
    public static final String STEP = "step";
    public static final String OK = "ok";
    public static final String SKIP = "skip";
    public static final String FAIL = "fail";
    public static final String NOTE = "note";
    public static final String URL = "url";
    public static final String DONE = "done";
    public static final String INFO = "info";

    /** The nonce the payload bootstrap uses, before dshd has one of its own. */
    public static final String PRENONCE = "pre";

    private Protocol() {
    }

    /** One parsed protocol line. */
    public static final class Event {
        public final String nonce;
        public final String kind;
        /** Step name or info key; null when the kind has none. */
        public final String name;
        /** Everything after the name: prose, a URL, a value. May be empty. */
        public final String detail;
        public final String raw;

        Event(String nonce, String kind, String name, String detail, String raw) {
            this.nonce = nonce;
            this.kind = kind;
            this.name = name;
            this.detail = detail == null ? "" : detail;
            this.raw = raw;
        }

        public String toString() {
            return kind + (name == null ? "" : " " + name) + (detail.isEmpty() ? "" : " " + detail);
        }
    }

    /**
     * Parses one line, or returns null when it is not a protocol line. Ordinary
     * output — apt, npm, a download's progress bar — is not: it is passed
     * through to the log pane untouched.
     */
    public static Event parse(String line) {
        if (line == null || !line.startsWith(PREFIX)) {
            return null;
        }
        String rest = line.substring(PREFIX.length()).trim();
        if (rest.isEmpty()) {
            return null;
        }
        String nonce;
        String kind;
        String tail;
        int firstSpace = rest.indexOf(' ');
        if (firstSpace < 0) {
            // "##dshd done" with nothing else is malformed: a nonce is required.
            return null;
        }
        nonce = rest.substring(0, firstSpace);
        String afterNonce = rest.substring(firstSpace + 1).trim();
        if (afterNonce.isEmpty()) {
            return null;
        }
        int secondSpace = afterNonce.indexOf(' ');
        if (secondSpace < 0) {
            kind = afterNonce;
            tail = "";
        } else {
            kind = afterNonce.substring(0, secondSpace);
            tail = afterNonce.substring(secondSpace + 1).trim();
        }

        String name = null;
        String detail = tail;
        if (STEP.equals(kind) || OK.equals(kind) || SKIP.equals(kind)
                || FAIL.equals(kind) || INFO.equals(kind)) {
            int split = tail.indexOf(' ');
            if (split < 0) {
                name = tail;
                detail = "";
            } else {
                name = tail.substring(0, split);
                detail = tail.substring(split + 1).trim();
            }
            if (name.isEmpty()) {
                return null;
            }
        }
        return new Event(nonce, kind, name, detail, line);
    }

    /** One entry of the setup progress list. */
    public static final class Step {
        public static final int RUNNING = 0;
        public static final int OK = 1;
        public static final int SKIPPED = 2;
        public static final int FAILED = 3;

        public final String name;
        public String message;
        public int state = RUNNING;

        Step(String name, String message) {
            this.name = name;
            this.message = message == null ? "" : message;
        }

        public boolean finished() {
            return state != RUNNING;
        }
    }

    /**
     * The app's view of one run: which steps have happened, what the script said
     * about the device, and how it ended.
     */
    public static final class State {
        public String nonce;
        /** True when the stream carried more than one nonce: see the class note. */
        public boolean nonceConflict;
        public final Map<String, String> info = new LinkedHashMap<String, String>();
        public final List<Step> steps = new ArrayList<Step>();
        public String url;
        /** null until a {@code done} event arrives. */
        public Boolean doneOk;
        public String doneDetail = "";
        public String failStep;
        public String failDetail = "";
        /** Set by the caller when the process exits: what the OS reported. */
        public Integer exitCode;

        /** Applies one event. Unknown kinds are recorded as notes, not dropped. */
        public void accept(Event e) {
            if (e == null) {
                return;
            }
            if (nonce == null) {
                nonce = e.nonce;
            } else if (!nonce.equals(e.nonce)) {
                nonceConflict = true;
            }

            if (STEP.equals(e.kind)) {
                Step s = find(e.name);
                if (s == null) {
                    steps.add(new Step(e.name, e.detail));
                } else {
                    s.message = e.detail;
                    s.state = Step.RUNNING;
                }
            } else if (OK.equals(e.kind) || SKIP.equals(e.kind) || FAIL.equals(e.kind)) {
                Step s = find(e.name);
                if (s == null) {
                    s = new Step(e.name, "");
                    steps.add(s);
                }
                s.state = OK.equals(e.kind) ? Step.OK : (SKIP.equals(e.kind) ? Step.SKIPPED : Step.FAILED);
                if (!e.detail.isEmpty()) {
                    s.message = e.detail;
                }
                if (FAIL.equals(e.kind)) {
                    failStep = e.name;
                    failDetail = e.detail;
                }
            } else if (INFO.equals(e.kind)) {
                info.put(e.name, e.detail);
            } else if (URL.equals(e.kind)) {
                url = e.detail;
            } else if (DONE.equals(e.kind)) {
                doneOk = Boolean.valueOf(e.detail.startsWith("ok"));
                doneDetail = e.detail;
            } else if (!BEGIN.equals(e.kind) && !NOTE.equals(e.kind)) {
                // An event kind this build does not know. Keep it visible.
                info.put("unknown:" + e.kind, e.detail);
            }
        }

        private Step find(String name) {
            for (int i = 0; i < steps.size(); i++) {
                if (steps.get(i).name.equals(name)) {
                    return steps.get(i);
                }
            }
            return null;
        }

        public Step current() {
            for (int i = 0; i < steps.size(); i++) {
                if (!steps.get(i).finished()) {
                    return steps.get(i);
                }
            }
            return null;
        }

        /** True when this run reported itself finished, and said how. */
        public boolean reported() {
            return doneOk != null;
        }

        /**
         * The one judgement the app makes about a finished run.
         *
         * <p>Both signals have to agree: the script's own {@code done} line and
         * the process's exit status. A run that printed {@code done ok} and then
         * exited non-zero is reported as a failure, because that is exactly the
         * shape of a truncated pipe or a shell that died mid-sentence, and
         * showing the user a working app in that state is the worst outcome
         * available.
         */
        public boolean succeeded() {
            if (exitCode == null || doneOk == null) {
                return false;
            }
            return exitCode.intValue() == 0 && doneOk.booleanValue();
        }

        /** Why this run is not a success, in one line, or null when it is one. */
        public String failureReason() {
            if (succeeded()) {
                return null;
            }
            if (exitCode == null) {
                return "the run did not finish";
            }
            // A named step is the best diagnosis available, so it comes first:
            // the script that refused knows why it refused, and its sentence
            // beats any summary this class could derive from a number. This
            // order is a fix, not a preference. The exit-code lines used to be
            // checked first, and exit 6 covered both "the payload did not
            // verify" and every other refusal the bootstrap could make — so a
            // root-owned directory left at 0775 by a previous run was reported
            // to the screen as a corrupt payload, and the person reading it went
            // looking in the wrong place. The codes below are the fallback for a
            // stream that named no step: an older payload on the device, or a
            // run killed before it finished a sentence.
            if (failStep != null) {
                String why = "setup failed at " + failStep;
                if (!failDetail.isEmpty()) {
                    why = why + ": " + failDetail;
                }
                return why;
            }
            if (exitCode.intValue() == 2) {
                return "root was not granted";
            }
            if (exitCode.intValue() == 6) {
                return "the payload did not verify";
            }
            if (exitCode.intValue() == 7) {
                return "the install directory is not safe";
            }
            if (doneOk == null) {
                return "the setup stopped without saying why (exit " + exitCode + ")";
            }
            if (!doneOk.booleanValue()) {
                return "setup failed (exit " + exitCode + ")";
            }
            return "the setup reported success and then exited " + exitCode;
        }
    }

    // ------------------------------------------------------------------
    // Host-side entry point: tests/apk.test.sh feeds this real script output and
    // asserts what the app would render. Not used by the app itself.
    // ------------------------------------------------------------------

    public static void main(String[] args) throws java.io.IOException {
        // `--exit N` tells the harness what the process exited with, so the
        // success rule (both signals must agree) is exercised rather than
        // assumed. Without it the run reads as "did not finish", which is the
        // honest answer when nobody said otherwise.
        Integer exit = null;
        for (int i = 0; i + 1 < args.length; i++) {
            if ("--exit".equals(args[i])) {
                exit = Integer.valueOf(args[i + 1]);
            }
        }
        java.io.BufferedReader in =
                new java.io.BufferedReader(new java.io.InputStreamReader(System.in, "UTF-8"));
        State state = new State();
        String line;
        while ((line = in.readLine()) != null) {
            Event e = parse(line);
            if (e == null) {
                System.out.println("raw   | " + line);
            } else {
                System.out.println("event | " + e);
                state.accept(e);
            }
        }
        state.exitCode = exit;
        System.out.println("nonce=" + state.nonce + " conflict=" + state.nonceConflict);
        for (Map.Entry<String, String> en : state.info.entrySet()) {
            System.out.println("info  | " + en.getKey() + " = " + en.getValue());
        }
        for (int i = 0; i < state.steps.size(); i++) {
            Step s = state.steps.get(i);
            System.out.println("step  | " + s.name + " state=" + s.state + " msg=" + s.message);
        }
        System.out.println("url=" + state.url);
        System.out.println("done=" + state.doneOk + " ok=" + state.succeeded()
                + " reason=" + state.failureReason());
    }
}
