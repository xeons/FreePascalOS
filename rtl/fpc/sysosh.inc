{
  Platform types of the FreePascalOS System unit.

  Handles are the kernel's handle numbers (small, so a LongInt as on
  Unix). A thread id (TThreadID) is the handle of the thread, which
  BeginThread returns and WaitForThreadTerminate waits on.
}

type
  THandle = LongInt;
  TThreadID = PtrUInt;

  { A recursive lock: State is 0 (free), 1 (held) or 2 (held, with
    threads sleeping on it in the kernel); Owner and Depth make it
    recursive, as critical sections must be. }
  PRTLCriticalSection = ^TRTLCriticalSection;
  TRTLCriticalSection = record
    State: LongInt;
    Depth: LongInt;
    Owner: QWord;
    Reserved: QWord;
  end;

  { What the startup code (si_prc) hands over besides the compiler's
    tables: the initial stack and how to end the process. }
  {$define HAS_ENTRYINFORMATION_OS}
  TEntryInformationOS = record
    argc: LongInt;
    argv: PPChar;
    envp: PPChar;
    { The auxiliary vector, after the environment. }
    auxv: PQWord;
    stkptr: Pointer;
    stklen: SizeUInt;
  end;
