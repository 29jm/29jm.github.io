---
layout: post
title: "Taming memory allocators"
author: Johan Manuel
tags: development osdev hobby-os c
---

![Current state of the GUI](/assets/sos-spam.jpg){:class="thumbnail" title="This used to be a 17 MiB gif, it got shot down. Notice that window staying on top of all others?" }
Today I'll be writing about memory allocation, a fairly fundamental topic, perhaps one that most encounter faily early in their OS development journey. Yet I've only now started to really get into it, now that I feel like it's needed. And it turned out to be fun after all!

## The basics

I decided to take guidance from [this post][allocator blog] by Dmitry Soshnikov, implementing in this post only the basics, to get to a point at which I can freely call `kmalloc` and `kfree`, without throwing away too much memory. And perhaps `malloc` and `free` in userspace later?

There is some terminology to get down before diving into the details:

+ *memory allocator*: a function that a program can call that returns an address to which the program can freely write. Typically, `malloc`. Different allocators have different qualities, such as performance, minimizing memory fragmentation...
+ *memory block*: a contiguous range of memory addresses, with a few attributes such as whether it's in use or has been freed, its address and size... These attributes are stored in the block's *header*.
+ *alignment*: an address `addr` is said to be `N`-aligned if `addr % N == 0`. It's important for a kernel allocator to be able to allocate buffers with specific alignments, as we'll later see.

## Our previous allocator: now too simple

Previously, SnowflakeOS used what's called a *bump allocator*, i.e. an allocator that keeps track of the last block only, and that always allocates after that last block, with no means of freeing previous blocks individually.

I would've liked to keep that design as the implementation is concise and easy to understand, but unfortunately it's now too simple for my use. Not being able to reuse blocks is the deal breaker here, as the window manager will have to do a lot of small and short-lived allocations, and the goal is to not to run out of memory in five seconds.

The new allocator will have to keep one feature from its predecessor, the ability to hand out addresses with a specific alignment. This is strictly needed, as we need to be able to remap a newly acquired page from our allocator, and pages boundaries are multiples of 4 KiB. See for instance [this use case][term remap].

## The new allocator

We'll write a *first-fit* memory allocator that can deliver arbitrarily-aligned addresses. You can find the whole source [here][mem.c], and an updated version for the end of this post [here][malloc.c].

First, our blocks are defined by the following struct. The first two members constitute the header:
```c
typedef struct _mem_block_t {
    struct _mem_block_t* next;
    uint32_t size; // We use the last bit as a 'used' flag
    uint8_t data[];
} mem_block_t;
```
That last member is what's called a "flexible array member" in C99. It's an array without a given dimension, i.e. we can manage its size manually by saying "I know that the memory after this struct is mine, let me access it though this member". Here, it'll be the pointer returned by our `kmalloc` function.

And secondly, we use a simple first-fit design, i.e. when allocating something, we first look through our list of blocks and see if there's a free one that fits our criteria of size and alignment. The global algorithm is as follows:
```c
void* kamalloc(uint32_t size, uint32_t align) {
    size = align_to(size, 8);

    mem_block_t* block = mem_find_block(size, align);

    if (block) {
        block->size |= 1; // Mark it as used
        return block->data;
    } else {
        block = mem_new_block(size, align);
    }

    if ((uintptr_t) block->data > KERNEL_HEAP_BEGIN + KERNEL_HEAP_SIZE) {
        printf("[MEM] The kernel ran out of memory!");
        abort();
    }

    return block->data;
}
```
And the "first-fit" logic is implemented in `mem_find_block` here, in no particular magic:
```c
mem_block_t* mem_find_block(uint32_t size, uint32_t align) {
    if (!bottom) {
        return NULL;
    }

    mem_block_t* block = bottom;

    while (block->size < size || block->size & 1 || !mem_is_aligned(block, align)) {
        block = block->next;

        if (!block) {
            return NULL;
        }
    }

    return block;
}
```

