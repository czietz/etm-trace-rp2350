# ETM instruction tracing for RP2350

Copyright (c) 2025 Christian Zietz

The ARM Cortex M33 cores inside the Raspberry Pi RP2350 microcontroller (found on the [Raspberry Pi Pico 2](https://www.raspberrypi.com/products/raspberry-pi-pico-2/) / Pico 2 W) have quite sophisticated capabilities to non-intrusively trace the execution of code. This is achieved via the ARM ETM (Embedded Trace Macrocell). The ARM ETM lets you record a history of what the processor was doing – like how it branched – without actually changing the behavior of your code. This is especially helpful for debugging. You can capture detailed execution data without inserting breakpoints or extra code that might alter timing or behavior. This means you’re seeing the system run as it normally would. The trace data provides a precise time-line of  executed instructions, which can help you pinpoint exactly where your  code might be misbehaving or diverging from expected behavior.

The script in this repository adds custom commands to GDB (the GNU debugger). They allow to configure everything required for instruction tracing: ETM, funnel, TPIU, DMA. The trace is stored in memory, can be downloaded with GDB, and analysed with tools such as [ptm2human](https://github.com/czietz/ptm2human/).

There is an option for “endless” tracing into a circular buffer. This permits capturing the last kilobytes of trace data until an exception or breakpoint is hit to reconstruct how program flow was immediately prior to the exception or breakpoint.

## Demo session

![Animated demo session](./img/demo4.gif)

## Prerequisites for use

* Hardware using the RP2350 microcontroller, such as the Raspberry Pi Pico 2 / Pico 2 W. The RP2040 – used on the original Pi Pico – does not contain the ETM hardware.
* An GDB and openocd setup for debugging, as described in Raspberry Pi’s [Getting started with Raspberry Pi Pico-series](https://datasheets.raspberrypi.com/pico/getting-started-with-pico.pdf) guide.

## Setup

Integrate the custom commands into your GDB session by running the GDB command `source trace.gdb`. You might also add this to your `.gdbinit` file.

No changes to your code are necessary. However, you must provide a memory buffer for the trace data and a DMA channel on the RP2350. The memory occupied by the buffer and the chosen DMA channel must not be used by your application. The address and size of the buffer and the DMA channel number can be configured with the `trc_setup`  command.

## Available commands

### trc_setup

Configure ETM tracing options.

Usage: `trc_setup [addr] [size] [dmachan] [ccount] [bbroadc] [formatter] [tstamp]`

Arguments are the address of the trace buffer in memory, the size of the buffer, the DMA channel number (0-15), whether to enable cycle counting (0/1), whether to enable branch broadcasting (0/1), whether to enable the TPIU formatter (0/1), whether to insert a timestamp every N cycles (0<N<65536, 0 to disable). Trailing arguments can be omitted. The options are applied during the next invocation of trc_start. Calling without arguments prints the current configuration.

Example: `trc_setup 0x20040000 4096`

### trc_start

Enable ETM and start tracing the current program.

Usage: `trc_start [endless]`

Continues the program being debugged. Execution will continue until a breakpoint or signal is hit, or Ctrl-C is pressed. An optional argument (0/1) specifies whether to enable endless tracing into a circular buffer. In case of endless tracing, the buffer must be 8/16/32 kiB and aligned to a multiple of its size. It’s also recommended to disable the TPIU formatter (see `trc_setup`) for endless tracing.

If endless tracing is disabled, tracing (but not execution) will stop as soon as the trace buffer is full.

Example: `trc_start`

### trc_save

Save ETM trace to a file.

Usage: `trc_save FILENAME`

Note that in endless tracing mode the filename is passed to the shell for processing. Be careful with untrusted input.

Example: `trc_save trace.bin`

## Notes

The default configuration is as follows:

* Trace buffer located at 0x2004_0000, the beginning of SRAM4.
* Trace buffer size 8 kiB.
* DMA channel number 12.
* Cycle counting disabled
* Branch broadcasting enabled.
* TPIU formatter enabled.
* Timestamp insertion disabled.

The trace data can be decoded with [ptm2human](https://github.com/czietz/ptm2human/). Be sure to use the `-e` (or `--decode-etmv4`) option. This fork of ptm2human has been adapted to the ARM Cortex M33. It also adds a new option `-n` (or `--unformatted`) to process traces that were captured while the TPIU formatter was disabled.

It is advisable to keep “branch broadcasting” enabled (in the `trc_setup` command). The trace then contains an address whenever a change in program flow occurs and is much easier to follow in the disassembly or debugger.

The Pico toolchain creates a disassembly (`*.dis`) of your project.

Instead of using a fixed memory address as trace buffer, you can also reserve space in your application, by adding a global variable, for example:

```c
uint32_t tracebuffer[2048];
```

Then, you can reference the buffer in GDB:

```
trc_setup tracebuffer sizeof(tracebuffer)
```

Depending on your program, you might be able get the number of an unclaimed DMA channel with the following command within GDB:

```
call dma_claim_unused_channel(0)
```

## References

* The [Raspberry Pi RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf) describes the available debug infrastructure and how to DMA the trace data into memory.
* The [Arm Embedded Trace Macrocell Architecture Specification ETMv4](https://developer.arm.com/documentation/ihi0064/latest/) describes the general functionality of the ETM. In particular, the chapters _Descriptions of Trace Elements_ and _Descriptions of Trace Protocols_ are helpful to better understand the ptm2human output.
* The [ARM CoreSight ETM-M33 Technical Reference Manual](https://developer.arm.com/documentation/100232/latest/) describes the specific implementation limits for ETM in the Cortex M33 cores.
* The [Arm CoreSight System-on-Chip SoC-600M Technical Reference Manual](https://developer.arm.com/documentation/100806/latest/) describes the funnel and TPIU (Trace Port Interface Unit) components.
