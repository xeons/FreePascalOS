{
  Reaching the current processor's data block on x86-64.

  Every processor keeps a pointer to its block (Kernel.Processors) in the
  GS base register while it runs kernel code. User code may change GS, so
  the kernel swaps it in on every entry from user mode and back out on the
  way out (SWAPGS, in the interrupt and system call entry code): while a
  processor runs user code its block pointer waits in the "kernel GS
  base" register and GS holds the user's value (always 0 here).

  The first fields of the block have fixed offsets so that assembly code
  and single instructions can reach them; reading the running thread with
  one GS-relative load cannot be torn by the thread moving to another
  processor halfway.
}
unit Kernel.Arch.ProcessorBlock;

{$mode objfpc}
{$asmmode intel}

interface

const
  { Offsets of the fixed fields of TProcessor (Kernel.Processors). }
  ProcessorSelfOffset = 0;
  ProcessorRunningThreadOffset = 8;
  ProcessorSystemCallStackOffset = 16;
  ProcessorUserStackScratchOffset = 24;

{ Makes Block the current processor's block (GS base), with the user's
  GS base 0. Call once per processor, after its segment registers were
  loaded (loading GS clears the base). }
procedure ArchSetProcessorBlock(Block: Pointer);

function ArchCurrentProcessorBlock: Pointer;
{ The running thread of the current processor, in one load. }
function ArchCurrentThreadBlock: Pointer;

implementation

uses
  Kernel.Arch.Cpu;

const
  MsrGsBase = $C0000101;
  MsrKernelGsBase = $C0000102;

procedure ArchSetProcessorBlock(Block: Pointer);
begin
  WriteModelSpecificRegister(MsrGsBase, QWord(Block));
  WriteModelSpecificRegister(MsrKernelGsBase, 0);
end;

function ArchCurrentProcessorBlock: Pointer; assembler; nostackframe;
asm
  mov rax, qword ptr gs:[ProcessorSelfOffset]
end;

function ArchCurrentThreadBlock: Pointer; assembler; nostackframe;
asm
  mov rax, qword ptr gs:[ProcessorRunningThreadOffset]
end;

end.
