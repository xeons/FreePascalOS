{
  Program startup code, linked into every user program.

  The compiler expects a unit with this name for Linux style programs. It
  provides the entry point "_start": the kernel starts a program there
  with the stack pointer at the argument count. The stack is aligned and
  control passes to System.StartProgram, which runs the main block.

  The compiler emits the unit initialization table (INITFINAL) and the
  threadvar tables (FPC_THREADVARTABLES) into the program itself; this
  unit is the program side, so it hands their addresses to the System
  unit in libsystem.
}
unit si_prc;

{$mode objfpc}
{$asmmode intel}

interface

implementation

procedure ProgramMainBlock; external name 'PASCALMAIN';

var
  InitFinalTable: Byte; external name 'INITFINAL';
  ThreadVarTables: Byte; external name 'FPC_THREADVARTABLES';

procedure EnterProgram(InitialStack: PQWord);
var
  Tables: TProgramTables;
begin
  Tables.InitFinalTable := @InitFinalTable;
  Tables.ThreadVarTables := @ThreadVarTables;
  StartProgram(InitialStack, @ProgramMainBlock, @Tables);
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
