---
layout: post
title: "Filesystems for dummies"
author: Johan Manuel
tags: development osdev hobby-os c
---

![Showing off the flex new background](/assets/sos-corpo2.png){: class="thumbnail" title="The dummy in question is the author, fwiw"}
Welcome to a new post from this very irregular blog! After busy summer holidays spent hiking in the Pyrenees, college has begun again and with it, the peace required for osdev work to resume. Last time I worked on SnowflakeOS, I'd gone all in on UI work, left unfinished and unpolished. Having entirely forgotten about that work, I booted up the project and thought: "why no files? let there be files", and now, files sort of are. Let's see how they work, and how they don't.

But first, take a look at that whole new logo, designed by the magnificent [sylvain-kern](https://github.com/sylvain-kern) <3 The sign of a new era of prosperity for SnowflakeOS, to be sure.

## A disk? Wherefore ſhis demonic inſtrument?

The fact is, we don't have a disk driver of any kind. Those don't look fun to me right now, the easiest thing to write would be an ATA PIO driver, which is an old an decrepit standard{% anecdote 1|I'll end up loving it at some point <3 %}. I deciced I wouldn't bother for now, having a much faster short-term solution in mind: loading the filesystem as a GRUB module.

This is just a matter of generating the filesystem with `mkfs.ext2` and placing it in the modules directory. The kernel then sees it as just another module, so we make an exception for it and feed it into the ext2 driver.

*Edit 19/10/2020:* while the problem described in the following parapgraph was indeed present in SnowflakeOS at the time of writing, it was in fact trivial to solve, and solved in [7d94942][modules]. Thanks /u/TheMonax :)

The thing with modules in SnowflakeOS though is that they can't exceed a certain size, around 3 MiB. The reason for that is that the physical memory manager stores its bitmap just after the kernel and its modules in memory, and when the PMM runs, the kernel has 4 MiB mapped for itself. If modules grow too large, the bitmap ends up unmapped and *fun* things happen. And it's too late then to map more memory: paging code has to be able to allocate physical pages, which requires a valid bitmap, etc...

All in all, our disk shall take the form of a pointer to a large area of memory containing the filesystem. In order to facilitate the transition to a real disk later, I decided to constrain myself to block sized reads and writes, hopefully that's how they work, modulo their block size.

##  Ext2 fundamentals

<figure>
    <img src="/assets/files-app.png">
    <figcaption>I tried my hand at a file explorer...</figcaption>
</figure>

In the beginning, there was the block. The block is the unit of size in an ext2 filesystem: they divide the volume into parts of equal size{% anecdote 3|1 KiB per block in my tests %}, much like how pages are the unit of division for memory. They're also a form of addressing, because blocks are numbered, and data is always pointed to in the form of a block number.  

Blocks contain the filesystem structures themselves: something called the superblock that contains properties of the filesystem, the allocation bitmaps for blocks themselves, for inodes... Inodes, what are they? They're a structure somewhere in a specific block, described by an inode number, that describes a file, with a file being either a regular file, a directory, or something more esoteric entirely that could still conceivably be called a file by unix gurus. Inodes structures are of fixed size though; the actual file data is only pointed to by block pointers in the structures. For maximum fun and fragmentation potential, this block pointer isn't simply a block pointer and a length, no, rather it's twelve direct block pointers, a pointer to a block containing a list of block pointers, a pointer to a block containing pointers to other blocks containing block pointers, and another level of that on top. Allocating such blocks is the very definition of [elegance][elegance]{% anecdote 2|sarcasm, please send help %}.

Anyway, the rest is most beautifully described by the online book [The Second Extended Filesystem][ext2 book] by Dave Poirier, and less beautifully and exhaustively described by the current `ext2` code in SnowflakeOS, [here][ext2 code].

Let's take a look at the userspace side of files now, here are the calls a `fopen` call triggers right now:

```c
1. fopen("/some/path", "r") -> FILE*;
2. ↪ syscall2(SYS_OPEN, path, O_READ) -> fd;
3.  ↪ syscall_open(path, O_READ) -> eax = fd;
4.   ↪ proc_open(path, O_READ) -> fd;
5.    ↪ fs_open(path, O_READ) -> fd;
6.     ↪ ext2_open(path) -> inode;
```

Quite a few layers to this particular onion, and it's bound to get worse as abstractions replace hardcoded choices. In particular, a VFS{% anecdote 3|Virtual File System %} is still missing, though maybe it could live in the `fs` layer here, in [fs.c][fs c].

With the basics down, SnowflakeOS can now load its wallpaper from disk instead of hardcoding it in a header file; it's cleaner but the real improvement is the compilation speed: parsing a 2.3 MiB header file takes time. Also, a file explorer was quickly thrown together, resulting in the design hellspawn pictured above.

## Bugs in the machinery

*Warning: this part gets technical*

As usual, I've had a healthy dose of madness-inducing bugs this session. Most of them affected a particularly fundamental part of the OS, the memory side of things. I always have mixed feelings about those: one one hand I'm thankful to have found them, on the other hand, it makes me realise that before fixing them, SnowflakeOS ran basically by pure chance. That should be my tag line honestly, "SnowflakeOS, the only luck-powered OS in existence".

The first bug appeared with the introduction of [ext2 read support][heisenbug a]. Suddenly, my terminal app started crashing when I removed a `printf` call from its source. Upon inspection, I found that it crashed because the program code I loaded was, in that case, random garbage{% anecdote 4|as opposed to the actual code, which is the regular kind of garbage %}. Turned out I was doing something dumb, `memcpy`ing the code from the physical address given by GRUB, when I should have been copying it from the kernel memory in higher half. Indeed, I only identity map around 1 MiB at the start of physical memory, but I map a whole 4 MiB large page of it to higher half addresses starting at `0xC0000000`. The GRUB module containing my terminal code ended up outside of this identity mapped memory, and so reading from it resulted{% anecdote 5|how it didn't crash is a mystery to me %} in random garbage being loaded.  
Now, while the terminal still crashed in some cases, it ran under specific conditions{% anecdote 6|bugs seem to live in 1e6-dimensional space %}. But a character or two got scrambled, much like it did [back in the day]({% post_url 2020-03-07-advanced-memory-allocation %}). Now this one was a quick fix; I'd had my head in memory code for a whole day at that point, and re-reading `pmm` code I noticed I wasn't marking module memory as taken, only the kernel's. What that implies is that the `pmm` is free to allocate this memory, which in SnowflakeOS's case it does, when starting other processes or allocating new page tables.

Understandably, crashing under any condition is not reasonable; a bug persisted. Like the previous commit message hinted at, I started investigating `malloc` code, which seemed to cause the crash. Debugging that code isn't a very pleasant thought to me; this is the realm of pointer arithmetic, raw memory shaped into blocks by sheer willpower, not stuff to mess with. And I trusted that code, too, so having to debug it was disappointing.  
My standard, first-approach mode of debugging with `printf` was out of question here: adding a printf made the crash disappear in most cases; I resorted once again to the ever-trustful (if slow) bochs{% anecdote 7|I have one gigantic complaint about it though: bringing up the stack or page tables makes it freeze entirely now, and it didn't use to be the case. I haven't gone through the motions of finding out if a change in my code is at fault or if it's really bochs though. But really, why would it crash? It can give me a linear dump of my stack, why would it crash displaying it slightly differently? %}. How peculiar, my static, global variable to the last allocated block was initialised to a non-zero, random-looking value, which caused the initialisation code to be skipped, leading to a segfault when traversing the block list.  
It was my understanding that static variables lived in the program code I was generating, for instance, I thought that if I'd added a static array of size 4 KiB, my executable would grow by that much. I knew that wasn't the case for "standard" executable files in ELF format for instance, but for some reason I'd assumed that flat binaries worked like that, for my convenience. They don't! To explain the rest of this bug, let me quote myself, in [this commit][heisenbug b]:

> Alright, I learned something today:
> - flat binaries can use addresses past their size to store static variables,
> - there's no way to tell how much memory a flat binary expects to have
>   for static variables.
>
> The bug was very much related to the aforementionned cool facts. It so
> happened that my terminal program was 0x2ff1 bytes long, juuust short of
> three pages, and it placed the global, static variable `used_memory` at
> address 0x3000. But when loading the program, I allocated three pages
> for it, so that program's malloc memory pool ended up starting at...
> 0x3000 exactly. On malloc(n), `used_memory` was increased by n, thus the
> first block's `next` member got assigned n instead of staying null. What
> does the next allocation check? If the previous block has a successor.
> Guess what? it does, it's located at... n. And so, the allocator
> returned an address corresponding to garbage at the beginning of the
> program's code... Ah, the marvels of osdev.

A real, proper fix would require an executable format a bit less primitive than raw binaries, but I haven't gotten to that point yet. What I did was to allocate one more page than needed by the code, and `memset` it all to zero to ensure proper initialisation. I really need to get going on an ELF parser, I doubt that a real-world program would be satisfied by a page worth of static variables.

The troubles weren't over yet though, as a very similar bug happened shortly after fixing that last one: after adding `strncmp` to my libc, my terminal stopped working *again*. Adding a function to my libc has one effect: increasing program size, and therefore the total space occupied by GRUB modules. This time though, everything appeared to be in order. No memory corruption, but a crash while mapping pages in `malloc`'s initialisation. This crash happened at a specific iteration of the loop in charge of mapping a span of pages; it made no sense, the code was correct, dammit. As explained in [this commit][heisenbug d], I figured it out after taking a day off. Paging code being correct, the physical memory manager had to be at fault{% anecdote 9|everything's obvious in retrospect %}. From there, it was a quick fix: I noticed an odd looking calculation:

```c
void pmm_deinit_region(uintptr_t addr, uint32_t size) {
    uint32_t base_block = addr/PMM_BLOCK_SIZE;
    uint32_t num = size/PMM_BLOCK_SIZE;
    ...;
```

It's not obvious unless you've been bitten by it before, but the issue is on the third line. When you have thirteen eggs, and twelve eggs per box, you need two boxes. Yet, `13 / 12 == 1`. But if by chance your number of eggs was a multiple of 12, you would've had no bug, which I guess was the case until now. Anyway, I already had a function to deal with that in [sys.h][sys h]:
```c
/* When you can't divide a person in half.
 */
static uint32_t divide_up(uint32_t n, uint32_t d) {
    if (n % d == 0) {
        return n / d;
    }

    return 1 + n / d;
}
```

The same mistake appeared a few times in my `pmm` code, a sign of its age really. This fixed, everything was back in order. All of this was a real test of patience, though very much necessary to keep the project going, and very useful for me to get back into the lower level details of memory management.

## Clang & UBSan

Having spent a good deal of time tracking down bugs, I thought it good to prioritize setting up a few tools to catch them more easily, or even prevent them. Setting up ubsan in particular had been on my todo list for a while: it's a compiler tool that pimps up your code to catch undefined behaviors at runtime, and for some reason I thought it was a clang-exclusivity, so I set out to make my Makefile compiler-agnostic and clang-proof.

### Clang

First thing I did was replacing `CC` with `clang`, and check the results. The results were mostly linker errors. Surprisingly, `clang` seems to call out to the system's `gcc` for a lot of things{% anecdote 10|which I've forgotten %}, and it uses the system's `ld` too. Anyway, I basically had to do four things:
+ Use `ld` for compilation phases instead of `CC`: `clang` calls `ld` there, but with somewhat crap arguments, it's far simpler to call `ld` directly and have control over them,
+ Call `as` directly, not `CC`: while `clang` can compile GNU assembly, it wasn't keen on doing so with the specific options I wanted to give it,
+ Remove `-lgcc` from `LDFLAGS`: I don't remember why it was there in the first place,
+ Add `-target i386-pc-none-eabi -m32 -mno-mmx -mno-sse -mno-sse2` to `CFLAGS`: the first two are to tell `clang` to cross-compile, the last three prevent it from assuming too much about our instruction set{% anecdote 11|it used SSE instructions to compile `printf`... %}.

Somewhere in the conversion process I learned that gcc also had ubsan support... No matter! Clang support brings something very very welcome: the possibility to test and develop SnowflakeOS without having to compile a cross-compiler{%anecdote 12|To be honest, I've never tried to compile SnowflakeOS with my system's gcc %}.

Using `clang` is now as simple as uncommenting the relevant lines in the main Makefile!

### UBSan

Enabling usbsan, on linux for instance, is as simple as adding `-fsanitize=undefined` to your compiler flags. When cross-compiling however, you can't do that, you need to implement its (thankfully compact) [runtime][ubsan runtime]. This runtime is just the collection of functions that'll get called when some type of undefined behavior is detected.  
A typical handler looks something like that:

```c
void __ubsan_handle_out_of_bounds(void* data, void* index) {
    ubsan_out_of_bounds_data_t* d = (ubsan_out_of_bounds_data_t*) data;
    printf("[ubsan] out of bounds at index %d\n", (uint32_t) index);
    ub_panic_at(&d->location, "out of bounds");
}
```

It instantly caught an out of bounds error in my keyboard driver, and the fact that my kernel stacks weren't aligned to 4 bytes, two pretty cool results. Also, it complained about `NULL` pointer dereferencing in my process loading code, which is fair enough, so I moved my userspace's entry point to `0x1000` for good measure{% anecdote 13|feeling more and more guilty about not having an ELF loader right now :/ %}. For what it's worth, you can get the structures and prototypes of whatever's missing from gcc's [source here][gcc ubsan].

## Apart from that...

### Paint

<figure>
    <img src="/assets/not-paint.png">
    <figcaption>Still not as glorious as the real thing, yes, but now with an icon</figcaption>
</figure>

I pushed some UI code I'd written at the beginning of summer to github, and rewrote the paint clone with it; this is close to the entirety of [its code][pisos]:

```c
ui_app_t paint = ui_app_new(win, fd ? icon : NULL);

vbox_t* vbox = vbox_new();
ui_set_root(paint, (widget_t*) vbox);

hbox_t* menu = hbox_new();
menu->widget.flags &= ~UI_EXPAND_VERTICAL;
menu->widget.bounds.h = 20;
vbox_add(vbox, (widget_t*) menu);

canvas = canvas_new();
vbox_add(vbox, (widget_t*) canvas);

for (uint32_t i = 0; i < sizeof(colors)/sizeof(colors[0]); i++) {
    color_button_t* cbutton = color_button_new(colors[i], &canvas->color);
    hbox_add(menu, (widget_t*) cbutton);
}

button_t* button = button_new("Clear");
button->on_click = on_clear_clicked;
hbox_add(menu, (widget_t*) button);

while (running) {
    ui_handle_input(paint, snow_get_event());
    ui_draw(paint);
    snow_render_window(win);
}
```

### Doom, a reality check

So, now that I had a some form of file support (who needs more than read/write anyway?), I thought trying a doom port was in my reach. I got it to compile easily enough, I got it to link pretty quickly too, I even managed to get it to run without crashing, but this is when I realized I didn't have the drive space to even store one `.iwad` file Doom requires. Anyway, the executable loops doing nothing at all, not even opening a window.

It was quite cool to confront my libc with a real-world use of a libc. I'm missing all of the `sprintf` family of functions, many file operations like `rename`, `remove`, `fseek`... but overall, it could be worse. Something that's getting pressing here is disk space. GRUB modules limit me to 4 MiB, my lack of png decoding makes just the background 2.3 MiB large, it's getting cramped in there. A disk driver will have to be attempted sooner rather than later.

Osdev work just never ends. It's the software version of gardening.

#### On that note...

I'll see you next time, hopefully talking about ELF loading and disk drivers and as many bugs as possible :)

[elegance]: https://github.com/29jm/SnowflakeOS/blob/3ec5e7113e425b6ff6b9e775f5d65ca545558f49/kernel/src/misc/ext2.c#L402-L508
[ext2 book]: http://www.nongnu.org/ext2-doc/ext2.html
[ext2 code]: https://github.com/29jm/SnowflakeOS/blob/3ec5e7113e425b6ff6b9e775f5d65ca545558f49/kernel/src/misc/ext2.c
[fs c]: https://github.com/29jm/SnowflakeOS/blob/3ec5e7113e425b6ff6b9e775f5d65ca545558f49/kernel/src/misc/ext2.c#L402-L508
[heisenbug a]: https://github.com/29jm/SnowflakeOS/commit/d120ecfcd3226c3fe74ac92b4267db608b3f7187
[heisenbug b]: https://github.com/29jm/SnowflakeOS/commit/bad19b3c081ed56d7127cda3276b0d18438d7dd6
[heisenbug c]: https://github.com/29jm/SnowflakeOS/commit/7cf702e74a2f697e97554a3c7a001792e2180bdf
[heisenbug d]: https://github.com/29jm/SnowflakeOS/commit/7cf702e74a2f697e97554a3c7a001792e2180bdf
[sys h]: https://github.com/29jm/SnowflakeOS/blob/21f066197e9d4a2b0c13b91393bd3ae060f7a6c3/kernel/include/kernel/sys.h#L24-L32
[ubsan gcc]: https://developers.redhat.com/blog/2014/10/16/gcc-undefined-behavior-sanitizer-ubsan/
[gcc ubsan]: https://github.com/gcc-mirror/gcc/blob/master/libsanitizer/ubsan/ubsan_handlers.h
[ubsan runtime]: https://github.com/29jm/SnowflakeOS/blob/5a0b82feb7c16e08778c5248f39127c18eecadcc/libc/src/ubsan.c
[pisos]: https://github.com/29jm/SnowflakeOS/blob/3ec5e7113e425b6ff6b9e775f5d65ca545558f49/modules/src/paint.c
[modules]: https://github.com/29jm/SnowflakeOS/commit/7d9494271329675e5f13a378012c58b301199cbd