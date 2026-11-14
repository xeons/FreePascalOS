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
  Information about the system: name, version, memory and volumes.
}
unit Sys.Information;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

type
  TSystemInformation = TAbiSystemInformation;
  TVolumeInformation = TAbiVolumeInformation;

function GetSystemInformation(out Information: TSystemInformation): LongInt;
{ Returns False when Index is past the last volume. }
function GetVolume(Index: Integer; out Information: TVolumeInformation): Boolean;

implementation

uses
  Sys.Kernel,
  Sys.Errors;

function GetSystemInformation(out Information: TSystemInformation): LongInt;
begin
  Result := ErrorCodeOf(KernelGetSystemInformation(Information));
end;

function GetVolume(Index: Integer; out Information: TVolumeInformation): Boolean;
begin
  Result := KernelListVolumes(QWord(Index), Information) > 0;
end;

end.
