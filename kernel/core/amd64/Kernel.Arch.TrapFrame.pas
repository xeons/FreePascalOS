{
  Register state saved on entry to an interrupt or exception handler.

  The layout matches the order in which the processor and the common
  interrupt entry code push values onto the stack: the general purpose
  registers last pushed (R15) are at the lowest address, followed by the
  vector number and error code pushed by the per-vector stub, followed by
  the frame the processor pushes itself.
}
unit Kernel.Arch.TrapFrame;

{$mode objfpc}

interface

type
  TTrapFrame = record
    { Pushed by the common entry code. }
    R15: QWord;
    R14: QWord;
    R13: QWord;
    R12: QWord;
    R11: QWord;
    R10: QWord;
    R9: QWord;
    R8: QWord;
    Rbp: QWord;
    Rdi: QWord;
    Rsi: QWord;
    Rdx: QWord;
    Rcx: QWord;
    Rbx: QWord;
    Rax: QWord;

    { Pushed by the per-vector stub. Exceptions without an error code get
      a zero pushed in its place so every frame has the same shape. }
    Vector: QWord;
    ErrorCode: QWord;

    { Pushed by the processor. }
    Rip: QWord;
    Cs: QWord;
    Rflags: QWord;
    Rsp: QWord;
    Ss: QWord;
  end;
  PTrapFrame = ^TTrapFrame;

function TrapFrameVector(Frame: PTrapFrame): Byte;
function TrapFrameInstructionPointer(Frame: PTrapFrame): QWord;

implementation

function TrapFrameVector(Frame: PTrapFrame): Byte;
begin
  Result := Byte(Frame^.Vector);
end;

function TrapFrameInstructionPointer(Frame: PTrapFrame): QWord;
begin
  Result := Frame^.Rip;
end;

end.
