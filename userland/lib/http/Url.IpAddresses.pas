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
  IPv4 and IPv6 hosts of URLs (URL Standard sections 3.4 and 3.5):

  - IPv4: one to four dot separated numbers, each decimal, octal
    ("0" in front) or hexadecimal ("0x"), the last filling the bytes
    the others leave ("127.1" is 127.0.0.1, "0x7f000001" too); a host
    that "ends in a number" must be one;
  - IPv6: eight groups, "::" once, an IPv4 address in the last 32 bits;
    serialized in lower case with the first longest run of zero groups
    (two or more) compressed.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.IpAddresses;

{$mode objfpc}
{$H+}

interface

type
  TIpv6Groups = array[0..7] of Word;

function ParseIpv4(const Text: string; out Address: LongWord): Boolean;
{ True if the last label of a domain is a number (so the domain must
  parse as IPv4). }
function EndsInNumber(const Domain: string): Boolean;
function SerializeIpv4(Address: LongWord): string;
{ Text is what is between the brackets. }
function ParseIpv6(const Text: string; out Address: TIpv6Groups): Boolean;
function SerializeIpv6(constref Address: TIpv6Groups): string;

implementation

uses
  SysUtils;

const
  { Larger values are only ever refused; parsing stops growing them. }
  NumberCeiling = QWord($1FFFFFFFF);

{ One part: decimal, "0" octal or "0x" hexadecimal; an empty part after
  the prefix is 0. }
function ParseIpv4Number(const Text: string; out Value: QWord): Boolean;
var
  Radix, Start, Index, Digit: Integer;
begin
  Value := 0;
  if Text = '' then
    Exit(False);
  Radix := 10;
  Start := 1;
  if (Length(Text) >= 2) and (Text[1] = '0') and (Text[2] in ['x', 'X']) then
  begin
    Radix := 16;
    Start := 3;
  end
  else if (Length(Text) >= 2) and (Text[1] = '0') then
  begin
    Radix := 8;
    Start := 2;
  end;
  for Index := Start to Length(Text) do
  begin
    case Text[Index] of
      '0'..'9': Digit := Ord(Text[Index]) - Ord('0');
      'a'..'f': Digit := Ord(Text[Index]) - Ord('a') + 10;
      'A'..'F': Digit := Ord(Text[Index]) - Ord('A') + 10;
    else
      Exit(False);
    end;
    if Digit >= Radix then
      Exit(False);
    if Value <= NumberCeiling then
      Value := Value * QWord(Radix) + QWord(Digit);
  end;
  Result := True;
end;

{ The dot separated parts, a final empty one (a trailing dot) dropped. }
function SplitParts(const Text: string): TStringArray;
begin
  Result := Text.Split(['.']);
  if (Length(Result) > 1) and (Result[High(Result)] = '') then
    SetLength(Result, Length(Result) - 1);
end;

function ParseIpv4(const Text: string; out Address: LongWord): Boolean;
var
  Parts: TStringArray;
  Numbers: array[0..3] of QWord;
  Index, Count: Integer;
  Limit, Total: QWord;
begin
  Address := 0;
  Parts := SplitParts(Text);
  Count := Length(Parts);
  if (Count = 0) or (Count > 4) then
    Exit(False);
  for Index := 0 to Count - 1 do
    if not ParseIpv4Number(Parts[Index], Numbers[Index]) then
      Exit(False);
  for Index := 0 to Count - 2 do
    if Numbers[Index] > 255 then
      Exit(False);
  Limit := QWord(1) shl (8 * (5 - Count));
  if Numbers[Count - 1] >= Limit then
    Exit(False);
  Total := Numbers[Count - 1];
  for Index := 0 to Count - 2 do
    Total := Total + (Numbers[Index] shl (8 * (3 - Index)));
  Address := LongWord(Total);
  Result := True;
end;

function EndsInNumber(const Domain: string): Boolean;
var
  Parts: TStringArray;
  Last: string;
  Value: QWord;
  Character: Char;
  AllDigits: Boolean;
begin
  Parts := Domain.Split(['.']);
  if (Length(Parts) > 0) and (Parts[High(Parts)] = '') then
  begin
    if Length(Parts) = 1 then
      Exit(False);
    SetLength(Parts, Length(Parts) - 1);
  end;
  if Length(Parts) = 0 then
    Exit(False);
  Last := Parts[High(Parts)];
  if Last = '' then
    Exit(False);
  AllDigits := True;
  for Character in Last do
    if not (Character in ['0'..'9']) then
      AllDigits := False;
  Result := AllDigits or ParseIpv4Number(Last, Value);
end;

function SerializeIpv4(Address: LongWord): string;
begin
  Result := IntToStr(Address shr 24) + '.' + IntToStr((Address shr 16) and 255) + '.' +
    IntToStr((Address shr 8) and 255) + '.' + IntToStr(Address and 255);
end;

