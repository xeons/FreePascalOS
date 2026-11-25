{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  Kernel startup.

  The loader jumps to KernelEntryPoint with interrupts disabled, running on
  the boot stack with the loader's page tables. Initialization then runs in
  two phases:

    Phase 0 runs on the boot processor before any other thread exists, with
    interrupts disabled. It brings up debug output, the processor tables,
    memory management, the object and process managers, the HAL and the
    scheduler. At the end, the boot code becomes the idle thread.

    Phase 1 runs in its own system thread with interrupts and preemption
    enabled, so it can sleep and wait. It finishes initialization that
    needs a working scheduler and then runs the kernel self tests.
}
unit Kernel.Startup;

{$mode objfpc}

interface

uses
  Boot.Information;

procedure KernelEntryPoint(BootInformation: PBootInformation);

implementation

uses
  Kernel.IdleStates,
  Io.AcpiPower,
  Objects.Events,
  Objects.Semaphores,
  Objects.Timers,
  Objects.Sections,
  Processes.Channels,
  Drivers.Displays,
  Memory.Layout,
  Memory.PhysicalPages,
  Memory.Arch.PageTables,
  Memory.VirtualRanges,
  Memory.KernelHeap,
  Hal.Platform,
  Kernel.Arch.Cpu,
  Kernel.Arch.PriorityLevel,
  Kernel.Arch.Processor,
  Kernel.PriorityLevel,
  Kernel.Threads,
  Kernel.Scheduler,
  Kernel.DeferredCalls,
  Kernel.Clock,
  Kernel.Options,
  Kernel.Random,
  Kernel.Panic,
  Kernel.SelfTest,
  Kernel.MemorySelfTest,
  Kernel.SynchronizationSelfTest,
  Kernel.HeapCheckTest,
  Kernel.ProtectionSelfTest,
  Kernel.ProtectionFaultTest,
  Kernel.Arch.ProcessorProtection,
  Memory.BootDataReclaim,
  Kernel.SecondaryProcessors,
  Kernel.FileSystemTest,
  Kernel.FileSystemWriteTest,
  Runtime.Checksums,
  Objects.Manager,
  Io.Startup,
  Network.Startup,
  Network.LogStreaming,
  Network.FallbackAddress,
  Kernel.NetworkShell,
  Kernel.NetworkSelfTest,
  Kernel.NetworkHardeningSelfTest,
  Io.BlockCache,
  Memory.Pressure,
  Io.AudioOutput,
  Io.AudioInput,
  Io.AcpiNamespace,
  Io.AcpiEvents,
  Processes.Shutdown,
  Drivers.Ps2Keyboard,
  Drivers.UsbKeyboard,
  Kernel.DebugShell,
  FileSystem.Files,
  FileSystem.Watches,
  Drivers.Xhci,
  Processes.Process,
  Processes.Thread,
  Processes.ThreadReaper,
  Kernel.Events,
  Processes.SystemCalls,
  Processes.Termination,
  Processes.TerminalSignals,
  Processes.Init,
  Io.Console,
  Io.TerminalSignals,
  Io.Manager,
  Io.DeviceFiles,
  Kernel.IoSelfTest,
  Kernel.WatchdogSelfTest,
  Kernel.PanicTest,
  Kernel.StackTraceSelfTest,
  Kernel.RandomSelfTest,
  Kernel.Arch.PlatformSelfTest,
  Kernel.Timers,
  Processes.ImageSections,
  Processes.MappedFiles,
  Processes.VirtualMemory,
  Processes.HangWatch,
  Drivers.MemoryDevices,
  Drivers.ConsoleDevice,
  Drivers.PseudoTerminalDevices,
  Drivers.DiskStatistics,
  Drivers.RamDisk,
  Io.Pipes,
  Debug.Output,
  Debug.FramebufferConsole;

const
  KernelName = 'FreePascalOS';
  KernelVersion = '0.1.0';
  PhaseOneThreadPriority = DefaultThreadPriority + 4;

procedure ValidateBootInformation(BootInformation: PBootInformation);
begin
  if BootInformation^.Signature <> BootInformationSignature then
    KernelPanicWithCode(PanicInvalidBootInformation,
      'boot information signature does not match',
      BootInformation^.Signature, BootInformationSignature, 0, 0);

  if BootInformation^.Version <> BootInformationVersion then
    KernelPanicWithCode(PanicInvalidBootInformation,
      'boot information was written by an incompatible loader',
      BootInformation^.Version, BootInformationVersion, 0, 0);
