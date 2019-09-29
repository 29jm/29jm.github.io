---
---

# SnowflakeOS - Challenge Edition

## Objectives

The stated goals of development this year are the following:

- Displaying a basic user interface
- Being able to run a simple graphical program, such as a clock.
- Document my progress
- Create learning resources and improve existing ones

That makes only two technical goals, but they aren't the easy kind. Here is a non-exhaustive list of required features to complete those goals:

- Being able to run programs in usermode
- Task switching
- System calls from userspace
- Program loading
- 2D graphics library
- GUI toolkit

Note that I don't intend to have the best scheduler, the best GUI, or great performance: they will likely be terrible; but I want to have working versions of them, and to be able to show something working by June 2020.

## Journal - the interesting part

I keep track of my progress through regular posts, listed here from oldest to newest:

<ul>
  {% assign sorted = (site.posts | sort: 'date') %}
  {% for post in sorted %}
    <li>
      <a href="{{ post.url }}">{{ post.title }}</a>
    </li>
  {% endfor %}
</ul>