function ParseIpv6(const Text: string; out Address: TIpv6Groups): Boolean;
var
  Position, PieceIndex, Compress, Length_, Swaps: Integer;
  Value, NumbersSeen, Ipv4Piece, Swap: Integer;
  HasIpv4Piece: Boolean;

  function C: Char;
  begin
    if Position <= Length(Text) then
      C := Text[Position]
    else
      C := #0;
  end;

  function AtEnd: Boolean;
  begin
    AtEnd := Position > Length(Text);
  end;

begin
  Address := Default(TIpv6Groups);
  Result := False;
  PieceIndex := 0;
  Compress := -1;
  Position := 1;
  if C = ':' then
  begin
    if (Length(Text) < 2) or (Text[2] <> ':') then
      Exit;
    Inc(Position, 2);
    Inc(PieceIndex);
    Compress := PieceIndex;
  end;
  while not AtEnd do
  begin
    if PieceIndex = 8 then
      Exit;
    if C = ':' then
    begin
      if Compress >= 0 then
        Exit;
      Inc(Position);
      Inc(PieceIndex);
      Compress := PieceIndex;
      Continue;
    end;
    Value := 0;
    Length_ := 0;
    while (Length_ < 4) and (C in ['0'..'9', 'a'..'f', 'A'..'F']) do
    begin
      case C of
        '0'..'9': Value := Value * 16 + Ord(C) - Ord('0');
        'a'..'f': Value := Value * 16 + Ord(C) - Ord('a') + 10;
      else
        Value := Value * 16 + Ord(C) - Ord('A') + 10;
      end;
      Inc(Position);
      Inc(Length_);
    end;
    if C = '.' then
    begin
      if Length_ = 0 then
        Exit;
      Dec(Position, Length_);
      if PieceIndex > 6 then
        Exit;
      NumbersSeen := 0;
      while not AtEnd do
      begin
        HasIpv4Piece := False;
        Ipv4Piece := 0;
        if NumbersSeen > 0 then
        begin
          if (C = '.') and (NumbersSeen < 4) then
            Inc(Position)
          else
            Exit;
        end;
        if not (C in ['0'..'9']) then
          Exit;
        while C in ['0'..'9'] do
        begin
          if not HasIpv4Piece then
          begin
            Ipv4Piece := Ord(C) - Ord('0');
            HasIpv4Piece := True;
          end
          else if Ipv4Piece = 0 then
            Exit
          else
            Ipv4Piece := Ipv4Piece * 10 + Ord(C) - Ord('0');
          if Ipv4Piece > 255 then
            Exit;
          Inc(Position);
        end;
        Address[PieceIndex] := Word(Address[PieceIndex] * $100 + Ipv4Piece);
        Inc(NumbersSeen);
        if (NumbersSeen = 2) or (NumbersSeen = 4) then
          Inc(PieceIndex);
      end;
      if NumbersSeen <> 4 then
        Exit;
      Break;
    end
    else if C = ':' then
    begin
      Inc(Position);
      if AtEnd then
        Exit;
    end
    else if not AtEnd then
      Exit;
    Address[PieceIndex] := Value;
    Inc(PieceIndex);
  end;
  if Compress >= 0 then
  begin
    Swaps := PieceIndex - Compress;
    PieceIndex := 7;
    while (PieceIndex <> 0) and (Swaps > 0) do
    begin
      Swap := Address[PieceIndex];
      Address[PieceIndex] := Address[Compress + Swaps - 1];
      Address[Compress + Swaps - 1] := Swap;
      Dec(PieceIndex);
      Dec(Swaps);
    end;
  end
  else if PieceIndex <> 8 then
    Exit;
  Result := True;
end;

function SerializeIpv6(constref Address: TIpv6Groups): string;
var
  Index, RunStart, RunLength, BestStart, BestLength: Integer;
  IgnoreZero: Boolean;
begin
  { The first longest run of two or more zero groups. }
  BestStart := -1;
  BestLength := 1;
  Index := 0;
  while Index < 8 do
  begin
    if Address[Index] = 0 then
    begin
      RunStart := Index;
      while (Index < 8) and (Address[Index] = 0) do
        Inc(Index);
      RunLength := Index - RunStart;
      if RunLength > BestLength then
      begin
        BestStart := RunStart;
        BestLength := RunLength;
      end;
    end
    else
      Inc(Index);
  end;
  Result := '';
  IgnoreZero := False;
  for Index := 0 to 7 do
  begin
    if IgnoreZero and (Address[Index] = 0) then
      Continue;
    IgnoreZero := False;
    if Index = BestStart then
    begin
      if Index = 0 then
        Result := Result + '::'
      else
        Result := Result + ':';
      IgnoreZero := True;
      Continue;
    end;
    Result := Result + LowerCase(IntToHex(Address[Index], 1));
    if Index <> 7 then
      Result := Result + ':';
  end;
end;

end.
