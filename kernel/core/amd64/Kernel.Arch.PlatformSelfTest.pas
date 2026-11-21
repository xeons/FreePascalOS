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
  Self tests of the platform: the AArch64 one checks its interrupt
  controller, address space identifiers and real-time clock; x86-64's
  are covered by the other self tests, so there is nothing here.
}
unit Kernel.Arch.PlatformSelfTest;

{$mode objfpc}

interface

procedure RunPlatformSelfTest;

implementation

procedure RunPlatformSelfTest;
begin
end;

end.
