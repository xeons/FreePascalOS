{
  System unit for user programs.

  Every user program and library is compiled against this unit, which
  becomes part of libsystem.so. Besides the types the compiler needs, it
  holds the bare minimum a process needs before any library code runs:

    * the raw system call instruction,
    * program startup: it receives the initial stack laid out by the
      kernel (argument count, arguments, environment) and runs the
      program's main block,
    * program exit, with a hook so buffered output can be flushed.

  Everything else (files, memory, text, processes) lives in the Sys.*
  units of libsystem.
}
unit System;

interface

{$mode fpc}
{$asmmode intel}

{$include system.types.inc}

type
  TExitProcedure = procedure;

var
  { Set by the main block or Halt; passed to the kernel on exit. }
  ExitCode: LongInt;
  ArgumentCount: LongInt;
  ArgumentValues: PPChar;
  EnvironmentValues: PPChar;
  { Runs just before the process ends (libsystem flushes output here). }
  ExitProcedure: TExitProcedure;

{ Performs system call Number with up to six arguments; see
  Abi.SystemCalls for the numbers and the meaning of the result. }
function SystemCall(Number: QWord; Argument1, Argument2, Argument3, Argument4,
  Argument5, Argument6: QWord): Int64;

{ Called by the startup code (si_prc) with the initial stack pointer. }
procedure StartProgram(InitialStack: PQWord; MainBlock: Pointer);

{ Ends the program with an exit code. }
procedure Halt(Code: LongInt);

procedure fpc_initializeunits; compilerproc;
procedure fpc_do_exit; compilerproc;

implementation

const
  SystemCallExit = 0;

type
  TMainBlock = procedure;

function SystemCall(Number: QWord; Argument1, Argument2, Argument3, Argument4,
  Argument5, Argument6: QWord): Int64; assembler; nostackframe;
asm
  { Our arguments arrive in RDI, RSI, RDX, RCX, R8, R9 and on the stack;
    the kernel wants the number in RAX and the arguments in RDI, RSI,
    RDX, R10, R8, R9. }
  mov rax, rdi
  mov rdi, rsi
  mov rsi, rdx
  mov rdx, rcx
  mov r10, r8
  mov r8, r9
  mov r9, [rsp + 8]
  syscall
end;

procedure EndProcess(Code: LongInt);
begin
  if Assigned(ExitProcedure) then
    ExitProcedure();
  while True do
    SystemCall(SystemCallExit, QWord(Code), 0, 0, 0, 0, 0);
end;

procedure StartProgram(InitialStack: PQWord; MainBlock: Pointer);
begin
  ArgumentCount := LongInt(InitialStack^);
  ArgumentValues := PPChar(InitialStack + 1);
  EnvironmentValues := PPChar(InitialStack + 2 + ArgumentCount);
  ExitCode := 0;
  ExitProcedure := nil;
  TMainBlock(MainBlock)();
  EndProcess(ExitCode);
end;

procedure Halt(Code: LongInt);
begin
  ExitCode := Code;
  EndProcess(Code);
end;

procedure fpc_initializeunits; [public, alias: 'FPC_INITIALIZEUNITS']; compilerproc;
begin
  { Units in this system are initialized explicitly, never implicitly. }
end;

procedure fpc_do_exit; [public, alias: 'FPC_DO_EXIT']; compilerproc;
begin
  EndProcess(ExitCode);
end;

end.
