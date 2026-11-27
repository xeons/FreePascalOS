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
  IconTest - checks on the host (make icon-test) the icon theme and the
  pointer's pictures as the build drew them (userland/data/icons), read with
  libimage as the system reads them:

    IconTest ICON_DIRECTORY POINTER_DIRECTORY

  every icon file and its sizes (IconTest.Files) and the theme's lookup
  of a size for a logical size and scale (IconTest.Lookup,
  Controls.IconFiles).
}
program IconTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  IconTest.Checks,
  IconTest.Files,
  IconTest.Lookup;

begin
  if ParamCount <> 2 then
  begin
    WriteLn('usage: IconTest ICON_DIRECTORY POINTER_DIRECTORY');
    Halt(2);
  end;
  CheckIconFiles(ParamStr(1));
  CheckPointerFiles(ParamStr(2));
  CheckThemeLookup(ParamStr(1));
  FinishChecks('ICON TEST');
end.
