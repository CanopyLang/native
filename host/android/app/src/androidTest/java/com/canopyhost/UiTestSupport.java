package com.canopyhost;

import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.BySelector;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.Until;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * AND-11 — shared UIAutomator scaffolding for the Canopy fixture suite.
 *
 * <p>The host maps every Canopy {@code A.testID} to the View's content-description
 * (see CanopyHost.java §"test identity"), so the whole cross-driver selector contract is
 * {@code By.desc(testID)}. These helpers wrap device acquisition, the deterministic-bundle
 * push, app launch, the standard wait, and screenshot/hierarchy capture for failure triage.
 *
 * <p>Determinism: the app-under-test is the DEBUG variant, whose readBundle() prefers a
 * dev-pushed bundle at {@code /data/local/tmp/canopy.bundle.js} over the baked asset
 * (the hot-reload path). Before launching we push the committed fixture bundle from the
 * test APK's own assets to that location, so the app boots the 4-screen fixture regardless
 * of whatever main bundle the checkout happens to carry.
 */
final class UiTestSupport {

    static final String PKG = "org.canopy.echo";
    static final String ACTIVITY = "com.canopyhost.MainActivity";
    static final long LAUNCH_TIMEOUT_MS = 15_000L;
    static final long FIND_TIMEOUT_MS = 15_000L;

    private static final String TAG = "CanopyUiTest";
    private static final String DEV_BUNDLE = "/data/local/tmp/canopy.bundle.js";

    /** The fixture bundle must be in place BEFORE the app's one-and-only boot; push it once. */
    private static volatile boolean sBundleInstalled = false;

    private UiTestSupport() {}

    static UiDevice device() {
        return UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
    }

    /** Push the committed fixture bundle (from the test APK assets) to the dev-bundle path the
     *  DEBUG app reads first, so the launched app boots a deterministic 4-screen fixture.
     *
     *  <p>The app/instrumentation uid cannot write {@code /data/local/tmp} (it is shell-owned), so we
     *  drive the write through {@link android.app.UiAutomation} which runs as the shell uid. Two
     *  pitfalls forced the design here:
     *  <ul>
     *    <li>{@code executeShellCommand} tokenizes naively and does NOT honour shell redirection
     *        ({@code >}, {@code >>}) reliably — earlier attempts to {@code printf … >> file} silently
     *        produced no file, so the app fell back to the baked bundle and booted the wrong app.</li>
     *    <li>The bundle is ~280KB, past a single command line's ARG_MAX, so it cannot be an argument.</li>
     *  </ul>
     *  So we stream the RAW bytes through {@code executeShellCommandRwe}'s stdin into
     *  {@code dd of=<path>} — the path is a plain argument (no redirect), and stdin carries the bytes.
     *  Then a separate {@code chmod 666} (two space-separated args, tokenizes fine) makes it readable
     *  by the app uid. Verified by the on-device read in readBundle()'s "hot-reload" log line. */
    static void installFixtureBundle() throws Exception {
        if (sBundleInstalled) return;  // boot is once-per-process; one push before it suffices
        Context testCtx = InstrumentationRegistry.getInstrumentation().getContext();
        byte[] bytes;
        try (InputStream in = testCtx.getAssets().open("canopy.bundle.js")) {
            bytes = readAll(in);
        }

        android.app.UiAutomation ua = InstrumentationRegistry.getInstrumentation().getUiAutomation();
        // [0]=stdout, [1]=stdin, [2]=stderr. dd reads the bundle bytes from stdin and writes them to
        // the of= path with no shell redirection involved.
        ParcelFileDescriptor[] fds = ua.executeShellCommandRwe("dd of=" + DEV_BUNDLE);
        ParcelFileDescriptor stdout = fds[0], stdin = fds[1], stderr = fds[2];
        try (OutputStream os = new ParcelFileDescriptor.AutoCloseOutputStream(stdin)) {
            os.write(bytes);
        }
        // Drain + close stdout/stderr so dd finishes and the fds are released.
        try (InputStream o = new ParcelFileDescriptor.AutoCloseInputStream(stdout)) { readAll(o); }
        try (InputStream er = new ParcelFileDescriptor.AutoCloseInputStream(stderr)) { readAll(er); }

        // Make the freshly-written file readable by the (different) app uid.
        shell("chmod 666 " + DEV_BUNDLE);

        sBundleInstalled = true;
        Log.i(TAG, "fixture bundle installed at " + DEV_BUNDLE + " (" + bytes.length + " bytes)");
    }

