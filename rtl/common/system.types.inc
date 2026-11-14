{
  Basic types shared by the kernel and user System units. The compiler
  requires jmp_buf, TExceptAddr, TGUID and TTypeKind to exist even though
  nothing here uses exceptions or interfaces.
}

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
  PPointer = ^Pointer;
  PByte = ^Byte;
  PWord = ^Word;
  PLongWord = ^LongWord;
  PQWord = ^QWord;
  PInt64 = ^Int64;
  PLongInt = ^LongInt;
  PBoolean = ^Boolean;
  PPtrInt = ^PtrInt;
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
