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
  Fax compression in TIFF (bilevel pictures, one bit a pixel):

    2  CCITT RLE    every row coded one-dimensionally (Modified Huffman,
                    T.4 runs), starting on a byte, no end-of-line codes
    3  Group 3      T.4: rows after end-of-line codes (EOL, eleven zeros
                    and a one, perhaps after fill bits); with T4Options
                    bit 0, each EOL is followed by a bit saying whether
                    the row is coded in one dimension (1) or two (0)
    4  Group 4      T.6: every row coded two-dimensionally against the
                    row above (the first against a white one), no EOLs

  A one-dimensional row is a white run, then a black one, and so on to
  the width. A two-dimensional row is coded by its changes of colour
  against those of the row above (the reference row): vertically (the
  change is within three pixels of the reference's), horizontally (two
  runs), or by passing a pair of reference changes.

  Rows are written as TIFF has them, a bit a pixel from the highest
  bit, each row starting on a byte: white is 0 and black 1, as libtiff
  gives them (the photometric interpretation says what they look like).

  Where the data runs out or breaks the rules, decoding stops and the
  rows left are white; the uncompressed mode (a T.4 extension almost
  nobody writes) is ImageErrorUnsupported.
}
unit Image.Tiff.Ccitt;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  SysUtils,
  Image.Errors;

type
  TCcittScheme = (CcittModifiedHuffman, CcittGroup3, CcittGroup4);

const
  { T4Options bits. }
  T4OptionTwoDimensional = 1;
  T4OptionUncompressed = 2;
  T4OptionFillBits = 4;
  { T6Options bit. }
  T6OptionUncompressed = 2;

{ Decodes Rows rows of Width pixels from Input into Output (RowBytes
  bytes a row, zeroed by the caller). Options are the T4Options (Group 3)
  or T6Options (Group 4). }
procedure DecodeCcitt(Input: PByte; InputCount: PtrInt; Scheme: TCcittScheme; Options: LongWord;
  Width, Rows: LongInt; Output: PByte; RowBytes: PtrInt);

implementation

uses
  Image.Tiff.CcittCodes;

type
  TFaxBitReader = record
    Data: PByte;
    Count: PtrInt;
    TotalBits: Int64;
    Position: Int64;
  end;

  { Positions where the colour changes along a row, the first to
    black; followed by sentinels at the width. }
  TChangeList = record
    Positions: array of LongInt;
    Count: LongInt;
  end;

  TRowOutcome = (RowDecoded, RowStop);

const
  SentinelCount = 3;
  { Fill bits before an EOL are never this many. }
  MostFillBits = 4096;

function ByteAt(constref Reader: TFaxBitReader; Index: PtrInt): LongWord; inline;
begin
  if Index < Reader.Count then
    Result := Reader.Data[Index]
  else
    Result := 0;
end;

{ The next Bits bits (at most 32), zeros past the end. }
function PeekBits(constref Reader: TFaxBitReader; Bits: LongInt): LongWord;
var
  First: PtrInt;
  Value: QWord;
  Index: LongInt;
begin
  First := Reader.Position shr 3;
  Value := 0;
  for Index := 0 to 4 do
    Value := (Value shl 8) or ByteAt(Reader, First + Index);
  Result := LongWord((Value shr (40 - (Reader.Position and 7) - Bits)) and ((QWord(1) shl Bits) - 1));
end;

procedure SkipBits(var Reader: TFaxBitReader; Bits: LongInt); inline;
begin
  Inc(Reader.Position, Bits);
end;

function AtEnd(constref Reader: TFaxBitReader): Boolean; inline;
begin
  Result := Reader.Position >= Reader.TotalBits;
end;

procedure AlignToByte(var Reader: TFaxBitReader);
begin
  Reader.Position := (Reader.Position + 7) and not Int64(7);
end;

{ One run: make-up codes and a terminating code. False at a code that
  is not one (or past the end of the data). }
function ReadRun(var Reader: TFaxBitReader; Table: PCcittRunTable; Width: LongInt; out Run: LongInt): Boolean;
var
  Entry: TCcittRunEntry;
begin
  Run := 0;
  repeat
    if AtEnd(Reader) then
      Exit(False);
    Entry := Table^[PeekBits(Reader, CcittRunBits)];
    if Entry.Length = 0 then
      Exit(False);
    SkipBits(Reader, Entry.Length);
    Inc(Run, Entry.Run);
    if Run > Width + 2560 then
      Exit(False);
  until Entry.Run < 64;
  Result := True;
end;

