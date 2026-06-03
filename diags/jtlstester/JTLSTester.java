import java.io.BufferedOutputStream;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.MalformedURLException;
import java.net.PortUnreachableException;
import java.net.Proxy;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URL;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.Provider;
import java.security.PublicKey;
import java.security.Security;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.security.interfaces.DSAPublicKey;
import java.security.interfaces.ECPublicKey;
import java.security.interfaces.RSAPublicKey;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collection;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import javax.net.ssl.KeyManager;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSession;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

/**
 * JTLSTester - A comprehensive TLS diagnostic tool for Java.
 * Tests connection to an endpoint, scans protocols and ciphers,
 * extracts certificate chain details, and diagnoses JVM security settings.
 */
@SuppressWarnings({
    "PMD.SystemPrintln",
    "PMD.AvoidCatchingGenericException",
    "PMD.AvoidDuplicateLiterals",
    "PMD.GuardLogStatement",
    "PMD.DoNotTerminateVM",
    "PMD.AvoidLiteralsInIfCondition",
    "PMD.ReplaceJavaUtilDate",
    "PMD.UseVarargs",
    "PMD.ArrayIsStoredDirectly",
    "PMD.MethodReturnsInternalArray",
    "PMD.UnusedFormalParameter",
    "PMD.AssignmentInOperand",
    "PMD.EmptyCatchBlock",
    "PMD.CloseResource",
    "PMD.UseTryWithResources",
    "PMD.AvoidPrintStackTrace",
    "checkstyle:all"
})
public final class JTLSTester {
    private static String exportCertPrefix = null;
    private static List<String> customHeaders = new ArrayList<>();
    private static String customSniHost = null;
    private static boolean disableSni = false;
    private static String proxyHost = null;
    private static int proxyPort = 8080;
    private static String proxyType = "http";
    private static int timeout = 5000;
    private static int retries = 3;
    private static boolean scanCiphers = false;
    private static boolean verbose = false;
    private static boolean insecure = false;
    private static boolean showCert = false;
    private static boolean jsonOutput = false;
    private static String csvFilePath = null;
    private static List<String> expectedHttpStatuses = new ArrayList<>();

    // Global keystore / truststore state
    private static KeyStore globalTrustStore = null;
    private static KeyStore globalKeyStore = null;
    private static KeyManager[] globalKeyManagers = null;
    private static X509TrustManager globalDefaultTrustManager = null;

    private JTLSTester() {
        // Prevent instantiation
    }

    private static class Target {
        String host;
        int port;
        String httpPath;
        String rawTarget;
        Target(final String host, final int port, final String httpPath, final String rawTarget) {
            this.host = host;
            this.port = port;
            this.httpPath = httpPath;
            this.rawTarget = rawTarget;
        }
    }

    private static class TargetResult {
        Target target;
        List<String> resolvedIps = new ArrayList<>();
        long tcpLatency = -1;
        boolean tcpConnected = false;
        boolean tlsHandshakeSuccess = false;
        long tlsHandshakeLatency = -1;
        String tlsProtocol = null;
        String tlsCipher = null;
        String tlsAlpn = null;
        boolean ocspStapled = false;
        boolean sessionResumptionAttempted = false;
        boolean sessionResumptionSuccess = false;
        long sessionResumptionLatency = -1;
        X509Certificate[] capturedChain = null;
        boolean certChainTrusted = false;
        String certChainTrustError = null;
        String httpStatusLine = null;
        String httpAltSvcLine = null;
        boolean quicReachable = false;
        List<ProtocolScanResult> protocolScanResults = new ArrayList<>();
        List<String> serverCiphers = new ArrayList<>();
        String error = null;
        String suggestion = null;

        TargetResult(final Target target) {
            this.target = target;
        }
    }

    private static class ProtocolScanResult {
        String protocol;
        String status;
        long latencyMs;
        ProtocolScanResult(final String p, final String s, final long l) {
            protocol = p;
            status = s;
            latencyMs = l;
        }
    }

    /**
     * Normalizes and parses raw URL input strings into Target configurations.
     * Automatically infers scheme defaults (https://, default port 443;
     * http://, default port 80) and maps endpoints to standardized hostname, port, and query-path
     * parameters.
     *
     * @param val Raw input string representing a URL or target spec.
     * @return Target instance encapsulating the resolved endpoint properties.
     * @throws MalformedURLException if the format does not resolve to a valid
     * hostname structure.
     */
    private static Target parseUrlTarget(final String val)throws MalformedURLException {
        String urlToParse = val;
        if (!val.contains("://")) {
            urlToParse = "https://" + val;
        }
        URL url;
        try {
            url = new URI(urlToParse).toURL();
        } catch (URISyntaxException e) {
            MalformedURLException ex = new MalformedURLException(e.getMessage());
            ex.initCause(e);
            throw ex;
        }
        String uHost = url.getHost();
        if (uHost == null || uHost.isEmpty()) {
            throw new MalformedURLException("Host name cannot be empty");
        }
        int uPort = url.getPort() != -1 ? url.getPort() : ("https".equalsIgnoreCase(url.getProtocol()) ? 443 : 80);
        String uPath = url.getFile();
        if (uPath == null || uPath.isEmpty()) {
            uPath = "/";
        }
        return new Target(uHost, uPort, uPath, val);
    }

