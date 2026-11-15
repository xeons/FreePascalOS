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
  TextTest: the plain logic behind the multi-line edit box, on the host.

    TextTest

  Positions in lines of UTF-8 text (Controls.TextPositions), the undo
  history and how it groups changes (Controls.TextUndo), breaking lines
  into rows for word wrap (Controls.TextWrap) and finding text
  (Controls.TextSearch). Every check prints a line; the exit code is 1 if
  any failed.

  This is a host tool, built with the normal Free Pascal runtime library.
}
program TextTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Classes,
  Controls.TextPositions,
  Controls.TextUndo,
  Controls.TextWrap,
  Controls.TextSearch;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('[text] pass: ', Name)
  else
  begin
    WriteLn('[text] FAIL: ', Name);
    Inc(Failures);
  end;
end;

function PositionText(const Position: TTextPosition): string;
begin
  Result := IntToStr(Position.Line) + ':' + IntToStr(Position.Column);
end;

procedure CheckPosition(const Name: string; const Got: TTextPosition; Line, Column: LongInt);
begin
  Check(Name + ' (got ' + PositionText(Got) + ')', SamePosition(Got, MakePosition(Line, Column)));
end;

function RowsText(const Rows: TRowStarts): string;
var
  Index: LongInt;
begin
  Result := '';
  for Index := 0 to High(Rows) do
  begin
    if Index > 0 then
      Result := Result + ',';
    Result := Result + IntToStr(Rows[Index]);
  end;
end;

{ --- Positions ------------------------------------------------------------------ }

procedure TestPositions;
const
  { "é" is two bytes, "€" three. }
  Accented = 'caf'#$C3#$A9' '#$E2#$82#$AC'5';
