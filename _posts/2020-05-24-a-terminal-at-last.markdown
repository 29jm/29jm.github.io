---
layout: post
title: "A terminal, at last"
author: Johan Manuel
tags: development
---

![picture](/assets/sos-paint.png){: class="thumbnail" title="The author wasn't fucking around _this_ week."}
Let's face it, it's hard to get excited about a kernel from just barebone demos of barely functional systems. In this article, I propose a radical solution: actually implementing useful userspace programs, namely a terminal, and ye old copycat of paint.

But wait, you scream, last time you didn't have moving windows, a mouse pointer, or the ability to get input from userspace, how come now we're implementing a terminal?  
Right, right, let's get it over with.

## Communicating with the wm

If you recall [this post]({% post_url 2019-10-14-of-mice-and-keyboards %}), our keyboard and mouse drivers were in pretty fine shape, useless though they were then. We'll use them right away to register callbacks, set to fire when a key is pressed, or released, and when something happens to the mouse:

```c
void init_wm() {
    ...;
    mouse_set_callback(wm_mouse_callback);
    kbd_set_callback(wm_kbd_callback);
}
```

Let's talk about how we handle mouse events first. We want clicks to push windows to the front, we want mouse drags to move windows, and we want some of these events to reach the affected window. I say some, because of a choice made in the wm: windows can be dragged from anywhere in their rectangle, and they can't opt out. Therefore there can't be drag events within windows, the cursor doesn't move relative to the dragged window anyway.  
All of that takes some code, about ninety lines total. It ain't thrilling, so I won't force it upon your eyes, dear reader, but it's [right here][mouse cb] if needed.

A point more worthy of being highlighted is how exactly the wm tells a window "you've been clicked here", or "the mouse moved from here to there". In most (all?) other OS, the wm is in userspace and uses IPC and some bespoke protocol to speak with its clients.  
In SnowflakeOS, clients poll the wm using a system call, `snow_get_event`, which is really a call to `syscall2(SYS_WM, WM_CMD_EVENT, wm_event_t* event)`<sup>[<a href="https://github.com/29jm/SnowflakeOS/blob/1dd718af791f4fd869e94f6ecbc9b98d1a3f6c9c/snow/src/gui.c#L80-L91" title="all wm commands go through the SYS_WM syscall">1</a>]</sup>. The structure returned, `wm_event_t`, is a copy of the kernel-side, per-window `wm_event_t` object, and contains approximately the following fields:

```c
typedef struct {
    uint32_t mask; // describes valid fields
    wm_mouse_event_t mouse;
    wm_kbd_event_t kbd;
} wm_event_t;
```

where `mouse` and `kbd` are defined in somewhat obvious ways in [uapi_wm.h][uapi wm]<sup>[<a href="" title="thanks to Protura's dev for suggesting this way of sharing kernel headers!">2</a>]</sup>. So, clients poll the wm for this structure, and that's the client side of it. The kernel, wm side of it is pretty straightforward: the mouse and keyboard callbacks fill `mask` and other fields as needed, for instance in the keyboard handler:

```c
void wm_kbd_callback(kbd_event_t event) {
    if (windows->count) {
        wm_window_t* win = list_last(windows);

        win->event.mask |= WM_EVENT_KBD;
        win->event.kbd.keycode = event.keycode;
        win->event.kbd.pressed = event.pressed;
        win->event.kbd.repr = event.repr;
    }
}
```

and events are cleared once they've been queried:

```c
void wm_get_event(uint32_t win_id, wm_event_t* event) {
    wm_window_t* win = wm_get_window(win_id);

    if (!win) {
        return;
    }

    *event = win->event;
    memset(&win->event, 0, sizeof(wm_event_t));
}
```

I'm sure some of you are wondering where event queues fit in there. I've heard of them, but I don't practice<sup>[<a href="" title="I'll make a queue in the keyboard driver for sure">3</a>]</sup>. What do I do if two keys are pressed, and the event structure hasn't been retrieved in between? I drop a keypress.

Just take your time when writing stuff, it's the zen of SnowflakeOS.

## A terminal

<figure>
    <img src="/assets/terminal.png">
    <figcaption>The classic, the irreplaceable.</figcaption>
</figure>

Here's something I haven't done in a long time, if ever: writing C apps. There's a very real difference between kernel code and application code, I think. And I suck at writing actual C programs. C feels much less friendly to me in this space, I guess in large part because I don't know what I'm doing. For instance I've felt the need to make my own string object and related functions. C's basic string handling functions are notoriously terrible though, I'm surprised it's the first time I felt the need to replace them.

