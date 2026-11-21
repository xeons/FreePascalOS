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
  WebScriptTest - checks libweb's script bindings on the host (make
  web-script-test): each scripts/*.js runs in a fresh window over its
  scripts/*.html (or an empty page) and makes its checks with check();
  then the Pascal side checks wrapper lifetime with the collectors,
  events from native code, the environment hooks, and reports the bytes
  a wrapper costs.

    WebScriptTest <scripts directory>

  JS_GC_STRESS=1 in the environment makes the engines collect every
  16 KiB.
}
program WebScriptTest;

{$mode objfpc}
{$H+}

uses
  WebScriptTest.Poison,
  SysUtils,
  Classes,
  TestChecks,
  Web.Bindings.Context,
  WebScriptTest.Harness,
  WebScriptTest.Lifetime;

procedure RunScripts(const Directory: string);
var
  Search: TSearchRec;
  Names: TStringList;
  Index: Integer;
  Html, BaseName: string;
  Bed: TTestBed;
begin
  Names := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*.js', faAnyFile, Search) = 0 then
    begin
      repeat
        Names.Add(Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    Names.Sort;
    for Index := 0 to Names.Count - 1 do
    begin
      BaseName := ChangeFileExt(Names[Index], '');
      Html := '';
      if FileExists(IncludeTrailingPathDelimiter(Directory) + BaseName + '.html') then
        Html := ReadTextFile(IncludeTrailingPathDelimiter(Directory) + BaseName + '.html');
      Bed := TTestBed.Create(BaseName, Html);
      try
        Bed.Run(ReadTextFile(IncludeTrailingPathDelimiter(Directory) + Names[Index]));
        Check(Pos('Uncaught', Bed.ConsoleText) = 0, BaseName + ': no uncaught exceptions' + LineEnding +
          Bed.ConsoleText);
      finally
        Bed.Free;
      end;
    end;
  finally
    Names.Free;
  end;
end;

begin
  { JS_GC_STRESS: collect every 16 KiB, to find wrappers or values the
    collector does not see. }
  if GetEnvironmentVariable('JS_GC_STRESS') <> '' then
    ContextHeapThreshold := 16 * 1024;
  if ParamCount >= 1 then
    RunScripts(ParamStr(1))
  else
    RunScripts('tools/WebScriptTest/scripts');
  RunLifetimeTests;
  FinishChecks('web script test');
end.
