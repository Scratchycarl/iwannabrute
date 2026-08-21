<h1 align="center">iwannabrute</h1>
<p align="center">
Bruteforce A4-A6 numeric password with ease.
</p>

# Prerequisites

1. A computer running macOS.
2. A compatible device (see below).
3. A4 devices also need an **Intel Mac** (`x86_64`). iPad 1 ramdisk builds need Xcode Command Line Tools (`clang++`).

# Compatible devices

Use the **A4** branch for all verified A4 devices:

| Device | Identifier | iOS |
| ------------ | ------------ | ------------ |
| iPhone 4 (GSM, Rev A) | iPhone3,2 | 7.1.2 |
| iPod touch 4 | iPod4,1 | 6.1.6 |
| iPad 1 | iPad1,1 | 5.1.1 |

A5–A6 devices continue to use the original ramdisk path on `2.0` / `main`.

# Usage
iwannabrute needs initial setup before usage.
 - Homebrew: `brew install bash curl libusb`
 - MacPorts: `sudo port install bash curl libusb`
 - For macOS 12.7.6 and lower, use MacPorts, not Homebrew.
 
1. Clone and cd into this repository: `git clone https://github.com/platinumstufff/iwannabrute --recursive && cd iwannabrute`
2. Place your device into DFU mode
3. Run `./start.sh`

On iPad 1, passcode checking shows only the method and range (`Bruteforcing using Keystore.` / `Checking 0000 to 9999.`), then the found passcode in large green digits. If Keystore does not find a 4-digit code, it falls back to userland derivation.

# Estimated bruteforce time

| Passcode length | Finish time (80 ms/p) | 30 ms/p |
| ------------ | ------------ | ------------ |
4-digit |13 minutes |5 minutes
5-digit |2 hours |50 minutes
6-digit |22 hours |8 hours
7-digit |9 days |3.5 days
8-digit |92 days |35 days

The tool will use the AES engine as much as possible with no restrictions at the full speed. 80 milliseconds is a value that Apple uses to calibrate it's software to this day.

# Soon™

- Linux support
- Disable password automatically

# Other Stuff

- [Reddit Post](https://www.reddit.com/r/setupapp/comments/1jn09d5/release_iwannabrute_bruteforce_a5a6_with_ease/)

# Credits
- [AJAIZ](https://github.com/AsyJAIZ) for original bruteforce method.
- [mewcat454](https://www.reddit.com/u/meowcat454) for original ramdisk.
- [Nathan](https://github.com/verygenericname) for some code from SSHRD_Script.
- [LukeeZGD](https://github.com/LukeZGD) for a lot code.
- [Scratchycarl](https://github.com/Scratchycarl) for verified A4 iPad 1 support.
- And anyone else I forgot to mention.
