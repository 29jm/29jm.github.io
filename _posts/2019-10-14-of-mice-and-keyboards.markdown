---
layout: post
title: "Mouse support and other PS/2 shenanigans"
author: Johan Manuel
tags: development
---

![Keyboard and mouse both working](/assets/kbd_demo.gif){:class="thumbnail" title="Notice the stray 'a'. Thanks, QEMU, I'll debug that some other day."}
At the beginning of last week, I was looking over my keyboard code, still wondering what kind of interface could be exposed to userspace and be useful, and also wondering why my scan codes seemed to have no physical relation to any known keyboard layouts.  
So I went over to OSDev's article about [PS/2 keyboards][osdev kbd], which sent me to the article about the [PS/2 controller][osdev ps2], and I knew I wanted to do things properly, and at the same time, gain mouse support.

Here above you can see keyboard input being written to the screen, and mouse coordinates on the bottom right corner - wait for it.

## The PS/2 controller

Source: [ps2.c][ps2 c], [ps2.h][ps2 h]

"PS/2" stands for "Personal System/2" and is the old green or purple round port which fit old keyboards. These ports were linked to the PS/2 "8042" controller, an old chip which, miraculously, still manages to exist in some form in modern computers. Indeed, while PS/2 devices have been replaced by USB ones, the BIOS (most of them anyway) offers an emulation of the 8042 on top of USB. Ideally I'd implement the USB protocol, but this is an OS project, not an USB project, and dealing with PS/2 devices is easy in comparison.

The steps to initialize the PS/2 controller to some base state are numerous and detailed in the relevant section of the wiki page. I've implemented them in [ps2.c][ps2 c init], a ~140 lines function full of hopefully well commented IO. Most of it looks something like this:

```c
// Give the controller a command
ps2_write(PS2_CMD, PS2_WRITE_CONFIG);
// and its associated data byte
ps2_write(PS2_DATA, config);
```

Where `ps2_write(port, byte)` is a wrapper around the x86 instruction `outb` which writes a byte to an IO port. This function also makes sure the controller is ready to receive a byte, and similarly, `ps2_read(port)` makes sure the controller has sent us a byte.

The outline of the initialization steps is that first, you need to pray that there really is a PS/2 controller to talk to: the correct way to do this is to query the ACPI tables, but hey, QEMU and Bochs are guaranteed to have one. Then, you need to test if there is a second controller (which usually handles the mouse) and run self-tests. The last step is to reset devices plugged into our functionning PS/2 controllers. Finally, we query their identity - keyboard, mice - and start the relevant device drivers.

Implementing the various steps didn't take me long; but chasing its bugs did. Specifically, a bug that appeared only on QEMU. After initialization of the PS/2 controllers, my keyboard code stopped working. The keyboard simply didn't send IRQs. And to get the mouse working, at first I needed to disable my keyboard code!  
I finally figured it out by looking at the controller's configuration byte: I was inadvertently setting a bit that disabled the keyboard clock. Somehow Bochs doesn't care if it's set when enabling IRQs from devices, it just unsets it, however QEMU doesn't let it fly.

## A PS/2 mouse driver

![Moving my mouse to the left crashed Bochs](/assets/mouse_crash.gif){: title="I have *no* idea why or how this is animated"}

I've had weird crashes implementing this. This happened when I moved my mouse to the left in Bochs!

Source: [mouse.c][mouse c], [mouse.h][mouse h]

First, one needs to enable reporting from the mouse, it then starts sending out IRQs on line 12. Each IRQ corresponds to a byte available for reading from the PS/2 controller's data port, `0x60`. The bytes must be treated in packets of three to four depending on the type of mouse we detected, or features we enabled. The bytes are sent in this order:

* flags: direction of the x and y movements, state of mice buttons, others...
* x movement
* y movement

and if there is a fourth byte, it contains scroll wheel movements and the state of buttons four and five of the mouse. Here's the code receiving the bytes:

```c
void mouse_handle_interrupt(registers_t* regs) {
    UNUSED(regs);

    uint8_t byte = ps2_read(PS2_DATA);

    // Try to stay synchronized by discarding obviously out of place bytes
    if (current_byte == 0 && !(byte & MOUSE_ALWAYS_SET)) {
        return;
    }

    packet[current_byte] = byte;
    current_byte = (current_byte + 1) % bytes_per_packet;

    // We've received a full packet
    if (current_byte == 0) {
        mouse_handle_packet();
    }
}
```

All we need to do then in `mouse_handle_packet` is keeping track of the mouse movements, and at a later time, making them available to userspace. Then, and only then, we'll get a mouse pointer.

## A better PS/2 keyboard driver

Source: [kbd.c][kbd c], [kbd.h][kbd h]

Now that I was initializing the PS/2 controller instead of letting it do its thing, my driver was working all funky. The reason lies in scan code sets.

First things first, a scan code is one or more bytes sent by the keyboard when a key event happens. For instance, pressing 'D' on my keyboard may send `0x23`, and releasing it may send `0xF0` followed by `0x23`. Some keys - in some scan code sets - send up to 8 bytes!

