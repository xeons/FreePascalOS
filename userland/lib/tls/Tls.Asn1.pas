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
  A strict reader of ASN.1 DER (ITU-T X.690), as certificates are
  written.

  An element is its tag (the whole identifier byte: class, constructed
  bit and a number below 31, which is all X.509 uses), its contents and
  its whole encoding. Lengths must be definite and as short as possible
  (DER), and every element must lie inside its parent; anything else is
  refused, so nothing malformed gets further than this unit. Readers
  never look outside the bytes they were given.
}
unit Tls.Asn1;

{$mode objfpc}
{$pointermath on}

interface

const
  Asn1Boolean = $01;
  Asn1Integer = $02;
  Asn1BitString = $03;
  Asn1OctetString = $04;
  Asn1Null = $05;
  Asn1ObjectIdentifier = $06;
  Asn1Utf8String = $0C;
  Asn1PrintableString = $13;
  Asn1TeletexString = $14;
  Asn1Ia5String = $16;
  Asn1UtcTime = $17;
  Asn1GeneralizedTime = $18;
  Asn1UniversalString = $1C;
  Asn1BmpString = $1E;
  Asn1Sequence = $30;
  Asn1Set = $31;
  { [n] in a context: Asn1ContextSpecific + n, or'ed with
    Asn1Constructed for constructed ones. }
  Asn1ContextSpecific = $80;
  Asn1Constructed = $20;

type
  TAsn1Element = record
    Tag: Byte;
    Contents: PByte;
    ContentsLength: PtrUInt;
    { The identifier, length and contents together. }
    Encoding: PByte;
    EncodingLength: PtrUInt;
  end;

  TAsn1Reader = record
    Position: PByte;
    Limit: PByte;
  end;

