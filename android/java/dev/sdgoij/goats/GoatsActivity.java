// The Java half of the client: the soft keyboard, the clipboard and the insets.
//
// A bare `NativeActivity` has no Java of its own -- the framework's class looks up
// `ANativeActivity_onCreate`, the glue calls `android_main`, and the game runs
// from there -- and every one of P2's needs is a *Java* object: an
// `InputMethodManager` for the soft keyboard, a `ClipboardManager`, and
// `WindowInsets` for the camera's cut-out and the gesture bars. None of them is
// reachable with the NDK alone (ANDROID.md section 3, D6).
//
// So this subclass is the seam, and it does two things:
//
//   * it hands the native side what JNI cannot look up for itself -- the
//     `JavaVM` and a global reference to this activity, which is also exactly
//     what `ndk-context` wants before cpal's AAudio host will open (P4)
//   * it answers three questions: show or hide the keyboard, read or write the
//     clipboard, and where the system's own edges are
//
// Typed text is *pushed*, not pulled. A soft keyboard commits whole strings
// rather than key codes, so there is nothing in raylib's queue to read --
// `getCharPressed` never sees it -- and `InputConnection` is the one interface a
// keyboard speaks through. `commitText` forwards what was committed; the two
// editing keys that are not text are forwarded as characters the scene already
// understands, `\n` to submit and `\b` to rub out.
//
// Everything here is reachable before the game has finished starting: the loop
// runs on the glue's own thread, so a question can arrive before `onCreate`
// returns. The answers are all "nothing yet" rather than an exception, and the
// native side reads them again when it needs them.

package dev.sdgoij.goats;

import android.app.NativeActivity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.Insets;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

public class GoatsActivity extends NativeActivity {
    /** The tag the client's own lines use, so one `logcat` filter shows both. */
    private static final String TAG = "goats-client";
    /** Backspace, enter and escape, as the scene's console reads them. */
    private static final String BACKSPACE = "\b";
    private static final String ENTER = "\n";
    private static final String ESCAPE = "\u001b";

    private static GoatsActivity self;

    // The library has to be loaded *by this class* before JNI will find the two
    // natives below. `NativeActivity` loads it with `System.load` from the
    // framework's own class, and the VM associates a library with the class loader
    // that asked for it -- so as far as this class is concerned the library is not
    // loaded at all, and `nativeInit` fails with "No implementation found ... is
    // the library loaded?". Loading it here first associates it with the app's
    // class loader as well, which is where the lookup happens. The two loads are
    // the same path, so the linker hands back one copy.
    static {
        System.loadLibrary("goats_android");
    }

    private InputView inputView;
    /** Whether the soft keyboard was visible at the last layout pass. */
    private boolean imeVisible;

    // ---- the native side ----------------------------------------------------

    /** Hands the native side this activity and the JVM. See `crates/goats/src/android.rs`. */
    private native void nativeInit();

    /** One committed string, or the two editing characters above. */
    private static native void nativeText(String text);

    // ---- the seam the native side calls -------------------------------------

    /**
     * Show or hide the soft keyboard. Called from the game's thread, so it hops to
     * the UI thread -- and the whole thing is a no-op before `onCreate` has built
     * the view, which is a state the game can be in.
     */
    public void setKeyboard(final boolean show) {
        runOnUiThread(() -> {
            if (inputView == null) return;
            InputMethodManager imm =
                    (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm == null) return;
            if (show) {
                inputView.requestFocus();
                imm.showSoftInput(inputView, InputMethodManager.SHOW_IMPLICIT);
            } else {
                imm.hideSoftInputFromWindow(inputView.getWindowToken(), 0);
                inputView.clearFocus();
                // The IME's composing state belongs to a console line that is gone.
                inputView.clearComposing();
                // The window still needs a focused view, or the game stops hearing
                // its own input; the decor takes it back rather than the IME's view
                // keeping it while hidden.
                getWindow().getDecorView().requestFocus();
            }
        });
    }