The load-bearing portion of our allocator is in the creation of blocks, in `mem_new_block`:
```c
mem_block_t* mem_new_block(uint32_t size, uint32_t align) {
    const uint32_t header_size = offsetof(mem_block_t, data);

    // We start the heap right where the first allocation works
    if (!top) {
        uintptr_t addr = align_to(KERNEL_HEAP_BEGIN+header_size, align) - header_size;
        bottom = (mem_block_t*) addr;
        top = bottom;
        top->size = size | 1;
        top->next = NULL;

        return top;
    }

    // I did the math and we always have next_aligned >= next.
    uintptr_t next = (uintptr_t) top + mem_block_size(top);
    uintptr_t next_aligned = align_to(next+header_size, align) - header_size;

    mem_block_t* block = (mem_block_t*) next_aligned;
    block->size = size | 1;
    block->next = NULL;

    // Insert a free block between top and our aligned block, if there's enough
    // space. That block is 8-bytes aligned.
    next = align_to(next+header_size, MIN_ALIGN) - header_size;
    if (next_aligned - next > sizeof(mem_block_t) + MIN_ALIGN) {
        mem_block_t* filler = (mem_block_t*) next;
        filler->size = next_aligned - next - sizeof(mem_block_t);
        top->next = filler;
        top = filler;
    }

    top->next = block;
    top = block;

    return block;
}
```
Notice that second `if`: as we want to support arbitrary alignment of the blocks we hand out, we want to prevent space from being wasted in between blocks, so unused blocks will be created to fill the gaps as they appear. For instance, imagine the heap is at 0x40, and a 0x1000-aligned block is requested. Then a gap of about `0x1000-0x40=0xFC0` bytes will be created between the first block and the new one. We'll create a block there with minimum alignment to fill the gap.

Note that the pages that consitute the memory we'll be distributing are already mapped in the kernel. That way the kernel can allocate after starting to execute in multiple page directories, without having to mirror the paging changes in each process. This is where the preallocation is done in [paging.c][paging]:
```c
    // Setup the kernel heap
    heap = KERNEL_HEAP_BEGIN;
    uintptr_t heap_phys = pmm_alloc_pages(KERNEL_HEAP_SIZE/0x1000);
    paging_map_pages(KERNEL_HEAP_BEGIN, heap_phys, KERNEL_HEAP_SIZE/0x1000, PAGE_RW);
```

## Think of the (userspace) children!

### Porting the allocator to userspace

Sure, the kernel and its window manager are what will be stressing memory the most for a while, and we could get away with keeping a bump allocator for our userspace `malloc`. That memory is freed on exit anyway. But where's the fun in that? Can't we adapt our code so that it works in both the kernel and in userspace?

Of course we can. We already have a build-level mechanism for that with our C library, which is built twice: once for the kernel with the `_KERNEL_` preprocessor symbol defined, and a second time for userspace.

There are two things that we'll have to adapt for userspace:
1. Our allocated blocks will now live after our program in memory, i.e. at `sbrk(0)`, and not after our kernel executable.
2. Whereas the kernel has its whole memory pool preallocated, that makes no sense for userspace, so we'll have to call `sbrk` regularly to ask the kernel for more memory.

To address the first point, I added the following bit of code to the beginning of `malloc`:
```c
    // If this is the first allocation, setup the block list:
    // it starts with an empty, used block, in order to avoid edge cases.
    if (!top) {
        const uint32_t header_size = offsetof(mem_block_t, data);

#ifdef _KERNEL_
        uintptr_t addr = KERNEL_HEAP_BEGIN;
#else
        uintptr_t addr = (uintptr_t) sbrk(header_size);
#endif
        bottom = (mem_block_t*) addr;
        top = bottom;
        top->size = 1; // That means used, of size 0
        top->next = NULL;
    }
```

And to address the second point, I added this distinction before calling `mem_new_block`:
```c
        // We'll have to allocate a new block, so we check if we haven't
        // exceeded the memory we can distribute.
        uintptr_t end = (uintptr_t) top + mem_block_size(top) + header_size, align;
        end = align_to(end, align) + size;
#ifdef _KERNEL_
        // The kernel can't allocate more
        if (end > KERNEL_HEAP_BEGIN + KERNEL_HEAP_SIZE) {
            printf("[MEM] The kernel ran out of memory!");
            abort();
        }
#else
        // But userspace can ask the kernel for more
        uintptr_t brk = (uintptr_t) sbrk(0);
        if (end > brk) {
            sbrk(end - brk);
        }
#endif

        block = mem_new_block(size, align);
```

### Testing it

<video controls>
  <source src="/assets/spam-win.mp4" type="video/mp4">
</video>

To test that new `malloc`, I made [a program][stress tester] to open and close windows continually while keeping the number of windows constant, which you can see in action above.

To be somewhat scientific, I counted the number of calls to `sbrk`. If everything was right, this program would call it a few times, then blocks would be reused *ad infinitum*.

And it did! With 20 windows, I counted 69 `sbrk`s, and no signs of more coming up even after five minutes of frenetic window respawning.

### A point on kernel/userspace interactions

It may not be clear what the code paths are for the userspace version of `malloc`, so I'll detail them a bit.