Now, a scan code set is the map between a physical key and the bytes the keyboard sends, and there are basically 3 of them. The previous example was true for scan code set 2; in scan code set 1, pressing 'D' would have caused the keyboard to send `0x20`, and releasing it would have given `0xA0`.

When I did zero PS/2 controller initialization, my keyboard defaulted to scan code set 1, with a twist: scan code translation, i.e. the controller converting scan codes to old IBM-PC compatible scan codes. This scan code set and weird translation mechanism are too vintage even for SnowflakeOS; it was time to handle scan code set 2.

In this shiny new 1983 scan code set, things are a bit more complicated than with scan code set 1. There are two categories of keys:  
There are the simple keys, which send a one-byte scan code when pressed, and `0xF0` followed by that same scan code when released.  
Then there are the other keys, which send multibyte scan codes. They can be identified as they send an `0xE0` byte first, followed by a `0xF0` byte in case of a release event, followed by one or more bytes of scan code.

Now keep in mind that we receive bytes one at a time in our interrupt handler, so we need to keep track of previously received bytes until we've identified a whole key event, and the difficulty is in the variable length of such packets. Obviously, what we need is some kind of state machine and a buffer to hold our bytes. Here's the function in [kbd.c][kbd c process] in charge of updating the state of the driver's state machine:

```c
bool kbd_process_byte(kbd_context_t* ctx, uint8_t sc, kbd_event_t* event) {
    ctx->scancode[ctx->current++] = sc;
    uint32_t sc_pos = ctx->current - 1;

    switch (ctx->state) {
        case KBD_NORMAL: // Not in the middle of a scancode
            event->pressed = true;

            if (sc == 0xF0) {
                ctx->state = KBD_RELEASE_SHORT;
            } else if (sc == 0xE0 || sc == 0xE1) {
                ctx->state = KBD_CONTINUE;
            } else {
                ctx->current = 0;
                event->key_code = simple_sc_to_kc[sc];
            }

            break;
        case KBD_RELEASE_SHORT: // We received `0xF0` previously
            ctx->state = KBD_NORMAL;
            ctx->current = 0;
            event->key_code = simple_sc_to_kc[sc];
            event->pressed = false;

            break;
        case KBD_CONTINUE: // We received `0xE0` at some point before
            if (sc == 0xF0 && sc_pos == 1) {
                event->pressed = false;
                break;
            }

            if (kbd_is_valid_scancode(&ctx->scancode[1], sc_pos, &event->key_code)) {
                ctx->state = KBD_NORMAL;
                ctx->current = 0;
            }

            break;
    }

    return ctx->state == KBD_NORMAL;
}
```

It's quite a big function, and still most of the heavy lifting is done in `kbd_is_valid_scancode(bytes, len, &key_code)`, in charge of identifying valid multibyte scancodes and translating those into key codes. Our `kbd_process_byte` function indicates that a valid scan code has been received by returning `true`, and makes the key event available through its `event` parameter.  
If you're really paying attention, you may notice a possible buffer overflow with `ctx->scancode[ctx->current++]`, but thankfully `kbd_is_valid_scancode` is guaranteed to return `true` before that... Hmm, this is a bit too clunky, perhaps I'll put a proper check back in just in case I ever modify `kbd_is_valid_scancode`'s interface in the future.

Anyway, SnowflakeOS can now handle a full QWERTY layout. This is a bit dumb as I myself have a French, AZERTY layout; let's just say I'm being international :)  
Ideally I'd move most of the keycode translation stuff to userspace where a keymap could be loaded, and there'd be no more problems.

[osdev kbd]: https://wiki.osdev.org/Keyboard
[osdev ps2]: https://wiki.osdev.org/%228042%22_PS/2_Controller
[ps2 c]: https://github.com/29jm/SnowflakeOS/blob/357ecc40169c2b8e02c7866ea383171cf436def4/kernel/src/devices/ps2.c
[ps2 c init]: https://github.com/29jm/SnowflakeOS/blob/357ecc40169c2b8e02c7866ea383171cf436def4/kernel/src/devices/ps2.c#L12-L158
[ps2 h]: https://github.com/29jm/SnowflakeOS/blob/357ecc40169c2b8e02c7866ea383171cf436def4/kernel/include/kernel/ps2.h
[mouse c]: https://github.com/29jm/SnowflakeOS/blob/357ecc40169c2b8e02c7866ea383171cf436def4/kernel/src/devices/mouse.c
[mouse h]: https://github.com/29jm/SnowflakeOS/blob/357ecc40169c2b8e02c7866ea383171cf436def4/kernel/include/kernel/mouse.h
[kbd c]: https://github.com/29jm/SnowflakeOS/blob/617e66a7107bd5821ef381a64598fa33c8891c08/kernel/src/devices/kbd.c
[kbd c process]: https://github.com/29jm/SnowflakeOS/blob/617e66a7107bd5821ef381a64598fa33c8891c08/kernel/src/devices/kbd.c#L133-L179
[kbd h]: https://github.com/29jm/SnowflakeOS/blob/617e66a7107bd5821ef381a64598fa33c8891c08/kernel/include/kernel/kbd.h