procedure InitializeAsn1Reader(out Reader: TAsn1Reader; Data: PByte; Length: PtrUInt);
{ A reader over an element's contents. }
procedure OpenAsn1Element(out Reader: TAsn1Reader; constref Element: TAsn1Element);
function Asn1ReaderAtEnd(constref Reader: TAsn1Reader): Boolean;

function ReadAsn1Element(var Reader: TAsn1Reader; out Element: TAsn1Element): Boolean;
{ The next element, which must have Tag. }
function ReadAsn1Expected(var Reader: TAsn1Reader; Tag: Byte; out Element: TAsn1Element): Boolean;
{ Present is True when the next element has Tag (it is then read);
  False (and nothing read) otherwise. Fails only on malformed data. }
function ReadAsn1Optional(var Reader: TAsn1Reader; Tag: Byte; out Element: TAsn1Element;
  out Present: Boolean): Boolean;
function PeekAsn1Tag(constref Reader: TAsn1Reader; out Tag: Byte): Boolean;

function Asn1ObjectIdentifierIs(constref Element: TAsn1Element; Identifier: PByte; IdentifierLength: PtrUInt): Boolean;
{ A non-negative INTEGER in its shortest form; Magnitude points at it
  without the leading zero byte a high bit needs. }
function ReadAsn1UnsignedInteger(constref Element: TAsn1Element; out Magnitude: PByte;
  out MagnitudeLength: PtrUInt): Boolean;
{ A non-negative INTEGER that fits in 31 bits. }
function ReadAsn1SmallInteger(constref Element: TAsn1Element; out Value: LongInt): Boolean;
{ DER booleans are 00 or FF. }
function ReadAsn1BooleanValue(constref Element: TAsn1Element; out Value: Boolean): Boolean;
{ A BIT STRING holding whole bytes (keys, signatures). }
function ReadAsn1BitStringBytes(constref Element: TAsn1Element; out Bytes: PByte; out Count: PtrUInt): Boolean;
{ A BIT STRING of named bits (KeyUsage): bit n of the result is bit n
  of the string (the first bit is bit 0). Up to 32 bits. }
function ReadAsn1BitFlags(constref Element: TAsn1Element; out Flags: LongWord): Boolean;
{ UTCTime (YYMMDDHHMMSSZ, years 1950-2049) or GeneralizedTime
  (YYYYMMDDHHMMSSZ), as Unix seconds. Fractions and offsets are refused,
  as RFC 5280 requires. }
function ReadAsn1Time(constref Element: TAsn1Element; out Time: Int64): Boolean;

implementation

uses
  Runtime.Time;

procedure InitializeAsn1Reader(out Reader: TAsn1Reader; Data: PByte; Length: PtrUInt);
begin
  Reader.Position := Data;
  Reader.Limit := Data + Length;
end;

procedure OpenAsn1Element(out Reader: TAsn1Reader; constref Element: TAsn1Element);
begin
  InitializeAsn1Reader(Reader, Element.Contents, Element.ContentsLength);
end;

function Asn1ReaderAtEnd(constref Reader: TAsn1Reader): Boolean;
begin
  Result := Reader.Position >= Reader.Limit;
end;

function ReadAsn1Element(var Reader: TAsn1Reader; out Element: TAsn1Element): Boolean;
var
  Remaining: PtrUInt;
  Cursor: PByte;
  FirstLengthByte: Byte;
  LengthByteCount: Integer;
  ContentsLength: PtrUInt;
  Index: Integer;
begin
  FillChar(Element, SizeOf(Element), 0);
  Result := False;
  if Reader.Position >= Reader.Limit then
    Exit;
  Remaining := PtrUInt(Reader.Limit - Reader.Position);
  if Remaining < 2 then
    Exit;
  Cursor := Reader.Position;
  { High tag numbers (31 and up) are not used by X.509. }
  if (Cursor[0] and $1F) = $1F then
    Exit;
  Element.Tag := Cursor[0];
  FirstLengthByte := Cursor[1];
  Cursor := Cursor + 2;
  Remaining := Remaining - 2;
  if FirstLengthByte < $80 then
    ContentsLength := FirstLengthByte
  else
  begin
    { Long form: 1 to 4 length bytes; indefinite ($80) is not DER. }
    LengthByteCount := FirstLengthByte and $7F;
    if (LengthByteCount = 0) or (LengthByteCount > 4) or (PtrUInt(LengthByteCount) > Remaining) then
      Exit;
    { No leading zero byte. }
    if Cursor[0] = 0 then
      Exit;
    ContentsLength := 0;
    for Index := 0 to LengthByteCount - 1 do
      ContentsLength := (ContentsLength shl 8) or Cursor[Index];
    { The short form must be used when it can be. }
    if ContentsLength < $80 then
      Exit;
    Cursor := Cursor + LengthByteCount;
    Remaining := Remaining - PtrUInt(LengthByteCount);
  end;
  if ContentsLength > Remaining then
    Exit;
  Element.Contents := Cursor;
  Element.ContentsLength := ContentsLength;
  Element.Encoding := Reader.Position;
  Element.EncodingLength := PtrUInt(Cursor - Reader.Position) + ContentsLength;
  Reader.Position := Cursor + ContentsLength;
  Result := True;
end;

function ReadAsn1Expected(var Reader: TAsn1Reader; Tag: Byte; out Element: TAsn1Element): Boolean;
begin
  Result := ReadAsn1Element(Reader, Element) and (Element.Tag = Tag);
end;

function PeekAsn1Tag(constref Reader: TAsn1Reader; out Tag: Byte): Boolean;
begin
  Tag := 0;
  Result := Reader.Position < Reader.Limit;
  if Result then
    Tag := Reader.Position[0];
end;

function ReadAsn1Optional(var Reader: TAsn1Reader; Tag: Byte; out Element: TAsn1Element;
  out Present: Boolean): Boolean;
var
  NextTag: Byte;
begin
  FillChar(Element, SizeOf(Element), 0);
  Present := PeekAsn1Tag(Reader, NextTag) and (NextTag = Tag);
  if not Present then
    Exit(True);
  Result := ReadAsn1Element(Reader, Element);
end;

function Asn1ObjectIdentifierIs(constref Element: TAsn1Element; Identifier: PByte; IdentifierLength: PtrUInt): Boolean;
begin
  Result := (Element.Tag = Asn1ObjectIdentifier) and (Element.ContentsLength = IdentifierLength) and
    (CompareByte(Element.Contents^, Identifier^, IdentifierLength) = 0);
end;

function ReadAsn1UnsignedInteger(constref Element: TAsn1Element; out Magnitude: PByte;
  out MagnitudeLength: PtrUInt): Boolean;
begin
  Magnitude := nil;
  MagnitudeLength := 0;
  if (Element.Tag <> Asn1Integer) or (Element.ContentsLength = 0) then
    Exit(False);
  { Negative numbers are refused. }
  if (Element.Contents[0] and $80) <> 0 then
    Exit(False);
  Magnitude := Element.Contents;
  MagnitudeLength := Element.ContentsLength;
  if (MagnitudeLength > 1) and (Magnitude[0] = 0) then
  begin
    { A leading zero is only there for a high bit that follows. }
    if (Magnitude[1] and $80) = 0 then
      Exit(False);
    Inc(Magnitude);
    Dec(MagnitudeLength);
  end;
  Result := True;
end;

function ReadAsn1SmallInteger(constref Element: TAsn1Element; out Value: LongInt): Boolean;
var
  Magnitude: PByte;
  MagnitudeLength: PtrUInt;
  Index: PtrUInt;
begin
  Value := 0;
  if not ReadAsn1UnsignedInteger(Element, Magnitude, MagnitudeLength) then
    Exit(False);
  if (MagnitudeLength > 4) or ((MagnitudeLength = 4) and (Magnitude[0] >= $80)) then
    Exit(False);
  Index := 0;
  while Index < MagnitudeLength do
  begin
    Value := (Value shl 8) or Magnitude[Index];
    Inc(Index);
  end;
  Result := True;
end;

function ReadAsn1BooleanValue(constref Element: TAsn1Element; out Value: Boolean): Boolean;
begin
  Value := False;
  Result := (Element.Tag = Asn1Boolean) and (Element.ContentsLength = 1) and
    ((Element.Contents[0] = 0) or (Element.Contents[0] = $FF));
  if Result then
    Value := Element.Contents[0] = $FF;
end;

function ReadAsn1BitStringBytes(constref Element: TAsn1Element; out Bytes: PByte; out Count: PtrUInt): Boolean;
begin
  Bytes := nil;
  Count := 0;
  { The first byte counts the unused bits at the end: none here. }
  if (Element.Tag <> Asn1BitString) or (Element.ContentsLength < 1) or (Element.Contents[0] <> 0) then
    Exit(False);
  Bytes := Element.Contents + 1;
  Count := Element.ContentsLength - 1;
  Result := True;
end;

function ReadAsn1BitFlags(constref Element: TAsn1Element; out Flags: LongWord): Boolean;
var
  UnusedBits: Byte;
  ByteCount: PtrUInt;
  ByteIndex: PtrUInt;
  Bit: Integer;
begin
  Flags := 0;
  if (Element.Tag <> Asn1BitString) or (Element.ContentsLength < 1) then
    Exit(False);
  UnusedBits := Element.Contents[0];
  ByteCount := Element.ContentsLength - 1;
  if (UnusedBits > 7) or ((ByteCount = 0) and (UnusedBits <> 0)) or (ByteCount > 4) then
    Exit(False);
  { DER: the unused bits are zero. }
  if (ByteCount > 0) and ((Element.Contents[ByteCount] and ((1 shl UnusedBits) - 1)) <> 0) then
    Exit(False);
  ByteIndex := 0;
  while ByteIndex < ByteCount do
  begin
    for Bit := 0 to 7 do
      if (Element.Contents[1 + ByteIndex] and ($80 shr Bit)) <> 0 then
        Flags := Flags or (LongWord(1) shl (8 * ByteIndex + PtrUInt(Bit)));
    Inc(ByteIndex);
  end;
  Result := True;
end;

{ Count decimal digits at Text into Value. }
function ReadDigits(Text: PByte; Count: Integer; out Value: LongInt): Boolean;
var
  Index: Integer;
begin
  Value := 0;
  for Index := 0 to Count - 1 do
  begin
    if (Text[Index] < Ord('0')) or (Text[Index] > Ord('9')) then
      Exit(False);
    Value := Value * 10 + (Text[Index] - Ord('0'));
  end;
  Result := True;
end;

function DaysInMonth(Year, Month: LongInt): LongInt;
begin
  case Month of
    4, 6, 9, 11: Result := 30;
    2:
      if ((Year mod 4 = 0) and (Year mod 100 <> 0)) or (Year mod 400 = 0) then
        Result := 29
      else
        Result := 28;
  else
    Result := 31;
  end;
end;

function ReadAsn1Time(constref Element: TAsn1Element; out Time: Int64): Boolean;
var
  Text: PByte;
  YearDigits: Integer;
  Year, Month, Day, Hour, Minute, Second: LongInt;
begin
  Time := 0;
  Result := False;
  if Element.Tag = Asn1UtcTime then
    YearDigits := 2
  else if Element.Tag = Asn1GeneralizedTime then
    YearDigits := 4
  else
    Exit;
  if Element.ContentsLength <> PtrUInt(YearDigits + 11) then
    Exit;
  Text := Element.Contents;
  if Text[YearDigits + 10] <> Ord('Z') then
    Exit;
  if not ReadDigits(Text, YearDigits, Year) or not ReadDigits(Text + YearDigits, 2, Month) or
     not ReadDigits(Text + YearDigits + 2, 2, Day) or not ReadDigits(Text + YearDigits + 4, 2, Hour) or
     not ReadDigits(Text + YearDigits + 6, 2, Minute) or not ReadDigits(Text + YearDigits + 8, 2, Second) then
    Exit;
  if YearDigits = 2 then
  begin
    if Year >= 50 then
      Year := Year + 1900
    else
      Year := Year + 2000;
  end;
  if (Month < 1) or (Month > 12) or (Day < 1) or (Day > DaysInMonth(Year, Month)) or (Hour > 23) or
     (Minute > 59) or (Second > 59) then
    Exit;
  Time := CalendarToUnixTime(Year, Month, Day, Hour, Minute, Second);
  Result := True;
end;

end.
