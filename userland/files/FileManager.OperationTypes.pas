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
  The words the file operations (copy, move, delete) are described in:
  what is asked for, the questions an operation asks on its way (a name
  taken already, an error) and their answers, and what it achieved.
}
unit FileManager.OperationTypes;

{$mode objfpc}
{$H+}

interface

uses
  FileManager.Items;

type
  TOperationKind = (OperationCopy, OperationMove, OperationDelete);

  { What is asked for: Sources (absolute paths) copied or moved into
    TargetFolder, or deleted (TargetFolder unused). }
  TOperationRequest = record
    Kind: TOperationKind;
    Sources: array of string;
    TargetFolder: string;
  end;

  TQuestionKind = (QuestionConflict, QuestionError);

  TConflictChoice = (ConflictReplace, ConflictSkip, ConflictRename, ConflictStop);
  TErrorChoice = (ErrorSkip, ErrorStop);

  TOperationQuestion = record
    Kind: TQuestionKind;
    { A conflict: the item being copied or moved and the one already at
      the target. }
    Source: TFolderItem;
    Target: TFolderItem;
    SourcePath: string;
    TargetPath: string;
    { Whether Replace can be offered (not over a folder). }
    CanReplace: Boolean;
    { An error: what was being done ("copy", "delete", ...), the path it
      was done to and why it failed. }
    Action: string;
    ErrorPath: string;
    Error: LongInt;
  end;

  TOperationAnswer = record
    { A TConflictChoice or a TErrorChoice, by the question's kind. }
    Choice: LongInt;
    { The same answer for every later question of this kind. }
    ApplyToAll: Boolean;
  end;

  TOperationOutcome = record
    { Top-level items done whole (copied, moved or deleted). }
    ItemsDone: LongInt;
    ItemsSkipped: LongInt;
    Errors: LongInt;
    { Stopped by the user (Cancel, or Stop in a question). }
    Stopped: Boolean;
  end;

function OperationVerb(Kind: TOperationKind): string;
function OperationPastTense(Kind: TOperationKind): string;

implementation

function OperationVerb(Kind: TOperationKind): string;
begin
  case Kind of
    OperationCopy: Result := 'Copying';
    OperationMove: Result := 'Moving';
  else
    Result := 'Deleting';
  end;
end;

function OperationPastTense(Kind: TOperationKind): string;
begin
  case Kind of
    OperationCopy: Result := 'copied';
    OperationMove: Result := 'moved';
  else
    Result := 'deleted';
  end;
end;

end.
