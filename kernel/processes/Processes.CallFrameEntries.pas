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
  Call frame information: finding and decoding the entries that say how
  to unwind a routine's frame (DWARF CFI).

  A program's code is described by frame description entries (FDEs),
  each covering one routine's addresses and pointing at a common
  information entry (CIE) it shares with others. They come in two
  forms: .eh_frame, loaded with the program (what C compilers emit,
  found through the .eh_frame_hdr search table that PT_GNU_EH_FRAME
  names), and .debug_frame, only in the file (what Free Pascal emits).
  Free Pascal's internal assembler writes the CIE pointer of a
  .debug_frame FDE as 8 bytes rather than 4; which layout an FDE uses is
  told by which one puts its first address inside the module's code.

  Nothing here touches the kernel: memory is read through a callback, so
  the same code runs in the host test (tools/CallFrameInfoTest). An
  entry found is copied (TFrameEntry, with the address each part had,
  for pc-relative pointers); Processes.CallFrameRules runs its program.
}
unit Processes.CallFrameEntries;

{$mode objfpc}
{$pointermath on}

interface

const
  { DWARF register columns kept (AArch64's x0-x30 and sp, plus a slot
    for the program counter). }
  CfiRegisterCapacity = 33;
  { The most bytes of one CIE or FDE kept. }
  CfiEntryCapacity = 2048;

  { Pointer encodings (DW_EH_PE_*). }
  PointerEncodingOmit = $FF;
  PointerEncodingAbsolute = $00;
  PointerEncodingUleb128 = $01;
  PointerEncodingUnsigned2 = $02;
  PointerEncodingUnsigned4 = $03;
  PointerEncodingUnsigned8 = $04;
  PointerEncodingSleb128 = $09;
  PointerEncodingSigned2 = $0A;
  PointerEncodingSigned4 = $0B;
  PointerEncodingSigned8 = $0C;
  PointerEncodingPcRelative = $10;
  PointerEncodingTextRelative = $20;
  PointerEncodingDataRelative = $30;
  PointerEncodingIndirect = $80;

