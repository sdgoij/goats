# The console (M24): `console.js` transcribed, and the UI's keystone.
#
# An *overlay*, not a menu. `console.js`'s header is emphatic about it: a menu is a
# `uiScreen` value, which freezes the world by forcing the frame's `dt` to 0, while the
# console must not, because it has to stay usable while the game keeps running -- and,
# once multiplayer lands, one player opening their console must not pause everyone else.
# So this is a `Control` that draws a panel over the top half of the screen and never
# touches the world; `main.gd` is what keeps the keyboard out of the goat while it is up.
#
# The shell is four things and one protocol:
#
#   * a **ring** of at most `MAX_LINES` scrollback entries, each `{ text, kind }`, where a
#     pushed reply is split on `\n` into one entry per row (the `help` page is the reason);
#   * a **line** with a caret, a 512-character cap, a 32-entry history that refuses two
#     identical lines in a row, and the editing keys (`consoleHandleInput`'s table);
#   * a **wrap** that keeps a word whole, keeps the leading indentation on every row, and
#     splits a single long token by shrinking the cut;
#   * the **panel**, drawn at `drawConsole`'s own geometry and colours;
#   * and the **reply protocol**: submit echoes `"> " + text`, dispatches through the same
#     `sceneCommand` the host's stdin channel drives, and prints what comes back -- an
#     empty reply prints *nothing*, which is what lets chat queue silently.
#
#     A `void` reply is `ok` in the scene's protocol, because the scene's `undefined` is
#     this language's `null`; every verb in `commands.gd` returns a `String` instead, so
#     that mapping is a guard rather than a path.
#
# What is deliberately *not* transcribed, because there is nothing here for it to do:
# the raylib character queue. The scene reads `rl.getCharPressed()` until it drains and
# clears the backlog on open, because raylib queues a character for every printable key
# whether or not anyone reads it, so the `wasd` typed while playing would land in the
# line. Godot delivers a key as an `InputEventKey` that `main.gd` forwards only while the
# console is open, so there is no backlog to clear. The Android soft-keyboard paths
# (`consoleTouchText`, `consoleTouchClipboard`) are the same kind of absence: there is no
# `android` global in a Godot build, and no phone target is built yet.
#
# The wrap's width is the scene's *estimate* -- `length * size * 0.55`, which is
# `consoleTextWidth`'s fallback for an engine without `measureTextEx` -- rather than
# Godot's real font metrics. That is on purpose: it is the one form of the rule a headless
# gate can hold against the JavaScript's, because raylib's default font and Godot's are
# not the same font. Godot's metrics are close (and the panel is half the screen wide), so
# the drawn result is the scene's; the *rule* is the scene's too, and it is checkable.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Console
extends Control

## `console.js`'s own numbers, named as it names them. `CONSOLE_KEY` (`KEY_GRAVE`, the
## backquote) is `main.gd`'s, because it is the key that *opens* this and this only ever
## sees keys once it is open.
const MAX_LINES := 200
const HISTORY := 32
const MAX_INPUT := 512

## `CONSOLE_COLORS`, display-space bytes exactly as the scene's `rl.color` calls give them.
## The panel is `rl.color(8, 10, 14, 215)`.
const PANEL := Color(8.0 / 255.0, 10.0 / 255.0, 14.0 / 255.0, 215.0 / 255.0)
const COLOR_ECHO := Color(148.0 / 255.0, 150.0 / 255.0, 158.0 / 255.0)
const COLOR_LOCAL := Color(184.0 / 255.0, 220.0 / 255.0, 184.0 / 255.0)
const COLOR_NET := Color(150.0 / 255.0, 200.0 / 255.0, 255.0 / 255.0)
const COLOR_SYSTEM := Color(216.0 / 255.0, 190.0 / 255.0, 140.0 / 255.0)
const COLOR_INPUT := Color(236.0 / 255.0, 236.0 / 255.0, 236.0 / 255.0)

## `drawConsole`'s own geometry: the row height (which is also the font size, because
## `rl.drawText` takes the size it draws at) and the panel's padding.
const LINE_HEIGHT := 18
const PAD := 10.0

## Whether the console is up. `consoleOpen`.
var open := false
## The line being typed, and where the caret is in it. `consoleInput`, `consoleCaret`.
var input_text := ""
var caret := 0
## The scrollback: one `{ text, kind }` per row, oldest first. `consoleLines`.
var lines: Array[Dictionary] = []
## Submitted lines, oldest first, and the cursor into them for Up/Down. `consoleHistory`,
## `consoleHistoryAt`. The cursor at `history.size()` means "the line being typed".
var history: Array[String] = []
var history_at := 0
## Whether the welcome line has been shown. `consoleSeen`.
var seen := false
## The pending question, or empty: `{ question, action }`. The next submitted line is its
## answer and goes to `action` instead of being dispatched. `consolePrompt`.
var prompt := {}

