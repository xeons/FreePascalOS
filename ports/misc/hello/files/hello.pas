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
  hello - the ports tree's smallest port: a greeting, built from the
  port's own files with the system's Free Pascal runtime.

  hello [NAME]      greets NAME (or the world)
  hello --version   prints the version
}
program hello;

{$mode objfpc}
{$H+}

const
  Version = '1.0';

begin
  if (ParamCount = 1) and (ParamStr(1) = '--version') then
    WriteLn('hello ', Version)
  else if ParamCount >= 1 then
    WriteLn('Hello, ', ParamStr(1), '!')
  else
    WriteLn('Hello, world!');
end.
