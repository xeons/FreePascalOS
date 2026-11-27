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
  What happens when an item copied or moved arrives where something of
  the same name is already:

  * copied into the folder it is in: a numbered name ("notes (2).txt"),
    no question; moved there: nothing to do;
  * a folder onto a folder: they merge (the question comes for the
    files inside that clash);
  * otherwise the user is asked: Replace (not offered over a folder),
    Skip, Keep both (the arriving one numbered), or Stop; "Do this for
    all" keeps the answer for the rest of the operation (the question
    channel remembers it).

  CompareText describes the two for the question's Compare part
  ("The arriving one is newer and larger"). Plain logic, checked on the
  host (make files-test).
}
unit FileManager.ConflictPolicy;

{$mode objfpc}
{$H+}

interface

uses
  FileManager.Items,
  FileManager.OperationTypes;

type
  TConflictDecision = (DecideNumberedName, DecideNothingToDo, DecideMerge, DecideAsk, DecideReplace, DecideSkip,
    DecideKeepBoth, DecideStop);

{ What to do before asking, from the paths and the items' kinds. }
function DecideBeforeAsking(Kind: TOperationKind; const SourcePath, TargetPath: string; SourceIsFolder,
  TargetIsFolder: Boolean): TConflictDecision;
{ What an answer means (Replace over a folder cannot be: skipped). }
function DecisionForAnswer(Choice: TConflictChoice; CanReplace: Boolean): TConflictDecision;
{ Whether Replace may be offered over Target. }
function CanReplaceTarget(const Target: TFolderItem): Boolean;
{ How the arriving item compares with the one there. }
function CompareText(const Source, Target: TFolderItem): string;

implementation

function DecideBeforeAsking(Kind: TOperationKind; const SourcePath, TargetPath: string; SourceIsFolder,
  TargetIsFolder: Boolean): TConflictDecision;
begin
  if SourcePath = TargetPath then
  begin
    if Kind = OperationCopy then
      Exit(DecideNumberedName);
    Exit(DecideNothingToDo);
  end;
  if SourceIsFolder and TargetIsFolder then
    Exit(DecideMerge);
  Result := DecideAsk;
end;

function DecisionForAnswer(Choice: TConflictChoice; CanReplace: Boolean): TConflictDecision;
begin
  case Choice of
    ConflictReplace:
      if CanReplace then
        Result := DecideReplace
      else
        Result := DecideSkip;
    ConflictRename: Result := DecideKeepBoth;
    ConflictStop: Result := DecideStop;
  else
    Result := DecideSkip;
  end;
end;

function CanReplaceTarget(const Target: TFolderItem): Boolean;
begin
  Result := (Target.Kind <> ItemFolder) or Target.IsLink;
end;

function CompareText(const Source, Target: TFolderItem): string;
var
  TimePart: string;
  SizePart: string;
begin
  if Source.ModificationTime > Target.ModificationTime then
    TimePart := 'newer'
  else if Source.ModificationTime < Target.ModificationTime then
    TimePart := 'older'
  else
    TimePart := '';
  SizePart := '';
  if (Source.Kind = ItemFile) and (Target.Kind = ItemFile) then
  begin
    if Source.SizeInBytes > Target.SizeInBytes then
      SizePart := 'larger'
    else if Source.SizeInBytes < Target.SizeInBytes then
      SizePart := 'smaller';
  end;
  if (TimePart = '') and (SizePart = '') then
    Result := 'Both have the same date and size.'
  else if TimePart = '' then
    Result := 'The arriving one is ' + SizePart + '.'
  else if SizePart = '' then
    Result := 'The arriving one is ' + TimePart + '.'
  else
    Result := 'The arriving one is ' + TimePart + ' and ' + SizePart + '.';
end;

end.
