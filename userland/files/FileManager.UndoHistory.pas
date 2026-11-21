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
  Undo and redo (Ctrl+Z, Ctrl+Y) of what the file manager did to files.

  Each thing done is an entry: a rename, a new item, a copy, a move or
  a move to the trash, with the pairs of paths it touched (where from,
  where to; a new item's or a copy's Target is what was made, a move to
  the trash's Target is the name in the trash). Undoing an entry moves
  it onto the redo list, redoing moves it back; something new done
  empties the redo list. At most MostEntries are kept.

  PlanFor says what undoing (or redoing) an entry takes, as steps the
  window carries out with its usual operations:

    rename          undo: rename back          redo: rename again
    new item        undo: to the trash         redo: make it again
    copy            undo: copies to the trash  redo: copy again
    move            undo: move back            redo: move again
    to the trash    undo: restore              redo: to the trash again

  Plain logic, checked on the host (make files-test).
}
unit FileManager.UndoHistory;

{$mode objfpc}
{$H+}

interface

type
  TUndoKind = (UndoRename, UndoNewFolder, UndoNewFile, UndoCopy, UndoMove, UndoTrash);

  TUndoPair = record
    Source: string;
    Target: string;
  end;
  TUndoPairs = array of TUndoPair;

  TUndoEntry = record
    Kind: TUndoKind;
    Pairs: TUndoPairs;
  end;

  TPlanStepKind = (StepRename, StepMove, StepCopy, StepTrash, StepRestore, StepCreateFolder, StepCreateFile);

  { One step: Source to Target (Trash and the Create steps use Source
    only; Restore puts the trash item Source back at Target). }
  TPlanStep = record
    Kind: TPlanStepKind;
    Source: string;
    Target: string;
  end;
  TPlanSteps = array of TPlanStep;

  TUndoHistory = class
  private
    FUndoList: array of TUndoEntry;
    FRedoList: array of TUndoEntry;
  public
    procedure Push(const Entry: TUndoEntry);
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    { The entry the next undo or redo is of (only when Can*). }
    function NextUndo: TUndoEntry;
    function NextRedo: TUndoEntry;
    { Moves the entry from one list to the other and returns it. }
    function Undo: TUndoEntry;
    function Redo: TUndoEntry;
    { Puts Entry in place of the last one moved to the undo list (a redo
      of a move to the trash gets new names in the trash). }
    procedure ReplaceLastDone(const Entry: TUndoEntry);
    procedure Clear;
    function UndoCount: LongInt;
    function RedoCount: LongInt;
  end;

const
  MostEntries = 100;

function MakeEntry(Kind: TUndoKind; const Sources, Targets: array of string): TUndoEntry;
function PlanFor(const Entry: TUndoEntry; Undoing: Boolean): TPlanSteps;
{ "Undo rename", "Redo move" (for menus and hints). }
function EntryDescription(const Entry: TUndoEntry; Undoing: Boolean): string;

implementation

const
  KindWords: array[TUndoKind] of string = ('rename', 'new folder', 'new file', 'copy', 'move', 'delete');

function MakeEntry(Kind: TUndoKind; const Sources, Targets: array of string): TUndoEntry;
var
  Index: LongInt;
begin
  Result := Default(TUndoEntry);
  Result.Kind := Kind;
  SetLength(Result.Pairs, Length(Sources));
  for Index := 0 to High(Sources) do
  begin
    Result.Pairs[Index].Source := Sources[Index];
    if Index <= High(Targets) then
      Result.Pairs[Index].Target := Targets[Index]
    else
      Result.Pairs[Index].Target := '';
  end;
end;

procedure AddStep(var Steps: TPlanSteps; Kind: TPlanStepKind; const Source, Target: string);
begin
  SetLength(Steps, Length(Steps) + 1);
  Steps[High(Steps)].Kind := Kind;
  Steps[High(Steps)].Source := Source;
  Steps[High(Steps)].Target := Target;
end;

function PlanFor(const Entry: TUndoEntry; Undoing: Boolean): TPlanSteps;
var
  Index: LongInt;
  Pair: TUndoPair;
