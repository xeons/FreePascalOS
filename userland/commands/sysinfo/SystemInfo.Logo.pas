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
  sysinfo's logo: the letters F and P drawn in plain ASCII (so the text
  console's font has every character), with "OS" in the corner. Each
  part has a colour of its own when colours are shown.
}
unit SystemInfo.Logo;

{$mode objfpc}{$H+}

interface

const
  LogoLineCount = 6;
  LogoWidth = 20;
  LogoLines: array[0..LogoLineCount - 1] of string = (
    ' ________  _______  ',
    '|   _____||   __  \ ',
    '|  |___   |  |__)  |',
    '|   ___|  |   ____/ ',
    '|  |      |  |      ',
    '|__|      |__|   OS ');

type
  TLogoPart = (LogoPartF, LogoPartP, LogoPartOS);

{ Which part of the logo the character at Column (from 0) of line Line is. }
function LogoPartAt(Line, Column: LongInt): TLogoPart;

implementation

const
  { The F takes the first ten columns, the P the rest; "OS" stands at
    the end of the last line. }
  FirstColumnOfP = 10;
  FirstColumnOfOS = 17;

function LogoPartAt(Line, Column: LongInt): TLogoPart;
begin
  if (Line = LogoLineCount - 1) and (Column >= FirstColumnOfOS) then
    Result := LogoPartOS
  else if Column < FirstColumnOfP then
    Result := LogoPartF
  else
    Result := LogoPartP;
end;

end.
