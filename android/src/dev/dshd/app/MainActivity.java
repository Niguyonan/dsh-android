package dev.dshd.app;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Process;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.SslErrorHandler;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * The whole user interface: set up, then show the harness.
 *
 * <p>There is no terminal in this app and nothing that asks the user to run a
 * command. The setup screen is a progress list, and the log is there for when
 * something goes wrong — not because anyone is expected to read it.
 *
 * <p>Three things in here are security decisions rather than UI ones:
 *
 * <ul>
 *   <li>the WebView is created in code and given no view id, so the framework
 *       does not fold its state into the saved instance state — which would put
 *       the tokenised URL into a bundle this app does not control
 *   <li>navigation is pinned to the loopback authority it loaded from; anything
 *       else opens in the system browser. The page inside is agent-generated
 *       output, and it does not get to steer the WebView somewhere else
 *   <li>no addJavascriptInterface, ever. A bridge into this app would be a bridge
 *       from agent output to an app that holds root
 *   <li>the WebView has a WebChromeClient for one reason — the page's file input
 *       — and the result of that picker is checked before the page is allowed to
 *       read it: the platform's own documentation says a file chooser result can
 *       point at this app's private files
 * </ul>
 */
public final class MainActivity extends Activity implements RunState.Observer {

    private static final String PREFS = "dshd";
    private static final String PREF_EXPLAINED = "explained";
    private static final String PREF_AUTOSTART = "autostart";

    /** Request code for the one picker this app opens: the page's file input. */
    private static final int REQUEST_PICK_FILES = 2;

    private TextView statusText;
    private TextView bannerText;
    private TextView setupTitle;
    private TextView setupBody;
    private TextView logText;
    private LinearLayout stepsBox;
    private Button primaryButton;
    private Button secondaryButton;
    private Button logButton;
    private Button stopButton;
    private LinearLayout welcomePanel;
    private ScrollView setupPanel;
    private ScrollView logScroll;
    private View logBox;
    private FrameLayout webContainer;

    private WebView web;
    private String allowedPrefix;
    private boolean webShowing;
    private boolean askedForUrl;
    /**
     * The page's unanswered file chooser, or null when no picker is open.
     *
     * <p>A file input stays disabled until exactly one of these is answered, so
     * every path through the picker has to end in a call on it — including the
     * ones where the user cancels.
     */
    private ValueCallback<Uri[]> pendingPick;
    private String stepsSignature = "";
    private long lastLogDraw;
    private boolean logVisible;
    private Button autostartButton;
    private long lastCheck;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        statusText = (TextView) findViewById(R.id.status_text);
        bannerText = (TextView) findViewById(R.id.banner_text);
        setupTitle = (TextView) findViewById(R.id.setup_title);
        setupBody = (TextView) findViewById(R.id.setup_body);
        logText = (TextView) findViewById(R.id.log_text);
        stepsBox = (LinearLayout) findViewById(R.id.steps_box);
        primaryButton = (Button) findViewById(R.id.primary_button);
        secondaryButton = (Button) findViewById(R.id.secondary_button);
        logButton = (Button) findViewById(R.id.log_button);
        stopButton = (Button) findViewById(R.id.stop_button);
        autostartButton = (Button) findViewById(R.id.autostart_button);
        welcomePanel = (LinearLayout) findViewById(R.id.welcome_panel);
        setupPanel = (ScrollView) findViewById(R.id.setup_panel);
        logScroll = (ScrollView) findViewById(R.id.log_scroll);
        logBox = findViewById(R.id.log_box);
        webContainer = (FrameLayout) findViewById(R.id.web_container);

        logText.setTypeface(Typeface.MONOSPACE);
        logText.setTextIsSelectable(true);