When a program calls `malloc`, execution stays in userspace, because the allocator is in the C library linked to it, along with everything else. If `malloc`'s memory pool needs expansion (i.e. there's no room to add a free block), the `sbrk` system call is run, and execution jumps [in the kernel][sbrk]. That system call maps pages as needed to expand the heap of the program. The process of mapping those pages may itself involve [allocating memory][paging alloc] for the kernel to create new page tables, but in this case, the kernel calls `pmm_alloc_page` to get a fresh page of physical memory directly, so `kmalloc` is never involved.

It would have been pretty neat to have `malloc` call `kmalloc`, wouldn't it? I like the idea of a piece of code calling another compilation of itself, anyway.

This is what `putchar` does, so at least such cross-source calling goodness is done somewhere. A call to `putchar` in userspace translates to the `putchar` [system call][putchar syscall] which calls the kernel version of `putchar`, which is about two lines above the first call in the [source][putchar.c]:
```c
int putchar(int c) {
#ifdef _KERNEL_
    term_putchar(c);
    serial_write((char) c);
#else
    asm (
        "mov $3, %%eax\n"
        "mov %[c], %%ecx\n"
        "int $0x30\n" // Syscall
        :: [c] "r" (c)
        : "%eax"
    );
#endif
    return c;
}
```
Neat.

## Miscellaneous bugs crushed since last time

### A scrambled 'w'

When I first tested my new kernel allocator, it seemed to work fine except for one detail. The 'w' of "SnowflakeOS" in the top left corner of the background and in the title bar of my window looked all wrong:

![scrambled w](/assets/scrambled_w.png)

And only when compiling without the nice blue background and identity mapping more pages than needed at the beginning of memory. Which I did then, otherwise I perhaps wouldn't have spotted this bug.

I fixed it in [this commit][commit w], basically by paying attention to where my GRUB modules (i.e. my programs) were in memory, and protecting that memory. Indeed, those modules were loaded right after my kernel in memory, and guess what I used that area for? The bitmap of my physical memory manager. That's not a story a James Molloy would tell you<sup>[<a href="" title="I owe much to his tutorials <3">1</a>]</sup>.

Now I check exactly where my modules end and place my physical memory manager after that, and I identity map exactly the right number of pages to be able to copy the modules into kernel memory.

### Classic windows

The gif at the top of this post looks somewhat okay, but it took some effort. Basically, I wanted a program that spawned `N` windows then closed the oldest ones and replaced them, in a loop. The first iteration of that popup-spamming program would either spawn +oo windows, or spawn `N` windows then get stuck in an infinite loop somewhere.

The problem, explained in [this commit][commit win], was that I had failed to maintain the integrity of my doubly linked list of windows when deleting an element, and the list turned into a circular list when traversed backwards, leading to an infinite loop in `wm_count_windows`.

## Till next time

That's it for this post, which is already far too long, too late and all over the place.  
Thank you for reading till the end!

[allocator blog]: http://dmitrysoshnikov.com/compilers/writing-a-memory-allocator/
[term remap]: https://github.com/29jm/SnowflakeOS/blob/132529e3bec0855597b769510ececd3f9213a8a9/kernel/src/devices/term.c#L53-L55
[paging]: https://github.com/29jm/SnowflakeOS/blob/132529e3bec0855597b769510ececd3f9213a8a9/kernel/src/mem/paging.c#L38-L41
[sbrk]: https://github.com/29jm/SnowflakeOS/blob/132529e3bec0855597b769510ececd3f9213a8a9/kernel/src/sys/proc.c#L278-L320
[paging alloc]: https://github.com/29jm/SnowflakeOS/blob/132529e3bec0855597b769510ececd3f9213a8a9/kernel/src/mem/paging.c#L68
[putchar syscall]: https://github.com/29jm/SnowflakeOS/blob/132529e3bec0855597b769510ececd3f9213a8a9/kernel/src/sys/syscall.c#L74
[putchar.c]: https://github.com/29jm/SnowflakeOS/blob/132529e3bec0855597b769510ececd3f9213a8a9/libc/src/stdio/putchar.c
[commit w]: https://github.com/29jm/SnowflakeOS/commit/ca7fedf2468319ecbeb503cf67d1031f2f5cb622
[commit win]: https://github.com/29jm/SnowflakeOS/commit/c16b531d3073cc15d5a9ccdcf0bbc70186c1d755
[mem.c]: https://github.com/29jm/SnowflakeOS/blob/3433a8c4abcc9a3193813b940882558ff623875d/kernel/src/mem/mem.c
[malloc.c]: https://github.com/29jm/SnowflakeOS/blob/132529e3bec0855597b769510ececd3f9213a8a9/libc/src/stdlib/malloc.c
[stress tester]: https://github.com/29jm/SnowflakeOS/blob/132529e3bec0855597b769510ececd3f9213a8a9/modules/src/test.c