# Terminal input modes

CLAUDE.md §6 asks for line-oriented and raw modes. The compose row in a
connected session has a Line/Raw switch. Line is the default and is how
AXTerm has always worked. Raw sends keys as they are typed.

## Line mode

The operator edits a whole line in the message field and nothing leaves until
Return. The line goes out as its bytes plus one CR (0x0D), cut into I-frames
at the session's paclen. With AXDP on and confirmed, the line goes out as an
AXDP chat message instead. A blank line sends a bare CR.

## Raw mode

Raw mode is for programs at the far end that read characters, not lines: a
node or BBS that prompts without a line ending, a password prompt, a menu that
acts on one key, or anything that wants Ctrl-C, Ctrl-Z or Esc.

Keys map to bytes like this:

| Key | Byte |
| --- | --- |
| printable character | its UTF-8 bytes |
| Return, keypad Enter | CR (0x0D) |
| Delete (backspace) | BS (0x08) |
| Tab | HT (0x09) |
| Esc | ESC (0x1B) |
| Ctrl-@, Ctrl-A … Ctrl-Z, Ctrl-[ Ctrl-\ Ctrl-] Ctrl-^ Ctrl-_ | 0x00 … 0x1F |

BS is the TNC-2 default (`DELETE OFF`) and what packet nodes and BBSes expect.
Arrow and function keys send nothing: there is no terminal type to negotiate
over AX.25, so any escape sequence would be a guess.

Pasted text is treated as typed. LF and CR LF become one CR.

### When bytes leave

One frame per keystroke would load the channel with an AX.25 header for every
character. Raw mode buffers keys and sends the buffer when the first of these
happens:

1. A CR is typed. The buffer goes out with the CR at its end.
2. A control byte other than BS or HT is typed (Ctrl-C, Ctrl-Z, Esc and the
   rest). The operator wants it acted on now.
3. Typing stops for 1 s. This is TNC-2 `PACTIME AFTER 10`, the idle send timer
   of transparent mode.
4. The buffer reaches the session's paclen. A full I-frame goes out and typing
   carries on into the next one.

Switching back to Line mode sends anything still buffered first, ahead of
the next line. When the session ends, whoever ends it, anything still
buffered is dropped along with the rest of the send queue, and the next
session starts on a clean line.

Raw bytes are never AXDP: raw means the far end gets exactly the bytes typed.
The AXDP switch stays as it was and applies again in Line mode.

### What the operator sees

The raw field shows the line in progress: the far end's partial line (a prompt
such as `BBS>` that has no CR yet), then the keys typed since, when Local Echo
is on. BS removes the last echoed character. CR ends the line.

Local Echo is on by default. Turn it off for a far end that echoes what it
receives, or every key appears twice.

Each frame sent appears in the console like any other transmitted I-frame,
with CR shown as `↵`, BS as `⌫` and other control bytes in caret form (`^C`).
Session history records one line per CR, from the echo.

### Control characters in Line mode

The control-character menu next to the field works in both modes. In Line mode
it sends the one byte at once, alone, and leaves the message field untouched.

## Where the code is

- `RawKeyCoalescer` (AXTerm/Terminal/RawKeyCoalescer.swift): the key map, the
  echo line and the four send rules, with no clock of its own. Tested in
  RawKeyCoalescerTests.
- `RawTerminalInput`: owns a coalescer, runs the 1 s idle timer and hands
  chunks to the send path.
- `RawKeyCaptureView`: the macOS key view and the iOS `UIKeyInput` view.
