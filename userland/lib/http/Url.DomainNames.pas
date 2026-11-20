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
  Domain to ASCII (URL Standard section 3.3, over UTS #46 with
  CheckHyphens, VerifyDnsLength and UseSTD3ASCIIRules off and
  nontransitional processing):

  - an ASCII domain without "xn--" labels is only lower cased (the
    fast path the standard allows);
  - otherwise each code point is mapped: ASCII, Latin-1, Latin
    Extended-A, Greek, Cyrillic and Armenian capitals to small letters,
    full-width ASCII to ASCII, the ideographic and full-width full
    stops to ".", the soft hyphen and variation selectors left out;
    joiners (U+200C, U+200D) and invalid UTF-8 refuse the domain;
  - a label with non-ASCII becomes "xn--" and its Punycode; an
    "xn--" label must decode to a label that is not all ASCII.

  This mapping is the part of UTS #46's table that covers the cased
  scripts; other scripts have no case and pass through unchanged. There
  is no NFC normalization (domains typed or linked are composed in
  practice).

  Domain to Unicode (for showing a host) decodes the "xn--" labels.

  Plain Pascal (the RTL only), checked on the host by tools/HttpTest.
}
unit Url.DomainNames;

{$mode objfpc}
{$H+}

interface

{ Domain is UTF-8 (percent-decoded already). False if it cannot be a
  domain; Ascii is lower case. }
function DomainToAscii(const Domain: string; out Ascii: string): Boolean;
{ The "xn--" labels of an ASCII domain decoded (UTF-8); a label that
  does not decode stays as it is. }