Anyway, what does a terminal do? Usually, it runs a single program, the shell, and it handles printing its output nice and tidy, which includes handling escape sequences (we had those, [a long time ago][ansi]), line wrapping, sometimes mouse handling I guess. I actually don't known much more than that. SnowflakeOS has an `exec` system call<sup>[<a href="https://github.com/29jm/SnowflakeOS/commit/6444c76b939975f91c96133118b1ea7dd58ecfe3" title="this is new too! not much work. this one is an actual link btw.">4</a>]</sup>, but no concept of child process, forks, etc... so we can't have that traditional terminal-shell separation just yet. For the same reason, external processes won't be able to print to the terminal, only builtin commands. Well _whatever_<sup>[<a href="" title="though this will be fixed">5</a>]</sup>, we just want a fancy way to start paint ;)

The terminal follows the same basic structure of every graphical app ever: handle input, redraw, loop. Let's take a look at input handling:

```c
while (running) {
    wm_event_t event = snow_get_event(win);
    ...;
    // Skip kbd handling & redrawing in this case
    if (!(key_pressed || focus_changed)) {
        continue;
    }

    ...;

    switch (event.kbd.keycode) {
        case KBD_ENTER:
        case KBD_KP_ENTER:
            str_append(text_buf, input_buf->buf);
            str_append(text_buf, "\n");
            interpret_cmd(text_buf, input_buf);
            input_buf->buf[0] = '\0';
            input_buf->len = 0;
            str_append(text_buf, prompt);
            break;
        case KBD_BACKSPACE:
            if (input_buf->len) {
                input_buf->buf[input_buf->len - 1] = '\0';
                input_buf->len -= 1;
            }
            break;
        default:
            if (key.keycode < KBD_KP_ENTER) {
                char str[2] = "\0\0";
                str[0] = key.repr;
                str_append(input_buf, str);
            }
            break;
    }
}
```

That's pretty ugly switch, let me explain. I chose to have two text buffers to represent the text displayed on the terminal. One, `input_buf`, contains the current line of user input, and it can be edited, and the other, `text_buf`, contains all the rest. It makes sense then that pressing enter would append the input to the static buffer, interpret that input, and clear it. Currently the terminal handles editing through backspace, no arrow keys yet. Other keys aren't special (we just require they be printable), and are just appended to the input buffer.  
My `str_t` type makes things a bit ugly there, I haven't taken the time to make enough utility functions. It's useful because  `str_t` has no length limit as `str_append` reallocates if needed, which happens when `text_buf` grows.

The next step is to interpret the input we got, which is done here:

```c
void interpret_cmd(str_t* text_buf, str_t* input_buf) {
    char* cmd = input_buf->buf;

    if (!strcmp(cmd, "")) {
        return;
    } else if (!strcmp(cmd, "uname")) {
        str_append(text_buf, "SnowflakeOS 0.5\n");
    } else if (!strcmp(cmd, "ls")) {
        str_append(text_buf, "No.");
    } else if (!strcmp(cmd, "dmesg")) {
        char klog[2048];
        sys_info_t info;
        info.kernel_log = klog;
        syscall2(SYS_INFO, SYS_INFO_LOG, (uintptr_t) &info);
        str_append(text_buf, klog);
    } else if (!strcmp(cmd, "exit")) {
        running = false;
    } else {
        int32_t ret = syscall1(SYS_EXEC, (uintptr_t) cmd);

        if (ret != 0) {
            str_append(text_buf, "invalid command: ");
            str_append(text_buf, cmd);
            str_append(text_buf, "\n");
        }
    }
}
```

Spot the funky `dmesg` here! The API to get the kernel log is dreadful, but now I can actually debug things from within QEMU:

