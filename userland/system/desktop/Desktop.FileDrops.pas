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
  Files dragged onto the desktop's icons (from Files, or any program
  dragging a file list): dropped on a program's icon, each file is
  opened with that program (Notepad edits it, Files shows its folder,
  the terminal starts in it), as if the program were started with the
  file's path. A drop opens at most a few, so a large selection does not
  start dozens of programs.
}
unit Desktop.FileDrops;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Windowing.DragAndDrop;

{ Whether the drag carries files. }
function DragCarriesFiles(const Drag: TDragEvent): Boolean;
{ The dragged files' paths (False if there are none). }
function ReadDroppedPaths(Paths: TStrings): Boolean;
{ Opens the files with desktop program Index. }
procedure OpenDroppedFiles(Index: LongInt; Paths: TStrings);

implementation

uses
  SysUtils,
  Windowing.Protocol,
  Windowing.DataTransfer,
  Controls.FileLists,
  Desktop.Programs,
  Desktop.Report;

const
  MaximumOpened = 4;

function DragCarriesFiles(const Drag: TDragEvent): Boolean;
begin
  Result := (Drag.Formats and DataFormatBit(DataFormatFileList)) <> 0;
end;

function ReadDroppedPaths(Paths: TStrings): Boolean;
var
  Data: TBytes;
  Action: TFileListAction;
begin
  Result := ReadDragData(DataFormatFileList, Data) and DecodeFileList(BytesToText(Data), Action, Paths) and
    (Paths.Count > 0);
end;

procedure OpenDroppedFiles(Index: LongInt; Paths: TStrings);
var
  Item: LongInt;
begin
  if (Index < 0) or (Index >= DesktopProgramCount) then
    Exit;
  Item := 0;
  while (Item < Paths.Count) and (Item < MaximumOpened) do
  begin
    Say('dropped ' + DesktopPrograms[Index].Command + ' ' + Paths[Item]);
    StartCommand(DesktopPrograms[Index].Command, Paths[Item], DesktopPrograms[Index].Caption);
    Inc(Item);
  end;
end;

end.