procedure StartChanges(var Changes: TChangeList; Width: LongInt);
begin
  if Length(Changes.Positions) < Width + 2 + SentinelCount then
    SetLength(Changes.Positions, Width + 2 + SentinelCount);
  Changes.Count := 0;
end;

procedure AddChange(var Changes: TChangeList; Position, Width: LongInt);
begin
  if Position > Width then
    Position := Width;
  if (Changes.Count > 0) and (Position < Changes.Positions[Changes.Count - 1]) then
    Position := Changes.Positions[Changes.Count - 1];
  if Changes.Count < Width + 2 then
  begin
    Changes.Positions[Changes.Count] := Position;
    Inc(Changes.Count);
  end;
end;

procedure EndChanges(var Changes: TChangeList; Width: LongInt);
var
  Index: LongInt;
begin
  for Index := 0 to SentinelCount - 1 do
    Changes.Positions[Changes.Count + Index] := Width;
end;

function DecodeOneDimensionalRow(var Reader: TFaxBitReader; Width: LongInt; var Changes: TChangeList): TRowOutcome;
var
  Position: LongInt;
  Black: Boolean;
  Run: LongInt;
  Table: PCcittRunTable;
begin
  StartChanges(Changes, Width);
  Position := 0;
  Black := False;
  while Position < Width do
  begin
    if Black then
      Table := BlackRunTable
    else
      Table := WhiteRunTable;
    if not ReadRun(Reader, Table, Width, Run) then
    begin
      EndChanges(Changes, Width);
      Exit(RowStop);
    end;
    Inc(Position, Run);
    if Position > Width then
      Position := Width;
    AddChange(Changes, Position, Width);
    Black := not Black;
  end;
  EndChanges(Changes, Width);
  Result := RowDecoded;
end;

function ReadMode(var Reader: TFaxBitReader): TCcittMode;
var
  Entry: TCcittModeEntry;
begin
  if AtEnd(Reader) then
    Exit(CcittModeNone);
  Entry := ModeTable^[PeekBits(Reader, CcittModeBits)];
  if Entry.Length = 0 then
    Exit(CcittModeNone);
  SkipBits(Reader, Entry.Length);
  Result := Entry.Mode;
end;

const
  VerticalOffsets: array[CcittModeVertical0..CcittModeVerticalLeft3] of LongInt = (0, 1, 2, 3, -1, -2, -3);

function DecodeTwoDimensionalRow(var Reader: TFaxBitReader; Width: LongInt; constref Reference: TChangeList;
  var Changes: TChangeList): TRowOutcome;
var
  A0: LongInt;
  A1: LongInt;
  A2: LongInt;
  B1: LongInt;
  B2: LongInt;
  Black: Boolean;
  ReferenceIndex: LongInt;
  Mode: TCcittMode;
  Start: LongInt;
  FirstRun: LongInt;
  SecondRun: LongInt;
  FirstTable: PCcittRunTable;
  SecondTable: PCcittRunTable;
