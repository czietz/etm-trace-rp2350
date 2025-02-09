# ETM instruction tracing for RP2350
# Copyright (c) 2025 Christian Zietz

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

# buffer address for trace data in SRAM
set $trc_bufaddr = 0x20040000
# buffer size, must be a multiple of 4 bytes
set $trc_bufsize = 8192
# DMA channel, must not be used by application
set $trc_dmachan = 12
# whether to include cycle counts in trace, gives a bigger trace
set $trc_ccount = 0
# whether to enable 'branch broadcast' mode, gives a better but bigger trace
set $trc_bbroadc = 1
# whether to enable formatter, required for decoding multiplexed streams
set $trc_formatter = 1
# insert timestamp every N cycles (0 to disable)
set $trc_tstamp = 0

# allow to redefine the parameters at runtime
define trc_setup

  if $argc == 0
    printf "Trace buffer address: %p\n", $trc_bufaddr
    printf "Trace buffer size: %d bytes\n", $trc_bufsize
    printf "DMA channel: %d\n", $trc_dmachan
    printf "Cycle counting: %d\n", $trc_ccount
    printf "Branch broadcasting: %d\n", $trc_bbroadc
    printf "Formatter: %d\n", $trc_formatter
    printf "Timestamping: %d\n", $trc_tstamp
  end

  if $argc > 0
    set $trc_bufaddr = $arg0
  end

  if $argc > 1
    set $trc_bufsize = $arg1
  end

  if $argc > 2
    set $trc_dmachan = $arg2
  end

  if $argc > 3
    set $trc_ccount = $arg3
  end

  if $argc > 4
    set $trc_bbroadc = $arg4
  end

  if $argc > 5
    set $trc_formatter = $arg5
  end

  if $argc > 6
    set $trc_tstamp = $arg6
  end

end

# main function: setup tracing and continue program
define trc_start
  dont-repeat

  ## optionally support endless tracing into a circular buffer
  if $argc > 0
    set $trc__endless = $arg0
  else
    set $trc__endless = 0
  end

  ## tracing into circular buffer imposes restrictions on buffer
  if $trc__endless

    # gdb has no function to calculate log2 of size
    if $trc_bufsize == 8192
      set $trc__endless = 13
    else
    if $trc_bufsize == 16384
      set $trc__endless = 14
    else
    if $trc_bufsize == 32768
      set $trc__endless = 15
    else
      printf "Endless tracing requires 8/16/32 kiB buffer (bufsize=%d)\n", $trc_bufsize
      printf "Switching to regular tracing.\n"
      set $trc__endless = 0
    end
    end
    end

    if ($trc_bufaddr & ($trc_bufsize-1)) != 0
      printf "Endless tracing requires %d kiB alignment of buffer (bufaddr=%p)\n", $trc_bufsize/1024, $trc_bufaddr
      printf "Switching to regular tracing.\n"
      set $trc__endless = 0
    end

  end

  ## stop DMA if it was left running
  set {long}0x50000464 = 1<<($trc_dmachan&15)
  while ({long}0x50000464)
  end

  ## stop ETM if it was running
  set $trc__etm = 0xe0041000
  # trcprgctlr = 0: stop the tracing
  set {long}($trc__etm+0x004) = 0
  # wait until trcstatr.idle is set
  while !(({long}($trc__etm+0x00c)) & 1)
  end

  ## clear trace memory
  eval "monitor mww %d 0 %d", $trc_bufaddr, $trc_bufsize/4
  
  ## setup timestamp generator and reset count value
  # stop
  set {long}0x40146000 = 0
  # reset counter
  set {long}0x40146008 = 0
  set {long}0x4014600c = 0
  # start
  set {long}0x40146000 = 3

  ## setup funnel: bit 1 is Core0 ETM, bit3 is Core1 ETM
  # read CPUID to determine core
  set $trc__cpuid = {long}0xd0000000
  if $trc__cpuid == 1
    set {long}0x40147000 = 1<<3
  else
    set {long}0x40147000 = 1<<1
  end

  ## setup TPIU (trace port interface unit) to dump into DMA FIFO
  set $trc__tpiu = 0x40148000
  # FFCR: formatter on/off, manual flush and stop on flush
  set {long}($trc__tpiu+0x304) = (1<<12) | (1<<6) | ($trc_formatter&1)
  # FFSR: wait while flush is in progress
  while ({long}($trc__tpiu+0x300)) & 1
  end
  # CSPSR: configure for 32-bit wide output
  set {long}($trc__tpiu+0x004) = 0x80000000
  # FFCR: formatter on/off
  set {long}($trc__tpiu+0x304) = ($trc_formatter&1)

  ## setup RP2350 DMA
  set $trc__dma = 0x50000000 + (0x40*($trc_dmachan&15))
  # coresight_trace: allow DMA access
  set {long}(0x40060058) = {long}(0x40060058) | (1<<6) | 0xACCE0000
  # keep TPIU FIFO flushed
  set {long}(0x50700000) = 1
  # set DMA read address to TPIU FIFO
  set {long}($trc__dma+0x00) = 0x50700004
  # set DMA write address to buffer
  set {long}($trc__dma+0x04) = $trc_bufaddr
  if $trc__endless == 0
    # set DMA transfer count in words
    set {long}($trc__dma+0x08) = $trc_bufsize/4
    # setup DMA: DREQ 53 (Coresight), write increment, 32 bit data size, enable, and trigger
    set {long}($trc__dma+0x0c) = (53<<17) | (1<<6) | (2<<2) | 1
  else
    # set DMA to endless mode
    set {long}($trc__dma+0x08) = 0xFFFFFFFF
    # setup DMA: DREQ 53 (Coresight), ring mode on write, write increment, 32 bit data size, enable, and trigger
    set {long}($trc__dma+0x0c) = (53<<17) | (1<<12) | ($trc__endless<<8) | (1<<6) | (2<<2) | 1
  end
  # start TPIU FIFO and clear overflow flag
  set {long}(0x50700000) = 2

  ## setup ETM: note that it needs to be stopped, which happened above
  # trcconfigr = branch broadcasting, cycle counting, timestamping
  set {long}($trc__etm+0x010) = ($trc_bbroadc&1)<<3 | ($trc_ccount&1)<<4 | (($trc_tstamp>0)<<11)
  # trceventctl0r = trceventctl1r = 0: disable all event tracing
  set {long}($trc__etm+0x020) = 0
  set {long}($trc__etm+0x024) = 0
  # trcstallctlr = 0: disable stalling of CPU
  set {long}($trc__etm+0x02c) = 0
  # trccntrldvr0: set counter reload value
  set {long}($trc__etm+0x140) = $trc_tstamp
  # trcrsctlr2: resource selection for event 2: counter at zero
  set {long}($trc__etm+0x208) = (2<<16) | 1
  if $trc_tstamp>0
    # trctsctlr = 2: timestamp on event 2
    set {long}($trc__etm+0x030) = 2
  else
    # trctsctlr = 0: disable timestamp event
    set {long}($trc__etm+0x030) = 0
  end
  # trctraceidr = 0x01: set trace ID (note: seems not to be documented on RP2350?)
  set {long}($trc__etm+0x040) = $trc__cpuid + 1
  # trcccctlr = 0: no threshold between cycle-count packets
  set {long}($trc__etm+0x038) = 0
  # trcvictlr = 0x01: select the always on logic and start the start-stop logic
  set {long}($trc__etm+0x080) = (1<<9) | 0x01
  # trcprgctlr = 1: start the tracing
  set {long}($trc__etm+0x004) = 1

  # run program
  cont