## What a submitted line is dispatched through: `Commands.run`, handed in by `main.gd`.
## A `Callable` rather than a reference for the reason the goat's `bite` is one -- this
## file does not link against the command vocabulary.
var dispatch: Callable = Callable()

func _ready() -> void:
	# Anchors *and* offsets -- see the note in `hud.gd`: `set_anchors_preset` alone leaves
	# the offsets where they were, so a `Control` under a `CanvasLayer` keeps a size of
	# nothing and every corner computed from `size` lands off-screen.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The console touches nothing: the camera's drag has to reach `main.gd`, and this
	# panel is only ever *looked* at.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

## The scene's console is *immediate mode*: `drawConsole` runs every frame the panel is up, and
## there is no stored scene graph to invalidate. Godot's `Control` is retained, so a `_draw`
## only runs when something dirties it -- and the one `queue_redraw` `toggle` makes happens in
## `_ready`, before the control can be drawn, so it is cleared and the panel never paints at
## all. Pumping the redraw while open is what makes the port's panel behave like the scene's:
## it is up, so it is drawn.
func _process(_delta: float) -> void:
	if open:
		queue_redraw()

## Append a line, dropping the oldest once the ring is full. A reply may carry newlines
## (the `help` page does), so it is split into one entry per row. `consolePush`.
func push(text: Variant, kind: String = "local") -> void:
	for part in String(text).split("\n"):
		lines.append({"text": part, "kind": kind})
	while lines.size() > MAX_LINES:
		lines.pop_front()
	queue_redraw()

## A line from the session: chat, joins, errors. `consoleNet`.
func net_line(text: String) -> void:
	push(text, "net")

## A line the scene itself is reporting. `consoleSystem`.
func system_line(text: String) -> void:
	push(text, "system")

## Close the console. A pending question is abandoned with it, which is `consoleClose`'s
## own rule: the player runs the command again if they still want it.
func close() -> void:
	open = false
	prompt = {}
	visible = false
	queue_redraw()

## Put `text` at the caret, as far as the line's limit. One place, because the keyboard's
## characters, a paste and a committed IME string all land here. `consoleInsert`.
func insert(text: String) -> void:
	var room: int = MAX_INPUT - input_text.length()
	if room <= 0:
		return
	var chunk: String = text.substr(0, room)
	input_text = input_text.substr(0, caret) + chunk + input_text.substr(caret)
	caret += chunk.length()
	queue_redraw()

## Rub out the character behind the caret. `consoleBackspace`.
func backspace() -> void:
	if caret <= 0:
		return
	input_text = input_text.substr(0, caret - 1) + input_text.substr(caret)
	caret -= 1
	queue_redraw()

## Toggle the console. On the way up the history cursor moves to the end and the caret to
## the end of the line, and the first open ever says so -- `consoleToggle`, minus the
## engine's stale character queue, which Godot has no equivalent of (see the header).
##
## `visible` is kept in step so the redraw `_process` pumps while open is the only one that
## runs; a `Control` draws only when a `queue_redraw` reaches it while it can be drawn.
func toggle() -> void:
	open = not open
	if not open:
		visible = false
		queue_redraw()
		return
	history_at = history.size()
	caret = input_text.length()
	if not seen:
		seen = true
		system_line("console ready - backquote or ESC closes, enter runs a command")
	visible = true
	queue_redraw()

## Ask a question in the console. The next submitted line becomes the answer and goes to
## `action`, whose reply is printed like any other command's. This is the username prompt,
## so it opens the console to be typed into. `consoleAsk`.
func ask(question: String, action: Callable) -> void:
	prompt = {"question": question, "action": action}
	if not open:
		toggle()
	input_text = ""
	caret = 0
	push(question, "system")
	queue_redraw()

