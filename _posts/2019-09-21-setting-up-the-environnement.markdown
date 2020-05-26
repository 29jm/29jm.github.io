---
layout: post
title: "Setting up the environnement"
author: Johan Manuel
tags: meta
---

The very first step to working on SnowflakeOS again was to setup the environment: download the sources and the tools to build them. Here's a quick rundown.

## Gathering the dependencies

### Packages

I run Archlinux, so if you want to follow along you'll have to grab the corresponding 
packages for your distro.  
After cloning the repository, I installed the dependencies listed in the `README`:

- `libisoburn`
- `mtools`
- `qemu`
- `grub`

### Cross-compiler

Things here get a bit hairier, but basically all that's needed is explained on OSDev's
wiki on [cross-compilation][osdev cross]. Still, I'll detail the process.

- export the following environnement variables:
```shell
export PREFIX="$HOME/opt/cross"
export TARGET=i686-elf
export PATH="$PREFIX/bin:$PATH"
```
- download the latest versions of [binutils][binutils] and [gcc][gcc]
- build them out-of-tree, with a clean outer directory:
```shell
./binutils-x.y.z/configure --target=$TARGET --prefix="$PREFIX" --with-sysroot --disable-nls --disable-werror
make
make install
```
and in another, clean directory above `gcc-x.y.z`,
```shell
./gcc-x.y.z/configure --target=$TARGET --prefix="$PREFIX" --disable-nls --enable-languages=c,c++ --without-headers
make all-gcc
make all-target-libgcc
make install-gcc
make install-target-libgcc
```
I recommend running `make` with at least `-j2`, otherwise compiling `gcc` might take long.
- Add `~/opt/cross/bin` to your path and you're set!
![gcc](/assets/gcc-ver.png)

### Compile & Run

*Updated on 19/12/19 to match the new buildsystem*

All that's left to do is compiling the kernel and running it. You can do both in one command
with
```shell
make qemu
```
![SnowflakeOS](/assets/sos-challenge.png)

I won't detail the build system too much; it was heavily inspired by the wiki's and that of other hobby OSes.  
The gist of it is that submakefiles are called first to copy their headers to an LFS-looking environment (the *sysroot* directory), and then in a second pass to build their respective projects and copy binaries, while respecting the dependencies listed in the root Makefile.

[osdev cross]: https://wiki.osdev.org/GCC_Cross-Compiler
[binutils]: https://www.gnu.org/software/binutils/
[gcc]: https://ftp.gnu.org/gnu/gcc/