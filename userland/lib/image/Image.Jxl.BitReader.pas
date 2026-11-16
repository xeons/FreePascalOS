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
  JPEG XL's bit reader: bits are taken from the least significant end
  of each byte first (ISO/IEC 18181-1, the codestream's bit order).

  A reader covers a span of the data (the whole codestream, or one
  section of a frame as its table of contents gives it). Reading past
  the span's end is ImageErrorTruncated; peeking past it gives zeros,
  so a prefix code may look ahead at the last bits.

  Besides plain bits it reads the codestream's field codings: U32 (two
  selector bits choosing one of four distributions), U64, F16 (a half
  precision float), Bool, Enum, and extension blocks (skipped).
}
unit Image.Jxl.BitReader;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Errors;

type
  { One of U32's four distributions: Offset plus Bits bits (0 bits for a
    plain value). }
  TJxlU32Distribution = record
    Offset: LongWord;
    Bits: Byte;
  end;

  TJxlBitReader = class
  private
    FData: TBytes;
    FStart: PtrInt;
    FEnd: PtrInt;
    { The next byte to go into the buffer. }
    FNextByte: PtrInt;
    FBuffer: QWord;
    FBufferedBits: LongInt;
    { Bits consumed since FStart. }
    FConsumed: Int64;
    procedure Refill; inline;
    procedure RaiseTruncated;
  public
    { A reader of Count bytes of Data from Start (clipped to the data). }
    constructor Create(const Data: TBytes; Start, Count: PtrInt);
    { The next Count (0 to 32) bits, without consuming them; zeros past
      the end. }
    function PeekBits(Count: LongInt): LongWord; inline;
    procedure SkipBits(Count: Int64);
    { Count (0 to 32) bits. }
    function ReadBits(Count: LongInt): LongWord;
    function ReadBits64(Count: LongInt): QWord;
    function ReadBool: Boolean;
    function ReadU32(const D0, D1, D2, D3: TJxlU32Distribution): LongWord;
    function ReadU64: QWord;
    function ReadF16: Single;
    function ReadEnum: LongWord;
    { Skips an extensions block (the mask, each extension's size, then
      the extensions themselves). }
    procedure SkipExtensions;
    { Skips to the next byte boundary. }
    procedure ZeroPadToByte;
    { The span's size in bits. }
    function TotalBits: Int64;
    { The offset in Data of the next whole byte. }
    function BytePosition: PtrInt;
    { Bits consumed so far. }
    property BitPosition: Int64 read FConsumed;
    property Data: TBytes read FData;
  end;

function JxlVal(Value: LongWord): TJxlU32Distribution;
function JxlBits(Count: Byte): TJxlU32Distribution;
function JxlBitsOffset(Count: Byte; Offset: LongWord): TJxlU32Distribution;
{ 0, 1, 2, 3, 4... as 0, -1, 1, -2, 2... }
function JxlUnpackSigned(Value: LongWord): LongInt; inline;
function JxlUnpackSigned64(Value: QWord): Int64; inline;

implementation

function JxlVal(Value: LongWord): TJxlU32Distribution;
begin
  Result.Offset := Value;
  Result.Bits := 0;
end;

function JxlBits(Count: Byte): TJxlU32Distribution;
begin
  Result.Offset := 0;
  Result.Bits := Count;
end;

function JxlBitsOffset(Count: Byte; Offset: LongWord): TJxlU32Distribution;
begin
  Result.Offset := Offset;
  Result.Bits := Count;
end;

function JxlUnpackSigned(Value: LongWord): LongInt;
begin
  if (Value and 1) <> 0 then
    Result := -LongInt(Value shr 1) - 1
  else
    Result := LongInt(Value shr 1);
end;

function JxlUnpackSigned64(Value: QWord): Int64;
begin
  if (Value and 1) <> 0 then
    Result := -Int64(Value shr 1) - 1
  else
    Result := Int64(Value shr 1);
end;

constructor TJxlBitReader.Create(const Data: TBytes; Start, Count: PtrInt);
begin
  inherited Create;
  FData := Data;
  if Start < 0 then
    Start := 0;
  if Start > Length(Data) then
    Start := Length(Data);
  if (Count < 0) or (Count > Length(Data) - Start) then
    Count := Length(Data) - Start;
  FStart := Start;
  FEnd := Start + Count;
  FNextByte := Start;
  FBuffer := 0;
  FBufferedBits := 0;
  FConsumed := 0;
end;

procedure TJxlBitReader.RaiseTruncated;
begin
  FConsumed := TotalBits;
  RaiseImageError(ImageErrorTruncated, 'JPEG XL codestream');
end;

procedure TJxlBitReader.Refill;
begin
  while (FBufferedBits <= 56) and (FNextByte < FEnd) do
  begin
    FBuffer := FBuffer or (QWord(FData[FNextByte]) shl FBufferedBits);
    Inc(FNextByte);
    Inc(FBufferedBits, 8);
  end;
end;

function TJxlBitReader.PeekBits(Count: LongInt): LongWord;
begin
  if FBufferedBits < Count then
    Refill;
  Result := LongWord(FBuffer and ((QWord(1) shl Count) - 1));
end;

procedure TJxlBitReader.SkipBits(Count: Int64);
var
  Whole: Int64;
begin
  if Count <= 0 then
    Exit;
  if Count > TotalBits - FConsumed then
    RaiseTruncated;
  Inc(FConsumed, Count);
  if Count <= FBufferedBits then
  begin
    FBuffer := FBuffer shr Count;
    Dec(FBufferedBits, LongInt(Count));
    Exit;
  end;
  Dec(Count, FBufferedBits);
  FBuffer := 0;
  FBufferedBits := 0;
  Whole := Count div 8;
  Inc(FNextByte, PtrInt(Whole));
  Dec(Count, Whole * 8);
  Refill;
  FBuffer := FBuffer shr Count;
  Dec(FBufferedBits, LongInt(Count));
end;

function TJxlBitReader.ReadBits(Count: LongInt): LongWord;
begin
  if Count = 0 then
    Exit(0);
  if FBufferedBits < Count then
    Refill;
  if Count > TotalBits - FConsumed then
    RaiseTruncated;
  Result := LongWord(FBuffer and ((QWord(1) shl Count) - 1));
  FBuffer := FBuffer shr Count;
  Dec(FBufferedBits, Count);
  Inc(FConsumed, Count);
end;

function TJxlBitReader.ReadBits64(Count: LongInt): QWord;
var
  Low: QWord;
begin
  if Count <= 32 then
    Exit(ReadBits(Count));
  Low := ReadBits(32);
  Result := Low or (QWord(ReadBits(Count - 32)) shl 32);
end;

function TJxlBitReader.ReadBool: Boolean;
begin
  Result := ReadBits(1) <> 0;
end;

function TJxlBitReader.ReadU32(const D0, D1, D2, D3: TJxlU32Distribution): LongWord;
var
  Distribution: TJxlU32Distribution;
begin
  case ReadBits(2) of
    0: Distribution := D0;
    1: Distribution := D1;
    2: Distribution := D2;
  else
    Distribution := D3;
  end;
  Result := LongWord((QWord(Distribution.Offset) + ReadBits(Distribution.Bits)) and $FFFFFFFF);
end;

function TJxlBitReader.ReadU64: QWord;
var
  Shift: LongInt;
begin
  case ReadBits(2) of
    0: Result := 0;
    1: Result := 1 + ReadBits(4);
    2: Result := 17 + ReadBits(8);
  else
    begin
      Result := ReadBits(12);
      Shift := 12;
      while ReadBool do
      begin
        if Shift = 60 then
        begin
          Result := Result or (QWord(ReadBits(4)) shl 60);
          Break;
        end;
        Result := Result or (QWord(ReadBits(8)) shl Shift);
        Inc(Shift, 8);
      end;
    end;
  end;
end;

function TJxlBitReader.ReadF16: Single;
var
  Bits16: LongWord;
  Sign: LongWord;
  Exponent: LongWord;
  Mantissa: LongWord;
  Bits32: LongWord;
begin
  Bits16 := ReadBits(16);
  Sign := Bits16 shr 15;
  Exponent := (Bits16 shr 10) and $1F;
  Mantissa := Bits16 and $3FF;
  if Exponent = 31 then
    RaiseImageError(ImageErrorMalformed, 'JPEG XL: infinite or NaN half float');
  if Exponent = 0 then
  begin
    Result := (1.0 / 16384) * (Mantissa * (1.0 / 1024));
    if Sign <> 0 then
      Result := -Result;
    Exit;
  end;
  Bits32 := (Sign shl 31) or ((Exponent + (127 - 15)) shl 23) or (Mantissa shl 13);
  Move(Bits32, Result, SizeOf(Result));
end;

function TJxlBitReader.ReadEnum: LongWord;
begin
  Result := ReadU32(JxlVal(0), JxlVal(1), JxlBitsOffset(4, 2), JxlBitsOffset(6, 18));
  if Result >= 64 then
    RaiseImageError(ImageErrorMalformed, 'JPEG XL: enum value out of range');
end;

procedure TJxlBitReader.SkipExtensions;
var
  Mask: QWord;
  Total: QWord;
  Size: QWord;
  Bit: LongInt;
begin
  Mask := ReadU64;
  if Mask = 0 then
    Exit;
  Total := 0;
  for Bit := 0 to 63 do
    if (Mask and (QWord(1) shl Bit)) <> 0 then
    begin
      Size := ReadU64;
      if (Size > QWord(TotalBits)) or (Total + Size > QWord(TotalBits)) then
        RaiseTruncated;
      Inc(Total, Size);
    end;
  SkipBits(Int64(Total));
end;

procedure TJxlBitReader.ZeroPadToByte;
var
  Remainder: LongInt;
begin
  Remainder := LongInt(FConsumed and 7);
  if Remainder <> 0 then
    SkipBits(8 - Remainder);
end;

function TJxlBitReader.TotalBits: Int64;
begin
  Result := Int64(FEnd - FStart) * 8;
end;

function TJxlBitReader.BytePosition: PtrInt;
begin
  Result := FStart + PtrInt((FConsumed + 7) div 8);
end;

end.
