{
  Program startup code, linked into every user program.

  The compiler expects a unit with this name for Linux style programs. It
  provides the entry point "_start": the kernel starts a program there
  with the stack pointer at the argument count. The stack is aligned and
  control passes to System.StartProgram, which runs the main block.
}
unit si_prc;

{$mode objfpc}
{$asmmode intel}

interface

implementation

procedure ProgramMainBlock; external name 'PASCALMAIN';

procedure EnterProgram(InitialStack: PQWord);
begin
  StartProgram(InitialStack, @ProgramMainBlock);
end;

procedure ProgramEntry; assembler; nostackframe; [public, alias: '_start'];
asm
  mov rdi, rsp
  and rsp, -16
  call EnterProgram
@NeverReturns:
  jmp @NeverReturns
end;

end.
