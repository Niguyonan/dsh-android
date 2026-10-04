package dev.dshd.app;

import java.nio.charset.Charset;

/**
 * The two decisions this app makes before it saves a file the page asked for:
 * whether the request may be answered at all, and what the file is called.
 *
 * <p>Like {@link Protocol} this class has no Android dependency, and for the same
 * reason: it is the one part of the download path a development host can decide
 * on its own. {@code tests/apk.test.sh} compiles it with plain javac and drives
 * it with the header the harness really sends, the URL the page really asks for,
 * and the names a hostile one would try.
 *
 * <p>A WebView downloads nothing by itself — not one byte, on any version. An
 * {@code <a download>} click and a {@code Content-Disposition: attachment}
 * response both end at {@code DownloadListener.onDownloadStart}, and an app that
 * sets no listener is handed the request and does nothing with it: the harness's
 * "Download session log" says <em>the browser is downloading the Session ZIP</em>,
 * no file appears in any folder, and nothing reports a failure. That is the same
 * shape as a file input with no {@code WebChromeClient}, and it is why the
 * browser was where this worked and the app was where it did not.
 *
 * <p>Two things are refused rather than guessed at:
 *
 * <ul>
 *   <li>Anything that is not the origin the WebView was loaded from. This app
 *       reaches exactly one server, on loopback, and the request carries that
 *       server's session cookie: a page that could name another host could ask
 *       this app to hand its credentials to it. A link out of the harness is
 *       opened in the system browser instead, where the user can see where it
 *       goes — the same rule navigation already follows.
 *   <li>{@code blob:} and {@code data:}, which are files the page made inside
 *       the renderer. Their bytes exist only in the WebView; a native GET cannot
 *       reach them, and saving the URL as if it were a name would write a text
 *       file containing the word {@code blob}.
 * </ul>
 */
public final class Download {

    /** Saved under this name when neither the response nor the URL names one. */
    public static final String FALLBACK = "download";

    /** Refusal: the page generated the file in the renderer; there is nothing to fetch. */
    public static final String REFUSE_GENERATED = "generated";

    /** Refusal: the URL is not on the origin this WebView was loaded from. */
    public static final String REFUSE_EXTERNAL = "external";

    /** Refusal: not a scheme this app fetches at all. */
    public static final String REFUSE_SCHEME = "scheme";

    /** Longest name that is kept, extension included; longer ones are trimmed. */
    private static final int MAX_NAME = 120;

    /** Longest extension worth keeping when a name has to be trimmed. */
    private static final int MAX_EXT = 12;

    private static final Charset UTF8 = Charset.forName("UTF-8");

    private Download() {
    }

    /**
     * Why this download may not be answered, or null when it may.
     *
     * <p>{@code allowedPrefix} is the origin the page was loaded from — scheme,
     * host and port, as {@code MainActivity} pinned it. A download that is not
     * on it is not this app's to fetch.
     */
    public static String refuse(String url, String allowedPrefix) {
        if (url == null || url.isEmpty()) {
            return REFUSE_SCHEME;
        }
        String scheme = schemeOf(url);
        if (scheme == null) {
            return REFUSE_SCHEME;
        }
        if ("blob".equals(scheme) || "data".equals(scheme) || "javascript".equals(scheme)) {
            return REFUSE_GENERATED;
        }
        if (!"http".equals(scheme) && !"https".equals(scheme)) {
            return REFUSE_SCHEME;
        }
        return sameOrigin(url, allowedPrefix) ? null : REFUSE_EXTERNAL;
    }

    /**
     * Whether {@code url} is a path on the pinned origin.
     *
     * <p>The prefix is compared on a boundary, not on its first characters: the
     * WebView's own navigation check is a plain {@code startsWith}, where a
     * server on port 30810 answers for a login pinned to 3081.
     */
    public static boolean sameOrigin(String url, String prefix) {
        if (url == null || prefix == null || prefix.isEmpty()) {
            return false;
        }
        if (url.equals(prefix)) {
            return true;
        }
        if (!url.startsWith(prefix) || url.length() == prefix.length()) {
            return false;
        }
        char next = url.charAt(prefix.length());
        return next == '/' || next == '?' || next == '#';
    }

    /**
     * The name to save under: the response's own first, the URL's path second.
     *
     * <p>{@code Content-Disposition} is a header from a server, so it is treated
     * as untrusted input rather than as a name: it can carry a directory
     * ({@code ../../databases/dshd}), a quote that ends the parameter early, or
     * control characters, and the app is the one that runs as root.
     */
    public static String filename(String contentDisposition, String url) {
        String name = fromHeader(contentDisposition);
        if (name == null) {
            name = fromUrl(url);
        }
        return name == null ? FALLBACK : name;
    }

    /** {@code filename*=UTF-8''…} first — it is the only form that carries non-Latin-1. */
    private static String fromHeader(String header) {
        if (header == null) {
            return null;
        }
        String extended = parameter(header, "filename*");
        if (extended != null) {
            // charset'language'value — the value is percent-encoded.
            int mark = extended.indexOf("''");
            String value = mark >= 0 ? extended.substring(mark + 2) : extended;
            String name = clean(percentDecode(value));
            if (name != null) {
                return name;
            }
        }
        return clean(unquote(parameter(header, "filename")));
    }

    /** The last path segment, percent-decoded; a query or fragment is not a name. */
    private static String fromUrl(String url) {
        if (url == null) {
            return null;
        }
        String path = url;
        int cut = path.length();
        int query = path.indexOf('?');
        if (query >= 0 && query < cut) {
            cut = query;
        }
        int fragment = path.indexOf('#');
        if (fragment >= 0 && fragment < cut) {
            cut = fragment;
        }
        path = path.substring(0, cut);
        int slash = path.lastIndexOf('/');
        return clean(percentDecode(slash >= 0 ? path.substring(slash + 1) : path));
    }