    /**
     * Entrypoint of the JTLSTester utility.
     * Responsible for:
     * 1. Setting up system property parameters for status extensions (OCSP).
     * 2. Early argument scans for enabling raw SSL logging.
     * 3. Orchestrating command-line parameter parsing and rejecting positional
     * target ambiguities.
     * 4. Executing Cartesian port expansions across the target configuration.
     * 5. Resolving global truststore and client keystore files securely.
     * 6. Initializing and managing the ExecutorService thread-pool.
     * 7. Executing targets concurrently, collecting results, exporting
     * summaries (CSV/JSON), and resolving exit codes.
     *
     * @param args Array of CLI arguments.
     */
    public static void main(final String[] args) {
        // Enable OCSP status request extension for OCSP stapling
        System.setProperty("jdk.tls.client.enableStatusRequestExtension", "true");

        // Early scan for --debug-ssl to initialize JSSE logging before any SSL
        // classes are loaded
        for (String arg : args) {
            if ("--debug-ssl".equals(arg)) {
                System.setProperty("javax.net.debug", "ssl,handshake");
                break;
            }
        }

        // Parsing options
        List<String> rawHosts = new ArrayList<>();
        List<Integer> targetPorts = new ArrayList<>();
        List<Target> finalTargets = new ArrayList<>();
        String targetsFilePath = null;
        int maxWorkers = 4;

        boolean diagnose = false;
        boolean showHelp = false;
        boolean showVersion = false;
        String trustStorePath = null;
        String trustStorePassType = null;
        String trustStorePassFilePath = null;
        String keyStorePath = null;
        String keyStorePassType = null;
        String keyStorePassFilePath = null;
        String logFilePath = null;

        int i = 0;
        while (i < args.length) {
            String arg = args[i];
            if ("-h".equals(arg) || "--help".equals(arg)) {
                showHelp = true;
            } else if ("-t".equals(arg) || "--timeout".equals(arg)) {
                if (i + 1 < args.length) {
                    try {
                        i++;
                        timeout = Integer.parseInt(args[i]);
                    } catch (NumberFormatException e) {
                        System.err.println("Error: Invalid timeout value: " + args[i]);
                        System.exit(1);
                    }
                } else {
                    System.err.println("Error: Missing timeout value");
                    System.exit(1);
                }
            } else if ("-p".equals(arg) || "--port".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    String[] parts = args[i].split(",");
                    for (String part : parts) {
                        try {
                            targetPorts.add(Integer.parseInt(part.trim()));
                        } catch (NumberFormatException e) {
                            System.err.println("Error: Invalid port: " + part);
                            System.exit(1);
                        }
                    }
                } else {
                    System.err.println("Error: Missing port value");
                    System.exit(1);
                }
            } else if ("-e".equals(arg) || "--endpoint".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    rawHosts.add(args[i]);
                } else {
                    System.err.println("Error: Missing endpoint value");
                    System.exit(1);
                }
            } else if ("-u".equals(arg) || "--url".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    String val = args[i];
                    try {
                        finalTargets.add(parseUrlTarget(val));
                    } catch (MalformedURLException e) {
                        System.err.println("Error: Invalid URL: " + val + " (" + e.getMessage() + ")");
                        System.exit(1);
                    }
                } else {
                    System.err.println("Error: Missing URL value");
                    System.exit(1);
                }
            } else if ("--hostname".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    String[] parts = args[i].split(",");
                    for (String part : parts) {
                        String pTrim = part.trim();
                        if (!pTrim.isEmpty()) {
                            rawHosts.add(pTrim);
                        }
                    }
                } else {
                    System.err.println("Error: Missing hostname value");
                    System.exit(1);
                }
            } else if ("-f".equals(arg) || "--file".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    targetsFilePath = args[i];
                } else {
                    System.err.println("Error: Missing file path");
                    System.exit(1);
                }
            } else if ("--workers".equals(arg)) {
                if (i + 1 < args.length) {
                    try {
                        i++;
                        maxWorkers = Integer.parseInt(args[i]);
                        if (maxWorkers < 1) {
                            System.err.println("Error: Concurrency workers must be at least 1");
                            System.exit(1);
                        }
                    } catch (NumberFormatException e) {
                        System.err.println("Error: Invalid workers count: " + args[i]);
                        System.exit(1);
                    }
                } else {
                    System.err.println("Error: Missing workers count");
                    System.exit(1);
                }
            } else if ("-r".equals(arg) || "--truststore".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    String val = args[i];
                    String[] parts = val.split(",");
                    if (parts.length < 2) {
                        System.err.println("Error: Invalid truststore argument format. Expected <file>,<type>[,<passfile>]");
                        System.exit(1);
                    }
                    trustStorePath = parts[0];
                    trustStorePassType = parts[1].toLowerCase(Locale.ENGLISH);
                    if ("secret".equals(trustStorePassType) || "file".equals(trustStorePassType)) {
                        if (parts.length < 3) {
                            System.err.println("Error: Missing password file path for 'secret'/'file' type. Expected <file>,secret,<passfile>");
                            System.exit(1);
                        }
                        trustStorePassFilePath = parts[2];
                    }
                } else {
                    System.err.println("Error: Missing truststore arguments");
                    System.exit(1);
                }
            } else if ("-c".equals(arg) || "--cert".equals(arg)) {
                showCert = true;
            } else if ("-s".equals(arg) || "--scan".equals(arg)) {
                scanCiphers = true;
            } else if ("-V".equals(arg) || "--verbose".equals(arg)) {
                verbose = true;
            } else if ("-v".equals(arg) || "--version".equals(arg)) {
                showVersion = true;
            } else if ("-i".equals(arg) || "--retries".equals(arg)) {
                if (i + 1 < args.length) {
                    try {
                        i++;
                        retries = Integer.parseInt(args[i]);
                    } catch (NumberFormatException e) {
                        System.err.println("Error: Invalid retries value: " + args[i]);
                        System.exit(1);
                    }
                } else {
                    System.err.println("Error: Missing retries value");
                    System.exit(1);
                }
            } else if ("-k".equals(arg) || "--insecure".equals(arg)) {
                insecure = true;
            } else if ("-K".equals(arg) || "--keystore".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    String val = args[i];
                    String[] parts = val.split(",");
                    if (parts.length < 2) {
                        System.err.println("Error: Invalid keystore argument format. Expected <file>,<type>[,<passfile>]");
                        System.exit(1);
                    }
                    keyStorePath = parts[0];
                    keyStorePassType = parts[1].toLowerCase(Locale.ENGLISH);
                    if ("secret".equals(keyStorePassType) || "file".equals(keyStorePassType)) {
                        if (parts.length < 3) {
                            System.err.println("Error: Missing password file path for 'secret'/'file' type. Expected <file>,secret,<passfile>");
                            System.exit(1);
                        }
                        keyStorePassFilePath = parts[2];
                    }
                } else {
                    System.err.println("Error: Missing keystore arguments");
                    System.exit(1);
                }
            } else if ("--sni".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    customSniHost = args[i];
                } else {
                    System.err.println("Error: Missing SNI hostname");
                    System.exit(1);
                }
            } else if ("--no-sni".equals(arg)) {
                disableSni = true;
            } else if ("--debug-ssl".equals(arg)) {
                // Handled in early scan
            } else if ("--json".equals(arg)) {
                jsonOutput = true;
                Console.setQuiet(true);
            } else if ("--proxy".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    String val = args[i];
                    int colonIdx = val.lastIndexOf(':');
                    if (colonIdx > 0) {
                        proxyHost = val.substring(0, colonIdx);
                        try {
                            proxyPort = Integer.parseInt(val.substring(colonIdx + 1));
                        } catch (NumberFormatException e) {
                            System.err.println("Error: Invalid proxy port: " + val);
                            System.exit(1);
                        }
                    } else {
                        proxyHost = val;
                        proxyPort = 8080;
                    }
                } else {
                    System.err.println("Error: Missing proxy value");
                    System.exit(1);
                }
            } else if ("--proxy-type".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    proxyType = args[i].toLowerCase(Locale.ENGLISH);
                    if (!"http".equals(proxyType) && !"socks".equals(proxyType)) {
                        System.err.println("Error: Invalid proxy type. Expected 'http' or 'socks'");
                        System.exit(1);
                    }
                } else {
                    System.err.println("Error: Missing proxy-type value");
                    System.exit(1);
                }
            } else if ("-l".equals(arg) || "--log".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    logFilePath = args[i];
                } else {
                    System.err.println("Error: Missing log file path");
                    System.exit(1);
                }
            } else if ("-H".equals(arg) || "--header".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    String header = args[i];
                    if (!header.contains(":")) {
                        System.err.println("Error: Invalid header format: '" + header + "'. Expected 'Name: Value'");
                        System.exit(1);
                    }
                    customHeaders.add(header);
                } else {
                    System.err.println("Error: Missing header value");
                    System.exit(1);
                }
            } else if ("--export-cert".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    exportCertPrefix = args[i];
                } else {
                    System.err.println("Error: Missing export certificate prefix");
                    System.exit(1);
                }
            } else if ("--csv".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    csvFilePath = args[i];
                } else {
                    System.err.println("Error: Missing CSV file path");
                    System.exit(1);
                }
            } else if ("--assert-status".equals(arg)) {
                if (i + 1 < args.length) {
                    i++;
                    String[] parts = args[i].split(",");
                    for (String part : parts) {
                        expectedHttpStatuses.add(part.trim());
                    }
                } else {
                    System.err.println("Error: Missing status code assertion value");
                    System.exit(1);
                }
            } else if ("-d".equals(arg) || "--diagnose".equals(arg)) {
                diagnose = true;
            } else if ("--no-color".equals(arg)) {
                Console.setUseColor(false);
            } else if ("--color".equals(arg)) {
                Console.setUseColor(true);
            } else {
                System.err.println("Error: Positional targets are not allowed: " + arg);
                System.err.println("Please specify targets using -e/--endpoint, -u/--url, -f/--file, or --hostname.");
                System.exit(1);
            }
            i++;
        }

        if (logFilePath != null) {
            try {
                File logFile = new File(logFilePath);
                File parent = logFile.getParentFile();
                if (parent != null) {
                    parent.mkdirs();
                }
                PrintStream ps = new PrintStream(new BufferedOutputStream(new FileOutputStream(logFile)), true, StandardCharsets.UTF_8.name());
                System.setOut(ps);
            } catch (Exception e) {
                System.err.println("Error: Failed to create log file " + logFilePath + ": " + e.getMessage());
                System.exit(1);
            }
        }

        // Check environment for NO_COLOR
        if (System.getenv("NO_COLOR") != null) {
            Console.setUseColor(false);
        }

        if (showVersion) {
            System.out.println("JTLSTester version " + getVersion());
            System.exit(0);
        }

        if (showHelp) {
            printUsage();
            System.exit(0);
        }

        if (diagnose) {
            runDiagnostics();
            if (rawHosts.isEmpty() && finalTargets.isEmpty() && targetsFilePath == null) {
                System.exit(0);
            }
        }

        // Read targets from file if provided
        if (targetsFilePath != null) {
            try {
                if (!"-".equals(targetsFilePath)) {
                    File file = new File(targetsFilePath);
                    if (!file.exists() || !file.isFile()) {
                        System.err.println("Error: Target file not found: " + targetsFilePath);
                        System.exit(1);
                    }
                }
                try (BufferedReader reader = "-".equals(targetsFilePath)
                        ? new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))
                        : new BufferedReader(new InputStreamReader(new FileInputStream(targetsFilePath), StandardCharsets.UTF_8))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        line = line.trim();
                        if (line.isEmpty() || line.startsWith("#")) {
                            continue;
                        }
                        if (line.contains("://")) {
                            try {
                                finalTargets.add(parseUrlTarget(line));
                            } catch (MalformedURLException e) {
                                System.err.println("Error: Invalid URL in file: " + line + " (" + e.getMessage() + ")");
                                System.exit(1);
                            }
                        } else {
                            rawHosts.add(line);
                        }
                    }
                }
            } catch (Exception e) {
                System.err.println("Error: Failed to read target file: " + e.getMessage());
                System.exit(1);
            }
        }

        // Expand rawHosts with targetPorts
        if (!rawHosts.isEmpty()) {
            if (targetPorts.isEmpty()) {
                targetPorts.add(443);
            }
            for (String rawHost : rawHosts) {
                int colonIdx = rawHost.lastIndexOf(':');
                if (colonIdx > 0 && !rawHost.startsWith("[")) {
                    try {
                        int p = Integer.parseInt(rawHost.substring(colonIdx + 1));
                        String h = rawHost.substring(0, colonIdx);
                        finalTargets.add(new Target(h, p, "/", rawHost));
                    } catch (NumberFormatException e) {
                        for (int port : targetPorts) {
                            finalTargets.add(new Target(rawHost, port, "/", rawHost));
                        }
                    }
                } else if (rawHost.startsWith("[")) {
                    int closeBracket = rawHost.indexOf(']');
                    if (closeBracket > 0) {
                        String ip = rawHost.substring(1, closeBracket);
                        if (rawHost.length() > closeBracket + 1 && rawHost.charAt(closeBracket + 1) == ':') {
                            try {
                                int p = Integer.parseInt(rawHost.substring(closeBracket + 2));
                                finalTargets.add(new Target(ip, p, "/", rawHost));
                            } catch (NumberFormatException e) {
                                for (int port : targetPorts) {
                                    finalTargets.add(new Target(ip, port, "/", rawHost));
                                }
                            }
                        } else {
                            for (int port : targetPorts) {
                                    finalTargets.add(new Target(ip, port, "/", rawHost));
                            }
                        }
                    } else {
                        for (int port : targetPorts) {
                            finalTargets.add(new Target(rawHost, port, "/", rawHost));
                        }
                    }
                } else {
                    for (int port : targetPorts) {
                        finalTargets.add(new Target(rawHost, port, "/", rawHost));
                    }
                }
            }
        }

        if (finalTargets.isEmpty()) {
            System.err.println("Error: No targets specified.");
            printUsage();
            System.exit(1);
        }

        // Load custom truststore dynamically once globally
        try {
            TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
            if (trustStorePath != null) {
                char[] password = null;
                if ("env".equals(trustStorePassType)) {
                    String envPass = System.getenv("TLSTESTER_TRUSTSTORE_PASS");
                    if (envPass != null) {
                        password = envPass.toCharArray();
                    } else {
                        System.err.println("Error: Environment variable TLSTESTER_TRUSTSTORE_PASS not defined.");
                        System.exit(1);
                    }
                } else if ("interactive".equals(trustStorePassType)) {
                    if (System.console() != null) {
                        password = System.console().readPassword("  [?] Enter truststore password (press Enter for none): ");
                    } else {
                        System.err.println("  [!] Warning: System console not available. Reading password via stdin falls back to heap strings.");
                        System.out.print("  [?] Enter truststore password (echoed, run interactively to mask): ");
                        try (BufferedReader r = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
                            String l = r.readLine();
                            if (l != null && !l.isEmpty()) {
                                password = l.toCharArray();
                            }
                        } catch (IOException ignored) {
                        }
                    }
                } else if ("secret".equals(trustStorePassType) || "file".equals(trustStorePassType)) {
                    try {
                        File passFile = new File(trustStorePassFilePath);
                        if (!passFile.exists() || !passFile.isFile()) {
                            throw new FileNotFoundException("Password file not found: " + trustStorePassFilePath);
                        }
                        try (InputStreamReader isr = new InputStreamReader(new FileInputStream(passFile), StandardCharsets.UTF_8);
                             BufferedReader br = new BufferedReader(isr)) {
                            String l = br.readLine();
                            if (l != null) {
                                password = l.toCharArray();
                            }
                        }
                    } catch (Exception e) {
                        System.err.println("Error: Failed to read truststore password from file " + trustStorePassFilePath + ": " + e.getMessage());
                        System.exit(1);
                    }
                }
                char[] loadPassword = (password != null && password.length > 0) ? password : null;
                try (FileInputStream fis = new FileInputStream(trustStorePath)) {
                    String storeType = trustStorePath.toLowerCase(Locale.ENGLISH).endsWith(".jks") ? "JKS" : "PKCS12";
                    globalTrustStore = KeyStore.getInstance(storeType);
                    globalTrustStore.load(fis, loadPassword);
                } finally {
                    if (password != null) {
                        Arrays.fill(password, '\0');
                    }
                }
            }
            tmf.init(globalTrustStore);
            for (TrustManager tm : tmf.getTrustManagers()) {
                if (tm instanceof X509TrustManager) {
                    globalDefaultTrustManager = (X509TrustManager) tm;
                    break;
                }
            }
        } catch (Exception e) {
            System.err.println("Error: Failed to initialize trust managers: " + e.getMessage());
            System.exit(1);
        }

        // Load custom keystore globally for mTLS
        if (keyStorePath != null) {
            char[] password = null;
            if ("env".equals(keyStorePassType)) {
                String envPass = System.getenv("TLSTESTER_KEYSTORE_PASS");
                if (envPass != null) {
                    password = envPass.toCharArray();
                } else {
                    System.err.println("Error: Environment variable TLSTESTER_KEYSTORE_PASS not defined.");
                    System.exit(1);
                }
            } else if ("interactive".equals(keyStorePassType)) {
                if (System.console() != null) {
                    password = System.console().readPassword("  [?] Enter client keystore password (press Enter for none): ");
                } else {
                    System.err.println("  [!] Warning: System console not available. Reading password via stdin falls back to heap strings.");
                    System.out.print("  [?] Enter client keystore password (echoed, run interactively to mask): ");
                    try (BufferedReader r = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
                        String l = r.readLine();
                        if (l != null && !l.isEmpty()) {
                            password = l.toCharArray();
                        }
                    } catch (IOException ignored) {
                    }
                }
            } else if ("secret".equals(keyStorePassType) || "file".equals(keyStorePassType)) {
                try {
                    File passFile = new File(keyStorePassFilePath);
                    if (!passFile.exists() || !passFile.isFile()) {
                        throw new FileNotFoundException("Keystore password file not found: " + keyStorePassFilePath);
                    }
                    try (InputStreamReader isr = new InputStreamReader(new FileInputStream(passFile), StandardCharsets.UTF_8);
                         BufferedReader br = new BufferedReader(isr)) {
                        String l = br.readLine();
                        if (l != null) {
                            password = l.toCharArray();
                        }
                    }
                } catch (Exception e) {
                    System.err.println("Error: Failed to read keystore password from file " + keyStorePassFilePath + ": " + e.getMessage());
                    System.exit(1);
                }
            }
            char[] loadPassword = (password != null && password.length > 0) ? password : null;
            try (FileInputStream fis = new FileInputStream(keyStorePath)) {
                String storeType = keyStorePath.toLowerCase(Locale.ENGLISH).endsWith(".jks") ? "JKS" : "PKCS12";
                globalKeyStore = KeyStore.getInstance(storeType);
                globalKeyStore.load(fis, loadPassword);
                KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
                kmf.init(globalKeyStore, loadPassword);
                globalKeyManagers = kmf.getKeyManagers();
            } catch (Exception e) {
                System.err.println("Error: Failed to load client keystore from " + keyStorePath + ": " + e.getMessage());
                System.exit(1);
            } finally {
                if (password != null) {
                    Arrays.fill(password, '\0');
                }
            }
        }

        // Set quiet mode during threads run if multiple targets and not verbose
        if (finalTargets.size() > 1 && !verbose) {
            Console.setQuiet(true);
        }

        // Run targets in concurrent workers
        int workers = Math.min(finalTargets.size(), maxWorkers);
        ExecutorService executor = Executors.newFixedThreadPool(workers);
        try {
            List<Future<TargetResult>> futures = new ArrayList<>();
            
            if (finalTargets.size() > 1 && !verbose && !jsonOutput) {
                System.err.println("[+] Starting parallel diagnostic checks against " + finalTargets.size() + " target(s) using " + workers + " worker(s)...");
            }

            for (Target target : finalTargets) {
                futures.add(executor.submit(() -> {
                    if (finalTargets.size() > 1 && !verbose && !jsonOutput) {
                        System.err.println("  -> Probing target: " + target.rawTarget + " (" + target.host + ":" + target.port + ")...");
                    }
                    try {
                        return runTargetDiagnostics(target);
                    } catch (Exception e) {
                        TargetResult errResult = new TargetResult(target);
                        errResult.error = "Uncaught error during run: " + e.toString();
                        errResult.suggestion = getFailureSuggestion(errResult);
                        return errResult;
                    }
                }));
            }

            List<TargetResult> results = new ArrayList<>();
            for (Future<TargetResult> future : futures) {
                try {
                    results.add(future.get());
                } catch (Exception e) {
                    // Should not happen
                }
            }

            // Restore quiet mode
            Console.setQuiet(jsonOutput);

            // Export summary to CSV if requested
            if (csvFilePath != null) {
                writeCsvReport(results, csvFilePath);
            }

            // Print final outputs
            if (jsonOutput) {
                printJsonArrayAndExit(results);
            } else {
                printSummaryTable(results);
                
                boolean anyFailed = false;
                for (TargetResult r : results) {
                    if (r.error != null || !r.tlsHandshakeSuccess) {
                        anyFailed = true;
                    }
                }
                System.exit(anyFailed ? 1 : 0);
            }
        } finally {
            executor.shutdown();
        }
    }

    /**
     * Executes the comprehensive, sequential diagnostics suite for a single
     * Target.
     * The diagnostic lifecycle consists of the following sequential operational
     * phases:
     * 1. DNS Name Resolution
     * 2. TCP Connectivity verification (with configurable retry logic and
     * network latency measurements)
     * 3. Custom SSLContext bootstrapping using a SavingTrustManager wrapper to
     * intercept certificates
     * 4. Outbound TLS handshake routing with custom SNI headers and ALPN
     * capabilities negotiation
     * 5. Cryptographic chain analysis (order validation, expiration metrics,
     * weak algorithm detection)
     * 6. Application-level probe checks (HTTP status code validation, Alt-Svc
     * header logging)
     * 7. Session Resumption capability evaluation (comparing original and
     * resumed session tickets)
     * 8. Datagram layer reachability check (UDP / QUIC port diagnostics using
     * ICMP feedback)
     * 9. Protocol scanning sweeps (TLS 1.3 down to SSL 3.0 support
     * identification)
     * 10. Multi-negotiation cipher capabilities sweeps (if enabled)
     * Note: A try-finally block bounds execution to guarantee ThreadLocal
     * context cleanup for recycled execution threads.
     *
     * @param target configuration defining hostname, port, and probe endpoints.
     * @return TargetResult containing execution latency, trust profiles, and
     * failure parameters.
     */
    private static TargetResult runTargetDiagnostics(final Target target) {
        TargetResult result = new TargetResult(target);
        
        try {
            if (verbose) {
                Console.setPrefix("[" + target.rawTarget + "] ");
            }
            
            Console.println(Console.BOLD + Console.CYAN, "Starting TLS Diagnostics for " + target.host + ":" + target.port);
            Console.println(Console.GRAY, "Timeout: " + timeout + "ms | Insecure mode: " + insecure + " | Cipher scan: " + scanCiphers + " | Show cert details: " + showCert);

            // 1. DNS Resolution
            Console.header("DNS Resolution");
            InetAddress[] addresses;
            try {
                addresses = InetAddress.getAllByName(target.host);
                Console.success("Resolved '" + target.host + "' to " + addresses.length + " address(es):");
                for (InetAddress addr : addresses) {
                    Console.info("IP Address", addr.getHostAddress());
                    result.resolvedIps.add(addr.getHostAddress());
                }
            } catch (UnknownHostException e) {
                Console.error("Failed to resolve hostname: " + target.host);
                result.error = "Failed to resolve hostname: " + e.getMessage();
                result.suggestion = getFailureSuggestion(result);
                return result;
            }

            // 2. TCP Connectivity Check
            Console.header("TCP Connectivity");
            InetAddress targetAddr = addresses[0];
            int tcpAttempts = 1 + retries;
            for (int attempt = 1; attempt <= tcpAttempts; attempt++) {
                long startTcp = System.currentTimeMillis();
                try (Socket socket = (proxyHost != null) ?
                        new Socket(new Proxy("socks".equalsIgnoreCase(proxyType) ? Proxy.Type.SOCKS : Proxy.Type.HTTP, new InetSocketAddress(proxyHost, proxyPort))) :
                        new Socket()) {
                    socket.connect(new InetSocketAddress(targetAddr, target.port), timeout);
                    result.tcpLatency = System.currentTimeMillis() - startTcp;
                    Console.success("TCP connection established to " + targetAddr.getHostAddress() + ":" + target.port + " in " + result.tcpLatency + " ms");
                    if (proxyHost != null) {
                        Console.info("Proxy used", proxyType.toUpperCase(Locale.ENGLISH) + " proxy (" + proxyHost + ":" + proxyPort + ")");
                    }
                    result.tcpConnected = true;
                    break;
                } catch (IOException e) {
                    Console.error("TCP connection attempt " + attempt + "/" + tcpAttempts + " failed: " + e.getMessage());
                    if (attempt < tcpAttempts) {
                        Console.warning("Retrying TCP connection in 1 second...");
                        try {
                            Thread.sleep(1000);
                        } catch (InterruptedException ie) {
                            Thread.currentThread().interrupt();
                        }
                    } else {
                        Console.warning("Check network connectivity, host status, or firewall rules.");
                    }
                }
            }

            if (!result.tcpConnected) {
                Console.error("Stopping TLS diagnostics because TCP connection failed.");
                result.error = "TCP connection failed";
                result.suggestion = getFailureSuggestion(result);
                return result;
            }

            // Initialize custom TrustManager to capture cert chain per target
            // run
            SavingTrustManager savingTm = new SavingTrustManager(globalDefaultTrustManager);
            SSLContext sslContext;
            try {
                sslContext = SSLContext.getInstance("TLS");
                sslContext.init(globalKeyManagers, new TrustManager[]{savingTm}, null);
            } catch (Exception e) {
                Console.error("Failed to initialize custom SSLContext: " + e.getMessage());
                result.error = "Failed to initialize SSLContext: " + e.getMessage();
                result.suggestion = getFailureSuggestion(result);
                return result;
            }

            // 4. Standard TLS Connection & Certificate Retrieval
            Console.header("TLS Handshake");
            byte[] originalSessionId = new byte[0];
            int tlsAttempts = 1 + retries;
            for (int attempt = 1; attempt <= tlsAttempts; attempt++) {
                long startTls = System.currentTimeMillis();
                try (SSLSocket sslSocket = createConnectedSocket(target.host, target.port, timeout, sslContext.getSocketFactory())) {
                    setAlpnProtocols(sslSocket, new String[]{"h2", "http/1.1"});
                    if (verbose) {
                        Console.println(Console.GRAY, "  [DEBUG] Handshake starting...");
                    }
                    sslSocket.startHandshake();
                    long endTls = System.currentTimeMillis();

                    SSLSession session = sslSocket.getSession();
                    result.tlsHandshakeLatency = endTls - startTls;
                    result.tlsProtocol = session.getProtocol();
                    result.tlsCipher = session.getCipherSuite();
                    result.tlsAlpn = getNegotiatedAlpn(sslSocket);
                    originalSessionId = session.getId();
                    result.tlsHandshakeSuccess = true;
                    result.ocspStapled = isOcspStapled(session);

                    Console.success("TLS Handshake completed successfully in " + result.tlsHandshakeLatency + " ms");
                    Console.info("Protocol negotiated", Console.GREEN, result.tlsProtocol);
                    Console.info("Cipher suite negotiated", Console.GREEN, result.tlsCipher);

                    if (result.tlsAlpn != null) {
                        Console.info("ALPN Protocol negotiated", Console.GREEN, result.tlsAlpn);
                    } else {
                        Console.info("ALPN Protocol negotiated", "None/Not supported by client JRE");
                    }

                    if (result.ocspStapled) {
                        Console.info("OCSP Stapling", Console.GREEN, "YES (Stapled response returned by server)");
                    } else {
                        Console.info("OCSP Stapling", "NO");
                    }

                    // TLS Security Warnings
                    List<String> tlsWarnings = getTlsWarnings(result.tlsProtocol, result.tlsCipher);
                    if (!tlsWarnings.isEmpty()) {
                        Console.println(Console.BOLD + Console.YELLOW, "  [!] TLS Security Warnings:");
                        for (String w : tlsWarnings) {
                            Console.println(Console.YELLOW, "    - " + w);
                        }
                    }

                    result.capturedChain = savingTm.getChain();
                    if (result.capturedChain == null || result.capturedChain.length == 0) {
                        try {
                            java.security.cert.Certificate[] peerCerts = session.getPeerCertificates();
                            result.capturedChain = new X509Certificate[peerCerts.length];
                            for (int j = 0; j < peerCerts.length; j++) {
                                result.capturedChain[j] = (X509Certificate) peerCerts[j];
                            }
                        } catch (SSLPeerUnverifiedException e) {
                            Console.warning("No peer certificates were presented by the server.");
                        }
                    }

                    if (result.capturedChain != null && result.capturedChain.length > 0) {
                        Console.info("Certificate chain length", String.valueOf(result.capturedChain.length));

                        if (exportCertPrefix != null) {
                            exportCertificates(result.capturedChain, exportCertPrefix + "_" + target.host + "_" + target.port);
                        }

                        // Hostname verification
                        boolean hostnameMatches = verifyHostnameCustom(target.host, result.capturedChain[0]);
                        if (hostnameMatches) {
                            Console.info("Hostname verification", Console.GREEN, "MATCH (" + target.host + " matches certificate SAN/CN)");
                        } else {
                            Console.info("Hostname verification", Console.RED, "MISMATCH (" + target.host + " DOES NOT match certificate SAN/CN)");
                        }

                        // Trust verification
                        result.certChainTrustError = checkTrustStatus(result.capturedChain, savingTm.getAuthType(), globalDefaultTrustManager);
                        result.certChainTrusted = (result.certChainTrustError == null);
                        if (result.certChainTrusted) {
                            Console.info("Certificate trust status", Console.GREEN, "TRUSTED");
                        } else {
                            if (insecure) {
                                Console.info("Certificate trust status", Console.YELLOW, "UNTRUSTED - Bypassed via --insecure (" + result.certChainTrustError + ")");
                            } else {
                                Console.info("Certificate trust status", Console.RED, "UNTRUSTED (" + result.certChainTrustError + ")");
                            }
                        }

                        if (showCert) {
                            printCertificateChain(result.capturedChain);
                        } else {
                            Console.println(Console.GRAY, "\nHint: Use option -c or --cert to display detailed certificate chain details.");
                        }
                    }
                    probeHttp(sslSocket, target.host, timeout, result);
                    break;
                } catch (Exception e) {
                    Console.error("TLS Handshake attempt " + attempt + "/" + tlsAttempts + " failed: " + e.toString());
                    if (attempt < tlsAttempts) {
                        Console.warning("Retrying TLS Handshake in 1 second...");
                        try {
                            Thread.sleep(1000);
                        } catch (InterruptedException ie) {
                            Thread.currentThread().interrupt();
                        }
                    } else {
                        if (verbose) {
                            e.printStackTrace();
                        }
                        result.error = "TLS Handshake failed: " + e.getMessage();
                        result.capturedChain = savingTm.getChain();
                        if (result.capturedChain != null && result.capturedChain.length > 0 && showCert) {
                            Console.warning("Retrieved partial/untrusted certificate chain during failed handshake:");
                            printCertificateChain(result.capturedChain);
                        }
                    }
                }
            }

            if (!result.tlsHandshakeSuccess) {
                Console.error("Stopping TLS diagnostics because TLS Handshake failed after " + tlsAttempts + " attempts.");
                if (result.error == null) {
                    result.error = "TLS Handshake failed";
                }
                result.suggestion = getFailureSuggestion(result);
                return result;
            }

            // 4.1. TLS Session Resumption Check
            if (result.tlsHandshakeSuccess) {
                result.sessionResumptionAttempted = true;
                Console.header("TLS Session Resumption");
                long startResumption = System.currentTimeMillis();
                try (SSLSocket sslSocket2 = createConnectedSocket(target.host, target.port, timeout, sslContext.getSocketFactory())) {
                    setAlpnProtocols(sslSocket2, new String[]{"h2", "http/1.1"});
                    sslSocket2.startHandshake();
                    result.sessionResumptionLatency = System.currentTimeMillis() - startResumption;
                    SSLSession session2 = sslSocket2.getSession();
                    
                    byte[] newSessionId = session2.getId();
                    result.sessionResumptionSuccess = newSessionId != null && newSessionId.length > 0 && Arrays.equals(originalSessionId, newSessionId);
                    
                    if (result.sessionResumptionSuccess) {
                        Console.success("Session successfully resumed in " + result.sessionResumptionLatency + " ms (Session ID matched)");
                    } else {
                        if (result.sessionResumptionLatency < (result.tlsHandshakeLatency / 2) && result.sessionResumptionLatency < 50) {
                            result.sessionResumptionSuccess = true;
                            Console.success("Session resumed in " + result.sessionResumptionLatency + " ms (Assumed via TLS 1.3 Session Ticket due to low latency)");
                        } else {
                            Console.warning("New TLS session negotiated in " + result.sessionResumptionLatency + " ms (Session ID did not match)");
                        }
                    }
                } catch (Exception e) {
                    Console.error("Session resumption check failed: " + e.getMessage());
                }
            }

            // 4.5. QUIC UDP Reachability Check
            probeQuicUdp(target.host, target.port, timeout, result);

            // 5. Protocols Scan
            scanProtocols(target.host, target.port, timeout, sslContext, result);

            // 6. Ciphers Scan
            if (scanCiphers) {
                scanCipherSuites(target.host, target.port, timeout, sslContext, result);
            } else {
                Console.println(Console.GRAY, "\nHint: Use option -s or --scan to run a full scan of supported cipher suites.");
            }

            if (result.error != null) {
                result.suggestion = getFailureSuggestion(result);
            }
        } finally {
            if (verbose) {
                Console.clearPrefix();
            }
        }

        return result;
    }

    private static boolean verifyHostnameCustom(final String host, final X509Certificate cert) {
        List<String> dnsNames = new ArrayList<>();
        List<String> ipNames = new ArrayList<>();
        try {
            Collection<List<?>> altNames = cert.getSubjectAlternativeNames();
            if (altNames != null) {
                for (List<?> item : altNames) {
                    if (item.size() >= 2) {
                        Integer type = (Integer) item.get(0);
                        String value = item.get(1).toString();
                        if (type == 2) { // dNSName
                            dnsNames.add(value);
                        } else if (type == 7) { // iPAddress
                            ipNames.add(value);
                        }
                    }
                }
            }
        } catch (Exception e) {
            // ignore
        }

        if (!dnsNames.isEmpty() || !ipNames.isEmpty()) {
            boolean isIp = host.matches("^[0-9.:a-fA-F]+$");
            if (isIp) {
                for (String ip : ipNames) {
                    if (host.equalsIgnoreCase(ip)) {
                        return true;
                    }
                }
            } else {
                for (String dns : dnsNames) {
                    if (matchHostname(host, dns)) {
                        return true;
                    }
                }
            }
            return false;
        }

        String dn = cert.getSubjectX500Principal().getName();
        String cn = extractCN(dn);
        if (cn != null) {
            return matchHostname(host, cn);
        }
        return false;
    }

    private static boolean matchHostname(final String host, final String pattern) {
        final String hostLower = host.toLowerCase(Locale.US);
        final String patternLower = pattern.toLowerCase(Locale.US);
        if (patternLower.startsWith("*.")) {
            String suffix = patternLower.substring(2);
            if (hostLower.length() <= suffix.length()) {
                return false;
            }
            if (!hostLower.endsWith(suffix)) {
                return false;
            }
            int suffixLen = suffix.length();
            int hostLen = hostLower.length();
            String prefix = hostLower.substring(0, hostLen - suffixLen - 1);
            return prefix.indexOf('.') == -1 && !prefix.isEmpty();
        }
        return hostLower.equals(patternLower);
    }

    private static String extractCN(final String dn) {
        try {
            int start = dn.indexOf("CN=");
            if (start == -1) {
                return null;
            }
            start += 3;
            int end = dn.indexOf(',', start);
            if (end == -1) {
                end = dn.length();
            }
            return dn.substring(start, end).trim();
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Helper factory to instantiate and connect a standard TCP socket,
     * optionally routing through
     * a configured proxy, and wrapping it in a configured SSLSocket instance.
     * 
     * Defensive Resource Management Pattern:
     * To prevent leaking OS file descriptors when connection handshakes or
     * Server Name Indication (SNI) parameter assignments throw runtime or network IOExceptions, the entire
     * wrap sequence is executed
     * within a try-catch block. On failure, the raw underlying TCP socket is
     * explicitly closed before the
     * exception is rethrown to the caller.
     *
     * @param host destination server hostname or IP address.
     * @param port target network port.
     * @param timeout connection and read timeout values in milliseconds.
     * @param sf SSLSocketFactory configured with active credentials and trust
     * managers.
     * @return fully established SSLSocket ready for cryptographic handshake
     * execution.
     * @throws IOException if network routing, TCP handshake, or wrapping fails.
     */
    private static SSLSocket createConnectedSocket(final String host, final int port, final int timeout, final SSLSocketFactory sf)throws IOException {
        Socket rawSocket = (proxyHost != null) ? 
            new Socket(new Proxy("socks".equalsIgnoreCase(proxyType) ? Proxy.Type.SOCKS : Proxy.Type.HTTP, new InetSocketAddress(proxyHost, proxyPort))) : 
            new Socket();
        try {
            rawSocket.connect(new InetSocketAddress(host, port), timeout);
            SSLSocket sslSocket = (SSLSocket) sf.createSocket(rawSocket, host, port, true);
            if (!disableSni) {
                String sni = (customSniHost != null) ? customSniHost : host;
                try {
                    SSLParameters params = sslSocket.getSSLParameters();
                    params.setServerNames(Collections.singletonList(new SNIHostName(sni)));
                    sslSocket.setSSLParameters(params);
                } catch (Exception e) {
                    // Ignore if SNI is not supported or host is not valid
                    // format (e.g. IP address)
                }
            }
            return sslSocket;
        } catch (IOException e) {
            try {
                rawSocket.close();
            } catch (IOException ignored) {
            }
            throw e;
        }
    }

    private static String checkTrustStatus(final X509Certificate[] chain, final String authType, final X509TrustManager tm) {
        if (tm == null) {
            return "No trust manager available";
        }
        try {
            final String activeAuthType = authType != null ? authType : chain[0].getPublicKey().getAlgorithm();
            tm.checkServerTrusted(chain, activeAuthType);
            return null; // Trusted (no exception)
        } catch (CertificateException e) {
            Throwable cause = e.getCause();
            if (cause != null) {
                return e.getMessage() + " (Cause: " + cause.getMessage() + ")";
            }
            return e.getMessage();
        }
    }

    private static void printCertificateChain(final X509Certificate[] chain) {
        Console.header("Certificate Chain Details");
        for (int i = 0; i < chain.length; i++) {
            X509Certificate cert = chain[i];
            String certType = (i == 0) ? " (Leaf)" : ((i == chain.length - 1) ? " (Root CA)" : " (Intermediate CA)");
            Console.println(Console.BOLD + Console.BLUE, "  [Certificate #" + i + certType + "]");
            
            String subject = cert.getSubjectX500Principal().getName();
            String cn = extractCN(subject);
            Console.info("    Common Name (CN)", cn != null ? cn : "N/A");
            Console.info("    Subject DN", subject);
            
            String issuer = cert.getIssuerX500Principal().getName();
            String issuerCn = extractCN(issuer);
            Console.info("    Issuer CN", issuerCn != null ? issuerCn : "N/A");
            Console.info("    Issuer DN", issuer);

            Console.info("    Serial Number", cert.getSerialNumber().toString(16).toUpperCase(Locale.ENGLISH));

            Date notBefore = cert.getNotBefore();
            Date notAfter = cert.getNotAfter();
            Date now = new Date();
            String valColor = Console.GREEN;
            String valStatus;
            if (now.before(notBefore)) {
                valColor = Console.RED;
                valStatus = "NOT YET ACTIVE (Starts: " + notBefore + ")";
            } else if (now.after(notAfter)) {
                valColor = Console.RED;
                valStatus = "EXPIRED (Ended: " + notAfter + ")";
            } else {
                valStatus = "Valid (From " + notBefore + " to " + notAfter + ")";
            }
            Console.info("    Expiration Date", valColor, valStatus);

            PublicKey key = cert.getPublicKey();
            int size = getKeySize(key);
            String sizeStr = size > 0 ? size + " bits" : "unknown size";
            Console.info("    Public Key", key.getAlgorithm() + " (" + sizeStr + ")");
            Console.info("    Signature Alg", cert.getSigAlgName());

            if (i == 0) {
                List<String> sans = getSubjectAlternativeNames(cert);
                if (!sans.isEmpty()) {
                    Console.println(Console.BOLD, "    Subject Alternative Names (SANs):");
                    for (String san : sans) {
                        Console.println(Console.GRAY, "      - " + san);
                    }
                }
            }
        }

        List<String> orderIssues = validateChainOrder(chain);
        if (!orderIssues.isEmpty()) {
            Console.println(Console.BOLD + Console.YELLOW, "\n  [!] Certificate Chain Order Issues:");
            for (String issue : orderIssues) {
                Console.println(Console.YELLOW, "    - " + issue);
            }
        }

        boolean securityWarningsFound = false;
        for (int i = 0; i < chain.length; i++) {
            List<String> certWarnings = getCertWarnings(chain[i], i);
            if (!certWarnings.isEmpty()) {
                if (!securityWarningsFound) {
                    Console.println(Console.BOLD + Console.YELLOW, "\n  [!] Certificate Cryptographic Warnings:");
                    securityWarningsFound = true;
                }
                for (String warning : certWarnings) {
                    Console.println(Console.YELLOW, "    - [Cert #" + i + "] " + warning);
                }
            }
        }
    }

    private static int getKeySize(final PublicKey key) {
        if (key instanceof RSAPublicKey) {
            return ((RSAPublicKey) key).getModulus().bitLength();
        } else if (key instanceof ECPublicKey) {
            return ((ECPublicKey) key).getParams().getOrder().bitLength();
        } else if (key instanceof DSAPublicKey) {
            return ((DSAPublicKey) key).getParams().getP().bitLength();
        }
        return -1;
    }

    private static List<String> getSubjectAlternativeNames(final X509Certificate cert) {
        List<String> sans = new ArrayList<>();
        try {
            Collection<List<?>> altNames = cert.getSubjectAlternativeNames();
            if (altNames != null) {
                for (List<?> item : altNames) {
                    if (item.size() >= 2) {
                        Integer type = (Integer) item.get(0);
                        Object value = item.get(1);
                        String typeName = getSanTypeName(type);
                        sans.add(typeName + ":" + value.toString());
                    }
                }
            }
        } catch (Exception e) {
            // ignore
        }
        return sans;
    }

    private static String getSanTypeName(final int type) {
        switch (type) {
            case 0: return "otherName";
            case 1: return "rfc822Name";
            case 2: return "dNSName";
            case 3: return "x400Address";
            case 4: return "directoryName";
            case 5: return "ediPartyName";
            case 6: return "uniformResourceIdentifier";
            case 7: return "iPAddress";
            case 8: return "registeredID";
            default: return "unknown(" + type + ")";
        }
    }

    private static void scanProtocols(final String host, final int port, final int timeout, final SSLContext sslContext, final TargetResult result) {
        Console.header("Supported Protocols Scan");
        String[] protocols = {"TLSv1.3", "TLSv1.2", "TLSv1.1", "TLSv1.0", "SSLv3"};

        for (String protocol : protocols) {
            try (SSLSocket sslSocket = createConnectedSocket(host, port, timeout, sslContext.getSocketFactory())) {
                sslSocket.setEnabledProtocols(new String[]{protocol});
                long start = System.currentTimeMillis();
                sslSocket.startHandshake();
                long elapsed = System.currentTimeMillis() - start;
                Console.info(protocol, Console.GREEN, "SUPPORTED (Handshake took " + elapsed + " ms)");
                result.protocolScanResults.add(new ProtocolScanResult(protocol, "SUPPORTED", elapsed));
            } catch (IllegalArgumentException e) {
                Console.info(protocol, Console.GRAY, "UNSUPPORTED BY CLIENT (Disabled or not present in JVM)");
                result.protocolScanResults.add(new ProtocolScanResult(protocol, "UNSUPPORTED BY CLIENT", -1));
            } catch (IOException e) {
                Console.info(protocol, Console.RED, "NO (Connection/handshake failed: " + e.getMessage() + ")");
                result.protocolScanResults.add(new ProtocolScanResult(protocol, "NO: " + e.getMessage(), -1));
            }
        }
    }

    private static void scanCipherSuites(final String host, final int port, final int timeout, final SSLContext sslContext, final TargetResult result) {
        Console.header("Supported Cipher Suites Scan");
        SSLSocketFactory sf = sslContext.getSocketFactory();
        String[] supportedCiphers = sf.getSupportedCipherSuites();

        if (supportedCiphers == null || supportedCiphers.length == 0) {
            Console.error("No supported cipher suites found in JVM.");
            return;
        }

        Console.println(Console.GRAY, "  Scanning " + supportedCiphers.length + " client ciphers against server...");
        List<String> remainingCiphers = new ArrayList<>(Arrays.asList(supportedCiphers));

        while (!remainingCiphers.isEmpty()) {
            try (SSLSocket sslSocket = createConnectedSocket(host, port, timeout, sf)) {
                sslSocket.setEnabledCipherSuites(remainingCiphers.toArray(new String[0]));
                try {
                    sslSocket.setEnabledProtocols(sslSocket.getSupportedProtocols());
                } catch (Exception e) {
                    // ignore
                }

                sslSocket.startHandshake();

                String negotiated = sslSocket.getSession().getCipherSuite();
                String negotiatedProto = sslSocket.getSession().getProtocol();

                result.serverCiphers.add(negotiated + " (" + negotiatedProto + ")");
                remainingCiphers.remove(negotiated);
            } catch (Exception e) {
                break;
            }
        }

        if (result.serverCiphers.isEmpty()) {
            Console.warning("Multi-pass negotiation scan returned no ciphers. Trying sequential scan...");
            for (String cipher : supportedCiphers) {
                try (SSLSocket sslSocket = createConnectedSocket(host, port, timeout, sf)) {
                    sslSocket.setEnabledCipherSuites(new String[]{cipher});
                    try {
                        sslSocket.setEnabledProtocols(sslSocket.getSupportedProtocols());
                    } catch (Exception e) {
                        // ignore
                    }
                    sslSocket.startHandshake();

                    String negotiatedProto = sslSocket.getSession().getProtocol();
                    result.serverCiphers.add(cipher + " (" + negotiatedProto + ")");
                } catch (Exception e) {
                    // Not supported
                }
            }
        }

        if (result.serverCiphers.isEmpty()) {
            Console.error("No cipher suites could be negotiated with the server.");
        } else {
            Console.success("Found " + result.serverCiphers.size() + " cipher suite(s) supported by server:");
            for (String c : result.serverCiphers) {
                Console.println(Console.GREEN, "    - " + c);
            }
        }
    }

    private static void runDiagnostics() {
        Console.header("JVM TLS/SSL Diagnostics");
        Console.info("Java Version", System.getProperty("java.version"));
        Console.info("Java Runtime", System.getProperty("java.runtime.name"));
        Console.info("Java Home", System.getProperty("java.home"));
        Console.info("OS Name", System.getProperty("os.name"));
        Console.info("OS Version", System.getProperty("os.version"));
        Console.info("OS Arch", System.getProperty("os.arch"));

        Console.header("System Truststore & Keystore");
        Console.info("javax.net.ssl.trustStore", System.getProperty("javax.net.ssl.trustStore", "Not defined (using default cacerts)"));
        Console.info("javax.net.ssl.trustStorePassword", System.getProperty("javax.net.ssl.trustStorePassword") != null ? "[DEFINED]" : "Not defined");
        Console.info("javax.net.ssl.trustStoreType", System.getProperty("javax.net.ssl.trustStoreType", "Not defined"));
        Console.info("javax.net.ssl.keyStore", System.getProperty("javax.net.ssl.keyStore", "Not defined"));
        Console.info("javax.net.ssl.keyStorePassword", System.getProperty("javax.net.ssl.keyStorePassword") != null ? "[DEFINED]" : "Not defined");
        Console.info("javax.net.ssl.keyStoreType", System.getProperty("javax.net.ssl.keyStoreType", "Not defined"));

        Console.header("Disabled Cryptographic Algorithms");
        Console.info("jdk.tls.disabledAlgorithms", Security.getProperty("jdk.tls.disabledAlgorithms"));
        Console.info("jdk.certpath.disabledAlgorithms", Security.getProperty("jdk.certpath.disabledAlgorithms"));

        Console.header("Security Providers");
        for (Provider provider : Security.getProviders()) {
            Console.println(Console.GRAY, "  - " + provider.getName() + " v" + getProviderVersion(provider) + ": " + provider.getInfo());
        }

        try {
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, null, null);
            SSLSocketFactory sf = context.getSocketFactory();

            Console.header("Client JVM Supported Protocols & Ciphers");
            Console.info("Default Protocols", Arrays.toString(context.getDefaultSSLParameters().getProtocols()));
            Console.info("Supported Protocols", Arrays.toString(context.getSupportedSSLParameters().getProtocols()));

            Console.println(Console.BOLD, "\n  Default Enabled Cipher Suites:");
            for (String c : sf.getDefaultCipherSuites()) {
                Console.println(Console.GRAY, "    - " + c);
            }

            Console.println(Console.BOLD, "\n  All Supported Cipher Suites:");
            for (String c : sf.getSupportedCipherSuites()) {
                Console.println(Console.GRAY, "    - " + c);
            }
        } catch (Exception e) {
            Console.error("Failed to extract SSLContext parameters: " + e.getMessage());
        }
    }

    private static void printUsage() {
        Console.println(Console.BOLD + Console.CYAN, "\n=== JTLSTester - Comprehensive TLS Diagnostic Tool ===");
        System.out.println("Usage: java -jar jtlstester.jar [options]");
        System.out.println("\nTarget Options (At least one required unless --diagnose is set):");
        System.out.println("  -e, --endpoint <host>[:port]   Add a target endpoint. Can be specified multiple times.");
        System.out.println("  -u, --url <url>                Add a target URL. Can be specified multiple times.");
        System.out.println("  -f, --file <path>              Load targets from a file (or '-' for stdin).");
        System.out.println("  --hostname <host1,host2,...>   Add targets from a comma-separated list of hostnames.");
        System.out.println("  -p, --port <p1,p2,...>         Target ports to expand for hostnames (comma-separated, default: 443).");
        System.out.println("  --workers <n>                  Concurrency worker threads count (default: 4).");
        System.out.println("\nGeneral Options:");
        System.out.println("  -h, --help                     Show this help message");
        System.out.println("  -v, --version                  Display version information");
        System.out.println("  -t, --timeout <ms>             Connection timeout in milliseconds (default: 5000)");
        System.out.println("  -i, --retries <n>              Number of connection retries (default: 3)");
        System.out.println("  -c, --cert                     Show detailed certificate chain information");
        System.out.println("  -r, --truststore <file>,<type>[,<passfile>]");
        System.out.println("                                 Reference a JKS/P12 truststore to resolve trust issues.");
        System.out.println("                                 type can be: env (load TLSTESTER_TRUSTSTORE_PASS),");
        System.out.println("                                 interactive (prompt securely), or secret/file");
        System.out.println("                                 (read from <passfile>).");
        System.out.println("  -K, --keystore <file>,<type>[,<passfile>]");
        System.out.println("                                 Reference a client PKCS12/JKS keystore for mTLS.");
        System.out.println("                                 type can be: env (load TLSTESTER_KEYSTORE_PASS),");
        System.out.println("                                 interactive (prompt securely), or secret/file");
        System.out.println("                                 (read from <passfile>).");
        System.out.println("  --sni <hostname>               Override Server Name Indication (SNI) host");
        System.out.println("  --no-sni                       Disable Server Name Indication (SNI)");
        System.out.println("  --debug-ssl                    Enable native JVM SSL handshake debug logging");
        System.out.println("  --json                         Output diagnostic results in JSON array format");
        System.out.println("  --proxy <host>:<port>          Route connections through SOCKS or HTTP proxy");
        System.out.println("  --proxy-type <type>            Type of proxy: http (default) or socks");
        System.out.println("  -l, --log <file>               Redirect all output to a log file");
        System.out.println("  -H, --header <header>          Custom HTTP header for probe (e.g. \"Authorization: Bearer token\")");
        System.out.println("  --assert-status <codes>        Assert HTTP response status (comma-separated list, e.g. 200, 301, 302)");
        System.out.println("  --csv <file>                   Export summary table to a CSV file");
        System.out.println("  --export-cert <prefix>         Export negotiated certificates to PEM files");
        System.out.println("  -s, --scan                     Perform a full cipher suite scan of the server");
        System.out.println("  -V, --verbose                  Enable verbose output (e.g. stack traces on error)");
        System.out.println("  -k, --insecure                 Ignore chain trust verification exceptions");
        System.out.println("  -d, --diagnose                 Print client JVM security parameters and providers");
        System.out.println("  --color                        Force color output (default: auto)");
        System.out.println("  --no-color                     Disable color output");
        System.out.println("\nExamples:");
        System.out.println("  java -jar jtlstester.jar -e google.com -c");
        System.out.println("  java -jar jtlstester.jar -u https://google.com/search?q=test");
        System.out.println("  java -jar jtlstester.jar --hostname host1,host2 -p 443,8443");
        System.out.println("  java -jar jtlstester.jar -f targets.txt --json");
    }

    /**
     * A pass-through decorator for {@link X509TrustManager} that intercepts and
     * caches the
     * negotiated server certificate chain.
     * 
     * Methodology:
     * During standard SSL engine operations, a certificate validation failure
     * triggers immediate
     * connection cancellation, rendering the peer certificate chain
     * inaccessible. By wrapping
     * the standard trust manager and storing the chain array inside
     * checkServerTrusted before
     * trust exceptions are thrown, JTLSTester can inspect, diagnose, and export
     * server certificates
     * even when the TLS path is completely untrusted.
     */
    private static class SavingTrustManager implements X509TrustManager {
        private final X509TrustManager defaultTm;
        private X509Certificate[] chain;
        private String authType;

        public SavingTrustManager(final X509TrustManager defaultTm) {
            this.defaultTm = defaultTm;
        }

        @Override
        public X509Certificate[] getAcceptedIssuers() {
            return defaultTm != null ? defaultTm.getAcceptedIssuers() : new X509Certificate[0];
        }

        @Override
        public void checkClientTrusted(final X509Certificate[] chain, final String authType)throws CertificateException {
        }

        @Override
        public void checkServerTrusted(final X509Certificate[] chain, final String authType)throws CertificateException {
            this.chain = chain;
            this.authType = authType;
        }

        public X509Certificate[] getChain() {
            return chain;
        }

        public String getAuthType() {
            return authType;
        }
    }

    @SuppressWarnings("deprecation")
    private static String getProviderVersion(final Provider provider) {
        try {
            return (String) Provider.class.getMethod("getVersionStr").invoke(provider);
        } catch (Exception e) {
            return Double.toString(provider.getVersion());
        }
    }

    private static final String DEFAULT_VERSION = "0.0.0-DEV";

    private static String getVersion() {
        try {
            String ver = JTLSTester.class.getPackage().getImplementationVersion();
            if (ver != null) {
                return ver;
            }
        } catch (Exception ignored) {
        }

        try (InputStream is = JTLSTester.class.getResourceAsStream("/version.txt")) {
            if (is != null) {
                try (BufferedReader br = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
                    String ver = br.readLine();
                    if (ver != null) {
                        return ver.trim();
                    }
                }
            }
        } catch (Exception ignored) {
        }

        return DEFAULT_VERSION;
    }

    private static void setAlpnProtocols(final SSLSocket sslSocket, final String[] protocols) {
        try {
            SSLParameters params = sslSocket.getSSLParameters();
            java.lang.reflect.Method setAppProtos = SSLParameters.class.getMethod("setApplicationProtocols", String[].class);
            setAppProtos.invoke(params, (Object) protocols);
            sslSocket.setSSLParameters(params);
        } catch (Exception e) {
        }
    }

    private static String getNegotiatedAlpn(final SSLSocket sslSocket) {
        try {
            java.lang.reflect.Method getAppProto = SSLSocket.class.getMethod("getApplicationProtocol");
            String proto = (String) getAppProto.invoke(sslSocket);
            if (proto != null && !proto.isEmpty()) {
                return proto;
            }
        } catch (Exception e) {
        }
        return null;
    }

    @SuppressWarnings("PMD.CloseResource")
    private static void probeHttp(final SSLSocket sslSocket, final String host, final int timeout, final TargetResult result) {
        Console.header("Application-Level HTTP Probe");
        String alpn = getNegotiatedAlpn(sslSocket);
        SSLSocket probeSocket = sslSocket;
        boolean openedNewSocket = false;

        if ("h2".equals(alpn)) {
            Console.println(Console.GRAY, "  ALPN negotiated h2. Establishing fallback HTTP/1.1 connection for HTTP probe...");
            try {
                SSLContext tempContext = SSLContext.getInstance("TLS");
                tempContext.init(null, new TrustManager[]{new SavingTrustManager(null)}, null);
                probeSocket = createConnectedSocket(host, sslSocket.getPort(), timeout, tempContext.getSocketFactory());
                setAlpnProtocols(probeSocket, new String[]{"http/1.1"});
                probeSocket.startHandshake();
                openedNewSocket = true;
            } catch (Exception e) {
                Console.error("Failed to establish fallback HTTP/1.1 connection: " + e.getMessage());
                return;
            }
        }

        try {
            probeSocket.setSoTimeout(timeout);
            try (BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(probeSocket.getOutputStream(), StandardCharsets.UTF_8));
                 BufferedReader reader = new BufferedReader(new InputStreamReader(probeSocket.getInputStream(), StandardCharsets.UTF_8))) {
                
                writer.write("GET " + result.target.httpPath + " HTTP/1.1\r\n");
                String hostHeader = host;
                if (host.contains(":") && !host.startsWith("[")) {
                    hostHeader = "[" + host + "]";
                }
                writer.write("Host: " + hostHeader + "\r\n");
                
                boolean hasUserAgent = false;
                boolean hasConnection = false;
                for (String h : customHeaders) {
                    String hLower = h.toLowerCase(Locale.US);
                    if (hLower.startsWith("user-agent:")) {
                        hasUserAgent = true;
                    }
                    if (hLower.startsWith("connection:")) {
                        hasConnection = true;
                    }
                }
                if (!hasUserAgent) {
                    writer.write("User-Agent: JTLSTester/1.1.0\r\n");
                }
                if (!hasConnection) {
                    writer.write("Connection: close\r\n");
                }
                for (String header : customHeaders) {
                    writer.write(header + "\r\n");
                }
                writer.write("\r\n");
                writer.flush();

                String statusLine = reader.readLine();
                if (statusLine != null) {
                    result.httpStatusLine = statusLine;
                    String color = (statusLine.contains("200") || statusLine.contains("301") || statusLine.contains("302")) ? Console.GREEN : Console.RESET;
                    Console.info("HTTP Response Status", color, statusLine);

                    String line;
                    boolean altSvcFound = false;
                    while ((line = reader.readLine()) != null && !line.isEmpty()) {
                        if (line.toLowerCase(Locale.US).startsWith("alt-svc:")) {
                            result.httpAltSvcLine = line.substring(8).trim();
                            Console.info("Alt-Svc (HTTP/3 support)", Console.GREEN, result.httpAltSvcLine);
                            altSvcFound = true;
                        }
                    }
                    if (!altSvcFound) {
                        Console.info("Alt-Svc (HTTP/3 support)", "No Alt-Svc header found (HTTP/3/QUIC might not be advertised)");
                    }

                    // HTTP Status Assertions
                    if (!expectedHttpStatuses.isEmpty()) {
                        String actualCode = "-";
                        String[] parts = statusLine.split(" ");
                        if (parts.length >= 2) {
                            actualCode = parts[1];
                        }
                        if (!expectedHttpStatuses.contains(actualCode)) {
                            result.error = "HTTP status assertion failed: expected " + expectedHttpStatuses + " but got " + actualCode;
                        }
                    }
                } else {
                    Console.warning("Server closed connection without returning an HTTP response.");
                    if (!expectedHttpStatuses.isEmpty()) {
                        result.error = "HTTP status assertion failed: expected " + expectedHttpStatuses + " but got no response";
                    }
                }
            }
        } catch (Exception e) {
            Console.error("HTTP probe failed: " + e.getMessage());
            if (!expectedHttpStatuses.isEmpty() && result.error == null) {
                result.error = "HTTP status assertion failed: probe connection error (" + e.getMessage() + ")";
            }
        } finally {
            if (openedNewSocket && probeSocket != null) {
                try {
                    probeSocket.close();
                } catch (Exception e) {
                }
            }
        }
    }

    private static void probeQuicUdp(final String host, final int port, final int timeout, final TargetResult result) {
        Console.header("UDP / QUIC Reachability Probe");
        long start = System.currentTimeMillis();
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.setSoTimeout(timeout);
            InetAddress address = InetAddress.getByName(host);
            socket.connect(address, port);

            byte[] mockQuicPacket = new byte[] {
                (byte) 0xc0,
                0x00, 0x00, 0x00, 0x01,
                0x08,
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x00,
                0x00,
                0x02,
                0x00, 0x00
            };

            DatagramPacket sendPacket = new DatagramPacket(mockQuicPacket, mockQuicPacket.length);
            socket.send(sendPacket);

            byte[] receiveBuf = new byte[512];
            DatagramPacket receivePacket = new DatagramPacket(receiveBuf, receiveBuf.length);
            try {
                socket.receive(receivePacket);
                long elapsed = System.currentTimeMillis() - start;
                Console.success("UDP / QUIC port is REACHABLE! Received UDP response in " + elapsed + " ms");
                result.quicReachable = true;
            } catch (SocketTimeoutException e) {
                Console.success("UDP / QUIC port is REACHABLE! (No ICMP unreachable returned, connection timed out as expected)");
                result.quicReachable = true;
            } catch (PortUnreachableException e) {
                Console.error("UDP / QUIC port is UNREACHABLE (ICMP Port Unreachable returned by server)");
                result.quicReachable = false;
            }
        } catch (Exception e) {
            Console.error("UDP / QUIC probe failed: " + e.getMessage());
            result.quicReachable = false;
        }
    }

    private static List<String> validateChainOrder(final X509Certificate[] chain) {
        List<String> issues = new ArrayList<>();
        if (chain == null || chain.length <= 1) {
            return issues;
        }
        for (int i = 1; i < chain.length; i++) {
            if (!chain[i - 1].getIssuerX500Principal().equals(chain[i].getSubjectX500Principal())) {
                issues.add("Certificate chain is out of order at index " + i + 
                           ". Certificate #" + (i - 1) + " was issued by: [" + 
                           chain[i - 1].getIssuerX500Principal().getName() + "], but Certificate #" + 
                           i + " is: [" + chain[i].getSubjectX500Principal().getName() + "]");
            }
        }
        return issues;
    }

    private static List<String> getCertWarnings(final X509Certificate cert, final int index) {
        List<String> warnings = new ArrayList<>();
        String sigAlg = cert.getSigAlgName().toUpperCase(Locale.US);
        if (sigAlg.contains("MD5") || sigAlg.contains("SHA1") || sigAlg.contains("SHA-1")) {
            warnings.add("Weak signature algorithm: " + cert.getSigAlgName());
        }

        PublicKey key = cert.getPublicKey();
        int keySize = getKeySize(key);
        String alg = key.getAlgorithm();
        if ("RSA".equalsIgnoreCase(alg)) {
            if (keySize > 0 && keySize < 2048) {
                warnings.add("RSA key size is weak: " + keySize + " bits (should be >= 2048 bits)");
            }
        } else if ("DSA".equalsIgnoreCase(alg)) {
            if (keySize > 0 && keySize < 2048) {
                warnings.add("DSA key size is weak: " + keySize + " bits (should be >= 2048 bits)");
            }
        } else if ("EC".equalsIgnoreCase(alg)) {
            if (keySize > 0 && keySize < 224) {
                warnings.add("EC key size is weak: " + keySize + " bits (should be >= 224 bits)");
            }
        }
        return warnings;
    }

    private static List<String> getTlsWarnings(final String protocol, final String cipher) {
        List<String> warnings = new ArrayList<>();
        String protoUpper = protocol.toUpperCase(Locale.US);
        if (protoUpper.contains("SSL") || "TLSV1.0".equals(protoUpper) || "TLSV1.1".equals(protoUpper)) {
            warnings.add("Protocol " + protocol + " is obsolete and insecure.");
        }

        String cipherUpper = cipher.toUpperCase(Locale.US);
        if (cipherUpper.contains("_RC4_") || cipherUpper.contains("_DES_") || cipherUpper.contains("_3DES_") ||
            cipherUpper.contains("_MD5") || cipherUpper.contains("_NULL") || cipherUpper.contains("_ANON_") ||
            cipherUpper.contains("_EXPORT_")) {
            warnings.add("Cipher suite " + cipher + " is cryptographically weak.");
        }

        if (!"TLSv1.3".equals(protocol)) {
            if (!cipherUpper.contains("ECDHE_") && !cipherUpper.contains("DHE_")) {
                warnings.add("Cipher suite " + cipher + " does not support Perfect Forward Secrecy (PFS).");
            }
        }
        return warnings;
    }

    private static String escapeJson(final String val) {
        if (val == null) {
            return "null";
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < val.length(); i++) {
            char ch = val.charAt(i);
            switch (ch) {
                case '"': sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:
                    if (ch < ' ') {
                        String hex = Integer.toHexString(ch);
                        sb.append("\\u0000".substring(0, 6 - hex.length())).append(hex);
                    } else {
                        sb.append(ch);
                    }
            }
        }
        return sb.toString();
    }

    private static void printJsonArrayAndExit(final List<TargetResult> results) {
        StringBuilder sb = new StringBuilder();
        sb.append("[\n");
        for (int rIdx = 0; rIdx < results.size(); rIdx++) {
            TargetResult r = results.get(rIdx);
            sb.append("  {\n");
            sb.append("    \"target\": {\n");
            sb.append("      \"host\": \"").append(escapeJson(r.target.host)).append("\",\n");
            sb.append("      \"port\": ").append(r.target.port).append(",\n");
            sb.append("      \"path\": \"").append(escapeJson(r.target.httpPath)).append("\"\n");
            sb.append("    },\n");
            sb.append("    \"dns\": {\n");
            sb.append("      \"resolved\": ").append(!r.resolvedIps.isEmpty()).append(",\n");
            sb.append("      \"ips\": [");
            for (int i = 0; i < r.resolvedIps.size(); i++) {
                sb.append("\"").append(escapeJson(r.resolvedIps.get(i))).append("\"");
                if (i < r.resolvedIps.size() - 1) {
                    sb.append(", ");
                }
            }
            sb.append("]\n");
            sb.append("    },\n");
            sb.append("    \"tcp\": {\n");
            sb.append("      \"connected\": ").append(r.tcpConnected).append(",\n");
            sb.append("      \"latency_ms\": ").append(r.tcpLatency).append("\n");
            sb.append("    },\n");
            sb.append("    \"tls\": {\n");
            sb.append("      \"handshake_completed\": ").append(r.tlsHandshakeSuccess).append(",\n");
            sb.append("      \"latency_ms\": ").append(r.tlsHandshakeLatency).append(",\n");
            sb.append("      \"protocol\": ").append(r.tlsProtocol == null ? "null" : "\"" + escapeJson(r.tlsProtocol) + "\"").append(",\n");
            sb.append("      \"cipher\": ").append(r.tlsCipher == null ? "null" : "\"" + escapeJson(r.tlsCipher) + "\"").append(",\n");
            sb.append("      \"alpn\": ").append(r.tlsAlpn == null ? "null" : "\"" + escapeJson(r.tlsAlpn) + "\"").append(",\n");
            sb.append("      \"ocsp_stapled\": ").append(r.ocspStapled).append(",\n");
            sb.append("      \"session_resumed\": ").append(r.sessionResumptionSuccess).append(",\n");
            sb.append("      \"resumption_latency_ms\": ").append(r.sessionResumptionLatency).append("\n");
            sb.append("    },\n");

            sb.append("    \"certificates\": [\n");
            if (r.capturedChain != null) {
                for (int i = 0; i < r.capturedChain.length; i++) {
                    X509Certificate cert = r.capturedChain[i];
                    List<String> certWarnings = getCertWarnings(cert, i);
                    sb.append("      {\n");
                    sb.append("        \"index\": ").append(i).append(",\n");
                    sb.append("        \"subject\": \"").append(escapeJson(cert.getSubjectX500Principal().getName())).append("\",\n");
                    sb.append("        \"subject_cn\": \"").append(escapeJson(extractCN(cert.getSubjectX500Principal().getName()))).append("\",\n");
                    sb.append("        \"issuer\": \"").append(escapeJson(cert.getIssuerX500Principal().getName())).append("\",\n");
                    sb.append("        \"issuer_cn\": \"").append(escapeJson(extractCN(cert.getIssuerX500Principal().getName()))).append("\",\n");
                    sb.append("        \"serial_number\": \"").append(cert.getSerialNumber().toString(16).toUpperCase(Locale.ENGLISH)).append("\",\n");
                    sb.append("        \"valid_from\": \"").append(cert.getNotBefore().toString()).append("\",\n");
                    sb.append("        \"valid_to\": \"").append(cert.getNotAfter().toString()).append("\",\n");
                    sb.append("        \"is_expired\": ").append(new Date().after(cert.getNotAfter())).append(",\n");
                    sb.append("        \"is_not_yet_active\": ").append(new Date().before(cert.getNotBefore())).append(",\n");
                    
                    PublicKey key = cert.getPublicKey();
                    int size = getKeySize(key);
                    sb.append("        \"public_key\": {\n");
                    sb.append("          \"algorithm\": \"").append(escapeJson(key.getAlgorithm())).append("\",\n");
                    sb.append("          \"size_bits\": ").append(size).append("\n");
                    sb.append("        },\n");
                    sb.append("        \"signature_algorithm\": \"").append(escapeJson(cert.getSigAlgName())).append("\",\n");
                    
                    sb.append("        \"sans\": [");
                    List<String> sans = getSubjectAlternativeNames(cert);
                    for (int j = 0; j < sans.size(); j++) {
                        sb.append("\"").append(escapeJson(sans.get(j))).append("\"");
                        if (j < sans.size() - 1) {
                            sb.append(", ");
                        }
                    }
                    sb.append("],\n");

                    sb.append("        \"warnings\": [");
                    for (int j = 0; j < certWarnings.size(); j++) {
                        sb.append("\"").append(escapeJson(certWarnings.get(j))).append("\"");
                        if (j < certWarnings.size() - 1) {
                            sb.append(", ");
                        }
                    }
                    sb.append("]\n");

                    sb.append("      }");
                    if (i < r.capturedChain.length - 1) {
                        sb.append(",");
                    }
                    sb.append("\n");
                }
            }
            sb.append("    ],\n");

            sb.append("    \"trust\": {\n");
            sb.append("      \"trusted\": ").append(r.certChainTrusted).append(",\n");
            sb.append("      \"error\": ").append(r.certChainTrustError == null ? "null" : "\"" + escapeJson(r.certChainTrustError) + "\"").append("\n");
            sb.append("    },\n");

            List<String> orderIssues = validateChainOrder(r.capturedChain);
            sb.append("    \"chain_validation\": {\n");
            sb.append("      \"chain_order_valid\": ").append(orderIssues.isEmpty()).append(",\n");
            sb.append("      \"issues\": [");
            for (int i = 0; i < orderIssues.size(); i++) {
                sb.append("\"").append(escapeJson(orderIssues.get(i))).append("\"");
                if (i < orderIssues.size() - 1) {
                    sb.append(", ");
                }
            }
            sb.append("]\n");
            sb.append("    },\n");

            sb.append("    \"http_probe\": {\n");
            sb.append("      \"status_line\": ").append(r.httpStatusLine == null ? "null" : "\"" + escapeJson(r.httpStatusLine) + "\"").append(",\n");
            sb.append("      \"alt_svc\": ").append(r.httpAltSvcLine == null ? "null" : "\"" + escapeJson(r.httpAltSvcLine) + "\"").append("\n");
            sb.append("    },\n");

            sb.append("    \"quic_probe\": {\n");
            sb.append("      \"reachable\": ").append(r.quicReachable).append("\n");
            sb.append("    },\n");

            sb.append("    \"scanned_protocols\": [\n");
            for (int i = 0; i < r.protocolScanResults.size(); i++) {
                ProtocolScanResult ps = r.protocolScanResults.get(i);
                sb.append("      {\n");
                sb.append("        \"protocol\": \"").append(escapeJson(ps.protocol)).append("\",\n");
                sb.append("        \"status\": \"").append(escapeJson(ps.status)).append("\",\n");
                sb.append("        \"latency_ms\": ").append(ps.latencyMs).append("\n");
                sb.append("      }");
                if (i < r.protocolScanResults.size() - 1) {
                    sb.append(",");
                }
                sb.append("\n");
            }
            sb.append("    ],\n");

            sb.append("    \"scanned_ciphers\": [");
            for (int i = 0; i < r.serverCiphers.size(); i++) {
                sb.append("\"").append(escapeJson(r.serverCiphers.get(i))).append("\"");
                if (i < r.serverCiphers.size() - 1) {
                    sb.append(", ");
                }
            }
            sb.append("],\n");

            List<String> globalWarnings = new ArrayList<>();
            if (r.tlsHandshakeSuccess) {
                globalWarnings.addAll(getTlsWarnings(r.tlsProtocol, r.tlsCipher));
            }
            sb.append("    \"global_warnings\": [");
            for (int i = 0; i < globalWarnings.size(); i++) {
                sb.append("\"").append(escapeJson(globalWarnings.get(i))).append("\"");
                if (i < globalWarnings.size() - 1) {
                    sb.append(", ");
                }
            }
            sb.append("],\n");

            sb.append("    \"error\": ").append(r.error == null ? "null" : "\"" + escapeJson(r.error) + "\"").append(",\n");
            sb.append("    \"suggestion\": ").append(r.suggestion == null ? "null" : "\"" + escapeJson(r.suggestion) + "\"").append("\n");
            sb.append("  }");
            if (rIdx < results.size() - 1) {
                sb.append(",");
            }
            sb.append("\n");
        }
        sb.append("]\n");

        System.out.print(sb.toString());
        
        boolean anyFailed = false;
        for (TargetResult r : results) {
            if (r.error != null || !r.tlsHandshakeSuccess) {
                anyFailed = true;
                break;
            }
        }
        System.exit(anyFailed ? 1 : 0);
    }

    private static void printSummaryTable(final List<TargetResult> results) {
        Console.header("TLS Scan Summary (" + results.size() + " target(s))");
        
        String format = "%-25s %-16s %-10s %-25s %-8s %-6s %-8s %-5s\n";
        
        System.out.printf(Console.BOLD + Console.CYAN + format + Console.RESET, 
            "TARGET", "IP", "PROTOCOL", "CIPHER", "TRUSTED", "OCSP", "HTTP", "QUIC");
        
        System.out.println("-------------------------------------------------------------------------------------------------------------------------");
        
        for (TargetResult r : results) {
            String targetStr = r.target.rawTarget;
            if (targetStr.length() > 24) {
                targetStr = targetStr.substring(0, 21) + "...";
            }
            
            String ipStr = r.resolvedIps.isEmpty() ? "-" : r.resolvedIps.get(0);
            String protoStr = r.tlsProtocol != null ? r.tlsProtocol : "-";
            String cipherStr = r.tlsCipher != null ? r.tlsCipher : "-";
            if (cipherStr.length() > 24) {
                cipherStr = cipherStr.substring(0, 21) + "...";
            }
            
            String trustedStr = "-";
            String trustColor = Console.RESET;
            if (r.tlsHandshakeSuccess) {
                if (r.certChainTrusted) {
                    trustedStr = "YES";
                    trustColor = Console.GREEN;
                } else {
                    trustedStr = "NO";
                    trustColor = Console.RED;
                }
            } else if (r.error != null) {
                cipherStr = "(Failed)";
            }
            
            String ocspStr = r.tlsHandshakeSuccess ? (r.ocspStapled ? "YES" : "NO") : "-";
            String ocspColor = r.ocspStapled ? Console.GREEN : Console.RESET;
            
            String httpStr = "-";
            if (r.httpStatusLine != null) {
                String[] parts = r.httpStatusLine.split(" ");
                if (parts.length >= 2) {
                    httpStr = parts[1];
                } else {
                    httpStr = r.httpStatusLine;
                }
            }
            String httpColor = ("200".equals(httpStr) || "301".equals(httpStr) || "302".equals(httpStr)) ? Console.GREEN : Console.RESET;
            
            String quicStr = r.quicReachable ? "YES" : "NO";
            String quicColor = r.quicReachable ? Console.GREEN : Console.RESET;
            
            if (Console.useColor) {
                System.out.printf("%-25s %-16s %-10s %-25s " + trustColor + "%-8s" + Console.RESET + " " + ocspColor + "%-6s" + Console.RESET + " " + httpColor + "%-8s" + Console.RESET + " " + quicColor + "%-5s" + Console.RESET + "\n",
                    targetStr, ipStr, protoStr, cipherStr, trustedStr, ocspStr, httpStr, quicStr);
            } else {
                System.out.printf(format,
                    targetStr, ipStr, protoStr, cipherStr, trustedStr, ocspStr, httpStr, quicStr);
            }
        }
        System.out.println();

        // Print troubleshooting suggestions if any targets failed
        boolean printedSuggestionHeader = false;
        for (TargetResult r : results) {
            if (r.suggestion != null) {
                if (!printedSuggestionHeader) {
                    Console.println(Console.BOLD + Console.YELLOW, "=== Troubleshooting Suggestions ===");
                    printedSuggestionHeader = true;
                }
                Console.println(Console.YELLOW, "  [!] " + r.target.rawTarget + ": " + r.suggestion);
            }
        }
    }

    private static void writeCsvReport(final List<TargetResult> results, final String path) {
        try (OutputStreamWriter fw = new OutputStreamWriter(new FileOutputStream(path), StandardCharsets.UTF_8)) {
            fw.write("Target,IP,Protocol,Cipher,Trusted,OCSP,HTTP,QUIC,Error,Suggestion\n");
            for (TargetResult r : results) {
                String ip = r.resolvedIps.isEmpty() ? "" : r.resolvedIps.get(0);
                String httpStr = "";
                if (r.httpStatusLine != null) {
                    String[] parts = r.httpStatusLine.split(" ");
                    httpStr = parts.length >= 2 ? parts[1] : r.httpStatusLine;
                }
                fw.write(String.format("\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",
                    escapeCsv(r.target.rawTarget),
                    escapeCsv(ip),
                    escapeCsv(r.tlsProtocol != null ? r.tlsProtocol : ""),
                    escapeCsv(r.tlsCipher != null ? r.tlsCipher : ""),
                    r.tlsHandshakeSuccess ? (r.certChainTrusted ? "YES" : "NO") : "",
                    r.tlsHandshakeSuccess ? (r.ocspStapled ? "YES" : "NO") : "",
                    escapeCsv(httpStr),
                    r.quicReachable ? "YES" : "NO",
                    escapeCsv(r.error != null ? r.error : ""),
                    escapeCsv(r.suggestion != null ? r.suggestion : "")
                ));
            }
        } catch (Exception e) {
            System.err.println("Error: Failed to write CSV file " + path + ": " + e.getMessage());
        }
    }

    private static String escapeCsv(final String val) {
        if (val == null) {
            return "";
        }
        return val.replace("\"", "\"\"");
    }

    private static String getFailureSuggestion(final TargetResult r) {
        if (r.error == null) {
            return null;
        }
        String err = r.error.toLowerCase(Locale.US);
        if (err.contains("unknownhostexception") || err.contains("failed to resolve")) {
            return "Failed to resolve hostname. Please verify the host domain name, DNS server configuration, or check if the target host is correct.";
        }
        if (err.contains("tcp connection failed") || err.contains("connectexception") || err.contains("timeout") || err.contains("timed out")) {
            if (r.tcpLatency == -1 && !r.tcpConnected) {
                return "TCP connection failed. This usually indicates a firewall rule blocking the port, security group restrictions, or that the service on the remote host is not running.";
            }
        }
        if (err.contains("trust") || r.certChainTrustError != null) {
            return "Certificate chain is untrusted. Use -r/--truststore to load a custom CA bundle or JVM cacerts file, or check if the root certificate is missing or invalid.";
        }
        if (err.contains("handshake") || err.contains("sslexception") || err.contains("alert") || err.contains("protocol")) {
            return "Handshake failed. This could indicate the server requires client certificate "
                + "authentication (mTLS) (use -K/--keystore), enforces modern protocols/ciphers "
                + "not enabled in your JVM, or blocks the connection due to Server Name "
                + "Indication (SNI). Run with -s/--scan to inspect server ciphers.";
        }
        if (err.contains("assertion failed")) {
            return "HTTP status code assertion failed. The server returned a response code that "
                + "was not expected (e.g. service is down, unauthorized, or redirected).";
        }
        return "An unexpected error occurred. Verify network routes, TLS configurations, and client certificate/key credentials.";
    }

    private static boolean isOcspStapled(final SSLSession session) {
        try {
            Class<?> extendedSessionClass = Class.forName("javax.net.ssl.ExtendedSSLSession");
            if (extendedSessionClass.isInstance(session)) {
                java.lang.reflect.Method getStatusResponsesMethod = extendedSessionClass.getMethod("getStatusResponses");
                @SuppressWarnings("unchecked")
                List<byte[]> responses = (List<byte[]>) getStatusResponsesMethod.invoke(session);
                if (responses != null && !responses.isEmpty()) {
                    for (byte[] resp : responses) {
                        if (resp != null && resp.length > 0) {
                            return true;
                        }
                    }
                }
            }
        } catch (Exception e) {
        }
        return false;
    }

    private static void exportCertificates(final X509Certificate[] chain, final String prefix) {
        if (chain == null || chain.length == 0) {
            Console.error("No certificate chain captured to export.");
            return;
        }
        Console.header("Certificate Export");
        for (int i = 0; i < chain.length; i++) {
            String filename = prefix + "_" + i + ".crt";
            try {
                byte[] certBytes = chain[i].getEncoded();
                String base64 = Base64.getMimeEncoder(64, new byte[]{'\n'}).encodeToString(certBytes);
                try (OutputStreamWriter fw = new OutputStreamWriter(new FileOutputStream(filename), StandardCharsets.UTF_8)) {
                    fw.write("-----BEGIN CERTIFICATE-----\n");
                    fw.write(base64);
                    if (!base64.endsWith("\n")) {
                        fw.write("\n");
                    }
                    fw.write("-----END CERTIFICATE-----\n");
                }
                Console.success("Exported Certificate #" + i + " to " + filename);
            } catch (Exception e) {
                Console.error("Failed to export Certificate #" + i + " to " + filename + ": " + e.getMessage());
            }
        }
    }

    private static class Console {
        private static boolean useColor = true;
        private static boolean quiet = false;
        private static ThreadLocal<String> prefix = new ThreadLocal<>();

        public static void setPrefix(final String p) {
            prefix.set(p);
        }

        public static void clearPrefix() {
            prefix.remove();
        }

        public static void setUseColor(final boolean enable) {
            useColor = enable;
        }

        public static void setQuiet(final boolean enable) {
            quiet = enable;
        }

        public static final String RESET = "\u001B[0m";
        public static final String BOLD = "\u001B[1m";
        public static final String RED = "\u001B[31m";
        public static final String GREEN = "\u001B[32m";
        public static final String YELLOW = "\u001B[33m";
        public static final String BLUE = "\u001B[34m";
        public static final String CYAN = "\u001B[36m";
        public static final String GRAY = "\u001B[90m";

        public static void print(final String color, final String text) {
            if (quiet) {
                return;
            }
            String p = prefix.get();
            String output = text;
            if (p != null) {
                if (text.startsWith("\n")) {
                    output = "\n" + p + text.substring(1);
                } else {
                    output = p + text;
                }
            }
            if (useColor) {
                System.out.print(color + output + RESET);
            } else {
                System.out.print(output);
            }
        }

        public static void println(final String color, final String text) {
            if (quiet) {
                return;
            }
            print(color, text + "\n");
        }

        public static void header(final String text) {
            if (quiet) {
                return;
            }
            println(BOLD + CYAN, "\n=== " + text + " ===");
        }

        public static void info(final String label, final String value) {
            if (quiet) {
                return;
            }
            print(BOLD, "  " + label + ": ");
            System.out.println(value);
        }

        public static void info(final String label, final String color, final String value) {
            if (quiet) {
                return;
            }
            print(BOLD, "  " + label + ": ");
            println(color, value);
        }

        public static void success(final String text) {
            if (quiet) {
                return;
            }
            println(GREEN, "  [+] " + text);
        }

        public static void warning(final String text) {
            if (quiet) {
                return;
            }
            println(YELLOW, "  [!] " + text);
        }

        public static void error(final String text) {
            if (quiet) {
                return;
            }
            println(RED, "  [-] " + text);
        }
    }
}
