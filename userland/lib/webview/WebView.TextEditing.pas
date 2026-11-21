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
  Editing a text control's value: the value is UTF-8, the selection is
  in UTF-16 code units (what script's selectionStart and selectionEnd
  count). A TTextEdit is the value, the selection's anchor and focus
  (the end that moves), and the operations keys do: insert, delete
  backward and forward (a character, or a word with Ctrl), move by
  character, word, line start and end (extending the selection with
  Shift). Line operations work within the line of a multi-line value.
}
unit WebView.TextEditing;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}

interface

type
  TCaretMove = (MoveCharacterLeft, MoveCharacterRight, MoveWordLeft, MoveWordRight, MoveLineStart, MoveLineEnd,
    MoveLineUp, MoveLineDown, MoveAll);

  TTextEdit = record
    Value: string;
    Anchor: Integer;
    Focus: Integer;
    function SelectionStart: Integer;
    function SelectionEnd: Integer;
    function HasSelectedText: Boolean;
    function SelectedText: string;
    { 'forward', 'backward' or 'none'. }
    function Direction: string;
    { Replaces the selection with Text (line breaks dropped unless
      MultiLine); the caret goes after it. }
    procedure Insert(const Text: string; MultiLine: Boolean);
    { Deletes the selection, else the character (or word) before or after
      the caret; False when nothing was deleted. }
    function DeleteBackward(ByWord: Boolean): Boolean;
    function DeleteForward(ByWord: Boolean): Boolean;
    procedure Move(How: TCaretMove; Extend: Boolean);
    procedure SetSelection(Start, Finish: Integer; const ADirection: string);
  end;

{ The UTF-16 length of UTF-8 text, and the byte index (1-based) of a
  UTF-16 offset. }
function Utf16CountOf(const Text: string): Integer;
function ByteIndexOfUtf16(const Text: string; Offset: Integer): Integer;

implementation

uses
  SysUtils;

function SequenceLength(Lead: Byte): Integer;
begin
  if Lead < $80 then
    Result := 1
  else if Lead < $E0 then
    Result := 2
  else if Lead < $F0 then
    Result := 3
  else
    Result := 4;
end;

function Utf16CountOf(const Text: string): Integer;
var
  Index, Size: Integer;
begin
  Result := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Size := SequenceLength(Ord(Text[Index]));
    if Size = 4 then
      Inc(Result, 2)
    else
      Inc(Result);
    Inc(Index, Size);
  end;
end;

function ByteIndexOfUtf16(const Text: string; Offset: Integer): Integer;
var
  Units, Size: Integer;
begin
  Result := 1;
  Units := 0;
  while (Result <= Length(Text)) and (Units < Offset) do
  begin
    Size := SequenceLength(Ord(Text[Result]));
    if Size = 4 then
      Inc(Units, 2)
    else
      Inc(Units);
    Inc(Result, Size);
  end;
end;

{ The UTF-16 width of the character before or at Offset. }
function UnitsBefore(const Text: string; Offset: Integer): Integer;
var
  Index: Integer;
begin
  if Offset <= 0 then
    Exit(0);
  Index := ByteIndexOfUtf16(Text, Offset) - 1;
  while (Index > 1) and ((Ord(Text[Index]) and $C0) = $80) do
    Dec(Index);
  if (Index >= 1) and (SequenceLength(Ord(Text[Index])) = 4) then
    Result := 2
  else
    Result := 1;
end;

function UnitsAfter(const Text: string; Offset: Integer): Integer;
var
  Index: Integer;
begin
  Index := ByteIndexOfUtf16(Text, Offset);
  if Index > Length(Text) then
    Exit(0);
  if SequenceLength(Ord(Text[Index])) = 4 then
    Result := 2
  else
    Result := 1;
end;