    /**
     * One parameter of a header, unquoted as far as its own syntax goes.
     *
     * <p>Read by hand because a quoted value may contain the character that
     * separates parameters, and because {@code filename} is a prefix of
     * {@code filename*}: the key has to end at {@code =} to match at all.
     */
    private static String parameter(String header, String key) {
        int i = 0;
        while (i < header.length()) {
            // Start of a parameter: the header's first token, or after a ';'.
            int start = i;
            int end = header.length();
            boolean quoted = false;
            for (int j = i; j < header.length(); j++) {
                char c = header.charAt(j);
                if (c == '"') {
                    quoted = !quoted;
                } else if (c == ';' && !quoted) {
                    end = j;
                    break;
                }
            }
            String part = header.substring(start, end).trim();
            int eq = part.indexOf('=');
            if (eq > 0 && part.substring(0, eq).trim().equalsIgnoreCase(key)) {
                return part.substring(eq + 1).trim();
            }
            if (end >= header.length()) {
                return null;
            }
            i = end + 1;
        }
        return null;
    }

    private static String unquote(String value) {
        if (value == null) {
            return null;
        }
        String s = value.trim();
        if (s.length() >= 2 && s.charAt(0) == '"' && s.charAt(s.length() - 1) == '"') {
            s = s.substring(1, s.length() - 1);
        }
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && i + 1 < s.length()) {
                i++;
                b.append(s.charAt(i));
            } else {
                b.append(c);
            }
        }
        return b.toString();
    }

    /**
     * A name that cannot leave the directory it is saved in, and that a
     * filesystem will accept: one path segment, no control characters, no
     * separators, no {@code "}, {@code *}, {@code ?}, {@code :}, {@code <},
     * {@code >} or {@code |}, and bounded in length.
     */
    static String clean(String raw) {
        if (raw == null) {
            return null;
        }
        String s = raw.trim();
        int cut = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\'));
        if (cut >= 0) {
            s = s.substring(cut + 1);
        }
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c < 0x20 || c == 0x7f) {
                continue;
            }
            if (c == '"' || c == '*' || c == '?' || c == ':' || c == '<' || c == '>' || c == '|') {
                continue;
            }
            b.append(c);
        }
        s = b.toString().trim();
        // "." and ".." are directories, not names; a name of nothing but dots is
        // not one either.
        boolean dots = !s.isEmpty();
        for (int i = 0; i < s.length() && dots; i++) {
            dots = s.charAt(i) == '.';
        }
        if (s.isEmpty() || dots) {
            return null;
        }
        while (s.endsWith(".") || s.endsWith(" ")) {
            s = s.substring(0, s.length() - 1);
        }
        if (s.isEmpty()) {
            return null;
        }
        if (s.length() > MAX_NAME) {
            String ext = "";
            int dot = s.lastIndexOf('.');
            if (dot > 0 && s.length() - dot <= MAX_EXT) {
                ext = s.substring(dot);
            }
            s = s.substring(0, MAX_NAME - ext.length()) + ext;
        }
        return s;
    }

    /** Percent-decoding that keeps {@code +} as {@code +}: this is a path, not a form. */
    static String percentDecode(String value) {
        if (value == null || value.indexOf('%') < 0) {
            return value;
        }
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        StringBuilder literal = new StringBuilder();
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '%' && i + 2 < value.length()) {
                int hi = hex(value.charAt(i + 1));
                int lo = hex(value.charAt(i + 2));
                if (hi >= 0 && lo >= 0) {
                    if (literal.length() > 0) {
                        byte[] bytes = literal.toString().getBytes(UTF8);
                        out.write(bytes, 0, bytes.length);
                        literal.setLength(0);
                    }
                    out.write((hi << 4) | lo);
                    i += 2;
                    continue;
                }
            }
            literal.append(c);
        }
        if (literal.length() > 0) {
            byte[] bytes = literal.toString().getBytes(UTF8);
            out.write(bytes, 0, bytes.length);
        }
        return new String(out.toByteArray(), UTF8);
    }

    private static int hex(char c) {
        if (c >= '0' && c <= '9') {
            return c - '0';
        }
        if (c >= 'a' && c <= 'f') {
            return c - 'a' + 10;
        }
        if (c >= 'A' && c <= 'F') {
            return c - 'A' + 10;
        }
        return -1;
    }

    private static String schemeOf(String url) {
        int colon = url.indexOf(':');
        if (colon <= 0) {
            return null;
        }
        String scheme = url.substring(0, colon).toLowerCase();
        for (int i = 0; i < scheme.length(); i++) {
            char c = scheme.charAt(i);
            boolean ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                    || c == '+' || c == '-' || c == '.';
            if (!ok) {
                return null;
            }
        }
        return scheme;
    }

    /**
     * The same decisions, on a command line, for the host suite.
     *
     * <pre>
     *   java dev.dshd.app.Download &lt;content-disposition&gt; &lt;url&gt; &lt;allowed-prefix&gt;
     *   refuse=external
     *   name=dsh-session-abc.zip
     * </pre>
     *
     * <p>{@code -} stands for an absent value, which is how a download with no
     * {@code Content-Disposition} at all is expressed.
     */
    public static void main(String[] args) {
        String header = value(args, 0);
        String url = value(args, 1);
        String prefix = value(args, 2);
        System.out.println("refuse=" + refuse(url, prefix));
        System.out.println("name=" + filename(header, url));
    }

    private static String value(String[] args, int index) {
        if (index >= args.length || "-".equals(args[index])) {
            return null;
        }
        return args[index];
    }
}
