{
  Program startup code, linked into every user program (the compiler
  expects a unit of this name for Linux style programs).

  The kernel starts a program at _start with the stack pointer at the
  argument count, followed by the argument pointers, a nil, the
  environment pointers, a nil and the auxiliary vector. The compiler puts
  the unit tables into the program itself; this unit is the program
  side, so it collects their addresses and the initial stack into a
  TEntryInformation and hands it to System.SysEntry in libsystem, which
  never returns.
}
unit si_prc;

{$mode objfpc}

interface

implementation

procedure PascalMain; external name 'PASCALMAIN';

var
  InitFinalTable: record end; external name 'INITFINAL';
  ThreadvarTablesTable: record end; external name 'FPC_THREADVARTABLES';
  ResStrInitTables: record end; external name 'FPC_RESSTRINITTABLES';
  ResourceStringTables: record end; external name 'FPC_RESOURCESTRINGTABLES';
  ResLocation: Pointer; external name 'FPC_RESLOCATION';

procedure EnterProgram(InitialStack: PQWord);
var
  Information: TEntryInformation;
  Environment: PPChar;
begin
  FillChar(Information, SizeOf(Information), 0);
  Information.InitFinalTable := @InitFinalTable;
  Information.ThreadvarTablesTable := @ThreadvarTablesTable;
  Information.ResStrInitTables := @ResStrInitTables;
  Information.ResourceStringTables := @ResourceStringTables;
  Information.ResLocation := @ResLocation;
  Information.PascalMain := @PascalMain;
  Information.OS.argc := LongInt(InitialStack[0]);
  Information.OS.argv := PPChar(@InitialStack[1]);
  Environment := PPChar(@InitialStack[2 + InitialStack[0]]);
  Information.OS.envp := Environment;
  while Environment^ <> nil do
    Inc(Environment);
  Information.OS.auxv := PQWord(Environment + 1);
  Information.OS.stkptr := InitialStack;
  SysEntry(Information);
end;

procedure ProgramEntry; assembler; nostackframe; [public, alias: '_start'];
asm
  movq %rsp, %rdi
  andq $-16, %rsp
  call EnterProgram
.LNeverReturns:
  jmp .LNeverReturns
end;

end.