{ The character at a UTF-16 offset as ASCII (#0 for others and the end). }
function AsciiAt(const Text: string; Offset: Integer): Char;
var
  Index: Integer;
begin
  Index := ByteIndexOfUtf16(Text, Offset);
  if (Index > Length(Text)) or (Ord(Text[Index]) >= $80) then
    Result := #0
  else
    Result := Text[Index];
end;

function IsWordCharacter(Character: Char): Boolean;
begin
  { Non-ASCII counts as a word character. }
  Result := (Character = #0) or (Character in ['a'..'z', 'A'..'Z', '0'..'9', '_']);
end;

function TTextEdit.SelectionStart: Integer;
begin
  if Anchor < Focus then
    Result := Anchor
  else
    Result := Focus;
end;

function TTextEdit.SelectionEnd: Integer;
begin
  if Anchor > Focus then
    Result := Anchor
  else
    Result := Focus;
end;

function TTextEdit.HasSelectedText: Boolean;
begin
  Result := Anchor <> Focus;
end;

function TTextEdit.SelectedText: string;
var
  First, Last: Integer;
begin
  First := ByteIndexOfUtf16(Value, SelectionStart);
  Last := ByteIndexOfUtf16(Value, SelectionEnd);
  Result := Copy(Value, First, Last - First);
end;

function TTextEdit.Direction: string;
begin
  if Anchor = Focus then
    Result := 'none'
  else if Focus > Anchor then
    Result := 'forward'
  else
    Result := 'backward';
end;

procedure TTextEdit.SetSelection(Start, Finish: Integer; const ADirection: string);
begin
  if ADirection = 'backward' then
  begin
    Anchor := Finish;
    Focus := Start;
  end
  else
  begin
    Anchor := Start;
    Focus := Finish;
  end;
end;

procedure TTextEdit.Insert(const Text: string; MultiLine: Boolean);
var
  Inserted: string;
  First, Last, Start: Integer;
begin
  Inserted := StringReplace(StringReplace(Text, #13#10, #10, [rfReplaceAll]), #13, #10, [rfReplaceAll]);
  if not MultiLine then
    Inserted := StringReplace(Inserted, #10, '', [rfReplaceAll]);
  Start := SelectionStart;
  First := ByteIndexOfUtf16(Value, Start);
  Last := ByteIndexOfUtf16(Value, SelectionEnd);
  Value := Copy(Value, 1, First - 1) + Inserted + Copy(Value, Last, MaxInt);
  Anchor := Start + Utf16CountOf(Inserted);
  Focus := Anchor;
end;

function TTextEdit.DeleteBackward(ByWord: Boolean): Boolean;
var
  Origin: Integer;
begin
  if HasSelectedText then
  begin
    Insert('', True);
    Exit(True);
  end;
  if Focus <= 0 then
    Exit(False);
  Origin := Focus;
  if ByWord then
    Move(MoveWordLeft, False)
  else
    Focus := Focus - UnitsBefore(Value, Focus);
  Anchor := Origin;
  Insert('', True);
  Result := True;
end;

function TTextEdit.DeleteForward(ByWord: Boolean): Boolean;
var
  Origin: Integer;
begin
  if HasSelectedText then
  begin
    Insert('', True);
    Exit(True);
  end;
  if Focus >= Utf16CountOf(Value) then
    Exit(False);
  Origin := Focus;
  if ByWord then
    Move(MoveWordRight, False)
  else
    Focus := Focus + UnitsAfter(Value, Focus);
  Anchor := Origin;
  Insert('', True);
  Result := True;
end;

procedure TTextEdit.Move(How: TCaretMove; Extend: Boolean);
var
  Position, Length_, Column, LineStart, Target: Integer;
begin
  Length_ := Utf16CountOf(Value);
  Position := Focus;
  { Without Shift an arrow collapses a selection to its side. }
  if not Extend and HasSelectedText and (How in [MoveCharacterLeft, MoveCharacterRight]) then
  begin
    if How = MoveCharacterLeft then
      Position := SelectionStart
    else
      Position := SelectionEnd;
    Anchor := Position;
    Focus := Position;
    Exit;
  end;
  case How of
    MoveCharacterLeft:
      Position := Position - UnitsBefore(Value, Position);
    MoveCharacterRight:
      Position := Position + UnitsAfter(Value, Position);
    MoveWordLeft:
      begin
        while (Position > 0) and not IsWordCharacter(AsciiAt(Value, Position - 1)) do
          Dec(Position);
        while (Position > 0) and IsWordCharacter(AsciiAt(Value, Position - 1)) and
          (AsciiAt(Value, Position - 1) <> #0) do
          Dec(Position);
      end;
    MoveWordRight:
      begin
        while (Position < Length_) and IsWordCharacter(AsciiAt(Value, Position)) and
          (AsciiAt(Value, Position) <> #0) do
          Inc(Position);
        while (Position < Length_) and not IsWordCharacter(AsciiAt(Value, Position)) do
          Inc(Position);
      end;
    MoveLineStart:
      while (Position > 0) and (AsciiAt(Value, Position - 1) <> #10) do
        Dec(Position);
    MoveLineEnd:
      while (Position < Length_) and (AsciiAt(Value, Position) <> #10) do
        Inc(Position);
    MoveLineUp, MoveLineDown:
      begin
        LineStart := Position;
        while (LineStart > 0) and (AsciiAt(Value, LineStart - 1) <> #10) do
          Dec(LineStart);
        Column := Position - LineStart;
        if How = MoveLineUp then
        begin
          if LineStart = 0 then
            Position := 0
          else
          begin
            Target := LineStart - 1;
            while (Target > 0) and (AsciiAt(Value, Target - 1) <> #10) do
              Dec(Target);
            Position := Target;
            while (Position < LineStart - 1) and (Position - Target < Column) do
              Inc(Position);
          end;
        end
        else
        begin
          Target := Position;
          while (Target < Length_) and (AsciiAt(Value, Target) <> #10) do
            Inc(Target);
          if Target >= Length_ then
            Position := Length_
          else
          begin
            Inc(Target);
            Position := Target;
            while (Position < Length_) and (AsciiAt(Value, Position) <> #10) and (Position - Target < Column) do
              Inc(Position);
          end;
        end;
      end;
    MoveAll:
      begin
        Anchor := 0;
        Focus := Length_;
        Exit;
      end;
  end;
  if Position < 0 then
    Position := 0;
  if Position > Length_ then
    Position := Length_;
  Focus := Position;
  if not Extend then
    Anchor := Position;
end;

end.