## Run one submitted line: echo it, dispatch it, echo the reply. `consoleSubmit`.
##
## The scene catches a throw here and prints `error …`; this language has no exceptions, so
## a verb that fails must *answer* with an `error …` string itself (which is what
## `commands.gd` does) rather than throwing. The `null`-means-`ok` mapping stays because the
## scene's protocol has it, and because a `void` prompt action is a legal reply.
func submit(line: String, run: Callable) -> void:
	var text: String = line.strip_edges()
	if text.is_empty():
		return
	if history.is_empty() or history[history.size() - 1] != text:
		history.append(text)
		if history.size() > HISTORY:
			history.pop_front()
	history_at = history.size()
	push("> " + text, "echo")

	# A pending question consumes the line instead of dispatching it.
	var action: Variant = prompt.get("action", null)
	prompt = {}
	var reply: Variant = null
	if action is Callable and (action as Callable).is_valid():
		reply = (action as Callable).call(text)
	elif run.is_valid():
		reply = run.call(text)
	var message: String = "ok" if reply == null else String(reply)
	# An empty reply means "nothing to report" -- chat queues silently rather than printing
	# an `ok` after every line.
	if message != "":
		push(message, "local")
	input_text = ""
	caret = 0
	queue_redraw()

## Pasted text arrives as one line of printable characters: a ticket copied from a terminal
## comes with a newline, and a text field has no room for either. `consoleSanitizePaste`.
static func sanitize_paste(text: String) -> String:
	var out: String = ""
	for i in text.length():
		var code: int = text.unicode_at(i)
		if code < 32 or code == 127:
			continue
		out += text.substr(i, 1)
	return out.strip_edges()

## Ctrl+V: insert the clipboard at the caret. `consolePaste`, without the Android branch
## (there is no `android` global here).
func paste() -> void:
	insert(sanitize_paste(DisplayServer.clipboard_get()))

## Ctrl+C, or the `copy` verb: put text on the clipboard. Returns false when it did not
## reach it, so a command can report that. `consoleCopy`.
func copy(text: String) -> bool:
	DisplayServer.clipboard_set(text)
	system_line("copied %d characters" % text.length())
	return true

## One key event while the console owns the keyboard. Returns true when it consumed the
## press, which is what keeps Escape from also reaching the menu. `consoleHandleInput`,
## event-shaped: Godot hands the whole `InputEventKey` in rather than a poll per key.
##
## The printable-character arm is the fallback, not a match: a key with a `unicode` in
## `32..126` and no editing meaning is text. `Enter` is `KEY_ENTER` and the keypad's own;
## both carry a `unicode` of 13, which is why they cannot be left to the fallback.
func handle_key(event: InputEventKey) -> bool:
	if not open:
		return false
	if not event.pressed or event.echo:
		# A release or a key repeat is not an edit; only the press is.
		return true
	var code: int = event.physical_keycode
	if code == KEY_ESCAPE:
		close()
		return true
	if event.ctrl_pressed and code == KEY_V:
		paste()
		return true
	if event.ctrl_pressed and code == KEY_C:
		if input_text.length() > 0:
			copy(input_text)
		return true
	match code:
		KEY_BACKSPACE:
			backspace()
		KEY_DELETE:
			if caret < input_text.length():
				input_text = input_text.substr(0, caret) + input_text.substr(caret + 1)
				queue_redraw()
		KEY_LEFT:
			if caret > 0:
				caret -= 1
				queue_redraw()
		KEY_RIGHT:
			if caret < input_text.length():
				caret += 1
				queue_redraw()
		KEY_UP:
			if history.size() > 0:
				if history_at > 0:
					history_at -= 1
				input_text = history[history_at]
				caret = input_text.length()
				queue_redraw()
		KEY_DOWN:
			if history_at < history.size():
				history_at += 1
				input_text = history[history_at] if history_at < history.size() else ""
				caret = input_text.length()
				queue_redraw()
		KEY_ENTER, KEY_KP_ENTER:
			submit(input_text, dispatch)
		_:
			var character: int = event.unicode
			if character >= 32 and character < 127:
				insert(char(character))
	return true

## The width of a console row in pixels. `consoleTextWidth`'s fallback -- see the header on
## why the estimate and not Godot's own metrics: it is the form of the rule the JavaScript
## can also be held to.
static func text_width(text: String, size: int) -> float:
	return float(text.length()) * float(size) * 0.55

## The leading whitespace of a line. `consoleWrap`'s `/^\s*/`, as a loop: a console line has
## had its newlines split off already (`push`), so spaces and tabs are the whole of it.
static func indent_of(text: String) -> String:
	var i: int = 0
	while i < text.length():
		var c: String = text.substr(i, 1)
		if c != " " and c != "\t":
			break
		i += 1
	return text.substr(0, i)

