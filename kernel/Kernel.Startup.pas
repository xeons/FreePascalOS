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
  Kernel.Panic,
  Kernel.SelfTest,
  Kernel.FileSystemTest,
  Kernel.FileSystemWriteTest,
  Runtime.Checksums,
  Objects.Manager,
  Io.Manager,
  Io.BlockCache,
  FileSystem.Files,
  Processes.Process,
  Processes.Thread,
  Processes.SystemCalls,
  Processes.Termination,
  Processes.Init,
  Io.Console,
  Io.NullDevice,
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
  WritePhysicalMemorySummary;
end;

procedure InitializeExecutiveServices;
begin
  InitializeObjectManager;
  InitializeProcessManager;
  InitializeThreadManager;
  InitializeFileObjects;
  InitializeConsole;
  InitializeNullDevice;
  InitializePipes;
  InitializeSystemCalls;
end;

procedure SystemInitializationPhaseOne(Context: Pointer);
var
  InitialProgramExitCode: LongInt;
  OptionValue: array[0..63] of Char;
begin
  DebugWriteTag('init');
  DebugWriteLine('Phase 1 started');

  InitializeIoSystem(PBootInformation(Context)^);
  StartConsoleInterruptHandler;

  RunKernelSelfTests;
  RunFileSystemSelfTests;
  RunFileSystemWriteTests;
  WriteBlockCacheSummary;

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

  InitialProgramExitCode := RunInitialProgram;
  if InitialProgramExitCode <> InitialProgramNotStarted then
  begin
    { Everything the user programs used should have been given back. The
      last thread may still be finishing; give it a moment and free it. }
    SleepMilliseconds(50);
    ReapTerminatedThreads;
    WriteKernelHeapSummary;
    WriteObjectManagerSummary;
    WritePhysicalMemorySummary;
  end;

  if KernelOptionIsSet(OptionTestExit) then
  begin
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

procedure RunIdleLoop; noreturn;
begin
  while True do
  begin
    ReapTerminatedThreads;
    { Interrupts are enabled, so the next interrupt ends the halt. If it
      made a thread ready, the dispatch interrupt switches to it. }
    HaltProcessor;
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
  InitializeExecutiveServices;

  InitializeHal;
  HalWriteDescription;

  BootStackBase := QWord(PhysicalToVirtual(BootInformation^.BootStackPhysicalBase));
  IdleThread := CreateIdleThreadFromBootContext(BootStackBase,
    BootStackBase + BootInformation^.BootStackSizeInBytes);
  InitializeDeferredCalls;
  InitializeScheduler(@IdleThread^.ControlBlock);

  StartPhaseOne(BootInformation);

  StartSystemClock;
  DebugWriteTag('init');
  DebugWriteLine('Phase 0 complete, enabling interrupts');

  EnableInterrupts;
  RunIdleLoop;
end;

end.
