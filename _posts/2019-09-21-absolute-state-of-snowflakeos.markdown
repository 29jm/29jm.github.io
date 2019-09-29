---
layout: post
title:  "The absolute state of SnowflakeOS"
author: 29jm
author_profile: false
tags: meta
---

In my first run in summer 2015, I programmed the components listed in the following
categories, pretty much in that order. I've barely touched them since, so explaining
each of them here should help me get some knowledge back.  
Some of those categories may have to be moved to their own pages in the future.

## VGA Terminal

Source files: [tty.c][tty c]

This module is responsible for providing text writing support to the rest of the kernel.
This is done here using what's known as `VGA mode 3`, a mechanism that allows writing to
a 80x25 interface through a chunk of memory starting at `0xB8000`.  
At this address starts an array `80 * 25 * 2` bytes long, each character occupying two bytes.
Using it is simple, as writing a character on the screen is done by writing that character
(plus metadata like foreground and background color) to this array, at offset `y*width+x`.  

## IRQs

Source files: [irq.c][irq c], [irq.S][irq S], [isr.c][isr c]

This module handles communication with the `PIC`, or `Programmable Interrupt Controller`. It
sets a few things up, such as renaming interrupt numbers from the 0-15 range to the 32-47
range, so as not to interfere with CPU-generated interrupts like page faults that are mapped
to the 0-31 range.  
It sets up a generic handler that gets called on every interrupt. That handler checks if that
interrupt has been associated with a specific handler, in which case that handler is called.  
The class of interrupts in the 0-31 range are called `Interrupt Service Routines`, or `ISR`,
and those are handled in `isr.c`.

## Timer

Source files: [timer.c][timer c]

This file contains the handler for interrupt 0, or rather interrupt 32 as we've remapped
interrupts as noted in the previous section. This interrupt comes from the `PIT`, or
`Programmable Interval Timer`, which in the case that interests us is nothing more than a
clock.  
We set a frequency for that clock to fire, and we register a handler to keep track of time.

## Keyboard

Source files: [keyboard.c][keyboard c]

This is more of a proof of concept, something I wanted to see working soon, rather than a
useful or working component of SnowflakeOS. Basically, it sets up an interrupt handler for
interrupt 1. In that handler, it reads the given signal from the corresponding IO port,
converts it to ASCII and prints it, with modifiers if any.  
There's no API to speak of, I don't know yet how I'll expose it to userspace.

## Physical Memory Manager (PMM)

Source files: [pmm.c][pmm c]

Now that file is very important, as it contains functions that manage physical memory,
regardless of paging changes. Its job is to make the allocation of physical pages of
memory pretty much trivial, along with de-allocation.  
It starts by reading the `multiboot` structure provided by `GRUB`, and marks as such the
areas described as unavailable, as well as areas already occupied by the kernel.  
It does its job of keeping track of free pages though a bitmap allocated after the kernel
in memory. The `n`th bit in that bitmap indicates whether the page at address `n*4096` is
free, with `0` meaning free.

## Paging

Source files: [paging.c][paging c], [liballoc.c][liballoc c]

I won't get into the 'why' or the 'how' of paging here, but I'll describe what it does
currently in SnowflakeOS. First, it's the mechanism that allows the kernel to live at
address `0xC0100000` when physically the kernel is stored at `0x100000` - the kernel is
said to be a "higher half" kernel. That mechanism is address translation from a virtual
address space to the physical address space.  
Having our kernel mapped to high addresses is useful as it frees lower memory: we'll be
able to map the code of our processes there at fixed addresses, with their stacks right
below the kernel. We'll have one address space per process, with the kernel mapped into
each so that we can make syscalls.  
I borrowed a library called `liballoc` to implement `kmalloc` in SnowflakeOS. It works
by dynamically allocating pages and dividing them in smaller chunks, keeping track of
allocations. The code in this library is horrific, though, and I intend to get rid of it.

## Syscalls

Source files: [syscall.c][syscall c]

Which brings us to syscalls, or system calls. Those are a way to call a kernel function
from a userspace process, thereby gaining access to higher priviledge but in a way that
is entirely controlled by the kernel.  
Concretely, syscalls are implemented by registering an unused interrupt handler, and by
checking the arguments passed to that interrupt (I'll use registers for parameter passing)
to call the proper kernel function, and if needed, return a result.  
That interrupt can be triggered from userspace though the `int` instruction; it's a software
interrupt, as opposed to hardware interrupts caused by the `PIT`, etc...  
As of now, this mechanism is untested.

[tty c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/devices/tty.c
[irq c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/cpu/irq.c
[irq S]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/cpu/asm/irq.S
[isr c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/cpu/isr.c
[timer c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/devices/timer.c
[keyboard c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/devices/keyboard.c
[pmm c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/mem/pmm.c
[paging c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/mem/paging.c
[liballoc c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/mem/liballoc.c
[syscall c]: https://github.com/29jm/SnowflakeOS/blob/29163f3af06f782bab188a0b60b5402b33ad14d9/kernel/src/sys/syscall.c