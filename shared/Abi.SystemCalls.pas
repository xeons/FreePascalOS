{
  The system call interface between user programs and the kernel.

  Calling convention (x86-64): the "syscall" instruction with the call
  number in RAX and up to six arguments in RDI, RSI, RDX, R10, R8, R9.
  The result comes back in RAX: a value of zero or more is success, and a
  negative value is an error, minus one of the Error* codes below.

  Paths passed to the kernel are UTF-8 and may be absolute or relative to
  the process's current directory. "/" is the root of the system volume;
  other volumes are reached under "/volumes/<name>".

  This unit is compiled into both the kernel and libsystem, so the record
  layouts must only use explicitly sized types.
}
unit Abi.SystemCalls;

{$mode objfpc}

interface

{$include Abi.SystemCalls.inc}

implementation

end.