type
  { The processor's register numbering as unwinding needs it. }
  TCfiArchitecture = record
    { DWARF columns 0 .. RegisterCount - 1 are tracked. }
    RegisterCount: LongWord;
    ReturnAddressColumn: LongWord;
    StackPointerIndex: LongWord;
    FramePointerIndex: LongWord;
    { Where TUnwindRegisters keeps the program counter (the return
      address column itself on x86-64). }
    ProgramCounterIndex: LongWord;
    { The alignment a frame pointer must have. }
    FramePointerAlignment: LongWord;
  end;

  { A frame's registers; bit N of Known says Values[N] is known. }
  TUnwindRegisters = record
    Values: array[0..CfiRegisterCapacity - 1] of QWord;
    Known: QWord;
  end;

  { Reads Count bytes at Address; False if it cannot. }
  TCfiReadMemory = function(Context: Pointer; Address: QWord; Buffer: Pointer; Count: LongWord): Boolean;
  TCfiMemory = record
    Read: TCfiReadMemory;
    Context: Pointer;
  end;

  { One FDE and its CIE, copied from wherever they were, each from its
    length field on. }
  TFrameEntry = record
    Cie: array[0..CfiEntryCapacity - 1] of Byte;
    CieSize: LongWord;
    CieAddress: QWord;
    Fde: array[0..CfiEntryCapacity - 1] of Byte;
    FdeSize: LongWord;
    FdeAddress: QWord;
    IsEhFrame: Boolean;
    { 4, or 8 for Free Pascal's .debug_frame. }
    CiePointerSize: LongWord;
    { Added to the absolute addresses in the entry (.debug_frame holds
      link addresses). }
    AddressBias: QWord;
  end;
  PFrameEntry = ^TFrameEntry;

  TCommonInformation = record
    CodeAlignment: QWord;
    DataAlignment: Int64;
    ReturnAddressColumn: LongWord;
    PointerEncoding: Byte;
    HasAugmentationData: Boolean;
    IsSignalFrame: Boolean;
    { The initial instructions, as offsets into TFrameEntry.Cie. }
    InstructionsStart: LongWord;
    InstructionsEnd: LongWord;
  end;

  TFrameDescription = record
    { The addresses covered, [Start, Finish), bias applied. }
    Start: QWord;
    Finish: QWord;
    { As offsets into TFrameEntry.Fde. }
    InstructionsStart: LongWord;
    InstructionsEnd: LongWord;
  end;

{ Byte readers over a bounded buffer: False past its end. }
function ReadUnsignedLeb128(Bytes: PByte; Size: LongWord; var Position: LongWord; out Value: QWord): Boolean;
function ReadSignedLeb128(Bytes: PByte; Size: LongWord; var Position: LongWord; out Value: Int64): Boolean;
function ReadFixed(Bytes: PByte; Size: LongWord; var Position: LongWord; Width: LongWord; out Value: QWord): Boolean;
{ An encoded pointer; BytesAddress is the address Bytes[0] had (for
  pc-relative ones) and DataBase the base of data-relative ones. }
function ReadEncodedPointer(Bytes: PByte; Size: LongWord; var Position: LongWord; Encoding: Byte;
  BytesAddress, DataBase: QWord; out Value: QWord): Boolean;
{ Adds a signed offset to an address, wrapping. }
function AddressPlusOffset(Address: QWord; Offset: Int64): QWord;

function DecodeCommonInformation(constref Entry: TFrameEntry; out Cie: TCommonInformation): Boolean;
function DecodeFrameDescription(constref Entry: TFrameEntry; constref Cie: TCommonInformation;
  out Fde: TFrameDescription): Boolean;

{ Finds the FDE covering Pc through the .eh_frame_hdr at HeaderAddress
  (in Memory) and copies it and its CIE into Entry. }
function FindInEhFrameHeader(constref Memory: TCfiMemory; HeaderAddress, Pc: QWord;
  var Entry: TFrameEntry): Boolean;
{ Finds the FDE covering Pc in a whole section held in memory of ours
  (.debug_frame read from a file, or .eh_frame). SectionAddress is the
  address its first byte has where its pc-relative pointers point (0
  for .debug_frame); Bias is added to its absolute addresses; CodeStart
  and CodeEnd (unbiased; both 0 if unknown) tell the two .debug_frame
  layouts apart. }
function FindInFrameSection(Section: PByte; SectionSize: QWord; IsEhFrame: Boolean;
  SectionAddress, Bias, CodeStart, CodeEnd, Pc: QWord; var Entry: TFrameEntry): Boolean;

implementation

uses
  Runtime.Memory;

{$push}{$R-}{$Q-}
function AddressPlusOffset(Address: QWord; Offset: Int64): QWord;
begin
  Result := Address + QWord(Offset);
end;
{$pop}

{$push}{$R-}{$Q-}
function ReadUnsignedLeb128(Bytes: PByte; Size: LongWord; var Position: LongWord; out Value: QWord): Boolean;
var
  Shift: LongWord;
  Current: Byte;
begin
  Value := 0;
  Shift := 0;
  repeat
    if Position >= Size then
      Exit(False);
    Current := Bytes[Position];
    Inc(Position);
    if Shift < 64 then
      Value := Value or (QWord(Current and $7F) shl Shift);
    Shift := Shift + 7;
  until (Current and $80) = 0;
  Result := True;
end;

function ReadSignedLeb128(Bytes: PByte; Size: LongWord; var Position: LongWord; out Value: Int64): Boolean;
var
  Shift: LongWord;
  Current: Byte;
  Bits: QWord;
begin
  Value := 0;
  Bits := 0;
  Shift := 0;
  repeat
    if Position >= Size then
      Exit(False);
    Current := Bytes[Position];
    Inc(Position);
    if Shift < 64 then
      Bits := Bits or (QWord(Current and $7F) shl Shift);
    Shift := Shift + 7;
  until (Current and $80) = 0;
  if (Shift < 64) and ((Current and $40) <> 0) then
    Bits := Bits or (not QWord(0) shl Shift);
  Value := Int64(Bits);
  Result := True;
end;

function SignExtend(Value: QWord; Width: LongWord): Int64;
var
  SignBit: QWord;
begin
  SignBit := QWord(1) shl (Width * 8 - 1);
  if (Value and SignBit) <> 0 then
    Value := Value or not (SignBit * 2 - 1);
  Result := Int64(Value);
end;
{$pop}

function ReadFixed(Bytes: PByte; Size: LongWord; var Position: LongWord; Width: LongWord; out Value: QWord): Boolean;
var
  Index: LongWord;
begin
  Value := 0;
  if (Position > Size) or (Width > Size - Position) then
    Exit(False);
  Index := Width;
  while Index > 0 do
  begin
    Dec(Index);
    Value := (Value shl 8) or Bytes[Position + Index];
  end;
  Position := Position + Width;
  Result := True;
end;

function ReadEncodedPointer(Bytes: PByte; Size: LongWord; var Position: LongWord; Encoding: Byte;
  BytesAddress, DataBase: QWord; out Value: QWord): Boolean;
var
  FieldStart: LongWord;
  Raw: QWord;
  Signed: Int64;
begin
  Value := 0;
  Raw := 0;
  if Encoding = PointerEncodingOmit then
    Exit(False);
  FieldStart := Position;
  case Encoding and $0F of
    PointerEncodingAbsolute, PointerEncodingUnsigned8, PointerEncodingSigned8:
      Result := ReadFixed(Bytes, Size, Position, 8, Raw);
    PointerEncodingUleb128:
      Result := ReadUnsignedLeb128(Bytes, Size, Position, Raw);
    PointerEncodingUnsigned2:
      Result := ReadFixed(Bytes, Size, Position, 2, Raw);
    PointerEncodingUnsigned4:
      Result := ReadFixed(Bytes, Size, Position, 4, Raw);
    PointerEncodingSleb128:
      begin
        Result := ReadSignedLeb128(Bytes, Size, Position, Signed);
        Raw := QWord(Signed);
      end;
    PointerEncodingSigned2:
      begin
        Result := ReadFixed(Bytes, Size, Position, 2, Raw);
        Raw := QWord(SignExtend(Raw, 2));
      end;
    PointerEncodingSigned4:
      begin
        Result := ReadFixed(Bytes, Size, Position, 4, Raw);
        Raw := QWord(SignExtend(Raw, 4));
      end;
  else
    Exit(False);
  end;
  if not Result then
    Exit;
  case Encoding and $70 of
    0:
      Value := Raw;
    PointerEncodingPcRelative:
      Value := AddressPlusOffset(BytesAddress + FieldStart, Int64(Raw));
    PointerEncodingDataRelative:
      Value := AddressPlusOffset(DataBase, Int64(Raw));
  else
    { Text and function relative, aligned: not used for code ranges. }
    Result := False;
  end;
end;

{ The size (from its length field on) of the entry at Bytes, 32-bit
  format only; 0 for the terminator, a 64-bit one or one that does not
  fit in Size. }
function EntryTotalSize(Bytes: PByte; Size: QWord): QWord;
var
  Position: LongWord;
  Length: QWord;
begin
  Result := 0;
  if Size < 4 then
    Exit;
  Position := 0;
  ReadFixed(Bytes, 4, Position, 4, Length);
  if (Length = 0) or (Length >= $FFFFFFF0) or (Length > Size - 4) then
    Exit;
  Result := Length + 4;
end;

{ Reads the augmentation data of a CIE whose augmentation string is
  Augmentation ('z' first), at Position. }
function DecodeAugmentationData(constref Entry: TFrameEntry; Augmentation: PChar; var Position: LongWord;
  var Cie: TCommonInformation): Boolean;
var
  Bytes: PByte;
  DataLength: QWord;
  AugmentationEnd: LongWord;
  Index: Integer;
  Encoding: Byte;
  Personality: QWord;
begin
  Bytes := @Entry.Cie[0];
  if not ReadUnsignedLeb128(Bytes, Entry.CieSize, Position, DataLength) or
     (DataLength > Entry.CieSize - Position) then
    Exit(False);
  AugmentationEnd := Position + LongWord(DataLength);
  Index := 1;
  while Augmentation[Index] <> #0 do
  begin
    case Augmentation[Index] of
      'R':
        begin
          if Position >= AugmentationEnd then
            Exit(False);
          Cie.PointerEncoding := Bytes[Position];
          Inc(Position);
        end;
      'L':
        begin
          if Position >= AugmentationEnd then
            Exit(False);
          Inc(Position);
        end;
      'P':
        begin
          if Position >= AugmentationEnd then
            Exit(False);
          Encoding := Bytes[Position] and not PointerEncodingIndirect;
          Inc(Position);
          { Only skipped: the personality routine is never called. }
          if not ReadEncodedPointer(Bytes, AugmentationEnd, Position, Encoding, Entry.CieAddress, 0,
             Personality) then
            Exit(False);
        end;
      'S':
        Cie.IsSignalFrame := True;
    else
      { Unknown: the length lets the rest be skipped. }
      Break;
    end;
    Inc(Index);
  end;
  Position := AugmentationEnd;
  Result := True;
end;

function DecodeCommonInformation(constref Entry: TFrameEntry; out Cie: TCommonInformation): Boolean;
var
  Bytes: PByte;
  Size: LongWord;
  Position: LongWord;
  Value: QWord;
  Version: Byte;
  Augmentation: array[0..15] of Char;
  AugmentationLength: Integer;
begin
  ZeroMemory(@Cie, SizeOf(Cie));
  Cie.PointerEncoding := PointerEncodingAbsolute;
  Bytes := @Entry.Cie[0];
  Size := Entry.CieSize;
  Position := 4;
  if not ReadFixed(Bytes, Size, Position, 4, Value) then
    Exit(False);
  if Entry.IsEhFrame and (Value <> 0) then
    Exit(False);
  if not Entry.IsEhFrame and (Value <> $FFFFFFFF) then
    Exit(False);
  if Position >= Size then
    Exit(False);
  Version := Bytes[Position];
  Inc(Position);
  if not (Version in [1, 3, 4]) then
    Exit(False);
  AugmentationLength := 0;
  while (Position < Size) and (Bytes[Position] <> 0) do
  begin
    if AugmentationLength >= High(Augmentation) then
      Exit(False);
    Augmentation[AugmentationLength] := Char(Bytes[Position]);
    Inc(AugmentationLength);
    Inc(Position);
  end;
  Augmentation[AugmentationLength] := #0;
  if Position >= Size then
    Exit(False);
  Inc(Position);
  if (AugmentationLength > 0) and (Augmentation[0] <> 'z') then
    Exit(False);
  if Version = 4 then
  begin
    { The address size (8) and segment selector size. }
    if (Position + 2 > Size) or (Bytes[Position] <> 8) then
      Exit(False);
    Position := Position + 2;
  end;
  if not ReadUnsignedLeb128(Bytes, Size, Position, Cie.CodeAlignment) or
     not ReadSignedLeb128(Bytes, Size, Position, Cie.DataAlignment) then
    Exit(False);
  if Version = 1 then
  begin
    if Position >= Size then
      Exit(False);
    Cie.ReturnAddressColumn := Bytes[Position];
    Inc(Position);
  end
  else
  begin
    if not ReadUnsignedLeb128(Bytes, Size, Position, Value) or (Value > High(LongWord)) then
      Exit(False);
    Cie.ReturnAddressColumn := LongWord(Value);
  end;
  if AugmentationLength > 0 then
  begin
    Cie.HasAugmentationData := True;
    if not DecodeAugmentationData(Entry, @Augmentation[0], Position, Cie) then
      Exit(False);
  end;
  Cie.InstructionsStart := Position;
  Cie.InstructionsEnd := Size;
  Result := Cie.CodeAlignment <> 0;
end;

function DecodeFrameDescription(constref Entry: TFrameEntry; constref Cie: TCommonInformation;
  out Fde: TFrameDescription): Boolean;
var
  Bytes: PByte;
  Size: LongWord;
  Position: LongWord;
  Start: QWord;
  Range: QWord;
  DataLength: QWord;
begin
  ZeroMemory(@Fde, SizeOf(Fde));
  Bytes := @Entry.Fde[0];
  Size := Entry.FdeSize;
  Position := 4 + Entry.CiePointerSize;
  if Position > Size then
    Exit(False);
  if Entry.IsEhFrame then
  begin
    if not ReadEncodedPointer(Bytes, Size, Position, Cie.PointerEncoding, Entry.FdeAddress, 0, Start) or
       not ReadEncodedPointer(Bytes, Size, Position, Cie.PointerEncoding and $0F, Entry.FdeAddress, 0, Range) then
      Exit(False);
    if (Cie.PointerEncoding and $70) = 0 then
      Start := AddressPlusOffset(Start, Int64(Entry.AddressBias));
  end
  else
  begin
    if not ReadFixed(Bytes, Size, Position, 8, Start) or not ReadFixed(Bytes, Size, Position, 8, Range) then
      Exit(False);
    Start := AddressPlusOffset(Start, Int64(Entry.AddressBias));
  end;
  if Cie.HasAugmentationData then
  begin
    if not ReadUnsignedLeb128(Bytes, Size, Position, DataLength) or (DataLength > Size - Position) then
      Exit(False);
    Position := Position + LongWord(DataLength);
  end;
  if Range > High(QWord) - Start then
    Exit(False);
  Fde.Start := Start;
  Fde.Finish := Start + Range;
  Fde.InstructionsStart := Position;
  Fde.InstructionsEnd := Size;
  Result := True;
end;

{ Copies the entry of TotalSize bytes at Source into Destination. }
function CopyEntryBytes(Source: PByte; TotalSize: QWord; Destination: PByte; out Size: LongWord): Boolean;
begin
  Size := 0;
  if (TotalSize < 8) or (TotalSize > CfiEntryCapacity) then
    Exit(False);
  CopyMemory(Destination, Source, TotalSize);
  Size := LongWord(TotalSize);
  Result := True;
end;

{ Reads the entry at Address from Memory into Destination. }
function ReadEntryFromMemory(constref Memory: TCfiMemory; Address: QWord; Destination: PByte;
  out Size: LongWord): Boolean;
var
  Length: LongWord;
begin
  Size := 0;
  if not Memory.Read(Memory.Context, Address, @Length, 4) then
    Exit(False);
  if (Length < 4) or (Length > CfiEntryCapacity - 4) then
    Exit(False);
  if not Memory.Read(Memory.Context, Address, Destination, Length + 4) then
    Exit(False);
  Size := Length + 4;
  Result := True;
end;

{ Fills Entry with the .eh_frame FDE at FdeAddress (in Memory) and its
  CIE; True if it covers Pc. }
function TakeEhFrameEntry(constref Memory: TCfiMemory; FdeAddress, Pc: QWord; var Entry: TFrameEntry): Boolean;
var
  Position: LongWord;
  CiePointer: QWord;
  Cie: TCommonInformation;
  Fde: TFrameDescription;
begin
  Result := False;
  if not ReadEntryFromMemory(Memory, FdeAddress, @Entry.Fde[0], Entry.FdeSize) then
    Exit;
  Position := 4;
  ReadFixed(@Entry.Fde[0], Entry.FdeSize, Position, 4, CiePointer);
  if (CiePointer = 0) or (CiePointer > FdeAddress + 4) then
    Exit;
  Entry.FdeAddress := FdeAddress;
  Entry.CieAddress := FdeAddress + 4 - CiePointer;
  Entry.IsEhFrame := True;
  Entry.CiePointerSize := 4;
  Entry.AddressBias := 0;
  if not ReadEntryFromMemory(Memory, Entry.CieAddress, @Entry.Cie[0], Entry.CieSize) then
    Exit;
  if not DecodeCommonInformation(Entry, Cie) or not DecodeFrameDescription(Entry, Cie, Fde) then
    Exit;
  Result := (Pc >= Fde.Start) and (Pc < Fde.Finish);
end;

{ The bytes a pointer of a fixed size encoding takes; 0 for the LEB128
  ones and omitted pointers. }
function FixedEncodingSize(Encoding: Byte): LongWord;
begin
  case Encoding and $0F of
    PointerEncodingAbsolute, PointerEncodingUnsigned8, PointerEncodingSigned8:
      Result := 8;
    PointerEncodingUnsigned2, PointerEncodingSigned2:
      Result := 2;
    PointerEncodingUnsigned4, PointerEncodingSigned4:
      Result := 4;
  else
    Result := 0;
  end;
  if Encoding = PointerEncodingOmit then
    Result := 0;
end;

function FindInEhFrameHeader(constref Memory: TCfiMemory; HeaderAddress, Pc: QWord;
  var Entry: TFrameEntry): Boolean;
const
  TableEntrySize = 8;
var
  Header: array[0..31] of Byte;
  Position: LongWord;
  FrameSectionAddress: QWord;
  Count: QWord;
  TableStart: QWord;
  Low, High, Middle: QWord;
  Pair: array[0..1] of LongInt;
begin
  Result := False;
  { Read no further than the two fields: the table may end the page. }
  if not Memory.Read(Memory.Context, HeaderAddress, @Header[0], 4) then
    Exit;
  if (Header[0] <> 1) or (FixedEncodingSize(Header[1]) = 0) or (FixedEncodingSize(Header[2]) = 0) then
    Exit;
  if not Memory.Read(Memory.Context, HeaderAddress + 4, @Header[4],
     FixedEncodingSize(Header[1]) + FixedEncodingSize(Header[2])) then
    Exit;
  Position := 4;
  if not ReadEncodedPointer(@Header[0], SizeOf(Header), Position, Header[1], HeaderAddress, HeaderAddress,
     FrameSectionAddress) then
    Exit;
  if not ReadEncodedPointer(@Header[0], SizeOf(Header), Position, Header[2], HeaderAddress, HeaderAddress,
     Count) then
    Exit;
  { Every linker writes the table as data-relative signed 4-byte pairs. }
  if (Header[3] <> (PointerEncodingDataRelative or PointerEncodingSigned4)) or (Count = 0) or
     (Count > $10000000) then
    Exit;
  TableStart := HeaderAddress + Position;
  { The last entry whose initial location is at or below Pc. }
  Low := 0;
  High := Count;
  while High - Low > 1 do
  begin
    Middle := Low + (High - Low) div 2;
    if not Memory.Read(Memory.Context, TableStart + Middle * TableEntrySize, @Pair[0], TableEntrySize) then
      Exit;
    if AddressPlusOffset(HeaderAddress, Pair[0]) <= Pc then
      Low := Middle
    else
      High := Middle;
  end;
  if not Memory.Read(Memory.Context, TableStart + Low * TableEntrySize, @Pair[0], TableEntrySize) then
    Exit;
  if AddressPlusOffset(HeaderAddress, Pair[0]) > Pc then
    Exit;
  Result := TakeEhFrameEntry(Memory, AddressPlusOffset(HeaderAddress, Pair[1]), Pc, Entry);
end;

{ Reads an FDE's CIE offset and address range in .debug_frame layout
  with a CIE pointer of PointerSize bytes. }
function ReadDebugFrameFields(Bytes: PByte; Size: LongWord; PointerSize: LongWord;
  out CieOffset, Start, Range: QWord): Boolean;
var
  Position: LongWord;
begin
  Start := 0;
  Range := 0;
  Position := 4;
  Result := ReadFixed(Bytes, Size, Position, PointerSize, CieOffset) and
    ReadFixed(Bytes, Size, Position, 8, Start) and ReadFixed(Bytes, Size, Position, 8, Range);
end;

{ Copies the FDE at Offset (TotalSize bytes) and the CIE at CieOffset of
  Section into Entry and checks that the FDE covers Pc. }
function TakeSectionEntry(Section: PByte; SectionSize, Offset, TotalSize, CieOffset, Pc: QWord;
  var Entry: TFrameEntry): Boolean;
var
  Cie: TCommonInformation;
  Fde: TFrameDescription;
begin
  Result := False;
  if CieOffset + 8 > SectionSize then
    Exit;
  if not CopyEntryBytes(Section + Offset, TotalSize, @Entry.Fde[0], Entry.FdeSize) then
    Exit;
  if not CopyEntryBytes(Section + CieOffset, EntryTotalSize(Section + CieOffset, SectionSize - CieOffset),
     @Entry.Cie[0], Entry.CieSize) then
    Exit;
  if not DecodeCommonInformation(Entry, Cie) or not DecodeFrameDescription(Entry, Cie, Fde) then
    Exit;
  Result := (Pc >= Fde.Start) and (Pc < Fde.Finish);
end;

{ Which layout the .debug_frame FDE at Bytes has (4 or 8 byte CIE
  pointer; 0: neither fits), with its CIE offset and range. }
function DebugFrameLayout(Bytes: PByte; Size: LongWord; CodeStart, CodeEnd: QWord;
  out CieOffset, Start, Range: QWord): LongWord;
var
  KnowsCode: Boolean;
begin
  Result := 0;
  KnowsCode := CodeEnd > CodeStart;
  if ReadDebugFrameFields(Bytes, Size, 4, CieOffset, Start, Range) and
     (not KnowsCode or ((Start >= CodeStart) and (Start < CodeEnd))) then
    Exit(4);
  if KnowsCode and ReadDebugFrameFields(Bytes, Size, 8, CieOffset, Start, Range) and
     (Start >= CodeStart) and (Start < CodeEnd) then
    Exit(8);
end;

function FindInFrameSection(Section: PByte; SectionSize: QWord; IsEhFrame: Boolean;
  SectionAddress, Bias, CodeStart, CodeEnd, Pc: QWord; var Entry: TFrameEntry): Boolean;
var
  Offset: QWord;
  TotalSize: QWord;
  Bytes: PByte;
  Position: LongWord;
  Identifier: QWord;
  CieOffset: QWord;
  Start: QWord;
  Range: QWord;
  LinkPc: QWord;
begin
  Result := False;
  if Pc < Bias then
    Exit;
  LinkPc := Pc - Bias;
  Offset := 0;
  while Offset + 8 <= SectionSize do
  begin
    Bytes := Section + Offset;
    TotalSize := EntryTotalSize(Bytes, SectionSize - Offset);
    if TotalSize = 0 then
      Exit;
    Position := 4;
    ReadFixed(Bytes, 8, Position, 4, Identifier);
    if IsEhFrame and (Identifier <> 0) then
    begin
      { An FDE of .eh_frame: its CIE is Identifier bytes back. }
      if Identifier <= Offset + 4 then
      begin
        Entry.IsEhFrame := True;
        Entry.CiePointerSize := 4;
        Entry.AddressBias := Bias;
        Entry.FdeAddress := SectionAddress + Offset;
        Entry.CieAddress := Entry.FdeAddress + 4 - Identifier;
        if TakeSectionEntry(Section, SectionSize, Offset, TotalSize, Offset + 4 - Identifier, Pc, Entry) then
          Exit(True);
      end;
    end
    else if not IsEhFrame and (Identifier <> $FFFFFFFF) and (TotalSize <= CfiEntryCapacity) then
    begin
      { An FDE of .debug_frame, in either layout. }
      Entry.CiePointerSize := DebugFrameLayout(Bytes, LongWord(TotalSize), CodeStart, CodeEnd, CieOffset,
        Start, Range);
      if (Entry.CiePointerSize <> 0) and (LinkPc >= Start) and (LinkPc - Start < Range) then
      begin
        Entry.IsEhFrame := False;
        Entry.AddressBias := Bias;
        Entry.FdeAddress := SectionAddress + Offset;
        Entry.CieAddress := SectionAddress + CieOffset;
        if TakeSectionEntry(Section, SectionSize, Offset, TotalSize, CieOffset, Pc, Entry) then
          Exit(True);
      end;
    end;
    Offset := Offset + TotalSize;
  end;
end;

end.
