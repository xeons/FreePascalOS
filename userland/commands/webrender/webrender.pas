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
  webrender: renders an HTML file with libweb to a PNG, or prints its
  layout tree; the debugging aid for the layout and painting engine.

    webrender [-w WIDTH] [-h HEIGHT] [-s SCALE] [-f FONTDIR] [-l] [-t]
      FILE.html [OUT.png]

  -w the viewport width in CSS pixels (800), -h its height (600; with
  -t the whole document is drawn), -s the device scale (1), -f the font
  directory (userland/data/fonts on the host, /lib/fonts on the system), -l
  prints the layout tree. Images the page refers to with relative URLs
  are read from beside the file.
}
program webrender;

{$mode objfpc}
{$H+}

uses
  SysUtils, Classes, WebRender.Pages;

var
  Options: TRenderOptions;
  Index: Integer;
  Argument: string;

procedure Usage;
begin
  WriteLn('usage: webrender [-w WIDTH] [-h HEIGHT] [-s SCALE] [-f FONTDIR] [-l] [-t] FILE.html [OUT.png]');
  Halt(2);
end;

begin
  Options := DefaultRenderOptions;
  Index := 1;
  while Index <= ParamCount do
  begin
    Argument := ParamStr(Index);
    if (Argument = '-w') and (Index < ParamCount) then
    begin
      Inc(Index);
      Options.Width := StrToFloatDef(ParamStr(Index), 800);
    end
    else if (Argument = '-h') and (Index < ParamCount) then
    begin
      Inc(Index);
      Options.Height := StrToFloatDef(ParamStr(Index), 600);
    end
    else if (Argument = '-s') and (Index < ParamCount) then
    begin
      Inc(Index);
      Options.Scale := StrToFloatDef(ParamStr(Index), 1);
    end
    else if (Argument = '-f') and (Index < ParamCount) then
    begin
      Inc(Index);
      Options.FontDirectory := ParamStr(Index);
    end
    else if Argument = '-l' then
      Options.PrintLayout := True
    else if Argument = '-t' then
      Options.WholeDocument := True
    else if (Argument <> '') and (Argument[1] = '-') then
      Usage
    else if Options.InputFile = '' then
      Options.InputFile := Argument
    else
      Options.OutputFile := Argument;
    Inc(Index);
  end;
  if Options.InputFile = '' then
    Usage;
  Halt(RenderPage(Options));
end.
