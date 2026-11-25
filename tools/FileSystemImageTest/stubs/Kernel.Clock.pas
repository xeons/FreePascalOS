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

{ Host stand-in for the kernel clock (FileSystemImageTest): a fixed time. }
unit Kernel.Clock;

{$mode objfpc}

interface

uses
  Runtime.Time;

function CurrentWallClockTime: TUnixTime;

implementation

function CurrentWallClockTime: TUnixTime;
begin
  Result := 1700000000;
end;

end.
