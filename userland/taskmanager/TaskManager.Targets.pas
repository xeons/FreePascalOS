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
  A process the task manager acts on: its id and the name the user
  knows it by (the program's name, or its window's title).
}
unit TaskManager.Targets;

{$mode objfpc}
{$H+}

interface

type
  TProcessTarget = record
    ProcessId: QWord;
    Name: string;
  end;
  TProcessTargets = array of TProcessTarget;

function MakeTarget(ProcessId: QWord; const Name: string): TProcessTarget;
{ "NAME (PID)". }
function Describe(const Target: TProcessTarget): string;
procedure AddTarget(var Targets: TProcessTargets; const Target: TProcessTarget);

implementation

uses
  SysUtils;

function MakeTarget(ProcessId: QWord; const Name: string): TProcessTarget;
begin
  Result.ProcessId := ProcessId;
  Result.Name := Name;
end;

function Describe(const Target: TProcessTarget): string;
begin
  Result := Target.Name + ' (' + IntToStr(Target.ProcessId) + ')';
end;

procedure AddTarget(var Targets: TProcessTargets; const Target: TProcessTarget);
begin
  Insert(Target, Targets, Length(Targets));
end;

end.
