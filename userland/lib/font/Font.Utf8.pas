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
  UTF-8: the next character of a text.

  A byte that cannot start a character, a character cut short, an
  overlong form or a surrogate each count as one U+FFFD (replacement
  character): a character cut short counts once, its lead byte and the
  continuation bytes it did have together (as Unicode recommends), and
  the text goes on after them. No input stops the decoding or makes it
  read past the terminating zero.
}
unit Font.Utf8;

{$mode objfpc}
{$pointermath on}

interface

const
  ReplacementCharacter = $FFFD;

{ The character at Text^ (none at the terminating zero: returns False),
  advancing Text past it. }
function NextCharacter(var Text: PChar; out CodePoint: LongWord): Boolean;
{ The number of characters in Text. }
function CharacterCount(Text: PChar): LongInt;

implementation

function NextCharacter(var Text: PChar; out CodePoint: LongWord): Boolean;
var
  Lead: Byte;
  Extra: LongInt;
  Smallest: LongWord;
  Index: LongInt;
  Continuation: Byte;
begin
  CodePoint := 0;
  Lead := Byte(Text^);
  if Lead = 0 then
    Exit(False);
  Result := True;
  Inc(Text);
  if Lead < $80 then
  begin
    CodePoint := Lead;
    Exit;
  end;
  if (Lead and $E0) = $C0 then
  begin
    CodePoint := Lead and $1F;
    Extra := 1;
    Smallest := $80;
  end
  else if (Lead and $F0) = $E0 then
  begin
    CodePoint := Lead and $0F;
    Extra := 2;
    Smallest := $800;
  end
  else if (Lead and $F8) = $F0 then
  begin
    CodePoint := Lead and $07;
    Extra := 3;
    Smallest := $10000;
  end
  else
  begin
    CodePoint := ReplacementCharacter;
    Exit;
  end;
  for Index := 0 to Extra - 1 do
  begin
    Continuation := Byte(Text[Index]);
    { A zero ends the text too: never stepped past. }
    if (Continuation and $C0) <> $80 then
    begin
      Text := Text + Index;
      CodePoint := ReplacementCharacter;
      Exit;
    end;
    CodePoint := (CodePoint shl 6) or (Continuation and $3F);
  end;
  Text := Text + Extra;
  if (CodePoint < Smallest) or (CodePoint > $10FFFF) or ((CodePoint >= $D800) and (CodePoint <= $DFFF)) then
    CodePoint := ReplacementCharacter;
end;

function CharacterCount(Text: PChar): LongInt;
var
  CodePoint: LongWord;
begin
  Result := 0;
  while NextCharacter(Text, CodePoint) do
    Inc(Result);
end;

end.