begin
  Result := nil;
  { Undone in the opposite order to how it was done (a later pair may
    depend on an earlier one). }
  if Undoing then
    Index := High(Entry.Pairs)
  else
    Index := 0;
  while (Index >= 0) and (Index <= High(Entry.Pairs)) do
  begin
    Pair := Entry.Pairs[Index];
    case Entry.Kind of
      UndoRename:
        if Undoing then
          AddStep(Result, StepRename, Pair.Target, Pair.Source)
        else
          AddStep(Result, StepRename, Pair.Source, Pair.Target);
      UndoNewFolder:
        if Undoing then
          AddStep(Result, StepTrash, Pair.Target, '')
        else
          AddStep(Result, StepCreateFolder, Pair.Target, '');
      UndoNewFile:
        if Undoing then
          AddStep(Result, StepTrash, Pair.Target, '')
        else
          AddStep(Result, StepCreateFile, Pair.Target, '');
      UndoCopy:
        if Undoing then
          AddStep(Result, StepTrash, Pair.Target, '')
        else
          AddStep(Result, StepCopy, Pair.Source, Pair.Target);
      UndoMove:
        if Undoing then
          AddStep(Result, StepMove, Pair.Target, Pair.Source)
        else
          AddStep(Result, StepMove, Pair.Source, Pair.Target);
      UndoTrash:
        if Undoing then
          AddStep(Result, StepRestore, Pair.Target, Pair.Source)
        else
          AddStep(Result, StepTrash, Pair.Source, '');
    end;
    if Undoing then
      Dec(Index)
    else
      Inc(Index);
  end;
end;

function EntryDescription(const Entry: TUndoEntry; Undoing: Boolean): string;
begin
  if Undoing then
    Result := 'Undo ' + KindWords[Entry.Kind]
  else
    Result := 'Redo ' + KindWords[Entry.Kind];
end;

procedure TUndoHistory.Push(const Entry: TUndoEntry);
var
  Index: LongInt;
begin
  if Length(Entry.Pairs) = 0 then
    Exit;
  if Length(FUndoList) >= MostEntries then
  begin
    for Index := 1 to High(FUndoList) do
      FUndoList[Index - 1] := FUndoList[Index];
    SetLength(FUndoList, Length(FUndoList) - 1);
  end;
  SetLength(FUndoList, Length(FUndoList) + 1);
  FUndoList[High(FUndoList)] := Entry;
  FRedoList := nil;
end;

function TUndoHistory.CanUndo: Boolean;
begin
  Result := Length(FUndoList) > 0;
end;

function TUndoHistory.CanRedo: Boolean;
begin
  Result := Length(FRedoList) > 0;
end;

function TUndoHistory.NextUndo: TUndoEntry;
begin
  Result := FUndoList[High(FUndoList)];
end;

function TUndoHistory.NextRedo: TUndoEntry;
begin
  Result := FRedoList[High(FRedoList)];
end;

function TUndoHistory.Undo: TUndoEntry;
begin
  Result := FUndoList[High(FUndoList)];
  SetLength(FUndoList, Length(FUndoList) - 1);
  SetLength(FRedoList, Length(FRedoList) + 1);
  FRedoList[High(FRedoList)] := Result;
end;

function TUndoHistory.Redo: TUndoEntry;
begin
  Result := FRedoList[High(FRedoList)];
  SetLength(FRedoList, Length(FRedoList) - 1);
  SetLength(FUndoList, Length(FUndoList) + 1);
  FUndoList[High(FUndoList)] := Result;
end;

procedure TUndoHistory.ReplaceLastDone(const Entry: TUndoEntry);
begin
  if Length(FUndoList) > 0 then
    FUndoList[High(FUndoList)] := Entry;
end;

procedure TUndoHistory.Clear;
begin
  FUndoList := nil;
  FRedoList := nil;
end;

function TUndoHistory.UndoCount: LongInt;
begin
  Result := Length(FUndoList);
end;

function TUndoHistory.RedoCount: LongInt;
begin
  Result := Length(FRedoList);
end;

end.