## Break one line into rows that fit `max_width`. Words stay whole; a single long token (a
## URL, a JSON blob) is split rather than run off the panel. The leading indentation is kept
## on every row, so columns stay lined up after a wrap. `consoleWrap`.
##
## It is `wrap_rows` and not `wrap`, which is what the scene calls it: `wrap` is a *global*
## function in this language (`wrap(value, min, max)`), and an unqualified call to a
## same-named method in this class binds to the global instead -- a `SCRIPT ERROR` on the
## first argument's type, every frame, with nothing drawn. The gate's calls were qualified
## (`Console.wrap`), which is exactly why they passed while the panel was blank.
static func wrap_rows(text: String, max_width: float, size: int) -> PackedStringArray:
	var rows := PackedStringArray()
	if text_width(text, size) <= max_width:
		rows.append(text)
		return rows
	var indent: String = indent_of(text)
	var words: PackedStringArray = text.substr(indent.length()).split(" ")
	var row: String = ""
	for word in words:
		var candidate: String = word if row == "" else row + " " + word
		if text_width(indent + candidate, size) <= max_width:
			row = candidate
			continue
		if row != "":
			rows.append(row)
		var rest: String = word
		while text_width(indent + rest, size) > max_width and rest.length() > 1:
			var cut: int = rest.length() - 1
			while cut > 1 and text_width(indent + rest.substr(0, cut), size) > max_width:
				cut -= 1
			rows.append(rest.substr(0, cut))
			rest = rest.substr(cut)
		row = rest
	if row != "":
		rows.append(row)
	for i in rows.size():
		rows[i] = indent + rows[i]
	return rows

## The colour a row's kind is drawn in. `CONSOLE_COLORS[kind] || CONSOLE_COLORS.input`.
static func kind_color(kind: String) -> Color:
	match kind:
		"echo":
			return COLOR_ECHO
		"local":
			return COLOR_LOCAL
		"net":
			return COLOR_NET
		"system":
			return COLOR_SYSTEM
		_:
			return COLOR_INPUT

## `drawConsole`'s panel geometry, as one function so a gate can hold the arithmetic without
## a screen: the rows that fit, the width they wrap to, and the panel's height.
##
## `maxRows` is `max(3, floor((sh * 0.5 - pad * 2 - lineH) / lineH))` -- half the screen,
## less the padding and one row for the input line -- and `maxWidth` is the screen less the
## padding at both edges, floored at 80.
static func layout(screen: Vector2, line_count: int) -> Dictionary:
	var line_h: float = float(LINE_HEIGHT)
	var max_rows: int = maxi(3, int(floor((screen.y * 0.5 - PAD * 2.0 - line_h) / line_h)))
	var max_width: float = maxf(80.0, screen.x - PAD * 2.0)
	var count: int = mini(line_count, max_rows)
	var first: int = line_count - count
	var panel_h: float = minf(screen.y, PAD * 2.0 + float(count + 1) * line_h)
	return {
		"maxRows": max_rows, "maxWidth": max_width, "count": count,
		"first": first, "panelH": panel_h,
	}

func _draw() -> void:
	var font: Font = get_theme_default_font()
	# The scene's own `rl.getScreenWidth()`/`getScreenHeight()`: the viewport rather than this
	# control, because the console is an overlay and its panel is the screen's.
	var screen: Vector2 = get_viewport_rect().size
	# Wrap to display rows first, so a long reply or chat line never runs off, then keep the
	# last `maxRows` of them. `layout` answers the width and the row count from the same
	# arithmetic, so the wrap and the panel cannot disagree about how wide the panel is.
	var box: Dictionary = layout(screen, lines.size())
	var max_width: float = float(box["maxWidth"])
	var rows: Array[Dictionary] = []
	for entry in lines:
		for wrapped in wrap_rows(String(entry["text"]), max_width, LINE_HEIGHT):
			rows.append({"text": wrapped, "kind": String(entry["kind"])})
	box = layout(screen, rows.size())
	var count: int = int(box["count"])
	var first: int = int(box["first"])
	var panel_h: float = float(box["panelH"])
	draw_rect(Rect2(0.0, 0.0, screen.x, panel_h), PANEL)
	var y: float = PAD
	for i in count:
		var line: Dictionary = rows[first + i]
		_text(font, PAD, y, String(line["text"]), kind_color(String(line["kind"])))
		y += float(LINE_HEIGHT)
	var before: String = input_text.substr(0, caret)
	var after: String = input_text.substr(caret)
	_text(font, PAD, y, "> " + before + "|" + after, COLOR_INPUT)

## `rl.drawText` draws from a text's *top left*; `draw_string` draws from the baseline, so
## every call adds the ascent back -- the same helper `hud.gd` needs and for the same reason.
func _text(font: Font, x: float, y: float, text: String, color: Color) -> void:
	if font == null:
		return
	draw_string(font, Vector2(x, y + font.get_ascent(LINE_HEIGHT)), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, LINE_HEIGHT, color)