    /** Run a simple (no-redirect) shell command as the shell uid via UiAutomation and drain output. */
    private static void shell(String cmd) throws Exception {
        ParcelFileDescriptor pfd = InstrumentationRegistry.getInstrumentation()
                .getUiAutomation().executeShellCommand(cmd);
        try (FileInputStream fis = new FileInputStream(pfd.getFileDescriptor())) {
            readAll(fis);
        }
    }

    /** Ensure the app-under-test is running and showing the fixture, then return the device.
     *
     *  <p>IMPORTANT constraints under AndroidX instrumentation:
     *  <ul>
     *    <li>The test process IS the target app process ({@code org.canopy.echo}), so we must NOT
     *        {@code am force-stop} it — that kills the test runner itself (signal 9).</li>
     *    <li>{@code CanopyHostJni.boot()} creates a fresh Hermes runtime each call and is NOT safe to
     *        re-invoke, so we must NOT recreate the Activity between tests (no CLEAR_TASK). The app is
     *        booted ONCE — on the first test, after the fixture bundle has been pushed — and stays up;
     *        later tests reuse the running instance and just navigate via the tab bar.</li>
     *  </ul>
     *  We launch with SINGLE_TOP (reuse the existing instance if present, no re-create) so the single
     *  boot reads the pushed {@code /data/local/tmp} fixture bundle via readBundle()'s hot-reload path. */
    static UiDevice launchApp() throws Exception {
        UiDevice device = device();
        Instrumentation instr = InstrumentationRegistry.getInstrumentation();
        Context ctx = instr.getContext();
        Intent intent = new Intent();
        intent.setClassName(PKG, ACTIVITY);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        ctx.startActivity(intent);
        device.wait(Until.hasObject(By.pkg(PKG).depth(0)), LAUNCH_TIMEOUT_MS);
        // Wait for the fixture's first screen to actually render before handing control to the test.
        device.wait(Until.hasObject(By.desc("tab-form")), LAUNCH_TIMEOUT_MS);
        return device;
    }

    static BySelector byDesc(String testID) {
        return By.desc(testID);
    }

    /** Tap a tab in the fixture's tab bar (tab-form/tab-list/tab-feed/tab-modal) and return the device.
     *  Tests are order-independent: each one navigates to its own tab first, since the app instance is
     *  shared across the whole class (a single boot — see {@link #launchApp()}). */
    static void goToTab(UiDevice device, String tabTestID) {
        UiObject2 tab = waitForDesc(device, tabTestID);
        if (tab != null) {
            tab.click();
            device.waitForIdle();
        }
    }

    /** Wait for the node with the given testID (content-description) to exist, returning it or null. */
    static UiObject2 waitForDesc(UiDevice device, String testID, long timeoutMs) {
        return device.wait(Until.findObject(byDesc(testID)), timeoutMs);
    }

    static UiObject2 waitForDesc(UiDevice device, String testID) {
        return waitForDesc(device, testID, FIND_TIMEOUT_MS);
    }

    /** Capture a PNG screenshot under the app's external files dir (pulled by CI artifact upload). */
    static void screenshot(String name) {
        try {
            Context ctx = InstrumentationRegistry.getInstrumentation().getTargetContext();
            java.io.File dir = ctx.getExternalFilesDir("ui-test-screens");
            if (dir != null) {
                java.io.File f = new java.io.File(dir, name + ".png");
                device().takeScreenshot(f);
                Log.i(TAG, "screenshot -> " + f.getAbsolutePath());
            }
        } catch (Throwable t) {
            Log.w(TAG, "screenshot failed: " + t);
        }
    }

    /** Dump the current window hierarchy to logcat for failure triage. */
    static void dumpWindowHierarchy(String why) {
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            device().dumpWindowHierarchy(bos);
            Log.i(TAG, "window hierarchy (" + why + "):\n" + bos.toString("UTF-8"));
        } catch (Throwable t) {
            Log.w(TAG, "dumpWindowHierarchy failed: " + t);
        }
    }

    // ---- internals -----------------------------------------------------------

    private static byte[] readAll(InputStream in) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) bos.write(buf, 0, n);
        return bos.toByteArray();
    }
}
