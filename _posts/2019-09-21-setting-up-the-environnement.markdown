---
layout: post
title:  "Setting up the environnement"
author: 29jm
author_profile: false
tags: meta
---

## Gathering the dependencies

### Packages

I run Archlinux, so if you want to follow along you'll have to grab the corresponding 
packages for your distro.  
After cloning the repository, I installed the dependencies listed in the `README`

- `libisoburn`
- `mtools`
- `qemu`
- `grub`

### Cross-compiler

Things here get a bit hairier, but basically all that's needed is explained on OSDev's
wiki on [cross-compilation][osdev cross]. Still, I'll detail the process.

- export the following environnement variables:
{% highlight shell %}
export PREFIX="$HOME/opt/cross"
export TARGET=i686-elf
export PATH="$PREFIX/bin:$PATH"
{% endhighlight %}
- download the latest versions of [binutils][binutils] and [gcc][gcc]
- build them out-of-tree, with a clean outer directory:
{% highlight shell %}
./binutils-x.y.z/configure --target=$TARGET --prefix="$PREFIX" --with-sysroot --disable-nls --disable-werror
make
make install
{% endhighlight %}
and in another, clean directory above `gcc-x.y.z`,
{% highlight shell %}
./gcc-x.y.z/configure --target=$TARGET --prefix="$PREFIX" --disable-nls --enable-languages=c,c++ --without-headers
make all-gcc
make all-target-libgcc
make install-gcc
make install-target-libgcc
{% endhighlight %}
I recommend running `make` with at least `-j2`, otherwise compiling `gcc` might take long.
- Add `~/opt/cross/bin` to your path and you're set!
![gcc](/assets/gcc-ver.png)

### Compile & Run

All that's left to do is compiling the kernel and running it. You can do both in one command
with
{% highlight shell %}
./qemu.sh
{% endhighlight %}
![SnowflakeOS](/assets/sos-challenge.png)

I won't detail the build system too much; it was heavily inspired by the wiki's and that of other
hobby OSes. The gist of it is that `qemu.sh` calls `iso.sh` which in turn calls `build.sh`, and
that final script runs `make` for both the `kernel` and `libc` folders.

[osdev cross]: https://wiki.osdev.org/GCC_Cross-Compiler
[binutils]: https://www.gnu.org/software/binutils/
[gcc]: https://ftp.gnu.org/gnu/gcc/