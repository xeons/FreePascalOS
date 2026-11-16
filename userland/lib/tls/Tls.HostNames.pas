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
  Whether a certificate is for the host a program connected to (RFC
  6125, RFC 9525, as browsers do it):

  - only the subject alternative names count; the subject's common name
    is never used;
  - a numeric IPv4 address matches only an iPAddress name;
  - DNS names compare without regard to ASCII case, a final dot on the
    host ignored;
  - a wildcard is allowed only as the whole leftmost label ("*.example.
    com"), stands for exactly one non-empty label, and needs at least
    two labels after it ("*.com" matches nothing); partial wildcards
    ("f*.example.com") match nothing.
}
unit Tls.HostNames;

{$mode objfpc}
{$pointermath on}

interface

uses
  Tls.Certificates;

function CertificateMatchesHost(constref Certificate: TTlsCertificate; HostName: PChar): Boolean;

{ A dotted quad (four decimal parts, 0-255): the address in Address. }
function ParseIpv4Literal(HostName: PChar; out Address: array of Byte): Boolean;

{ The matching rule for one dNSName pattern (exposed for the tests). }
function DnsNameMatches(Pattern: PByte; PatternLength: PtrUInt; HostName: PByte; HostLength: PtrUInt): Boolean;

implementation

uses
  Tls.Asn1,
  Tls.ByteBuffers;

function LowerAscii(Character: Byte): Byte;
begin
  if (Character >= Ord('A')) and (Character <= Ord('Z')) then
    Result := Character + 32
  else
    Result := Character;
end;

function EqualIgnoringCase(First: PByte; Second: PByte; Count: PtrUInt): Boolean;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Index < Count do
  begin
    if LowerAscii(First[Index]) <> LowerAscii(Second[Index]) then
      Exit(False);
    Inc(Index);
  end;
  Result := True;
end;

function TextLength(Text: PChar): PtrUInt;
begin
  Result := 0;
  while Text[Result] <> #0 do
    Inc(Result);
end;

function ParseIpv4Literal(HostName: PChar; out Address: array of Byte): Boolean;
var
  Part: Integer;
  Value: Integer;
  Digits: Integer;
  Position: PtrUInt;
begin
  Result := False;
  if (HostName = nil) or (Length(Address) < 4) then
    Exit;
  Position := 0;
  for Part := 0 to 3 do
  begin
    Value := 0;
    Digits := 0;
    while (HostName[Position] >= '0') and (HostName[Position] <= '9') do
    begin
      Value := Value * 10 + (Ord(HostName[Position]) - Ord('0'));
      Inc(Digits);
      Inc(Position);
      if (Digits > 3) or (Value > 255) then
        Exit;
    end;
    if Digits = 0 then
      Exit;
    Address[Part] := Byte(Value);
    if Part < 3 then
    begin
      if HostName[Position] <> '.' then
        Exit;
      Inc(Position);
    end;
  end;
  Result := HostName[Position] = #0;
end;

function CountLabels(Name: PByte; Length: PtrUInt): Integer;
var
  Index: PtrUInt;
begin
  Result := 1;
  Index := 0;
  while Index < Length do
  begin
    if Name[Index] = Ord('.') then
      Inc(Result);
    Inc(Index);
  end;
end;

function DnsNameMatches(Pattern: PByte; PatternLength: PtrUInt; HostName: PByte; HostLength: PtrUInt): Boolean;
var
  Index: PtrUInt;
  HostLabelEnd: PtrUInt;
  Suffix: PByte;
  SuffixLength: PtrUInt;
begin
  Result := False;
  if (PatternLength = 0) or (HostLength = 0) then
    Exit;
  { A pattern with a final dot is not a valid dNSName. }
  if Pattern[PatternLength - 1] = Ord('.') then
    Exit;
  { Only letters, digits, hyphens, dots and a leading "*." belong in a
    dNSName. }
  Index := 0;
  while Index < PatternLength do
  begin
    if not (Chr(Pattern[Index]) in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '*']) then
      Exit;
    if (Pattern[Index] = Ord('*')) and (Index <> 0) then
      Exit;
    Inc(Index);
  end;

  if Pattern[0] <> Ord('*') then
    Exit((PatternLength = HostLength) and EqualIgnoringCase(Pattern, HostName, HostLength));

  { "*." and at least two more labels. }
  if (PatternLength < 3) or (Pattern[1] <> Ord('.')) then
    Exit;
  Suffix := Pattern + 1;
  SuffixLength := PatternLength - 1;
  if CountLabels(Suffix + 1, SuffixLength - 1) < 2 then
    Exit;
  { The host's first label: not empty, then the same suffix. }
  HostLabelEnd := 0;
  while (HostLabelEnd < HostLength) and (HostName[HostLabelEnd] <> Ord('.')) do
    Inc(HostLabelEnd);
  if (HostLabelEnd = 0) or (HostLabelEnd = HostLength) then
    Exit;
  Result := (HostLength - HostLabelEnd = SuffixLength) and
    EqualIgnoringCase(HostName + HostLabelEnd, Suffix, SuffixLength);
end;

function CertificateMatchesHost(constref Certificate: TTlsCertificate; HostName: PChar): Boolean;
var
  Reader: TAsn1Reader;
  Name: TAsn1Element;
  HostLength: PtrUInt;
  Address: array[0..3] of Byte;
  IsAddress: Boolean;
begin
  Result := False;
  if (HostName = nil) or not Certificate.HasSubjectAlternativeNames then
    Exit;
  HostLength := TextLength(HostName);
  if (HostLength > 0) and (HostName[HostLength - 1] = '.') then
    Dec(HostLength);
  if HostLength = 0 then
    Exit;
  IsAddress := ParseIpv4Literal(HostName, Address);
  InitializeAsn1Reader(Reader, Certificate.SubjectAlternativeNames.Data, Certificate.SubjectAlternativeNames.Length);
  while ReadAsn1Element(Reader, Name) do
  begin
    if IsAddress then
    begin
      if (Name.Tag = Asn1ContextSpecific or 7) and (Name.ContentsLength = 4) and
         (CompareByte(Name.Contents^, Address[0], 4) = 0) then
        Exit(True);
    end
    else if Name.Tag = Asn1ContextSpecific or 2 then
    begin
      if DnsNameMatches(Name.Contents, Name.ContentsLength, PByte(HostName), HostLength) then
        Exit(True);
    end;
  end;
end;

end.