    /** The clipboard's text, or an empty string. `""` and having nothing to paste are one answer. */
    public String clipboardGet() {
        ClipboardManager manager =
                (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (manager == null || !manager.hasPrimaryClip()) return "";
        ClipData clip = manager.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) return "";
        CharSequence text = clip.getItemAt(0).coerceToText(this);
        return text == null ? "" : text.toString();
    }

    public void clipboardSet(String text) {
        ClipboardManager manager =
                (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (manager == null) return;
        manager.setPrimaryClip(ClipData.newPlainText("goats", text));
    }

    /**
     * One edge of the system's insets: 0 left, 1 top, 2 right and 3 bottom. The
     * camera's cut-out is a strip down one side in landscape and the gesture bar is
     * on another, so the touch controls want both rather than a guessed margin.
     *
     * The system bars are "hidden" while the game is immersive, so what comes back
     * is the cut-out and the gestures -- which is what the controls have to avoid.
     */
    @SuppressWarnings("deprecation")   // the pre-API-30 path is the point
    public int inset(int edge) {
        WindowInsets insets = getWindow().getDecorView().getRootWindowInsets();
        if (insets == null) return 0;
        int left, top, right, bottom;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars()
                            | WindowInsets.Type.displayCutout()
                            | WindowInsets.Type.systemGestures());
            left = bars.left;
            top = bars.top;
            right = bars.right;
            bottom = bars.bottom;
        } else {
            left = insets.getSystemWindowInsetLeft();
            top = insets.getSystemWindowInsetTop();
            right = insets.getSystemWindowInsetRight();
            bottom = insets.getSystemWindowInsetBottom();
        }
        switch (edge) {
            case 0: return left;
            case 1: return top;
            case 2: return right;
            default: return bottom;
        }
    }

    // ---- lifecycle ----------------------------------------------------------

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // The framework loads `libgoats_android.so` in here, from the manifest's
        // `lib_name`, so `ANativeActivity_onCreate` has run and the game's thread
        // is up. The two `native*` methods are found by name on first call; there
        // is no `JNI_OnLoad` (see the class comment).
        super.onCreate(savedInstanceState);
        inputView = new InputView(this);
        // Invisible, one pixel, in the corner: the IME needs a *focused* view to
        // type into, and this one is far too small to sit over a control or to eat
        // the game's own touches. A plain `View` is not focusable by default, and
        // `requestFocus()` on one returns false without a word -- so the two flags
        // are what let `setKeyboard(true)` hand the IME something to serve. The
        // focus is the *view's*, not the window's: raylib's keys arrive through the
        // activity's input queue, so nothing about gameplay shifts when this takes
        // it or gives it back.
        inputView.setAlpha(0f);
        inputView.setFocusable(true);
        inputView.setFocusableInTouchMode(true);
        ((ViewGroup) getWindow().getDecorView())
                .addView(inputView, new ViewGroup.LayoutParams(1, 1));
        watchIme();
        nativeInit();
        Log.i(TAG, "activity ready");
    }

    /**
     * Close the console when the keyboard goes away.
     *
     * The console and the soft keyboard are one thing (D7): the scene shows the
     * keyboard when it opens the console, so if the keyboard is dismissed the
     * console has to go with it -- otherwise it sits open with nothing to type
     * into and no way out but the back button. It is also what makes the back
     * button a *single* press: Android's own back handler hides the keyboard
     * first, and this is what turns that into a closed console.
     *
     * Nothing reports the keyboard's visibility directly, so the insets are the
     * signal -- and only a visible -> hidden *transition* counts. The keyboard is
     * hidden whenever the console is closed, so acting on "hidden" alone would
     * close a console the instant it opened.
     */
    private void watchIme() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return;
        final View decor = getWindow().getDecorView();
        decor.getViewTreeObserver().addOnGlobalLayoutListener(() -> {
            WindowInsets insets = decor.getRootWindowInsets();
            if (insets == null) return;
            boolean visible = insets.isVisible(WindowInsets.Type.ime());
            if (imeVisible && !visible) nativeText(ESCAPE);
            imeVisible = visible;
        });
    }

    @Override
    public void onBackPressed() {
        // Back belongs to the game (the menu, the console), and quits nothing: the
        // framework's default would finish the activity out from under it. It is
        // the escape key -- ESC closes the console and toggles the menu (`goat.js`,
        // `console.js`) -- which is also where the patched raylib already reports
        // the back button (`prepare-raylib-sys.py`), so the engine normally eats
        // the event before it reaches here. This is the fallback for the delivery
        // where it does not.
        nativeText(ESCAPE);
    }

    /**
     * The view the keyboard types into. A plain `View` rather than an `EditText`:
     * the text never has to live anywhere, because it is forwarded as it is
     * committed, and an `EditText` would put a caret and a selection next to the
     * console's own.
     */
    private static final class InputView extends View {
        /**
         * What the IME has composed and we have already put in the console line.
         * Kept here so it can be dropped when the keyboard goes away.
         */
        private String composing = "";

        InputView(Context context) {
            super(context);
        }

        /** Forget the IME's composing state, which the console has moved past. */
        void clearComposing() {
            composing = "";
        }

        @Override
        public boolean onCheckIsTextEditor() {
            return true;
        }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo out) {
            // `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD` is what makes the keyboard send
            // *characters*. Without it the IME composes a word -- autocorrect, in
            // whatever language the phone is set to -- and commits it only on a word
            // boundary, so the console sits empty while the player types and then
            // receives something autocorrected. A password field is the standard way
            // to ask for one character per keystroke, no suggestions, no autocorrect.
            out.inputType = EditorInfo.TYPE_CLASS_TEXT
                    | EditorInfo.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                    | EditorInfo.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                    | EditorInfo.TYPE_TEXT_FLAG_MULTI_LINE;
            // No fullscreen editor: it would cover the console the text is going
            // into. `IME_ACTION_NONE` keeps the enter key an enter key.
            out.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN | EditorInfo.IME_ACTION_NONE;
            final InputView view = this;
            return new BaseInputConnection(this, false) {
                @Override
                public boolean setComposingText(CharSequence text, int newCursorPosition) {
                    // Composing is emulated against the console's line: what the IME
                    // showed last is rubbed out and this put in its place, so the
                    // player sees the typing as it happens.
                    for (int i = 0; i < view.composing.length(); i++) nativeText(BACKSPACE);
                    view.composing = text.toString();
                    if (!view.composing.isEmpty()) nativeText(view.composing);
                    return true;
                }

                @Override
                public boolean finishComposingText() {
                    view.composing = "";
                    return true;
                }

                @Override
                public boolean commitText(CharSequence text, int newCursorPosition) {
                    // The commit replaces the composing text, if there was any.
                    for (int i = 0; i < view.composing.length(); i++) nativeText(BACKSPACE);
                    view.composing = "";
                    nativeText(text.toString());
                    return true;
                }

                @Override
                public boolean deleteSurroundingText(int before, int after) {
                    // Backspace: the composing text goes first, or the console's
                    // line and the IME's idea of it drift apart.
                    for (int i = 0; i < before; i++) {
                        if (!view.composing.isEmpty()) {
                            view.composing =
                                    view.composing.substring(0, view.composing.length() - 1);
                        }
                        nativeText(BACKSPACE);
                    }
                    return true;
                }

                @Override
                public boolean sendKeyEvent(KeyEvent event) {
                    if (event.getAction() != KeyEvent.ACTION_DOWN) return true;
                    if (event.getKeyCode() == KeyEvent.KEYCODE_DEL) {
                        nativeText(BACKSPACE);
                        return true;
                    }
                    if (event.getKeyCode() == KeyEvent.KEYCODE_ENTER) {
                        nativeText(ENTER);
                        return true;
                    }
                    return false;
                }
            };
        }
    }
}
