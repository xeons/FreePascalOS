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
  Keys as the bytes a terminal sends for them, what programs on it read:

    printable characters    their UTF-8 (Alt with one: ESC first)
    Ctrl with a letter      the control character (Ctrl+C is 3, ...),
                            as the key event carries it; Ctrl+Space 0
    Enter                   carriage return (the terminal turns it into
                            a line feed for readers, as the console's
                            keyboard does)
    Backspace               DEL (127)      Tab  9, Shift+Tab ESC [ Z
    Escape                  ESC
    arrows                  ESC [ A, B, C, D
    Home, End               ESC [ H, ESC [ F
    Insert, Delete          ESC [ 2 ~, ESC [ 3 ~
    Page Up, Page Down      ESC [ 5 ~, ESC [ 6 ~
    F1 - F4                 ESC O P, Q, R, S
    F5 - F12                ESC [ 15 ~, 17 ~, 18 ~, 19 ~, 20 ~, 21 ~,
                            23 ~, 24 ~

  These are the sequences the console's keyboard sends, so the shell's
  line editor reads the same either way.
}
unit Terminal.Keys;

{$mode objfpc}
{$H+}

interface

{ The bytes for a key pressed (a key event's code, character and
  modifiers); False if the key sends nothing (a modifier alone). }
function KeySequence(Code, Character, Modifiers: LongWord; out Sequence: string): Boolean;
{ A code point as UTF-8. }
function Utf8Of(CodePoint: LongWord): string;

implementation

uses
  Abi.SystemCalls,
  Controls.Keys;

const
  Escape = #27;
  KeyF1 = $3B;
  KeyF2 = $3C;
  KeyF3 = $3D;
  KeyF5 = $3F;
  KeyF6 = $40;
  KeyF7 = $41;
  KeyF8 = $42;
  KeyF9 = $43;
  KeyF11 = $57;
  KeyF12 = $58;

function Utf8Of(CodePoint: LongWord): string;
begin
  if CodePoint < $80 then
    Result := Char(CodePoint)
  else if CodePoint < $800 then
    Result := Char($C0 or (CodePoint shr 6)) + Char($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Result := Char($E0 or (CodePoint shr 12)) + Char($80 or ((CodePoint shr 6) and $3F)) +
      Char($80 or (CodePoint and $3F))
  else
    Result := Char($F0 or (CodePoint shr 18)) + Char($80 or ((CodePoint shr 12) and $3F)) +
      Char($80 or ((CodePoint shr 6) and $3F)) + Char($80 or (CodePoint and $3F));
end;

{ The keys that send the same whatever the modifiers. }
function FixedKeySequence(Code, Modifiers: LongWord; out Sequence: string): Boolean;
begin
  Result := True;
  case Code of
    KeyArrowUp: Sequence := Escape + '[A';
    KeyArrowDown: Sequence := Escape + '[B';
    KeyArrowRight: Sequence := Escape + '[C';
    KeyArrowLeft: Sequence := Escape + '[D';
    KeyHome: Sequence := Escape + '[H';
    KeyEnd: Sequence := Escape + '[F';
    KeyInsert: Sequence := Escape + '[2~';
    KeyDelete: Sequence := Escape + '[3~';
    KeyPageUp: Sequence := Escape + '[5~';
    KeyPageDown: Sequence := Escape + '[6~';
    KeyF1: Sequence := Escape + 'OP';
    KeyF2: Sequence := Escape + 'OQ';
    KeyF3: Sequence := Escape + 'OR';
    KeyF4: Sequence := Escape + 'OS';
    KeyF5: Sequence := Escape + '[15~';
    KeyF6: Sequence := Escape + '[17~';
    KeyF7: Sequence := Escape + '[18~';
    KeyF8: Sequence := Escape + '[19~';
    KeyF9: Sequence := Escape + '[20~';
    KeyF10: Sequence := Escape + '[21~';
    KeyF11: Sequence := Escape + '[23~';
    KeyF12: Sequence := Escape + '[24~';
    KeyBackspace: Sequence := #127;
    KeyEscape: Sequence := Escape;
    KeyTab:
      if (Modifiers and ModifierShift) <> 0 then
        Sequence := Escape + '[Z'
      else
        Sequence := #9;
  else
    if IsEnterKey(Code) then
      Sequence := #13
    else
      Result := False;
  end;
end;

function KeySequence(Code, Character, Modifiers: LongWord; out Sequence: string): Boolean;
begin
  Sequence := '';
  if FixedKeySequence(Code, Modifiers, Sequence) then
    Exit(True);
  if (Code = KeySpace) and ((Modifiers and ModifierControl) <> 0) then
  begin
    Sequence := #0;
    Exit(True);
  end;
  if Character = 0 then
    Exit(False);
  Sequence := Utf8Of(Character);
  { Alt (the left one; AltGr types characters) sends ESC first. }
  if ((Modifiers and ModifierAlt) <> 0) and ((Modifiers and ModifierAltGr) = 0) then
    Sequence := Escape + Sequence;
  Result := True;
end;

end.