begin
  StartChanges(Changes, Width);
  A0 := -1;
  Black := False;
  ReferenceIndex := 0;
  Result := RowStop;
  while A0 < Width do
  begin
    { B1: the first change of the reference row right of A0 to the
      colour opposite to A0's (changes to black are at even indexes). }
    while (ReferenceIndex > 0) and (Reference.Positions[ReferenceIndex - 1] > A0) do
      Dec(ReferenceIndex);
    while (ReferenceIndex < Reference.Count) and (Reference.Positions[ReferenceIndex] <= A0) do
      Inc(ReferenceIndex);
    if Odd(ReferenceIndex) <> Black then
      Inc(ReferenceIndex);
    B1 := Reference.Positions[ReferenceIndex];
    B2 := Reference.Positions[ReferenceIndex + 1];
    Mode := ReadMode(Reader);
    case Mode of
      CcittModePass:
        A0 := B2;
      CcittModeHorizontal:
        begin
          Start := A0;
          if Start < 0 then
            Start := 0;
          if Black then
          begin
            FirstTable := BlackRunTable;
            SecondTable := WhiteRunTable;
          end
          else
          begin
            FirstTable := WhiteRunTable;
            SecondTable := BlackRunTable;
          end;
          if not ReadRun(Reader, FirstTable, Width, FirstRun) or not ReadRun(Reader, SecondTable, Width, SecondRun) then
            Break;
          A1 := Start + FirstRun;
          if A1 > Width then
            A1 := Width;
          A2 := A1 + SecondRun;
          if A2 > Width then
            A2 := Width;
          AddChange(Changes, A1, Width);
          AddChange(Changes, A2, Width);
          A0 := A2;
        end;
      CcittModeVertical0..CcittModeVerticalLeft3:
        begin
          A1 := B1 + VerticalOffsets[Mode];
          if (A1 <= A0) or (A1 > Width) then
            Break;
          AddChange(Changes, A1, Width);
          A0 := A1;
          Black := not Black;
        end;
      CcittModeExtension:
        RaiseImageError(ImageErrorUnsupported, 'TIFF CCITT uncompressed mode');
    else
      Break;
    end;
  end;
  if A0 >= Width then
    Result := RowDecoded;
  EndChanges(Changes, Width);
end;

procedure SetBits(Row: PByte; First, Last: LongInt);
var
  Position: LongInt;
begin
  Position := First;
  while (Position < Last) and ((Position and 7) <> 0) do
  begin
    Row[Position shr 3] := Row[Position shr 3] or ($80 shr (Position and 7));
    Inc(Position);
  end;
  while Position + 8 <= Last do
  begin
    Row[Position shr 3] := $FF;
    Inc(Position, 8);
  end;
  while Position < Last do
  begin
    Row[Position shr 3] := Row[Position shr 3] or ($80 shr (Position and 7));
    Inc(Position);
  end;
end;

procedure WriteRow(constref Changes: TChangeList; Width: LongInt; Row: PByte);
var
  Index: LongInt;
  Last: LongInt;
begin
  Index := 0;
  while Index < Changes.Count do
  begin
    if Index + 1 < Changes.Count then
      Last := Changes.Positions[Index + 1]
    else
      Last := Width;
    SetBits(Row, Changes.Positions[Index], Last);
    Inc(Index, 2);
  end;
end;

{ Passes over fill bits and end-of-line codes; True if there was an
  EOL. Ended is True when the data ends there. }
function SkipEndOfLines(var Reader: TFaxBitReader; out Ended: Boolean): Boolean;
var
  Zeros: LongInt;
begin
  Result := False;
  Ended := False;
  repeat
    Zeros := 0;
    while (Zeros < MostFillBits) and (Reader.Position + Zeros < Reader.TotalBits) and
      (PeekBits(Reader, 1) = 0) do
    begin
      Inc(Zeros);
      SkipBits(Reader, 1);
    end;
    if AtEnd(Reader) then
    begin
      Ended := True;
      Exit;
    end;
    if Zeros < CcittEndOfLineZeros then
    begin
      { The zeros were the start of the row's first code. }
      Dec(Reader.Position, Zeros);
      Exit;
    end;
    SkipBits(Reader, 1);
    Result := True;
  until False;
end;

procedure DecodeCcitt(Input: PByte; InputCount: PtrInt; Scheme: TCcittScheme; Options: LongWord;
  Width, Rows: LongInt; Output: PByte; RowBytes: PtrInt);
var
  Reader: TFaxBitReader;
  Reference: TChangeList;
  Current: TChangeList;
  Swap: TChangeList;
  Row: LongInt;
  TwoDimensional: Boolean;
  SawEndOfLine: Boolean;
  Ended: Boolean;
  Outcome: TRowOutcome;
begin
  Reader.Data := Input;
  Reader.Count := InputCount;
  Reader.TotalBits := Int64(InputCount) * 8;
  Reader.Position := 0;
  Reference := Default(TChangeList);
  Current := Default(TChangeList);
  StartChanges(Reference, Width);
  EndChanges(Reference, Width);
  for Row := 0 to Rows - 1 do
  begin
    TwoDimensional := Scheme = CcittGroup4;
    case Scheme of
      CcittModifiedHuffman:
        AlignToByte(Reader);
      CcittGroup3:
        begin
          SawEndOfLine := SkipEndOfLines(Reader, Ended);
          if Ended then
            Exit;
          if SawEndOfLine and ((Options and T4OptionTwoDimensional) <> 0) then
          begin
            TwoDimensional := PeekBits(Reader, 1) = 0;
            SkipBits(Reader, 1);
          end;
        end;
    end;
    if AtEnd(Reader) then
      Exit;
    if TwoDimensional then
      Outcome := DecodeTwoDimensionalRow(Reader, Width, Reference, Current)
    else
      Outcome := DecodeOneDimensionalRow(Reader, Width, Current);
    WriteRow(Current, Width, Output + PtrInt(Row) * RowBytes);
    if Outcome = RowStop then
      Exit;
    Swap := Reference;
    Reference := Current;
    Current := Swap;
  end;
end;

end.
