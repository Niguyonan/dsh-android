package dev.dshd.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.Process;

/**
 * Runs one dshd verb as root, in the foreground, for as long as it takes.
 *
 * <p>It is a foreground service for one reason: the first setup downloads about
 * a gigabyte and then installs a harness with npm. That is twenty minutes on a
 * phone, and it is exactly the kind of work Android kills when the user switches
 * apps — which they will, because there is nothing to look at. The notification
 * is the price of finishing.
 *
 * <p>It is not a keep-alive for the server. The server is a root process that
 * dshd detaches with setsid; it does not need this app to be running, and this
 * app does not hold a root shell open between runs. Every action is one `su -c`
 * command that ends.
 */
public final class SetupService extends Service {

    public static final String EXTRA_VERB = "verb";
    public static final String EXTRA_AUTOSTART = "autostart";

    private static final String CHANNEL_ID = "dshd-runs";
    private static final int NOTIFICATION_ID = 1;

    private Thread worker;
    private long lastNotification;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null && nm.getNotificationChannel(CHANNEL_ID) == null) {
                NotificationChannel channel = new NotificationChannel(
                        CHANNEL_ID, getString(R.string.channel_name), NotificationManager.IMPORTANCE_LOW);
                channel.setDescription(getString(R.string.channel_description));
                channel.setShowBadge(false);
                nm.createNotificationChannel(channel);
            }
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String verb = intent == null ? null : intent.getStringExtra(EXTRA_VERB);
        if (verb == null) {
            stopSelf();
            return START_NOT_STICKY;
        }
        boolean autostart = intent.getBooleanExtra(EXTRA_AUTOSTART, false);

        // startForeground has to happen before anything slow: the system gives a
        // started service a few seconds to show its notification or kills it.
        startForeground(NOTIFICATION_ID, notification(getString(R.string.notif_working), true));

        if (worker != null && worker.isAlive()) {
            // One run at a time. A second request would fight the first for the
            // same pid files and the same ports, and dshd is not the place to
            // discover that.
            return START_NOT_STICKY;
        }
        worker = new Thread(new Runnable() {
            public void run() {
                perform(verb, autostart);
            }
        }, "dshd-run");
        worker.start();
        return START_NOT_STICKY;
    }

    private void perform(String verb, boolean autostart) {
        RunState.begin(verb);
        final int uid = Process.myUid();

        String command;
        if ("setup".equals(verb)) {
            // The app's own uid, straight from the kernel: it is what the §7
            // firewall rule allows through, and nothing the user can edit.
            command = Shell.setupCommand(uid, autostart);
        } else if ("check".equals(verb)) {
            command = Shell.checkCommand();
        } else if ("boot".equals(verb)) {
            // The switch has two states and the verb needs to be told which one,
            // so the preference travels with the request rather than being
            // re-read here: the service and the screen must not disagree about
            // what the user just tapped.
            command = Shell.bootstrapCommand("boot", autostart ? "install" : "remove");
        } else {
            command = Shell.bootstrapCommand(verb);
        }
        RunState.stdout("$ su -c '" + command + "'");

        try {
            Shell.run(this, command, new Shell.Listener() {
                public void onStdout(String line) {
                    RunState.stdout(line);
                    progress();
                }

                public void onStderr(String line) {
                    RunState.stderr(line);
                }

                public void onExit(int status) {
                    RunState.stdout("$ exit " + status);
                    RunState.exited(status);
                }

                public void onFailure(String message) {
                    RunState.failed(message);
                }
            });
        } finally {
            // The notification goes away whatever happened: a foreground service
            // that forgets to stop is a notification the user cannot dismiss.
            stopForeground(true);
            stopSelf();
        }
    }

    /**
     * Notification text follows the step list, throttled twice over: once here
     * (a download prints far faster than a notification is useful) and once in
     * RunState, whose currentStepText() is cheap on purpose — taking a full
     * snapshot per output line would copy the whole log ring for every line npm
     * prints.
     */
    private void progress() {
        long now = System.currentTimeMillis();
        if (now - lastNotification < 1000) {
            return;
        }
        lastNotification = now;
        String step = RunState.currentStepText();
        String text = step.isEmpty() ? getString(R.string.notif_working) : step;
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) {
            nm.notify(NOTIFICATION_ID, notification(text, true));
        }
    }

    private Notification notification(String text, boolean ongoing) {
        Intent open = new Intent(this, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pending = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            b = new Notification.Builder(this, CHANNEL_ID);
        } else {
            b = new Notification.Builder(this);
        }
        return b.setSmallIcon(R.drawable.ic_stat_dshd)
                .setContentTitle(getString(R.string.app_name))
                .setContentText(text)
                .setContentIntent(pending)
                .setOngoing(ongoing)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .build();
    }
}
