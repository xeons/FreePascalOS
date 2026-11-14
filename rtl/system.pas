{
  Minimal freestanding System unit.

  The Free Pascal compiler implicitly uses a unit named "System" in every
  module. The stock one depends on an operating system, so both the UEFI
  loader and the kernel are built against this replacement instead.

  It deliberately contains only what the compiler insists on, plus the few
  basic type aliases everything else expects. Higher level helpers live in
  the kernel runtime units, not here.
}
unit System;

interface

{$mode fpc}

type
  Cardinal = LongWord;
  DWord = LongWord;
  Integer = LongInt;
  HResult = LongInt;
  UInt64 = QWord;

  SizeInt = Int64;
  SizeUInt = QWord;
  PtrInt = Int64;
  PtrUInt = QWord;

  PChar = ^Char;
  PPChar = ^PChar;
  PByte = ^Byte;
  PWord = ^Word;
  PLongWord = ^LongWord;
  PQWord = ^QWord;
  PPtrUInt = ^PtrUInt;
  PWideChar = ^WideChar;

  { The types below are required by the compiler even though this
    runtime never raises Pascal exceptions or uses interfaces. }
  jmp_buf = record
    Rbx, Rbp, R12, R13, R14, R15, Rsp, Rip: QWord;
  end;
  PJmp_buf = ^jmp_buf;

  PExceptAddr = ^TExceptAddr;
  TExceptAddr = record
    Buf: PJmp_buf;
    Next: PExceptAddr;
    FrameType: LongInt;
  end;

  TGUID = record
    D1: LongWord;
    D2: Word;
    D3: Word;
    D4: array[0..7] of Byte;
  end;

  TTypeKind = (tkUnknown);

{ Called by the compiler at the start of a "program" main block. }
procedure fpc_initializeunits; compilerproc;

{ Called by the compiler at the end of a "program" main block. }
procedure fpc_do_exit; compilerproc;

implementation

procedure fpc_initializeunits; [public, alias: 'FPC_INITIALIZEUNITS']; compilerproc;
begin
  { Units in this system are initialized explicitly, never implicitly. }
end;

procedure fpc_do_exit; [public, alias: 'FPC_DO_EXIT']; compilerproc;
begin
  { There is nothing to return to. }
end;

end.