        findViewById(R.id.continue_button).setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                prefs().edit().putBoolean(PREF_EXPLAINED, true).apply();
                requestNotificationPermission();
                render();
                check();
            }
        });
        primaryButton.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                onPrimary();
            }
        });
        secondaryButton.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                run("setup", prefs().getBoolean(PREF_AUTOSTART, false));
            }
        });
        logButton.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                logVisible = !logVisible;
                logBox.setVisibility(logVisible ? View.VISIBLE : View.GONE);
                logButton.setText(logVisible ? R.string.hide_log : R.string.show_log);
                render();
            }
        });
        autostartButton.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                boolean on = !prefs().getBoolean(PREF_AUTOSTART, false);
                prefs().edit().putBoolean(PREF_AUTOSTART, on).apply();
                // The preference only decides what the *next* setup writes; an
                // installed device is switched over now, through the same verb
                // that installed it, so the two cannot disagree.
                if (ready(RunState.snapshot())) {
                    run("boot", on);
                } else {
                    render();
                }
            }
        });
        stopButton.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                webShowing = false;
                run("stop", false);
            }
        });

        RunState.setObserver(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        RunState.setObserver(this);
        // Re-check on resume, throttled: coming back from the background after
        // stopping the server elsewhere should correct the status line, but a
        // su call per resume is not free.
        long now = System.currentTimeMillis();
        if (prefs().getBoolean(PREF_EXPLAINED, false) && !RunState.snapshot().busy
                && now - lastCheck > 5000) {
            check();
        }
        render();
    }

    @Override
    protected void onDestroy() {
        RunState.setObserver(null);
        // A picker the user left open: the run that asked for it is over, and the
        // callback belongs to a WebView about to be destroyed. Dropped, not
        // answered — invoking it against a torn-down WebView is the one way to
        // turn "the app was closed" into a crash report.
        pendingPick = null;
        if (web != null) {
            webContainer.removeView(web);
            web.destroy();
            web = null;
        }
        super.onDestroy();
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    // ------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------

    private void check() {
        if (RunState.snapshot().busy) {
            return;
        }
        lastCheck = System.currentTimeMillis();
        run("check", false);
    }

    private void run(String verb, boolean autostart) {
        Intent intent = new Intent(this, SetupService.class);
        intent.putExtra(SetupService.EXTRA_VERB, verb);
        intent.putExtra(SetupService.EXTRA_AUTOSTART, autostart);
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
    }

    private void onPrimary() {
        RunState.View v = RunState.snapshot();
        if (v.busy) {
            return;
        }
        if (!ready(v)) {
            run("setup", prefs().getBoolean(PREF_AUTOSTART, false));
        } else if (!v.yes("running")) {
            run("start", false);
        } else {
            webShowing = true;
            render();
        }
    }

    /**
     * Whether the device is set up — which is two facts, not one.
     *
     * <p>{@code dshd setup --check} reports {@code installed} (the rootfs and
     * Node) and {@code harness} (the harness's own {@code dsh}) apart, because a
     * run can leave the first in place and the second not: a device that stopped
     * at the harness step answered {@code installed yes} with {@code harness no}.
     * Keyed on {@code installed} alone, this screen said "the harness is
     * installed" and offered START, and START refused — correctly, and in words
     * worth reading: "harness not installed at …/usr/local/bin/dsh — run
     * tools/install-harness.sh". Both halves are what the button means by set up,
     * so both halves are what it asks for.
     */
    private boolean ready(RunState.View v) {
        return v.yes("installed") && v.yes("harness");
    }

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------

    private void render() {
        RunState.View v = RunState.snapshot();
        boolean explained = prefs().getBoolean(PREF_EXPLAINED, false);

        welcomePanel.setVisibility(explained ? View.GONE : View.VISIBLE);
        setupPanel.setVisibility(explained && !webShowing ? View.VISIBLE : View.GONE);
        webContainer.setVisibility(webShowing ? View.VISIBLE : View.GONE);

        // Status line.
        String status;
        if (v.busy) {
            String step = RunState.currentStepText();
            status = getString(R.string.status_working) + (step.isEmpty() ? "" : " — " + step);
        } else if (v.yes("running")) {
            status = getString(R.string.status_running);
        } else if (ready(v)) {
            status = getString(R.string.status_stopped);
        } else {
            status = getString(R.string.status_not_set_up);
        }
        statusText.setText(status);

        stopButton.setVisibility(v.yes("running") && explained ? View.VISIBLE : View.GONE);

        // The banner: the two things a person has to be told out loud.
        String warning = warning(v);
        bannerText.setVisibility(warning == null ? View.GONE : View.VISIBLE);
        if (warning != null) {
            bannerText.setText(warning);
        }

        if (!explained || webShowing) {
            return;
        }

        // Setup panel.
        if (v.busy) {
            setupTitle.setText(R.string.setup_running_title);
            setupBody.setText(R.string.setup_running_body);
        } else if (v.finished && !v.ok) {
            setupTitle.setText(R.string.setup_failed_title);
            setupBody.setText(v.reason == null ? getString(R.string.setup_failed_body) : v.reason);
        } else if (!ready(v)) {
            setupTitle.setText(R.string.setup_title);
            setupBody.setText(R.string.setup_body);
        } else if (!v.yes("running")) {
            setupTitle.setText(R.string.setup_start_title);
            setupBody.setText(R.string.setup_start_body);
        } else {
            setupTitle.setText(R.string.setup_done_title);
            setupBody.setText(R.string.setup_done_body);
        }

        primaryButton.setEnabled(!v.busy);
        secondaryButton.setVisibility(ready(v) && !v.busy ? View.VISIBLE : View.GONE);
        primaryButton.setText(!ready(v) ? R.string.action_set_up
                : (v.yes("running") ? R.string.action_open : R.string.action_start));
        autostartButton.setText(prefs().getBoolean(PREF_AUTOSTART, false)
                ? R.string.autostart_on : R.string.autostart_off);
        autostartButton.setVisibility(v.busy ? View.GONE : View.VISIBLE);

        drawSteps(v);

        if (logVisible) {
            long now = System.currentTimeMillis();
            if (now - lastLogDraw > 250 || !v.busy) {
                lastLogDraw = now;
                drawLog(v.log);
            }
        }
    }

    /**
     * The two warnings worth interrupting someone for. Both are the plan's
     * disclosures, in the place the person actually is: an unproven sandbox, and
     * a runtime on the device that is older than the one in this APK.
     */
    private String warning(RunState.View v) {
        String posture = v.info("posture");
        if (posture.startsWith("unresolved")) {
            return getString(R.string.warn_confinement_unknown);
        }
        if (posture.contains("not proven") || posture.contains("no landlock")) {
            return getString(R.string.warn_confinement, posture);
        }
        String installed = v.info("payload");
        String shipped = Shell.payloadId(this);
        if (!installed.isEmpty() && !shipped.isEmpty() && !installed.equals(shipped)) {
            return getString(R.string.warn_payload_stale);
        }
        return null;
    }

    private void drawSteps(RunState.View v) {
        List<Protocol.Step> steps = v.steps;
        StringBuilder signature = new StringBuilder();
        for (int i = 0; i < steps.size(); i++) {
            Protocol.Step s = steps.get(i);
            signature.append(s.name).append(s.state).append(s.message).append('\u0001');
        }
        signature.append(getString(R.string.step_payload)).append(v.info("installed"))
                .append(v.info("running"));
        if (signature.toString().equals(stepsSignature)) {
            return;
        }
        stepsSignature = signature.toString();

        stepsBox.removeAllViews();
        for (int i = 0; i < steps.size(); i++) {
            Protocol.Step s = steps.get(i);
            TextView row = new TextView(this);
            row.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
            row.setPadding(0, dp(6), 0, dp(6));
            String mark;
            int colour;
            if (s.state == Protocol.Step.OK) {
                mark = "✓";
                colour = getColor(R.color.ok);
            } else if (s.state == Protocol.Step.SKIPPED) {
                mark = "·";
                colour = getColor(R.color.dim);
            } else if (s.state == Protocol.Step.FAILED) {
                mark = "✗";
                colour = getColor(R.color.error);
            } else {
                mark = "•";
                colour = getColor(R.color.accent);
            }
            String label = label(s.name);
            row.setText(mark + "  " + label + (s.message.isEmpty() ? "" : "\n     " + s.message));
            row.setTextColor(s.state == Protocol.Step.RUNNING ? getColor(R.color.text) : colour);
            stepsBox.addView(row);
        }
    }

    /** Step names are a contract with the device; the words are ours. */
    private String label(String name) {
        if ("root".equals(name)) {
            return getString(R.string.step_root);
        }
        if ("payload".equals(name)) {
            return getString(R.string.step_payload);
        }
        if ("probe".equals(name)) {
            return getString(R.string.step_probe);
        }
        if ("rootfs".equals(name)) {
            return getString(R.string.step_rootfs);
        }
        if ("harness".equals(name)) {
            return getString(R.string.step_harness);
        }
        if ("confinement".equals(name)) {
            return getString(R.string.step_confinement);
        }
        if ("firewall".equals(name)) {
            return getString(R.string.step_firewall);
        }
        if ("config".equals(name)) {
            return getString(R.string.step_config);
        }
        if ("boot".equals(name)) {
            return getString(R.string.step_boot);
        }
        if ("start".equals(name)) {
            return getString(R.string.step_start);
        }
        // A step this build does not know: show it rather than hide it.
        return name;
    }

    private void drawLog(List<String> lines) {
        int from = Math.max(0, lines.size() - 200);
        logText.setText(TextUtils.join("\n", lines.subList(from, lines.size())));
        logScroll.post(new Runnable() {
            public void run() {
                logScroll.fullScroll(View.FOCUS_DOWN);
            }
        });
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density);
    }

    // ------------------------------------------------------------------
    // The WebView
    // ------------------------------------------------------------------

    /**
     * Called when a run reported a URL. The token is in it — that is how the
     * guard hands out a session — so it is loaded once and then dropped from the
     * history, and the URL is never written to a preference or a log.
     */
    private void loadHarness(String url) {
        if (web == null) {
            web = buildWebView();
            webContainer.addView(web, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        }
        Uri uri = Uri.parse(url);
        if (uri.getHost() == null) {
            toast(getString(R.string.error_bad_url));
            return;
        }
        allowedPrefix = uri.getScheme() + "://" + uri.getHost() + ":" + uri.getPort();
        webShowing = true;
        render();
        web.loadUrl(url);
    }

    private WebView buildWebView() {
        // No view id on purpose: the framework saves the state of views that have
        // one, and this WebView's state includes the URL it was handed.
        WebView view = new WebView(this);
        WebSettings settings = view.getSettings();
        settings.setJavaScriptEnabled(true);       // the harness UI is a web app
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setMediaPlaybackRequiresUserGesture(true);
        settings.setSaveFormData(false);
        // No addJavascriptInterface: a bridge here would connect agent output to
        // an app that holds root.
        CookieManager.getInstance().setAcceptCookie(true);

        view.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest request) {
                return handleNavigation(request.getUrl().toString());
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                // Drop the tokenised URL from the back/forward list; the session
                // cookie is what authenticates from here on.
                v.clearHistory();
            }

            @Override
            public void onReceivedSslError(WebView v, SslErrorHandler handler, android.net.http.SslError error) {
                // Loopback is plain HTTP; anything presenting a certificate here
                // is not the thing we asked for.
                handler.cancel();
            }
        });

        // The harness attaches a file with a plain <input type="file">, and that
        // input is the page's only way to hand the agent something it did not
        // type. Without a WebChromeClient the WebView answers the request with
        // null and the button does *nothing at all*: no picker, no error, and
        // nothing in the page that could report one. The same harness in a
        // browser attaches files, so the browser was where this worked and the
        // app was where it did not.
        view.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> callback,
                    FileChooserParams params) {
                return askForFiles(callback, params);
            }
        });
        return view;
    }

    /**
     * Open the system picker for one {@code <input type="file">} request.
     *
     * <p>The intent comes from the page's own parameters — {@code createIntent()}
     * builds {@code ACTION_GET_CONTENT} with the accept types, and already asks
     * for multiple selection when the input has {@code multiple}, which the
     * harness's does.
     *
     * <p>Every exit from here calls the callback exactly once, because a file
     * input that is never answered stays dead for the rest of the page's life:
     * a device with no picker at all is told out loud rather than left waiting.
     */
    private boolean askForFiles(ValueCallback<Uri[]> callback,
            WebChromeClient.FileChooserParams params) {
        // One at a time. A second request while the first picker is open — the
        // page can do that, and a second window can too — would otherwise leave
        // the first input unanswered for good.
        if (pendingPick != null) {
            pendingPick.onReceiveValue(null);
            pendingPick = null;
        }
        Intent picker;
        try {
            picker = params.createIntent();
        } catch (RuntimeException e) {
            callback.onReceiveValue(null);
            return true;
        }
        try {
            startActivityForResult(
                    Intent.createChooser(picker, getString(R.string.pick_file)), REQUEST_PICK_FILES);
        } catch (ActivityNotFoundException e) {
            callback.onReceiveValue(null);
            toast(getString(R.string.error_no_picker));
            return true;
        }
        pendingPick = callback;
        return true;
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_PICK_FILES) {
            super.onActivityResult(requestCode, resultCode, data);
            return;
        }
        ValueCallback<Uri[]> callback = pendingPick;
        pendingPick = null;
        if (callback == null) {
            // The run that opened the picker is gone; there is no page to answer.
            return;
        }
        callback.onReceiveValue(pickedFiles(resultCode, data));
    }

    /**
     * The files the user picked, or null — which is also how "cancelled" is said.
     *
     * <p>Hand-written rather than {@code FileChooserParams.parseResult}, because
     * that method reads {@code intent.getData()} and nothing else, and the system
     * picker returns a multiple selection in the intent's {@code ClipData} with
     * no data URI at all. The harness's input is {@code multiple}: with
     * {@code parseResult} the first file chosen would arrive and the rest would
     * disappear without a word.
     *
     * <p>A picker result is untrusted — the platform's own documentation says it
     * "can contain Uris pointing to your own app's sensitive data files", and
     * anything the page can read it can upload to the agent. So the whole
     * selection is accepted or refused together, by {@link #acceptable}: a
     * {@code content} URI, which is what the system picker returns, or a
     * {@code file} URI that is not this app's own. Chromium applies the same rule
     * in its own file dialog; WebView does not apply it for us.
     */
    private Uri[] pickedFiles(int resultCode, Intent data) {
        if (resultCode != RESULT_OK || data == null) {
            return null;
        }
        ArrayList<Uri> candidates = new ArrayList<Uri>();
        ClipData clip = data.getClipData();
        if (clip != null) {
            for (int i = 0; i < clip.getItemCount(); i++) {
                candidates.add(clip.getItemAt(i).getUri());
            }
        }
        candidates.add(data.getData());

        ArrayList<Uri> files = new ArrayList<Uri>();
        for (int i = 0; i < candidates.size(); i++) {
            Uri uri = candidates.get(i);
            if (uri == null) {
                continue;
            }
            if (!acceptable(uri)) {
                toast(getString(R.string.error_blocked_file));
                return null;
            }
            files.add(uri);
        }
        return files.isEmpty() ? null : files.toArray(new Uri[files.size()]);
    }

    /**
     * Whether one picked URI may be handed to the page.
     *
     * <p>Only two schemes can name a file the user chose. {@code content} is the
     * system picker's answer and is taken; anything else — {@code file},
     * {@code http}, a raw path — has to be a file that is not this app's own,
     * compared on canonical paths so {@code /data/data/…} and
     * {@code /data/user/0/…} and a symlink to either are the same answer.
     * Everything else is refused, which is the choice that cannot leak: the
     * WebView is showing a page the agent can write to, and this app is the one
     * holding a root token.
     */
    private boolean acceptable(Uri uri) {
        String scheme = uri.getScheme();
        if ("content".equals(scheme)) {
            return true;
        }
        if (!"file".equals(scheme) || uri.getPath() == null) {
            return false;
        }
        String dir = getApplicationInfo().dataDir;
        if (dir == null || dir.isEmpty()) {
            return false;
        }
        try {
            String path = new File(uri.getPath()).getCanonicalPath();
            String own = new File(dir).getCanonicalPath();
            return !path.equals(own) && !path.startsWith(own + File.separator);
        } catch (IOException e) {
            return false;
        }
    }

    private boolean handleNavigation(String url) {
        if (url == null) {
            return true;
        }
        if (allowedPrefix != null && url.startsWith(allowedPrefix)) {
            return false;
        }
        if (url.startsWith("http://") || url.startsWith("https://")) {
            // A link out of the harness: the user's browser, where the user can
            // see where it goes.
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url)));
            } catch (RuntimeException e) {
                toast(getString(R.string.error_no_browser));
            }
            return true;
        }
        // Everything else — file:, content:, intent:, javascript: — is refused
        // and said out loud.
        toast(getString(R.string.error_blocked_navigation));
        return true;
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_LONG).show();
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(new String[] {"android.permission.POST_NOTIFICATIONS"}, 1);
        }
    }

    // ------------------------------------------------------------------
    // The one reaction to a finished run
    // ------------------------------------------------------------------

    @Override
    public void onChanged() {
        render();
        RunState.View v = RunState.snapshot();
        if (v.busy || !v.finished) {
            return;
        }
        if (v.url != null && !v.url.isEmpty() && !webShowing) {
            loadHarness(v.url);
            askedForUrl = false;
            return;
        }
        if (v.ok && "check".equals(v.verb) && v.yes("running") && !askedForUrl) {
            // Set up and already running, but this run was a check: ask for the
            // URL separately so a check never turns into a second setup.
            askedForUrl = true;
            run("url", false);
        }
    }
}
