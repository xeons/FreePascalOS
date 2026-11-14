{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

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
  PInteger = ^Integer;
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
