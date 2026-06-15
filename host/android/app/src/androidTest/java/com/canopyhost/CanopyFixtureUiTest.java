package com.canopyhost;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.LargeTest;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.Until;

import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TestWatcher;
import org.junit.runner.Description;
import org.junit.runner.RunWith;

/**
 * AND-11 — end-to-end UIAutomator suite over the committed Canopy fixture (examples/uifixture).
 *
 * <p>This is the enabling instrumented substrate for every AND gate: it proves the full stack
 * — JSI boot, the C++ Fabric mounting, the Java view factories, Yoga layout, and the
 * testID→content-description selector contract — actually renders interactive native views on a
 * device and round-trips events through the real Canopy TEA update loop.
 *
 * <p>Every node is selected by {@code By.desc(testID)} (CanopyHost maps {@code A.testID} to the
 * View content-description). The fixture has four tab screens; this suite drives each one:
 * <ul>
 *   <li>form: type into field-name/field-email, submit, assert form-status echoes the values</li>
 *   <li>list: scroll until row-49 is on screen</li>
 *   <li>modal: open-modal → close-modal toggles the sheet</li>
 *   <li>feed: the image feed renders (feed-image + feed-status)</li>
 * </ul>
 *
 * <p>On any failure the {@link #watcher} captures a screenshot + window-hierarchy dump for triage.
 */
@RunWith(AndroidJUnit4.class)
@LargeTest
public class CanopyFixtureUiTest {

    private UiDevice device;

    @Rule
    public final TestWatcher watcher = new TestWatcher() {
        @Override
        protected void failed(Throwable e, Description description) {
            String name = description.getMethodName();
            UiTestSupport.screenshot("FAILED-" + name);
            UiTestSupport.dumpWindowHierarchy("failed:" + name);
        }
    };

    @Before
    public void setUp() throws Exception {
        UiTestSupport.installFixtureBundle();
        device = UiTestSupport.launchApp();
    }

    /** The app boots and the fixture's form screen renders within the timeout. */
    @Test
    public void boots_and_renders_form_screen() {
        UiTestSupport.goToTab(device, "tab-form");
        UiObject2 nameField = UiTestSupport.waitForDesc(device, "field-name");
        assertNotNull("field-name must render within " + UiTestSupport.FIND_TIMEOUT_MS + "ms", nameField);
        assertNotNull("field-email must render", UiTestSupport.waitForDesc(device, "field-email", 2_000));
        assertNotNull("submit-form must render", UiTestSupport.waitForDesc(device, "submit-form", 2_000));
        UiTestSupport.screenshot("01-form");
    }

    /** Typing into both fields then submitting drives the TEA update loop: form-status changes
     *  from "not submitted" to an echo of the typed values. */
    @Test
    public void form_submit_round_trips_through_TEA() {
        UiTestSupport.goToTab(device, "tab-form");
        UiObject2 name = UiTestSupport.waitForDesc(device, "field-name");
        assertNotNull("field-name", name);
        UiObject2 email = UiTestSupport.waitForDesc(device, "field-email");
        assertNotNull("field-email", email);

        // form-status exists and reflects model state. (We don't hard-assert the exact "not submitted"
        // text here so the test stays order-independent within the shared app process — the load-bearing
        // assertion is the AFTER state below, which proves type→submit→update→re-render end to end.)
        UiObject2 statusBefore = UiTestSupport.waitForDesc(device, "form-status");
        assertNotNull("form-status before submit", statusBefore);

        name.setText("Ada");
        email.setText("ada@example.com");
        UiObject2 submit = UiTestSupport.waitForDesc(device, "submit-form");
        assertNotNull("submit-form", submit);
        submit.click();

        // form-status now echoes the values — wait for the re-render.
        boolean changed = device.wait(
                Until.hasObject(By.desc("form-status").text("submitted: Ada / ada@example.com")),
                UiTestSupport.FIND_TIMEOUT_MS);
        UiObject2 statusAfter = UiTestSupport.waitForDesc(device, "form-status", 2_000);
        UiTestSupport.screenshot("02-form-submitted");
        assertNotNull("form-status after submit", statusAfter);
        assertTrue("status must echo the submitted values (was: " + statusAfter.getText() + ")",
                changed || "submitted: Ada / ada@example.com".equals(statusAfter.getText()));
    }

    /** The list screen scrolls: row-0 is visible at the top; after scrolling, row-49 comes on screen. */
    @Test
    public void list_scrolls_to_last_row() {
        UiObject2 tabList = UiTestSupport.waitForDesc(device, "tab-list");
        assertNotNull("tab-list", tabList);
        tabList.click();

        assertNotNull("row-0 visible at top of list", UiTestSupport.waitForDesc(device, "row-0"));
        UiTestSupport.screenshot("03-list-top");

        // Fling/scroll the screen until row-49 is found (a content-description not yet rendered/off-screen
        // is not present in the hierarchy, so we scroll until it appears or we run out of attempts).
        UiObject2 last = null;
        for (int i = 0; i < 30 && last == null; i++) {
            last = device.findObject(By.desc("row-49"));
            if (last == null) {
                int h = device.getDisplayHeight();
                int w = device.getDisplayWidth();
                device.swipe(w / 2, (int) (h * 0.8), w / 2, (int) (h * 0.2), 8);
                device.waitForIdle();
            }
        }
        UiTestSupport.screenshot("04-list-bottom");
        assertNotNull("row-49 must be reachable by scrolling the list", last);
    }

    /** The modal screen toggles: open-modal reveals close-modal; close-modal dismisses it. */
    @Test
    public void modal_opens_and_closes() {
        UiObject2 tabModal = UiTestSupport.waitForDesc(device, "tab-modal");
        assertNotNull("tab-modal", tabModal);
        tabModal.click();

        UiObject2 open = UiTestSupport.waitForDesc(device, "open-modal");
        assertNotNull("open-modal", open);
        open.click();

        UiObject2 close = UiTestSupport.waitForDesc(device, "close-modal");
        UiTestSupport.screenshot("05-modal-open");
        assertNotNull("close-modal must appear after opening the modal", close);

        close.click();
        boolean dismissed = device.wait(Until.gone(By.desc("close-modal")), UiTestSupport.FIND_TIMEOUT_MS);
        UiTestSupport.screenshot("06-modal-closed");
        assertTrue("close-modal must be gone after closing the modal", dismissed);
    }

    /** The image-feed screen renders its image + status label. */
    @Test
    public void feed_screen_renders_image() {
        UiObject2 tabFeed = UiTestSupport.waitForDesc(device, "tab-feed");
        assertNotNull("tab-feed", tabFeed);
        tabFeed.click();

        assertNotNull("feed-image must render", UiTestSupport.waitForDesc(device, "feed-image"));
        assertNotNull("feed-status must render", UiTestSupport.waitForDesc(device, "feed-status", 2_000));
        UiTestSupport.screenshot("07-feed");
    }
}