function DomainToUnicode(const Domain: string): string;
{ U+0000, tab, LF, CR, space, # / : < > ? @ [ \ ] ^ | }
function IsForbiddenHostCharacter(Character: Char): Boolean;
{ The above, C0 controls, % and DEL. }
function IsForbiddenDomainCharacter(Character: Char): Boolean;

implementation

uses
  SysUtils,
  StrUtils,
  Url.Punycode;

const
  AcePrefix = 'xn--';
  Removed = High(LongWord);
  Refused = High(LongWord) - 1;

function IsForbiddenHostCharacter(Character: Char): Boolean;
begin
  Result := Character in [#0, #9, #10, #13, ' ', '#', '/', ':', '<', '>', '?', '@', '[', '\', ']', '^', '|'];
end;

function IsForbiddenDomainCharacter(Character: Char): Boolean;
begin
  Result := IsForbiddenHostCharacter(Character) or (Ord(Character) < $20) or (Character = '%') or
    (Ord(Character) = $7F);
end;

{ Even capital, odd small (or the other way round with Odd set). }
function PairedCase(Value: LongWord; OddIsCapital: Boolean): LongWord;
begin
  if Odd(Value) = OddIsCapital then
    Result := Value + 1
  else
    Result := Value;
end;

{ The mapped code point, Removed, or Refused. }
function MapCodePoint(Value: LongWord): LongWord;
begin
  case Value of
    Ord('A')..Ord('Z'): Result := Value + 32;
    $00AA: Result := Ord('a');
    $00B2: Result := Ord('2');
    $00B3: Result := Ord('3');
    $00B9: Result := Ord('1');
    $00BA: Result := Ord('o');
    $00AD: Result := Removed;
    $00C0..$00D6, $00D8..$00DE: Result := Value + 32;
    $0100..$012F, $0132..$0137, $014A..$0177: Result := PairedCase(Value, False);
    $0139..$0148, $0179..$017E: Result := PairedCase(Value, True);
    $0178: Result := $00FF;
    $017F: Result := Ord('s');
    $0386: Result := $03AC;
    $0388..$038A: Result := Value + 37;
    $038C: Result := $03CC;
    $038E..$038F: Result := Value + 63;
    $0391..$03A1, $03A3..$03AB: Result := Value + 32;
    $0400..$040F: Result := Value + 80;
    $0410..$042F: Result := Value + 32;
    $0460..$0481, $048A..$04BF: Result := PairedCase(Value, False);
    $04C0: Result := $04CF;
    $04C1..$04CE: Result := PairedCase(Value, True);
    $04D0..$052F: Result := PairedCase(Value, False);
    $0531..$0556: Result := Value + 48;
    $200C, $200D, $FFFD: Result := Refused;
    $3002, $FF0E, $FF61: Result := Ord('.');
    $FE00..$FE0F: Result := Removed;
    $FF21..$FF3A: Result := Value - $FF21 + Ord('a');
    $FF01..$FF0D, $FF0F..$FF20, $FF3B..$FF5E: Result := Value - $FF01 + $21;
  else
    Result := Value;
  end;
end;

function IsAscii(const Text: string): Boolean;
var
  Character: Char;
begin
  for Character in Text do
    if Ord(Character) >= $80 then
      Exit(False);
  Result := True;
end;

function HasAceLabel(const Domain: string): Boolean;
var
  LabelText: string;
begin
  for LabelText in Domain.Split(['.']) do
    if StartsText(AcePrefix, LabelText) then
      Exit(True);
  Result := False;
end;

{ The domain mapped (UTF-8); False if a code point refuses it. }
function MapDomain(const Domain: string; out Mapped: string): Boolean;
var
  Input, Output: TCodePointArray;
  Value, MappedValue: LongWord;
  Count: Integer;
begin
  Mapped := '';
  Input := Utf8ToCodePoints(Domain);
  Output := nil;
  SetLength(Output, Length(Input) + 1);
  Count := 0;
  for Value in Input do
  begin
    if Value = $0130 then
    begin
      { Capital I with a dot: "i" and a combining dot above. }
      SetLength(Output, Length(Output) + 1);
      Output[Count] := Ord('i');
      Output[Count + 1] := $0307;
      Inc(Count, 2);
      Continue;
    end;
    MappedValue := MapCodePoint(Value);
    if MappedValue = Refused then
      Exit(False);
    if MappedValue = Removed then
      Continue;
    Output[Count] := MappedValue;
    Inc(Count);
  end;
  SetLength(Output, Count);
  Mapped := CodePointsToUtf8(Output);
  Result := True;
end;

{ One mapped label to its ASCII form. }
function LabelToAscii(const LabelText: string; out Ascii: string): Boolean;
var
  Decoded: TCodePointArray;
begin
  Ascii := LabelText;
  if IsAscii(LabelText) then
  begin
    if not StartsText(AcePrefix, LabelText) then
      Exit(True);
    { An encoded label must decode, to something that needed encoding. }
    if not PunycodeDecode(Copy(LabelText, Length(AcePrefix) + 1, MaxInt), Decoded) or (Length(Decoded) = 0) or
       IsAscii(CodePointsToUtf8(Decoded)) then
      Exit(False);
    Exit(True);
  end;
  Result := PunycodeEncode(Utf8ToCodePoints(LabelText), Ascii);
  Ascii := AcePrefix + Ascii;
end;

function DomainToAscii(const Domain: string; out Ascii: string): Boolean;
var
  Mapped, Converted: string;
  Labels: TStringArray;
  Index: Integer;
  Character: Char;
begin
  Ascii := '';
  if IsAscii(Domain) and not HasAceLabel(Domain) then
    Ascii := LowerCase(Domain)
  else
  begin
    if not MapDomain(Domain, Mapped) then
      Exit(False);
    Labels := Mapped.Split(['.']);
    for Index := 0 to High(Labels) do
    begin
      if not LabelToAscii(Labels[Index], Converted) then
        Exit(False);
      if Index > 0 then
        Ascii := Ascii + '.';
      Ascii := Ascii + Converted;
    end;
  end;
  if Ascii = '' then
    Exit(False);
  for Character in Ascii do
    if IsForbiddenDomainCharacter(Character) then
      Exit(False);
  Result := True;
end;

function DomainToUnicode(const Domain: string): string;
var
  Labels: TStringArray;
  Decoded: TCodePointArray;
  Index: Integer;
begin
  Result := '';
  Labels := Domain.Split(['.']);
  for Index := 0 to High(Labels) do
  begin
    if Index > 0 then
      Result := Result + '.';
    if StartsText(AcePrefix, Labels[Index]) and
       PunycodeDecode(Copy(Labels[Index], Length(AcePrefix) + 1, MaxInt), Decoded) then
      Result := Result + CodePointsToUtf8(Decoded)
    else
      Result := Result + Labels[Index];
  end;
end;

end.
