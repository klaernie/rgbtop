# RGBtop

## What is RGBtop?

It is a simple esphome configuration and a perl script parsing the Linux CPU usage (`/proc/stat`).

For each CPU core found on the system the biggest usage class is determined
(was the core idle, waiting for IO, executing user code, etc).
Then one LED on the strip is set to a color determined by the usage class.

## Prototype notes

The configuration is just an example. Unless your ESP is exactly the same, and
your network offers DHCP-based DNS and runs on a subnet with IP 172.16.3.255 as
either the ESP's IP or a broadcast IP you will have to make changes.
Also I have not yet provided any systemd-unit files to start it automatically.
