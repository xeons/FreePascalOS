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

(*
  Keyboard layouts: which character each key gives.

  Keys are numbered by their scan code in set 1 (0x01-0x39 for the main
  block, 0x56 for the extra key next to the left Shift on ISO
  keyboards). Each key has up to three characters: plain, with Shift,
  and with AltGr (the right Alt key), as Unicode code points; 0 means
  the key gives nothing at that level.

  The US layout is the base; the others are written as the keys that
  differ from it:

    us   US English
    uk   British English (£, # and ~ next to Enter, " on Shift-2)
    de   German QWERTZ (umlauts, ß, AltGr for @ { [ ] } \ ~ | €)
    fr   French AZERTY (é è ç à ù, digits on Shift, AltGr for ~ # { [ | ` \ ^ @ ] } €)

  The accent keys of de and fr give the accent itself; there are no
  dead keys.
*)
unit Drivers.KeyboardLayouts;

{$mode objfpc}

interface

const
  FirstLayoutKey = $00;
  LastLayoutKey = $58;

type
  TKeyLevel = (LevelPlain, LevelShifted, LevelAltGr);

{ Selects the layout called Name (us, uk, de or fr); returns False and
  keeps the current one if there is no such layout. }
function SelectKeyboardLayout(Name: PChar): Boolean;
function CurrentKeyboardLayoutName: PChar;

{ The code point of key Code at Level; 0 if it gives nothing. }
function LayoutCharacter(Code: Byte; Level: TKeyLevel): LongWord;

{ True when Caps Lock affects the key: its plain and shifted characters
  are a lower and upper case letter. }
function KeyIsCapsLockable(Code: Byte): Boolean;

implementation

uses
  Runtime.Text;

type
  TKeyCharacters = record
    Plain: LongWord;
    Shifted: LongWord;
    AltGr: LongWord;
  end;

  TKeyChange = record
    Code: Byte;
    Plain: LongWord;
    Shifted: LongWord;
    AltGr: LongWord;
  end;

const
  { The US layout for scan codes 0x00-0x39. }
  UsPlain: array[$00..$39] of Char = (
    #0, #27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', #8, #9,
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', #13, #0, 'a', 's',
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '''', '`', #0, '\', 'z', 'x', 'c', 'v',
    'b', 'n', 'm', ',', '.', '/', #0, '*', #0, ' ');
  UsShifted: array[$00..$39] of Char = (
    #0, #27, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', #8, #9,
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', #13, #0, 'A', 'S',
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', #0, '|', 'Z', 'X', 'C', 'V',
    'B', 'N', 'M', '<', '>', '?', #0, '*', #0, ' ');
  { The ISO key next to the left Shift. }
  ScanIsoExtraKey = $56;

  { Code points used below. }
  PoundSign = $A3;
  NotSign = $AC;
  BrokenBar = $A6;
  EuroSign = $20AC;
  SectionSign = $A7;
  DegreeSign = $B0;
  SuperscriptTwo = $B2;
  SuperscriptThree = $B3;
  AcuteAccent = $B4;
  MicroSign = $B5;
  Diaeresis = $A8;
  CurrencySign = $A4;
  SharpS = $DF;
  SmallAUmlaut = $E4;
  CapitalAUmlaut = $C4;
  SmallOUmlaut = $F6;
  CapitalOUmlaut = $D6;
  SmallUUmlaut = $FC;
  CapitalUUmlaut = $DC;
  SmallEAcute = $E9;
  SmallEGrave = $E8;
  SmallCCedilla = $E7;
  SmallAGrave = $E0;
  SmallUGrave = $F9;

  UkChanges: array[0..6] of TKeyChange = (
    (Code: $03; Plain: Ord('2'); Shifted: Ord('"'); AltGr: 0),
    (Code: $04; Plain: Ord('3'); Shifted: PoundSign; AltGr: 0),
    (Code: $05; Plain: Ord('4'); Shifted: Ord('$'); AltGr: EuroSign),
    (Code: $28; Plain: Ord(''''); Shifted: Ord('@'); AltGr: 0),
    (Code: $29; Plain: Ord('`'); Shifted: NotSign; AltGr: BrokenBar),
    (Code: $2B; Plain: Ord('#'); Shifted: Ord('~'); AltGr: 0),
    (Code: ScanIsoExtraKey; Plain: Ord('\'); Shifted: Ord('|'); AltGr: 0));

  GermanChanges: array[0..23] of TKeyChange = (
    (Code: $03; Plain: Ord('2'); Shifted: Ord('"'); AltGr: SuperscriptTwo),
    (Code: $04; Plain: Ord('3'); Shifted: SectionSign; AltGr: SuperscriptThree),
    (Code: $07; Plain: Ord('6'); Shifted: Ord('&'); AltGr: 0),
    (Code: $08; Plain: Ord('7'); Shifted: Ord('/'); AltGr: Ord('{')),
    (Code: $09; Plain: Ord('8'); Shifted: Ord('('); AltGr: Ord('[')),
    (Code: $0A; Plain: Ord('9'); Shifted: Ord(')'); AltGr: Ord(']')),
    (Code: $0B; Plain: Ord('0'); Shifted: Ord('='); AltGr: Ord('}')),
    (Code: $0C; Plain: SharpS; Shifted: Ord('?'); AltGr: Ord('\')),
    (Code: $0D; Plain: AcuteAccent; Shifted: Ord('`'); AltGr: 0),
    (Code: $10; Plain: Ord('q'); Shifted: Ord('Q'); AltGr: Ord('@')),
    (Code: $12; Plain: Ord('e'); Shifted: Ord('E'); AltGr: EuroSign),
    (Code: $15; Plain: Ord('z'); Shifted: Ord('Z'); AltGr: 0),
    (Code: $1A; Plain: SmallUUmlaut; Shifted: CapitalUUmlaut; AltGr: 0),
    (Code: $1B; Plain: Ord('+'); Shifted: Ord('*'); AltGr: Ord('~')),
    (Code: $27; Plain: SmallOUmlaut; Shifted: CapitalOUmlaut; AltGr: 0),
    (Code: $28; Plain: SmallAUmlaut; Shifted: CapitalAUmlaut; AltGr: 0),
    (Code: $29; Plain: Ord('^'); Shifted: DegreeSign; AltGr: 0),
    (Code: $2B; Plain: Ord('#'); Shifted: Ord(''''); AltGr: 0),
    (Code: $2C; Plain: Ord('y'); Shifted: Ord('Y'); AltGr: 0),
    (Code: $32; Plain: Ord('m'); Shifted: Ord('M'); AltGr: MicroSign),
    (Code: $33; Plain: Ord(','); Shifted: Ord(';'); AltGr: 0),
    (Code: $34; Plain: Ord('.'); Shifted: Ord(':'); AltGr: 0),
    (Code: $35; Plain: Ord('-'); Shifted: Ord('_'); AltGr: 0),
    (Code: ScanIsoExtraKey; Plain: Ord('<'); Shifted: Ord('>'); AltGr: Ord('|')));

  FrenchChanges: array[0..27] of TKeyChange = (
    (Code: $02; Plain: Ord('&'); Shifted: Ord('1'); AltGr: 0),
    (Code: $03; Plain: SmallEAcute; Shifted: Ord('2'); AltGr: Ord('~')),
    (Code: $04; Plain: Ord('"'); Shifted: Ord('3'); AltGr: Ord('#')),
    (Code: $05; Plain: Ord(''''); Shifted: Ord('4'); AltGr: Ord('{')),
    (Code: $06; Plain: Ord('('); Shifted: Ord('5'); AltGr: Ord('[')),
    (Code: $07; Plain: Ord('-'); Shifted: Ord('6'); AltGr: Ord('|')),
    (Code: $08; Plain: SmallEGrave; Shifted: Ord('7'); AltGr: Ord('`')),
    (Code: $09; Plain: Ord('_'); Shifted: Ord('8'); AltGr: Ord('\')),
    (Code: $0A; Plain: SmallCCedilla; Shifted: Ord('9'); AltGr: Ord('^')),
    (Code: $0B; Plain: SmallAGrave; Shifted: Ord('0'); AltGr: Ord('@')),
    (Code: $0C; Plain: Ord(')'); Shifted: DegreeSign; AltGr: Ord(']')),
    (Code: $0D; Plain: Ord('='); Shifted: Ord('+'); AltGr: Ord('}')),
    (Code: $10; Plain: Ord('a'); Shifted: Ord('A'); AltGr: 0),
    (Code: $11; Plain: Ord('z'); Shifted: Ord('Z'); AltGr: 0),
    (Code: $12; Plain: Ord('e'); Shifted: Ord('E'); AltGr: EuroSign),
    (Code: $1A; Plain: Ord('^'); Shifted: Diaeresis; AltGr: 0),
    (Code: $1B; Plain: Ord('$'); Shifted: PoundSign; AltGr: CurrencySign),
    (Code: $1E; Plain: Ord('q'); Shifted: Ord('Q'); AltGr: 0),
    (Code: $27; Plain: Ord('m'); Shifted: Ord('M'); AltGr: 0),
    (Code: $28; Plain: SmallUGrave; Shifted: Ord('%'); AltGr: 0),
    (Code: $29; Plain: SuperscriptTwo; Shifted: 0; AltGr: 0),
    (Code: $2B; Plain: Ord('*'); Shifted: MicroSign; AltGr: 0),
    (Code: $2C; Plain: Ord('w'); Shifted: Ord('W'); AltGr: 0),
    (Code: $32; Plain: Ord(','); Shifted: Ord('?'); AltGr: 0),
    (Code: $33; Plain: Ord(';'); Shifted: Ord('.'); AltGr: 0),
    (Code: $34; Plain: Ord(':'); Shifted: Ord('/'); AltGr: 0),
    (Code: $35; Plain: Ord('!'); Shifted: SectionSign; AltGr: 0),
    (Code: ScanIsoExtraKey; Plain: Ord('<'); Shifted: Ord('>'); AltGr: 0));

var
  ActiveKeys: array[FirstLayoutKey..LastLayoutKey] of TKeyCharacters;
  ActiveName: PChar = 'us';

procedure LoadUsLayout;
var
  Code: Integer;
begin
  for Code := FirstLayoutKey to LastLayoutKey do
  begin
    ActiveKeys[Code].Plain := 0;
    ActiveKeys[Code].Shifted := 0;
    ActiveKeys[Code].AltGr := 0;
  end;
  for Code := Low(UsPlain) to High(UsPlain) do
  begin
    ActiveKeys[Code].Plain := Ord(UsPlain[Code]);
    ActiveKeys[Code].Shifted := Ord(UsShifted[Code]);
  end;
  { On a US keyboard the ISO key repeats the backslash key. }
  ActiveKeys[ScanIsoExtraKey].Plain := Ord('\');
  ActiveKeys[ScanIsoExtraKey].Shifted := Ord('|');
end;

procedure ApplyChanges(const Changes: array of TKeyChange);
var
  Index: Integer;
begin
  for Index := Low(Changes) to High(Changes) do
  begin
    ActiveKeys[Changes[Index].Code].Plain := Changes[Index].Plain;
    ActiveKeys[Changes[Index].Code].Shifted := Changes[Index].Shifted;
    ActiveKeys[Changes[Index].Code].AltGr := Changes[Index].AltGr;
  end;
end;

function SelectKeyboardLayout(Name: PChar): Boolean;
begin
  Result := True;
  if TextIsEqual(Name, 'us') then
  begin
    LoadUsLayout;
    ActiveName := 'us';
  end
  else if TextIsEqual(Name, 'uk') then
  begin
    LoadUsLayout;
    ApplyChanges(UkChanges);
    ActiveName := 'uk';
  end
  else if TextIsEqual(Name, 'de') then
  begin
    LoadUsLayout;
    ApplyChanges(GermanChanges);
    ActiveName := 'de';
  end
  else if TextIsEqual(Name, 'fr') then
  begin
    LoadUsLayout;
    ApplyChanges(FrenchChanges);
    ActiveName := 'fr';
  end
  else
    Result := False;
end;

function CurrentKeyboardLayoutName: PChar;
begin
  Result := ActiveName;
end;

function LayoutCharacter(Code: Byte; Level: TKeyLevel): LongWord;
begin
  if Code > LastLayoutKey then
    Exit(0);
  case Level of
    LevelPlain: Result := ActiveKeys[Code].Plain;
    LevelShifted: Result := ActiveKeys[Code].Shifted;
  else
    Result := ActiveKeys[Code].AltGr;
  end;
end;

function IsLowerCaseLetter(CodePoint: LongWord): Boolean;
begin
  Result := ((CodePoint >= Ord('a')) and (CodePoint <= Ord('z'))) or
    ((CodePoint >= $E0) and (CodePoint <= $FE) and (CodePoint <> $F7));
end;

function KeyIsCapsLockable(Code: Byte): Boolean;
begin
  if Code > LastLayoutKey then
    Exit(False);
  Result := IsLowerCaseLetter(ActiveKeys[Code].Plain) and
    (ActiveKeys[Code].Shifted = ActiveKeys[Code].Plain - $20);
end;

end.
