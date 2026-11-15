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
  The undo and redo history of text kept as lines.

  Every change is the text removed at a position and the text inserted
  there instead (either may be empty). Changes are undone and redone in
  groups: what one undo takes back. Characters typed one after another
  form a group, a word at a time (a letter typed after a space starts a
  new one); so do Backspaces in a row, and Deletes in a row. Anything
  else (a paste, a cut, a line break, a replacement) is a group of its
  own, and changes made between BeginGroup and EndGroup are one group
  (every replacement of a "replace all"). Moving the caret ends the
  group being typed (BreakGroup). A new change throws away what could
  have been redone.

  Plain logic, checked on the host.
}
unit Controls.TextUndo;

{$mode objfpc}
{$H+}

interface

uses
  Controls.TextPositions;

type
  TTextChangeKind = (ChangeTyping, ChangeDeletingBackward, ChangeDeletingForward, ChangeOther);

  TTextChange = record
    Start: TTextPosition;
    Removed: string;
    Inserted: string;
    Kind: TTextChangeKind;
    { Changes undone together share a group number. }
    Group: LongInt;
  end;

  TTextChanges = array of TTextChange;

  TTextUndoHistory = class
  private
    FUndoable: TTextChanges;
    FUndoableCount: LongInt;
    FRedoable: TTextChanges;
    FRedoableCount: LongInt;
    FNextGroup: LongInt;
    FGroupBroken: Boolean;
    FGroupDepth: LongInt;
    FOpenGroup: LongInt;
    function JoinsPrevious(const Change: TTextChange): Boolean;
    procedure Push(var Changes: TTextChanges; var Count: LongInt; const Change: TTextChange);
    function TakeGroup(var Source: TTextChanges; var SourceCount: LongInt; var Target: TTextChanges;
      var TargetCount: LongInt): TTextChanges;
  public
    { Remembers a change just made. }
    procedure AddChange(const Start: TTextPosition; const Removed, Inserted: string; Kind: TTextChangeKind);
    { The next change starts a new group. }
    procedure BreakGroup;
    { Changes until the matching EndGroup are one group (they nest). }
    procedure BeginGroup;
    procedure EndGroup;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    { The newest group, newest change first, to take back (undo the
      changes in this order); it becomes redoable. Empty if none. }
    function TakeUndoGroup: TTextChanges;
    { The group undone last, oldest change first, to make again. }
    function TakeRedoGroup: TTextChanges;
    procedure Clear;
  end;

implementation

function LastCharacterIsSpace(const Text: string): Boolean;
begin
  Result := (Text <> '') and ((Text[Length(Text)] = ' ') or (Text[Length(Text)] = #9));
end;

function IsSpaceText(const Text: string): Boolean;
begin
  Result := (Text = ' ') or (Text = #9);
end;

procedure TTextUndoHistory.Push(var Changes: TTextChanges; var Count: LongInt; const Change: TTextChange);
begin
  if Count = Length(Changes) then
    SetLength(Changes, Count * 2 + 16);
  Changes[Count] := Change;
  Inc(Count);
end;

{ Whether Change carries on the group of the change before it. }
function TTextUndoHistory.JoinsPrevious(const Change: TTextChange): Boolean;
var
  Previous: TTextChange;
begin
  Result := False;
  if FGroupBroken or (FUndoableCount = 0) then
    Exit;
  Previous := FUndoable[FUndoableCount - 1];
  if (Previous.Kind <> Change.Kind) or (Change.Kind = ChangeOther) then
    Exit;
  case Change.Kind of
    ChangeTyping:
      { Right after what was typed; a word ends at a space. }
      Result := (Change.Removed = '') and
        SamePosition(Change.Start, PositionAfterText(Previous.Start, Previous.Inserted)) and
        not (LastCharacterIsSpace(Previous.Inserted) and not IsSpaceText(Change.Inserted));
    ChangeDeletingBackward:
      { Ending where the previous one started. }
      Result := (Change.Inserted = '') and
        SamePosition(PositionAfterText(Change.Start, Change.Removed), Previous.Start);
    ChangeDeletingForward:
      Result := (Change.Inserted = '') and SamePosition(Change.Start, Previous.Start);
  end;
end;

procedure TTextUndoHistory.AddChange(const Start: TTextPosition; const Removed, Inserted: string;
  Kind: TTextChangeKind);
var
  Change: TTextChange;
begin
  Change.Start := Start;
  Change.Removed := Removed;
  Change.Inserted := Inserted;
  Change.Kind := Kind;
  if FGroupDepth > 0 then
    Change.Group := FOpenGroup
  else if JoinsPrevious(Change) then
    Change.Group := FUndoable[FUndoableCount - 1].Group
  else
  begin
    Change.Group := FNextGroup;
    Inc(FNextGroup);
  end;
  Push(FUndoable, FUndoableCount, Change);
  FGroupBroken := False;
  FRedoable := nil;
  FRedoableCount := 0;
end;

procedure TTextUndoHistory.BreakGroup;
begin
  FGroupBroken := True;
end;

procedure TTextUndoHistory.BeginGroup;
begin
  if FGroupDepth = 0 then
  begin
    FOpenGroup := FNextGroup;
    Inc(FNextGroup);
  end;
  Inc(FGroupDepth);
end;

procedure TTextUndoHistory.EndGroup;
begin
  if FGroupDepth > 0 then
    Dec(FGroupDepth);
  if FGroupDepth = 0 then
    FGroupBroken := True;
end;

function TTextUndoHistory.CanUndo: Boolean;
begin
  Result := FUndoableCount > 0;
end;

function TTextUndoHistory.CanRedo: Boolean;
begin
  Result := FRedoableCount > 0;
end;

{ Moves the changes of the group on top of Source onto Target, top
  first, and returns them in that order. }
function TTextUndoHistory.TakeGroup(var Source: TTextChanges; var SourceCount: LongInt;
  var Target: TTextChanges; var TargetCount: LongInt): TTextChanges;
var
  Group: LongInt;
  Size: LongInt;
  Count: LongInt;
begin
  Result := nil;
  if SourceCount = 0 then
    Exit;
  Group := Source[SourceCount - 1].Group;
  { Sized once: a "replace all" can make thousands of changes. }
  Size := 0;
  while (Size < SourceCount) and (Source[SourceCount - 1 - Size].Group = Group) do
    Inc(Size);
  SetLength(Result, Size);
  Count := 0;
  while Count < Size do
  begin
    Result[Count] := Source[SourceCount - 1];
    Inc(Count);
    Push(Target, TargetCount, Source[SourceCount - 1]);
    Source[SourceCount - 1].Removed := '';
    Source[SourceCount - 1].Inserted := '';
    Dec(SourceCount);
  end;
  FGroupBroken := True;
end;

function TTextUndoHistory.TakeUndoGroup: TTextChanges;
begin
  Result := TakeGroup(FUndoable, FUndoableCount, FRedoable, FRedoableCount);
end;

function TTextUndoHistory.TakeRedoGroup: TTextChanges;
begin
  Result := TakeGroup(FRedoable, FRedoableCount, FUndoable, FUndoableCount);
end;

procedure TTextUndoHistory.Clear;
begin
  FUndoable := nil;
  FUndoableCount := 0;
  FRedoable := nil;
  FRedoableCount := 0;
  FGroupBroken := True;
end;

end.
