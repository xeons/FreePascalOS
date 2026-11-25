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
  A FreePascalOS program that NativeFpcTest has the cross compiler link
  with its internal ELF linker against the staged units (-XD): strings,
  classes, exceptions and an exported variable of SysUtils, so the
  output has data and code relocations of every kind.
}
program InternalLinkSample;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes;

var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(Format('%s %d', ['sample', 42]));
    try
      raise Exception.Create(Lines[0]);
    except
      on E: Exception do
        WriteLn(E.Message, DefaultFormatSettings.DecimalSeparator);
    end;
  finally
    Lines.Free;
  end;
end.