end;

procedure ExitEmulatorAfterPanic;
begin
  HalExitEmulator(EmulatorExitPanic);
end;

procedure ApplyKernelOptions(BootInformation: PBootInformation);
begin
  InitializeKernelOptions(BootInformation^);
  if KernelOptionIsSet(OptionTestExit) then
    SetPanicHook(@ExitEmulatorAfterPanic);
end;

procedure WriteBanner;
begin
  DebugBeginMessage;
  DebugSetColor(ColorWhite);
  DebugWrite(KernelName);
  DebugWrite(' ');
  DebugWrite(KernelVersion);
  DebugResetColor;
  DebugWriteLine(' - kernel starting');
  if KernelCommandLine^ <> #0 then
  begin
    DebugWrite('Options: ');
    DebugWriteLine(KernelCommandLine);
  end;
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure WriteBootSummary(BootInformation: PBootInformation);
begin
  DebugBeginMessage;
  DebugWriteTag('boot');
  DebugWrite('Kernel image ');
  DebugWriteSize(BootInformation^.KernelImage.SizeInBytes);
  DebugWrite(' at ');
  DebugWriteAddress(BootInformation^.KernelImage.VirtualBase);
  DebugWrite(', ');
  DebugWriteDecimal(BootInformation^.MemoryRegionCount);
  DebugWriteLine(' memory map regions');

  if FramebufferConsoleIsAvailable then
  begin
    DebugWriteTag('boot');
    DebugWrite('Framebuffer console ');
    DebugWriteDecimal(ConsoleColumnCount);
    DebugWrite(' x ');
    DebugWriteDecimal(ConsoleRowCount);
    DebugWrite(' characters (');
    DebugWriteDecimal(BootInformation^.Framebuffer.Width);
    DebugWrite(' x ');
    DebugWriteDecimal(BootInformation^.Framebuffer.Height);
    DebugWriteLine(' pixels)');
  end;
  DebugEndMessage;
end;

procedure InitializeMemoryManagement(BootInformation: PBootInformation);
begin
  InitializePhysicalMemory(BootInformation^);
  InitializeKernelPageTables;
  RemoveBootIdentityMapping;
  InitializeVirtualRanges;
  InitializeKernelHeap;
  { The console scrolls in ordinary memory from now on. }
  if FramebufferShadowSize > 0 then
    StartFramebufferShadow(PLongWord(AllocateKernelMemory(FramebufferShadowSize)));
  WritePhysicalMemorySummary;
end;

procedure InitializeExecutiveServices;
begin
  InitializeObjectManager;
  InitializeProcessManager;
  InitializeThreadManager;
  InitializeFileObjects;
  InitializeWatches;
  InitializeImageSections;
  InitializeMappedFiles;
  InitializeVirtualMemory;
  InitializeTerminalSignals;
  InitializeConsole;
  InitializeIoManager;
  InitializeDeviceFiles;
  InitializeMemoryDevices;
  InitializeConsoleDevice;
  InitializePseudoTerminalDevices;
  InitializePipes;
  InitializeEventObjects;
  InitializeSemaphoreObjects;
  InitializeTimerObjects;
  InitializeSectionObjects;
  InitializeChannels;
  InitializeSystemCalls;
end;

procedure RunIdleLoop; noreturn;
begin
  while True do
  begin
    { Exited threads are released by the reaper, which may wait. }
    WakeThreadReaperIfNeeded;
    { A thread this processor may run can be left in another's queue
      when that queue's lock was taken just as it looked: it looks again
      rather than halting. }
    if IdleProcessorFoundWork then
      Continue;
    { Checks again with interrupts off and waits for the next interrupt
      in the same step (Kernel.IdleStates). If it made a thread ready,
      the dispatch interrupt switches to it. }
    IdleProcessor;
  end;
end;

{ The power policy: the power button powers off. Only S5 can be
  entered, so the sleep button only says so. }
procedure HandlePowerEvent(Event: TPowerEvent);
begin
  case Event of
    PowerEventPowerButton:
      RequestShutdown(PowerActionOff);
    PowerEventSleepButton:
      begin
        DebugBeginMessage;
        DebugWriteTag('power');
        DebugWriteLine('sleeping is not supported; the sleep button does nothing');
        DebugEndMessage;
      end;
  end;
