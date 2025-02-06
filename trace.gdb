# buffer address for trace data in SRAM
set $trc_bufaddr = 0x20040000
# buffer size, must be a multiple of 4 bytes
set $trc_bufsize = 512*4
# DMA channel, must not be used by application
set $trc_dmachan = 12
# whether to include cycle counts in trace, gives a bigger trace
set $trc_ccount = 0
# whether to enable 'branch broadcast' mode, gives a better but bigger trace
set $trc_bbroadc = 1
# whether to enable formatter, required for decoding multiplexed streams
set $trc_formatter = 1

# allow to redefine the parameters at runtime
define trc_setup

  if $argc == 0
    printf "Trace buffer address: %p\n", $trc_bufaddr
    printf "Trace buffer size: %d bytes\n", $trc_bufsize
    printf "DMA channel: %d\n", $trc_dmachan
    printf "Cycle counting: %d\n", $trc_ccount
    printf "Branch broadcasting: %d\n", $trc_bbroadc
    printf "Formatter: %d\n", $trc_formatter
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


end

# main function: setup tracing and continue program
define trc_start
  dont-repeat

  ## stop ETM if it was running
  set $trc__etm = 0xe0041000
  # trcprgctlr = 0: stop the tracing
  set {long}($trc__etm+0x004) = 0
  # wait until trcstatr.idle is set
  while !(({long}($trc__etm+0x00c)) & 1)
  end

  ## clear trace memory
  eval "monitor mww %d 0 %d", $trc_bufaddr, $trc_bufsize/4
  
  ## setup timestamp generator (though it is not used by default)
  set {long}0x40146000 = 1

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
  # set DMA transfer count in words
  set {long}($trc__dma+0x08) = $trc_bufsize/4
  # setup DMA: DREQ 53 (Coresight), write increment, 32 bit data size, enable, and trigger
  set {long}($trc__dma+0x0c) = (53<<17) | (1<<6) | (2<<2) | 1
  # start TPIU FIFO and clear overflow flag
  set {long}(0x50700000) = 2

  ## setup ETM: note that it needs to be stopped, which happened above
  # trcconfigr = branch broadcasting, cycle counting
  set {long}($trc__etm+0x010) = ($trc_bbroadc&1)<<3 | ($trc_ccount&1)<<4
  # trceventctl0r = trceventctl1r = 0: disable all event tracing
  set {long}($trc__etm+0x020) = 0
  set {long}($trc__etm+0x024) = 0
  # trcstallctlr = 0: disable stalling of CPU
  set {long}($trc__etm+0x02c) = 0
  # trctsctlr = 0: disable timestamp event
  set {long}($trc__etm+0x030) = 0
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
  
  # note that gdb is a bit 'stupid' regarding the filename in 'dump'...
  dump binary memory _tempdump.bin $trc_bufaddr $trc_bufaddr+$trc_bufsize
  # ... so we rename it afterwards
  shell mv _tempdump.bin $arg0
end

# documentation aka help texts
document trc_setup
Configure ETM tracing options.
Usage: trc_setup [addr] [size] [dmachan] [ccount] [bbroadc] [formatter]

Arguments are the address of the trace buffer in memory, the size of
the buffer, the DMA channel number (0-15), whether to enable cycle
counting (0/1), whether to enable branch broadcasting (0/1), whether
to enable the TPIU formatter (0/1). Trailing arguments can be omitted.
The options are applied during the next invocation of trc_start.
Calling without arguments prints the current configuration.

Example: trc_setup 0x20040000 4096
end

document trc_start
Enable ETM and start tracing the current program.

Continues the program being debugged. Execution will continue until
a breakpoint or signal is hit, or Ctrl-C is pressed. Tracing will
automatically stop as soon as the defined trace buffer is full.
end

document trc_save
Save ETM trace to a file.
Usage: trc_save FILENAME
Example: trc_save trace.bin
end