end

# save trace result
define trc_save
  dont-repeat

  # flush remaining data from formatter
  set $trc__tpiu = 0x40148000
  # FFCR: formatter on/off, manual flush and stop on flush
  set {long}($trc__tpiu+0x304) = (1<<12) | (1<<6) | ($trc_formatter&1)
  # FFSR: wait while flush is in progress
  while ({long}($trc__tpiu+0x300)) & 1
  end
  
  if $trc__endless == 0
    dump binary memory $arg0 $trc_bufaddr $trc_bufaddr+$trc_bufsize
  else
    # circular buffer: the next address the DMA would write to
    set $trc__bufsplit = {long}($trc__dma+0x04)
    # first/older part of the buffer
    dump binary memory _tempdump1.bin $trc__bufsplit $trc_bufaddr+$trc_bufsize
    # second/newer part of the buffer
    dump binary memory _tempdump2.bin $trc_bufaddr $trc__bufsplit
    # join together
    shell cat _tempdump1.bin _tempdump2.bin > $arg0
    shell rm _tempdump1.bin _tempdump2.bin
  end
end

# documentation aka help texts
document trc_setup
Configure ETM tracing options.
Usage: trc_setup [addr] [size] [dmachan] [ccount] [bbroadc] [formatter] [tstamp]

Arguments are the address of the trace buffer in memory, the size of
the buffer, the DMA channel number (0-15), whether to enable cycle
counting (0/1), whether to enable branch broadcasting (0/1), whether
to enable the TPIU formatter (0/1), whether to insert a timestamp every
N cycles (0<N<65536, 0 to disable). Trailing arguments can be omitted.
The options are applied during the next invocation of trc_start.
Calling without arguments prints the current configuration.

Example: trc_setup 0x20040000 4096
end

document trc_start
Enable ETM and start tracing the current program.
Usage: trc_start [endless]

Continues the program being debugged. Execution will continue until
a breakpoint or signal is hit, or Ctrl-C is pressed. An optional
argument (0/1) specifies whether to enable endless tracing into a
circular buffer. In case of endless tracing, the buffer must be 8/16/32
kiB and aligned to a multiple of its size. It's also recommended to
disable the TPIU formatter (see trc_setup) for endless tracing.

If endless tracing is disabled, tracing (but not execution) will stop
as soon as the trace buffer is full.

Example: trc_start
end

document trc_save
Save ETM trace to a file.
Usage: trc_save FILENAME

Note that in endless tracing mode the filename is passed to the shell
for processing. Be careful with untrusted input.

Example: trc_save trace.bin
end