end;

{ ACPI events (buttons, GPEs), handled by a thread that runs AML. }
procedure StartAcpiEvents;
const
  EventStackSize = 256 * 1024;
begin
  if InitializeAcpiEvents(@HandlePowerEvent) then
    CreateSystemThread(@RunAcpiEvents, nil, PhaseOneThreadPriority, 'AcpiEvents', False, EventStackSize);
end;

{ The AML interpreter recurses as the AML nests: it runs on a thread
  with a large stack, waited for. }
procedure LoadAcpiNamespaceOnLargeStack;
const
  InterpreterStackSize = 256 * 1024;
var
  Thread: PThread;
begin
  Thread := CreateSystemThread(@LoadAcpiNamespace, nil, PhaseOneThreadPriority, 'AcpiInterpreter', True,
    InterpreterStackSize);
  if Thread = nil then
    Exit;
  WaitForEvent(Thread^.ExitEvent);
  DereferenceObject(Thread);
end;

{ The mixer and the capture thread, only where there are outputs and
  inputs: a thread that ended at once would free its stack under the
  self tests' feet. }
procedure StartAudioThreads;
begin
  if (AudioOutputCount > 0) and
     (CreateSystemThread(@RunAudioMixer, nil, PhaseOneThreadPriority, 'AudioMixer', False) = nil) then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the audio mixer', 0, 0, 0, 0);
  if (AudioInputCount > 0) and
     (CreateSystemThread(@RunAudioCapture, nil, PhaseOneThreadPriority, 'AudioCapture', False) = nil) then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the audio capture thread', 0, 0, 0, 0);
end;

procedure SystemInitializationPhaseOne(Context: Pointer);
var
  InitialProgramExitCode: LongInt;
  OptionValue: array[0..63] of Char;
begin
  DebugWriteTag('init');
  DebugWriteLine('Phase 1 started');

  StartThreadReaper;
  InitializePlatformTables(PBootInformation(Context)^);
  { With the firmware's processor list read, the processors start before
    the drivers, so device interrupts can go to all of them. }
  StartSecondaryProcessors(@RunIdleLoop);
  InitializeBuses;
  LoadAcpiNamespaceOnLargeStack;
  { Thermal zones, batteries and _CST's idle states, read on a thread of
    their own. }
  StartAcpiPower;
  InitializeIoSystem;
  { The network adapters registered with the drivers above. }
  StartNetworking;
  { Diagnostics over the network (netlog, netshell, netaddr, netdhcp). }
  StartNetworkLog;
  StartNetworkShell;
  StartFallbackAddressing(NetworkLogIsWanted or NetworkShellIsWanted);
  InitializeDisplays(PBootInformation(Context)^.Framebuffer);
  StartAcpiEvents;
  if CreateSystemThread(@RunBlockCacheWriter, nil, PhaseOneThreadPriority, 'CacheWriter', False) = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the cache writer', 0, 0, 0, 0);
  if CreateSystemThread(@RunMemoryPressureWatcher, nil, PhaseOneThreadPriority, 'MemoryPressure', False) = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the memory pressure thread', 0, 0, 0, 0);
  if (XhciControllerCount > 0) and
     (CreateSystemThread(@RunUsbPortWatcher, nil, PhaseOneThreadPriority, 'UsbPorts', False) = nil) then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the USB port watcher', 0, 0, 0, 0);
  StartAudioThreads;
  StartTerminalSignalHandler;
  StartHangWatch;
  RunPanicTestIfAsked;

  RunKernelSelfTests;
  RunMemorySelfTests;
  RunSynchronizationSelfTests;
  RunStackTraceSelfTest;
  RunRandomSelfTest;
  RunPlatformSelfTest;
  RunHeapCheckSelfTest;
  RunProtectionSelfTests;
  RunProtectionFaultTest;
  RunIoSelfTests;
  RunWatchdogSelfTest;
  RunNetworkSelfTests;
  RunNetworkHardeningSelfTests;
  RunFileSystemSelfTests;
  { Only when asked: the write tests change the test volumes, and end
    journaled ones with a simulated crash that leaves them read-only. }
  if KernelOptionIsSet(OptionFileSystemWriteTests) then
    RunFileSystemWriteTests;
  { Start-up is done with the boot information (Context): its pages go
    back to the allocator. }
  ReclaimBootData(PBootInformation(Context));
  WriteBlockCacheSummary;
  WriteDiskStatistics;

  WriteKernelHeapSummary;
  WriteObjectManagerSummary;
  WritePhysicalMemorySummary;

  DebugBeginMessage;
  DebugWriteTag('init');
  DebugWrite('System ready after ');
  DebugWriteDecimal(UptimeMilliseconds);
  DebugWrite(' ms, ');
  DebugWriteDecimal(ContextSwitchCount);
  DebugWriteLine(' context switches so far');
  DebugEndMessage;

  if KernelOptionIsSet(OptionKernelShell) then
    RunDebugShell;

  InitialProgramExitCode := RunInitialProgram;
  { Shutting down ended the programs: the shutdown thread finishes. }
  if ShutdownIsInProgress then
    Exit;
  if InitialProgramExitCode <> InitialProgramNotStarted then
  begin
    { Everything the user programs used should have been given back. The
      last thread may still be finishing; give it a moment and free it. }
    SleepMilliseconds(50);
    ReapTerminatedThreads;
    WriteDiskStatistics;
    WriteKernelHeapSummary;
    WriteObjectManagerSummary;
    WritePhysicalMemorySummary;
  end;

  if KernelOptionIsSet(OptionTestExit) then
  begin
    { Leave the disks clean (journals empty) for the host's checks. }
    SyncAllVolumes;
    WriteKeyboardSummary;
    { Without a system disk no program runs; that is only a failure if a
      test program was asked for. }
    if (InitialProgramExitCode = 0) or
       ((InitialProgramExitCode = InitialProgramNotStarted) and
        not GetKernelOptionValue('init', @OptionValue[0], SizeOf(OptionValue))) then
      HalExitEmulator(EmulatorExitSuccess)
    else
      HalExitEmulator(EmulatorExitTestFailure);
  end;
end;

procedure StartPhaseOne(BootInformation: PBootInformation);
var
  PhaseOneThread: PThread;
begin
  PhaseOneThread := CreateSystemThread(@SystemInitializationPhaseOne, BootInformation,
    PhaseOneThreadPriority, 'Phase1Init', False);
  if PhaseOneThread = nil then
    KernelPanicWithCode(PanicInitializationFailed, 'could not create the phase 1 thread', 0, 0, 0, 0);
end;

procedure KernelEntryPoint(BootInformation: PBootInformation); [public, alias: 'KernelEntry'];
var
  BootStackBase: QWord;
  IdleThread: PThread;
begin
  { The loader left interrupts disabled, and they stay disabled for all of
    phase 0. The priority level starts at PassiveLevel so that ordinary
    spin locks (which raise to DispatchLevel) work as usual. }
  ArchSetPriorityLevel(PassiveLevel);

  InitializeDebugOutput;
  ValidateBootInformation(BootInformation);
  ApplyKernelOptions(BootInformation);
  AttachFramebufferConsole(BootInformation^.Framebuffer,
    PhysicalToVirtual(BootInformation^.Framebuffer.PhysicalBase));

  WriteBanner;
  WriteBootSummary(BootInformation);
  InitializeChecksums;

  InitializeBootProcessor;
  WriteProcessorDescription;

  InitializeMemoryManagement(BootInformation);
  InitializeRandom(BootInformation^);
  { SMEP, UMIP, PAN: before the other processors start, which copy the
    boot processor's settings. }
  EnableProcessorProtection;
  RecordBootRamDisk(BootInformation^);
  InitializeExecutiveServices;

  InitializeHal;
  HalWriteDescription;
  InitializeIdleStates;
  WriteIdleStates;

  BootStackBase := QWord(PhysicalToVirtual(BootInformation^.BootStackPhysicalBase));
  IdleThread := CreateIdleThreadFromBootContext(BootStackBase,
    BootStackBase + BootInformation^.BootStackSizeInBytes);
  InitializeDeferredCalls;
  InitializeTimers;
  InitializeScheduler(@IdleThread^.ControlBlock);
  { Caches shrink when memory runs short (deferred calls are ready). }
  InitializeMemoryPressure;

  StartPhaseOne(BootInformation);

  StartSystemClock;
  DebugWriteTag('init');
  DebugWriteLine('Phase 0 complete, enabling interrupts');

  EnableInterrupts;
  RunIdleLoop;
end;

end.
