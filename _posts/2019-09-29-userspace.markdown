---
layout: post
title: "Getting to userspace - and back !"
author: Johan Manuel
tags: development
---

Before now, SnowflakeOS ran entirely in kernel mode, or `ring 0`. Now, the time has come for it to move on to better places, those of userland, also called `ring 3`.  
The transition to having processes roam free in `ring 3` was mostly made in the series of commits from [here][commit a] to [there][commit b], and I encourage readers to check them all out.

![Userspace !](/assets/userspace.png)

## What's a process, anyway?

Well, as of right now, a process is described by the following structure:

{% highlight c %}
typedef struct _proc_t {
    struct _proc_t* next;
    uint32_t pid;
    // Length of program memory in number of pages
    uint32_t stack_len;
    uint32_t code_len;
    uintptr_t directory;
    uintptr_t kernel_stack;
    registers_t registers;
} process_t;
{% endhighlight %}

I'll explain. A process consists of executable code, a stack, and an execution
context. And another stack for execution in the kernel, I'll get back to it.  
The executable code along with the stack is stored in physical memory somewhere,
of course, but it needs to be mapped through paging to be accessible (if only to
write the code to the physical page!), so what we store is a page directory. It
maps addresses `0x00000000+` to the pages containing our code, and addresses
below our kernel to our stack pages. It also maps the kernel exactly as the
initial kernel page directory did; it's a copy. Notice that once the code is
copied to physical memory, the page directory suffices to reference it; physical
memory never moves. We only keep track of the size occupied by the code and stack,
though I haven't made these things dynamic yet, both are 4 MiB pages.

The execution context consists of basically one thing: the process's registers, to
the surprise of no one who's written assembly before. Indeed, registers do not
only include working registers like `eax` et al, there's also `eip` storing the
address of the next instruction to be executed, `esp` storing the stack pointer,
`eflags`... The page directory can be considered context too, as it
may hold dynamically allocated memory (not yet implemented).

## Let's switch to it

With that said, starting a process in usermode is simply a matter of switching to
a correctly setup page directory, and pointing `eip` and `esp` to the right place!
And resuming an interrupted process is the same, but restoring registers beforehand.  
[Edit: this was a pretty poor way of resuming a process, see [the next post][next]
for a better one]

The way to do these things is a bit convoluted though, as we need to `iret` (aka
interrupt return) to our code, we can't just jump to it, the reason being that we
need to change privilege level (from 0 to 3):

{% highlight c %}
asm volatile (
    "push $0x23\n"    // user ds selector
    "mov %0, %%eax\n"
    "push %%eax\n"    // %esp
    "push $512\n"     // %eflags with 9th bit set to allow calling interrupts
    "push $0x1B\n"    // user cs selector
    "mov %1, %%eax\n"
    "push %%eax\n"    // %eip
    "iret\n"
    :                 /* read registers: none */
    : "r" (esp_val), "r" (eip_val) /* inputs %0 and %1 stored anywhere */
    : "%eax"          /* registers clobbered by hand in there */
);
{% endhighlight %}

## Getting control back

How do we get back to kernel mode execution once we've made the jump? The
answer is twofold: through syscalls and scheduling - interrupts in both cases.
Because right now scheduling is handled though syscalls in SnowflakeOS, I'll
describe only those. In our kernel, calling `int $48` with `eax` set to `n`
triggers the `n`th interrupt: process execution stops, privilege changes to 0 and
execution then resumes in the syscall handler. Because the kernel is mapped into
our process's address space, no page directory switch is needed here. However, one
thing needs to be changed, and it's the stack: we can't just pollute the process's
stack, and `x86` gives us (forces us to use) a mechanism to switch stack as part
of the jump to ring 0. So what's usually done, and what I did is allocating
memory for a kernel stack per process, and before switching to the execution of
that process, setting the "stack-to-be-switched-to" variable (in the `TSS`, a `GDT`
entry) to that stack.

Right now syscall `0` is `yield`, and it switches execution to the process pointed
to by the `next` pointer in the `process_t` structure. It's cooperative
multitasking, preemptive will come later.

## Collateral damage

### kmalloc is dead, hail the new kmalloc

In the process of implementing that, I got rid of `liballoc` and replaced it with
a dead-simple mechanism: I now map a certain zone after the kernel, and `kmalloc`
advances a pointer through it with each allocation. Sure, it doesn't allow freeing
memory, but it has a great advantage: the previous `kmalloc` needed to modify
kernel page tables dynamically, and those changes aren't automatically reflected
across all copies of the initial page directory! It's important because when
context switches, for instance while in kernel mode, the previous kernel stack
must remain mapped, as there are no stack switches when privilege level doesn't
change.

I'll reintroduce a cool allocator with the userspace `libc`, the kernel
will stay simple and only grant pages at at time to processes. I'm not sure how
I'll distribute the virtual address space, in fact, I'll have to think about it.
Same way I did the kernel heap, probably, but right in the middle of
`0x0-0xC0000000`.

### Implementing useful system calls

The real fun begins now that things are in working order: syscalls!  
I started with `yield` to get started with multitasking, and quickly implemented
`exit`, though testing that last one took a while: I've spent hours debugging 
assembly in in Bochs to get `yield` to work.

Only then, I started implementing a `putchar` syscall. First, I needed to make my
TTY work in processes, which involved mapping it somewhere; I decided to put it
[in my kernel heap][tty remap]. Tada, I can print again! I should have started
by doing that, it would have made a lot of debugging easier; but then again I've
learned __a lot__ of assembly without it. Implementing the syscall was trivial
after that, and I was able to get my first "Hello world" from userspace.  
I tried my hand at a `wait` syscall to pause a process for some time, but I
approached it the wrong way, or at least in a way that Bochs liked, but QEMU did
not: waiting for time to pass in the syscall handler. In QEMU, timer interrupts
don't trigger then, so time never passes :( I'll get back to it from a scheduler
perspective.

[commit a]: https://github.com/29jm/SnowflakeOS/commit/a0af7081f44b3c746e661f1e5488ccb06073fa5a
[commit b]: https://github.com/29jm/SnowflakeOS/commit/3ed963cc8847f6ed92ac83c5220190600131f2c3
[next]: /2019/10/06/switches-and-knobs.html
[tty remap]: https://github.com/29jm/SnowflakeOS/blob/36fc37d92dac7e248fb2863ba09a80813ff0e5d5/kernel/src/mem/paging.c#L41-L48