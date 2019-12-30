---
layout: post
title: "Room for graphical improvement"
author: Johan Manuel
tags: development
---

![Current state of the GUI](/assets/sos-with-bg.png){: title="It's always christmas with SnowflakeOS" }
In the last post, I presented the first working version of SnowflakeOS's window manager. While it worked, it had<sup>[<a href="" title="still has">1</a>]</sup> a few important shortcomings.

## WM design: simple is too simple

### In the last post

Here's how it worked:

1. The WM held a state: which window had to be drawn next to correctly on top of others
2. Windows had to call the WM in a loop in order not to block others

The rationale was that having the windows call the WM allowed for a single buffer per window. Performance wasn't great either: framerate was limited by the slowest window, drawing a single frame took as many system calls as there are windows, and each window had to be copied entirely. Plus the final off-screen buffer to framebuffer copy. Last but not least, drawing in a loop when the screen doesn't even require redrawing is plain dumb.

### A slight improvement

Since the last post, I decided I could spare the RAM to build something less outrageous, so now it works like this:

1. When a window calls the WM, its buffer is copied in the kernel
2. All windows are redrawn from their in-kernel buffers
3. The off-screen buffer is copied to the framebuffer

Now the screen is only refreshed as needed, in a single system call, but when it needs to be, it's still incredibly slow. For a video mode of 1024x768x32, we're copying at least 6 MiB per refresh. Still sort of outrageous.

### Reinventing the wheel from second-hand principles

Doing a bit of searching, I found [a magnificent series of blog posts](http://www.trackze.ro/tag/windowing-systems-by-example/) by Joe Marlin<sup>[<a href="" title="Joe, I had to steal your footnotes, for I could not steal your style">2</a>]</sup> in which he implements a window manager from scratch in C, taking proper design and performance in consideration. Finding information about the algorithms and architecture of window managers is surprisingly difficult, which is why Joe's posts are of such value.

One of the techniques described that I really want to implement is clipping, to avoid copying so much memory and redrawing things that haven't changed. There's also a neat GUI system described there, but I don't want to have it live in the WM so I'll make my own way there.

## Miscellaneous improvements since last time

### Bug hunting

I've spent most of my development time on this item, with two outstanding bugs.

The first was a page fault occuring only when optimisations were turned when compiling the kernel. I fixed it in [this commit][page fault] and while the precise instruction causing the fault escaped me, I know it was a result of two things:

+ I used `ebx` to pass arguments in my system calls without saving its value: it's a callee-saved register in the C calling convention. It was only a matter of time before it caused a bug.
+ Even after fixing the above point, not qualifying my inline assembly system calls with `volatile` left my code crashing. I guess gcc tried something funny during optimisation there.

The [second bug][buffer shift] was with my background window (shown at the top of this post) being shifted 50 pixels to the right. Specifically, the top row began at the 51th pixel, thus shifting the rest of the image, and drawing 50 pixels past the end of the buffer. The worst is that this bug occured only with `-O2` optimisations turned on, and only on bochs, not on QEMU. This made me think it had to be a memory error, caused by me triggering undefined behavior somewhere, as I had reworked my `malloc` implementation just before<sup>[<a href="" title="see the very next section">3</a>]</sup>.  
It turned out to be a lot more mundane: with optimisations on, my scheduler switched from the "background window" program ealier than in other cases, so it opened its window after the other program. Can you guess what my window-placing code does? It shifts new windows 50 pixels to the right of the last one. The first window was placed at x=0, the background at x=50.

I was rooting for a much more interesting resolution for that second bug! That'll teach me not to make too many assumptions while debugging, and not to be okay with drawing outside buffers. And my window-placing code is now clearly marked as "radioactive garbage".

### Gradual improvements to malloc

I've [implemented][sbrk syscall] the `sbrk`<sup>[<a href="" title="it stands for 'set break'">4</a>]</sup> system call as a first step to get a free-able malloc implementation. It's useful for allocating and deallocating memory after the program's code. Handling page boudaries make the code somewhat hard to understand. If the program asks for `n` more bytes, do we need to allocate a new page? several? Same thing for deallocation.

For the first time<sup>[<a href="" title="I repent, I swear!">5</a>]</sup>, I spent some time reading about memory allocators, on this clear and concise [site][malloc] in particular. It's pretty much a requirement for implementing clipping in my window manager, so that's what comes next.

### Putting programs to sleep

Finally, long-standing useless system call number 2 works, [processes can sleep][sleep syscall]! Well, most of the time, there are still two issues:

+ When all processes sleep, one has to run anyway. To avoid this situation, I need to add an "idle" process that does nothing yet never sleeps.
+ Sleep doesn't work on bochs, as it's a bit more anal than QEMU about the FPU<sup>[<a href="" title="Floating Point Unit">6</a>]</sup> not being setup. I compute the number of timer ticks to sleep using `(ms/1000.0)*TIMER_FREQ`, and without initialising the FPU, this always equals 0 on bochs.

Setting up the FPU isn't entirely trivial as it's a part of the execution context of a process that isn't saved on task switch, so it needs special care. It's on the shortlist though, it's pretty important.

### Background improvements

Notice how the wallpaper doesn't look like a graphical glitch anymore? I picked a background, converted it to raw RGB values, stuck it in a C header with `xxd -i` and loaded it in the buffer of my background window. At 14 MiB of header file, it's outright heavy, but thankfully once compiled it compresses down to around 2 MiB. A PNG parser is somewhere on my todo list :)

[page fault]: https://github.com/29jm/SnowflakeOS/commit/4089a7460f31153ea7f5d2734f5a538c6918e4da
[buffer shift]: https://github.com/29jm/SnowflakeOS/commit/5bbd545037487fc8f9f935b3b7f5755e9bfdd0d6
[sbrk syscall]: https://github.com/29jm/SnowflakeOS/blob/5bbd545037487fc8f9f935b3b7f5755e9bfdd0d6/kernel/src/sys/proc.c#L278-L320
[malloc]: http://dmitrysoshnikov.com/compilers/writing-a-memory-allocator/
[sleep syscall]: https://github.com/29jm/SnowflakeOS/blob/5bbd545037487fc8f9f935b3b7f5755e9bfdd0d6/kernel/src/sys/proc.c#L273-L276