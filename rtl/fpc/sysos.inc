{
  System calls and error handling of the FreePascalOS System unit.

  Every kernel call returns a value of zero or more on success and minus
  an Abi error code on failure. The Abi error codes are the POSIX errno
  numbers, so they map onto InOutRes the way Unix ones do. The last error
  of the calling thread is kept for GetLastOSError (SysUtils).
}

{$include Abi.SystemCalls.inc}

function SystemCall(Number: QWord; Argument1, Argument2, Argument3, Argument4,
  Argument5, Argument6: QWord): Int64; assembler; nostackframe;
asm
  { Our arguments arrive in RDI, RSI, RDX, RCX, R8, R9 and on the stack;
    the kernel wants the number in RAX and the arguments in RDI, RSI,
    RDX, R10, R8, R9. }
  movq %rdi, %rax
  movq %rsi, %rdi
  movq %rdx, %rsi
  movq %rcx, %rdx
  movq %r8, %r10
  movq %r9, %r8
  movq 8(%rsp), %r9
  syscall
end;

threadvar
  LastSystemError: LongInt;

function GetLastSystemError: LongInt;
begin
  GetLastSystemError := LastSystemError;
end;

procedure SetLastSystemError(Error: LongInt);
begin
  LastSystemError := Error;
end;

{ The InOutRes value for an Abi error code. }
function ErrorToInOutRes(Error: LongInt): Word;
begin
  case Error of
    ErrorTooManyHandles: ErrorToInOutRes := 4;
    ErrorNotFound: ErrorToInOutRes := 2;
    ErrorBadHandle: ErrorToInOutRes := 6;
    ErrorOutOfMemory, ErrorBadAddress: ErrorToInOutRes := 217;
    ErrorInvalidArgument: ErrorToInOutRes := 218;
    ErrorBrokenPipe, ErrorInterrupted, ErrorIo, ErrorNoSpace: ErrorToInOutRes := 101;
    ErrorNameTooLong: ErrorToInOutRes := 3;
    ErrorReadOnly, ErrorExists, ErrorDirectoryNotEmpty, ErrorAccessDenied, ErrorNotPermitted,
    ErrorBusy, ErrorNotDirectory, ErrorIsDirectory: ErrorToInOutRes := 5;
  else
    ErrorToInOutRes := Word(Error);
  end;
end;

{ For the low level file routines: a negative call result becomes the
  thread's last error and InOutRes. Returns True if Result is an error. }
function FailedCall(CallResult: Int64): Boolean;
begin
  FailedCall := CallResult < 0;
  if FailedCall then
  begin
    LastSystemError := LongInt(-CallResult);
    InOutRes := ErrorToInOutRes(LastSystemError);
  end;
end;

function Do_IsDevice(Handle: THandle): Boolean;
begin
  Do_IsDevice := SystemCall(CallGetHandleKind, QWord(Int64(Handle)), 0, 0, 0, 0, 0) = HandleKindConsole;
end;
