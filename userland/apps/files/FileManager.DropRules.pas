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
  What dropping dragged files on a folder does: within one volume they
  move (a rename, at once), onto another volume they are copied (the
  originals stay where they are, as on the disk being plugged out).
  Ctrl held copies, Shift held moves, whatever the volumes. Dropping
  files on the folder they are in, or a folder on itself or into a
  folder inside it, does nothing.

  Plain logic: the host checks it (make files-test).
}
unit FileManager.DropRules;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Controls.DragData;

{ What a drop of files from SourceVolume onto a folder on TargetVolume
  does. }
function DropEffectFor(SourceVolume, TargetVolume: LongWord; ControlHeld, ShiftHeld: Boolean): TDropEffect;
{ Whether Paths may be dropped into TargetFolder at all (not into
  themselves, nor where they already are). }
function CanDropInto(Paths: TStrings; const TargetFolder: string): Boolean;

implementation

uses
  Controls.FileNames,
  FileManager.Paths;

function DropEffectFor(SourceVolume, TargetVolume: LongWord; ControlHeld, ShiftHeld: Boolean): TDropEffect;
begin
  if ControlHeld then
    Exit(DropCopy);
  if ShiftHeld then
    Exit(DropMove);
  if SourceVolume = TargetVolume then
    Result := DropMove
  else
    Result := DropCopy;
end;

function CanDropInto(Paths: TStrings; const TargetFolder: string): Boolean;
var
  Index: LongInt;
  AllHere: Boolean;
begin
  if Paths.Count = 0 then
    Exit(False);
  AllHere := True;
  for Index := 0 to Paths.Count - 1 do
  begin
    if IsSameOrInside(TargetFolder, Paths[Index]) then
      Exit(False);
    if ParentFolderOf(Paths[Index]) <> TargetFolder then
      AllHere := False;
  end;
  Result := not AllHere;
end;

end.
