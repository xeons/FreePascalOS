{
  Threads.

  Every thread of a process shares its memory, handles and libraries and
  has its own stack, threadvars and thread-local storage. A thread runs
  a routine with one pointer argument; the routine's result becomes the
  thread's exit code, which WaitForThread reports.

  How a process ends with several threads:

    * Halt, or the main block returning, ends the whole process (other
      threads are stopped by the kernel); unit finalization and the
      output flush run in the thread that ended it,
    * ExitThread (or a thread routine returning) ends only that thread;
      if it was the last one, the process ends with its exit code, but
      without unit finalization or the output flush, so the main thread
      should wait for the others and end the process normally,
    * a thread that crashes ends the whole process (exit code 139).

  Locks for shared data are in Sys.Locks. The heap (Sys.Memory) may be
  used from every thread; buffered text output (Sys.Text) is not
  synchronized and should be written by one thread at a time.
}
unit Sys.Threads;

{$mode objfpc}

interface

type
  { Runs in the new thread; the result is its exit code. }
  TThreadRoutine = function(Argument: Pointer): LongInt;

{ Starts a thread running Routine(Argument) with a stack of StackSize
  bytes (0 for the default of 1 MiB). Returns a thread handle (close it
  with CloseThreadHandle) or a negative error code. }
function CreateThread(Routine: TThreadRoutine; Argument: Pointer; StackSize: QWord = 0): Int64;

{ Waits for the thread to end (TimeoutMilliseconds < 0 waits as long as
  it takes). Returns 0 and the exit code, or a negative error code
  (-ErrorTimedOut, -ErrorBadHandle, ...). }
function WaitForThread(Handle: Int64; TimeoutMilliseconds: Int64; out ExitCode: LongInt): Int64;

{ Closing a thread handle does not affect the thread. }
function CloseThreadHandle(Handle: Int64): Int64;

{ Ends the calling thread. }
procedure ExitThread(ExitCode: LongInt); noreturn;

{ The id of the calling thread, or of the thread behind a handle. }
function GetCurrentThreadId: QWord;
function GetThreadId(Handle: Int64): Int64;

{ Gives up the rest of the time slice. }
procedure YieldThread;

implementation

uses
  Abi.SystemCalls,
  Sys.Memory;

type
  TThreadStart = record
    Routine: TThreadRoutine;
    Argument: Pointer;
  end;
  PThreadStart = ^TThreadStart;

procedure ExitThread(ExitCode: LongInt);
begin
  ReleaseThreadVariables;
  while True do
    SystemCall(CallExitThread, QWord(LongWord(ExitCode)), 0, 0, 0, 0, 0);
end;

{ The kernel starts every new thread here, with the start record as its
  argument. }
procedure ThreadEntry(Start: PThreadStart);
var
  Routine: TThreadRoutine;
  Argument: Pointer;
begin
  Routine := Start^.Routine;
  Argument := Start^.Argument;
  FreeMemory(Start);
  ExitThread(Routine(Argument));
end;

function CreateThread(Routine: TThreadRoutine; Argument: Pointer; StackSize: QWord): Int64;
var
  Start: PThreadStart;
begin
  Start := PThreadStart(AllocateMemory(SizeOf(TThreadStart)));
  if Start = nil then
    Exit(-ErrorOutOfMemory);
  Start^.Routine := Routine;
  Start^.Argument := Argument;
  Result := SystemCall(CallCreateThread, QWord(@ThreadEntry), QWord(Start), StackSize, 0, 0, 0);
  if Result < 0 then
    FreeMemory(Start);
end;

function WaitForThread(Handle: Int64; TimeoutMilliseconds: Int64; out ExitCode: LongInt): Int64;
begin
  ExitCode := 0;
  Result := SystemCall(CallWaitForThread, QWord(Handle), QWord(TimeoutMilliseconds), QWord(@ExitCode),
    0, 0, 0);
end;

function CloseThreadHandle(Handle: Int64): Int64;
begin
  Result := SystemCall(CallClose, QWord(Handle), 0, 0, 0, 0, 0);
end;

function GetCurrentThreadId: QWord;
begin
  Result := CurrentThreadId;
end;

function GetThreadId(Handle: Int64): Int64;
begin
  Result := SystemCall(CallGetThreadId, QWord(Handle), 0, 0, 0, 0, 0);
end;

procedure YieldThread;
begin
  SystemCall(CallSleep, 0, 0, 0, 0, 0, 0);
end;

end.