![isn't it glorious](/assets/dmesg.png){: title="the calc is a lie"}

Finally, we get to redrawing the terminal. We have the tools to draw text, we have the text, let's do this.

```c
void redraw(str_t* text_buf, const str_t* input_buf) {
    /* Title bar, background... */
    ...;

    /* Text content */

    // Temporarily concatenate the input and a cursor
    str_append(text_buf, input_buf->buf);

    if (cursor) {
        str_append(text_buf, "_");
    }

    char* text_view = text_buf->buf;
    char* line_buf = malloc(max_col + 1);
    uint32_t n_lines = count_lines(text_buf);
    uint32_t y = 22; // below the title bar

    // Scroll the view as needed
    if (n_lines > max_line) {
        for (uint32_t i = 0; i < n_lines - max_line; i++) {
            text_view = scroll_view(text_view);
        }
    }

    // Draw line by line, wrapping text
    while (text_view < &text_buf->buf[text_buf->len]) {
        char* lf = strchrnul(text_view, '\n');
        uint32_t line_len = (uint32_t) (lf - text_view);

        if (line_len <= max_col) {
            strncpy(line_buf, text_view, line_len);
            line_buf[line_len] = '\0';
            text_view += line_len + 1; // +1 discards linefeed
        } else {
            strncpy(line_buf, text_view, max_col);
            line_buf[max_col] = '\0';
            text_view += max_col;
        }

        snow_draw_string(win->fb, line_buf, margin, y, text_color);

        y += char_height;
    }

    // De-concatenate the input
    text_buf->buf[text_buf->len - input_buf->len] = '\0';
    text_buf->len -= input_buf->len;

    if (cursor) {
        text_buf->buf[text_buf->len - 1] = '\0';
        text_buf->len -= 1;
    }

    // Update the window
    snow_render_window(win);
}
```

Let's break it down. First, we make sure to work with only one text buffer by merging the input with the static text, we don't care to distinguish those here. We even include a blinking cursor for sanity reasons. Then, we make sure to draw the "bottom" of the buffer by scrolling if needed. If what this means is unclear, try spamming commands in a newly opened terminal, it'll scroll the view when you reach the bottom. Finally, we draw the text line by line, keeping in mind that a line either ends with a line feed, or by reaching the right side of the window.  
If you're like me and didn't know about it, `strchrnul` returns the the address of the trailing null byte in a string if nothing matches the query, instead of returning `NULL` like the classic `strchr` would.

All in all, we now have a working terminal.

## Paint

<figure>
    <img src="/assets/paint.png">
    <figcaption>"Snowflakistan". I blame my mouse driver.</figcaption>
</figure>

Kernel development is an art, or so some think. I enjoy consensus and wanted to address the concerns of naysayers, and with that goal in mind set out to make my kernel art-able. What program then could be better suited to artistic expression than the humble paint?

The code here has even fewer bells and whistles than the terminal, and I won't dare bore you with it. Get input, if click, toggle drawing, if mouse move and drawing, draw a line, loop. Note that because of window dragging mechanics you can't keep pressing the mouse to draw, you have to release it. I think it's not totally senseless UX-wise<sup>[<a href="" title="it mostly is though, yes">6</a>]</sup>, as you're free to focus only on the movement of your hand.

But, but, but, the five cool, old-school buttons on the top left are of some interest. I've started making a GUI toolkit, and what you're really seeing here are three color picker buttons and two normal buttons in a horizontal layout. This code is really a work in progress by any measure, but working on it has been pretty interesting so far. I'm taking a GTK-like approach, because it's the only C GUI toolkit I've ever touched. Thankfully I barely remember any of it, so I'm free to make the same mistakes it did, but also new and cooler ones.

In our paint version, this toolkit is used in a very hackish way, but it gives a general idea of how things will look:

```c
/* Setup the UI */
hbox_t* picker = hbox_new();
// No parent/root widget, so we position it manually
picker->widget.bounds.x = fb_x + 10;
picker->widget.bounds.y = fb_y;

// `color` is defined earlier
hbox_add(picker, (widget_t*) color_button_new(0x000000, &color));
hbox_add(picker, (widget_t*) color_button_new(0x513CBC, &color));
hbox_add(picker, (widget_t*) color_button_new(0xFC0A5A, &color));

button_t* exit_button = button_new("exit");
exit_button->widget.on_click = (widget_clicked_t) on_exit_clicked;
hbox_add(picker, (widget_t*) exit_button);

button_t* clear_button = button_new("clear");
clear_button->widget.on_click = (widget_clicked_t) on_clear_clicked;
hbox_add(picker, (widget_t*) clear_button);

...; // Later, in the program loop

/* Give these lads some input */
if (point_in_rect(pos, picker->widget.bounds)) {
    picker->widget.on_click((widget_t*) picker, pos);
}
```

Anyway, you can paint stuff now. It's plenty fast in QEMU, but that could still be easily improved: right now we tell the wm to update the whole window rect<sup>[<a href="" title="clipping rules still apply in wm land, of course">7</a>]</sup>, when we could tell it to update only the small square containing the new line we just drew. Another big improvement, and not just to paint, would be to store the mouse's position as a pair of floats instead of ints, because right now small movements are basically ignored due to rounding errors in the wm's code. One advantage is that it's really easy to draw squares right now, but unless a sizeable fraction of users turns out to be rabbid fans of the [Suprematist][suprematist] movement, I think it's worth fixing.

---

On a final note, I wanted to thank /r/osdev's users for sharing their progress, in particular skiftOS's developer, whose beautiful UI and OS reminded me to try a little harder, because the results are clearly worth it.

[uapi wm]: https://github.com/29jm/SnowflakeOS/blob/1dd718af791f4fd869e94f6ecbc9b98d1a3f6c9c/kernel/include/kernel/uapi/uapi_wm.h
[mouse cb]: https://github.com/29jm/SnowflakeOS/blob/1dd718af791f4fd869e94f6ecbc9b98d1a3f6c9c/kernel/src/misc/wm/wm.c#L407-L501
[ansi]: https://github.com/29jm/SnowflakeOS/commit/1e1c45656152f428ebfdc0b919bd08a1074580b0
[suprematist]: https://en.wikipedia.org/wiki/Suprematism