begin
  Check('characters counted, not bytes', CountCharacters(Accented) = 7);
  Check('a column''s byte', ByteOfColumn(Accented, 5) = 6);
  Check('the byte past the end', ByteOfColumn(Accented, 99) = Length(Accented));
  Check('a byte''s column', ColumnOfByte(Accented, 6) = 5);
  Check('a byte inside a character', ColumnOfByte(Accented, 4) = 3);
  Check('a range of characters', CharacterRange(Accented, 3, 3) = #$C3#$A9' '#$E2#$82#$AC);
  Check('byte offsets', Length(ByteOffsetsOf(Accented)) = 8);
  Check('a zero byte is a character', CountCharacters('a'#0'b') = 3);
  CheckPosition('after text on one line', PositionAfterText(MakePosition(2, 3), 'ab'), 2, 5);
  CheckPosition('after text with line feeds', PositionAfterText(MakePosition(2, 3), 'ab'#10'x'#10 + Accented), 4, 7);
  Check('before', PositionBefore(MakePosition(1, 9), MakePosition(2, 0)) and
    not PositionBefore(MakePosition(2, 0), MakePosition(2, 0)));
end;

{ --- Undo ------------------------------------------------------------------------- }

procedure TypeText(History: TTextUndoHistory; Line, Column: LongInt; const Text: string);
var
  Index: LongInt;
begin
  for Index := 1 to Length(Text) do
    History.AddChange(MakePosition(Line, Column + Index - 1), '', Text[Index], ChangeTyping);
end;

procedure TestUndo;
var
  History: TTextUndoHistory;
  Changes: TTextChanges;
begin
  History := TTextUndoHistory.Create;
  try
    Check('nothing to undo at first', not History.CanUndo and not History.CanRedo);
    TypeText(History, 0, 0, 'hello world');
    Changes := History.TakeUndoGroup;
    Check('typing is undone a word at a time (got ' + IntToStr(Length(Changes)) + ')', Length(Changes) = 5);
    Check('newest change first', (Length(Changes) = 5) and (Changes[0].Inserted = 'd') and
      (Changes[4].Inserted = 'w'));
    Changes := History.TakeUndoGroup;
    Check('the first word with its space', (Length(Changes) = 6) and (Changes[0].Inserted = ' '));
    Check('nothing more to undo', not History.CanUndo and History.CanRedo);
    Changes := History.TakeRedoGroup;
    Check('redone oldest first', (Length(Changes) = 6) and (Changes[0].Inserted = 'h'));
    Changes := History.TakeRedoGroup;
    Check('redone the second word', (Length(Changes) = 5) and not History.CanRedo);

    History.Clear;
    TypeText(History, 0, 0, 'abc');
    History.BreakGroup;
    TypeText(History, 0, 3, 'def');
    Check('a moved caret starts a new group', Length(History.TakeUndoGroup) = 3);
    History.AddChange(MakePosition(0, 2), 'c', '', ChangeDeletingBackward);
    History.AddChange(MakePosition(0, 1), 'b', '', ChangeDeletingBackward);
    Check('Backspaces in a row are one group', Length(History.TakeUndoGroup) = 2);
    Check('a new change forgets what could be redone', History.CanRedo);
    History.AddChange(MakePosition(0, 0), 'a', '', ChangeDeletingForward);
    History.AddChange(MakePosition(0, 0), 'b', '', ChangeDeletingForward);
    Check('...it does', not History.CanRedo);
    History.AddChange(MakePosition(0, 0), '', 'pasted', ChangeOther);
    History.AddChange(MakePosition(0, 6), '', 'again', ChangeOther);
    Check('pastes are a group each', Length(History.TakeUndoGroup) = 1);
    Check('Deletes in a row (after the paste)', (Length(History.TakeUndoGroup) = 1) and
      (Length(History.TakeUndoGroup) = 2));
    TypeText(History, 0, 0, 'ab');
    TypeText(History, 0, 5, 'cd');
    Check('typing elsewhere starts a new group', Length(History.TakeUndoGroup) = 2);
    History.Clear;
    History.BeginGroup;
    History.AddChange(MakePosition(0, 0), 'x', 'y', ChangeOther);
    History.AddChange(MakePosition(3, 0), 'x', 'y', ChangeOther);
    History.AddChange(MakePosition(9, 0), 'x', 'y', ChangeOther);
    History.EndGroup;
    TypeText(History, 0, 0, 'z');
    Check('typing after a group is its own', Length(History.TakeUndoGroup) = 1);
    Changes := History.TakeUndoGroup;
    Check('a replace all is one group', (Length(Changes) = 3) and (Changes[0].Start.Line = 9));
  finally
    History.Free;
  end;
end;

{ --- Word wrap ------------------------------------------------------------------------ }

{ Positions for Text in a font where every character is 10 pixels wide. }
procedure Measure(const Text: string; out Positions: TCharacterPositions; out BreakAfter: TBreakFlags);
var
  Index: LongInt;
begin
  SetLength(Positions, Length(Text) + 1);
  SetLength(BreakAfter, Length(Text));
  for Index := 0 to Length(Text) do
    Positions[Index] := Index * 10;
  for Index := 1 to Length(Text) do
    BreakAfter[Index - 1] := Text[Index] = ' ';
end;

function Wrapped(const Text: string; Width: LongInt): string;
var
  Positions: TCharacterPositions;
  BreakAfter: TBreakFlags;
begin
  Measure(Text, Positions, BreakAfter);
  Result := RowsText(WrapRows(Positions, BreakAfter, Width));
end;

procedure CheckWrap(const Name, Text: string; Width: LongInt; const Expected: string);
var
  Got: string;
begin
  Got := Wrapped(Text, Width);
  Check(Name + ' (got ' + Got + ')', Got = Expected);
end;

procedure TestWrap;
begin
  CheckWrap('a line that fits is one row', 'short line', 100, '0');
  CheckWrap('an empty line is one row', '', 50, '0');
  CheckWrap('breaks after the last space that fits', 'one two three four', 80, '0,8,14');
  CheckWrap('spaces at a row''s end may go past it', 'abcd      efgh', 40, '0,10');
  CheckWrap('a long word is broken where it stops fitting', 'abcdefghij', 40, '0,4,8');
  CheckWrap('a long word after a short one', 'ab abcdefghij', 40, '0,3,7,11');
  CheckWrap('too narrow for anything: a character a row', 'abc', 0, '0,1,2');
  CheckWrap('exactly the width fits', 'abcd efgh', 40, '0,5');
end;

{ --- Search ------------------------------------------------------------------------- }

procedure TestSearch;
var
  Lines: TStringList;
  MatchStart: TTextPosition;
  MatchEnd: TTextPosition;
  Found: Boolean;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('The quick brown fox');
    Lines.Add('jumps over the lazy dog');
    Lines.Add('caf'#$C3#$A9' The end');
    Found := FindInLines(Lines, 'the', MakePosition(0, 0), MakeSearchOptions(False, SearchDown),
      MatchStart, MatchEnd);
    Check('found ignoring case', Found and SamePosition(MatchStart, MakePosition(0, 0)) and
      SamePosition(MatchEnd, MakePosition(0, 3)));
    Found := FindInLines(Lines, 'the', MakePosition(0, 0), MakeSearchOptions(True, SearchDown),
      MatchStart, MatchEnd);
    CheckPosition('matching case skips "The"', MatchStart, 1, 11);
    Check('...and was found', Found);
    Found := FindInLines(Lines, 'The', MakePosition(1, 12), MakeSearchOptions(True, SearchDown),
      MatchStart, MatchEnd);
    CheckPosition('columns are characters after "é"', MatchStart, 2, 5);
    Found := FindInLines(Lines, 'the', MakePosition(2, 5), MakeSearchOptions(False, SearchUp),
      MatchStart, MatchEnd);
    CheckPosition('searching up finds the one before', MatchStart, 1, 11);
    Found := FindInLines(Lines, 'the', MakePosition(1, 11), MakeSearchOptions(False, SearchUp),
      MatchStart, MatchEnd);
    CheckPosition('...and the one before that', MatchStart, 0, 0);
    Found := FindInLines(Lines, 'the', MakePosition(0, 0), MakeSearchOptions(False, SearchUp),
      MatchStart, MatchEnd);
    Check('nothing before the first', not Found);
    Found := FindInLines(Lines, 'cat', MakePosition(0, 0), MakeSearchOptions(False, SearchDown),
      MatchStart, MatchEnd);
    Check('nothing found', not Found);
    Found := FindInLines(Lines, 'end', MakePosition(2, 10), MakeSearchOptions(False, SearchDown),
      MatchStart, MatchEnd);
    Check('nothing after the last', not Found);
    Check('text matches ignoring case', TextMatches('Fox', 'fOX', False) and not TextMatches('Fox', 'fOX', True));
  finally
    Lines.Free;
  end;
end;

begin
  TestPositions;
  TestUndo;
  TestWrap;
  TestSearch;
  WriteLn('[text] ', Checks - Failures, ' of ', Checks, ' checks passed');
  if Failures > 0 then
    Halt(1);
end.
