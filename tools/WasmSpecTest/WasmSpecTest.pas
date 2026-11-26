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
  The WebAssembly specification test suite against libwasm, on the host:

    WasmSpecTest DIRECTORY [--verbose]   every .wast in DIRECTORY and in
                                         DIRECTORY/simd
    WasmSpecTest FILE.wast ...           those files

  DIRECTORY is the spec repository's test/core (the 2.0 release,
  downloaded, never committed). Prints one line per file with its
  passed and failed assertions, the first failures of each file (all
  with --verbose) and a total; exits with 1 if anything failed.
}
program WasmSpecTest;

{$mode objfpc}
{$H+}

uses
  Classes,
  SysUtils,
  WasmScript,
  WasmSpecRunner;

var
  Files: TStringList;
  Verbose: Boolean;
  TotalPassed, TotalFailed, FilesFailed: Integer;

procedure AddDirectory(const Directory: AnsiString);
var
  Search: TSearchRec;
  Found: TStringList;
begin
  Found := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*.wast', faAnyFile, Search) = 0 then
    begin
      repeat
        Found.Add(IncludeTrailingPathDelimiter(Directory) + Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    Found.Sort;
    Files.AddStrings(Found);
  finally
    Found.Free;
  end;
end;

procedure RunFile(const FileName: AnsiString);
var
  Text: TStringList;
  Commands: TScriptCommandList;
  Outcome: TScriptOutcome;
  Index, Shown: Integer;
begin
  Outcome.Passed := 0;
  Outcome.Failed := 0;
  Outcome.Failures := TStringList.Create;
  Text := TStringList.Create;
  try
    Text.LoadFromFile(FileName);
    try
      Commands := ParseScript(Text.Text);
      try
        RunScript(Commands, Outcome);
      finally
        Commands.Free;
      end;
    except
      on E: Exception do
      begin
        Inc(Outcome.Failed);
        Outcome.Failures.Add('script: ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    WriteLn(Format('%-45s %5d passed %5d failed', [ExtractFileName(FileName), Outcome.Passed, Outcome.Failed]));
    if Verbose then
      Shown := Outcome.Failures.Count
    else
      Shown := 5;
    for Index := 0 to Outcome.Failures.Count - 1 do
      if Index < Shown then
        WriteLn('    FAIL ', Outcome.Failures[Index]);
    Inc(TotalPassed, Outcome.Passed);
    Inc(TotalFailed, Outcome.Failed);
    if Outcome.Failed > 0 then
      Inc(FilesFailed);
  finally
    Text.Free;
    Outcome.Failures.Free;
  end;
end;

var
  Index: Integer;
begin
  Files := TStringList.Create;
  Verbose := False;
  for Index := 1 to ParamCount do
    if ParamStr(Index) = '--verbose' then
      Verbose := True
    else if DirectoryExists(ParamStr(Index)) then
    begin
      AddDirectory(ParamStr(Index));
      if DirectoryExists(IncludeTrailingPathDelimiter(ParamStr(Index)) + 'simd') then
        AddDirectory(IncludeTrailingPathDelimiter(ParamStr(Index)) + 'simd');
    end
    else
      Files.Add(ParamStr(Index));
  if Files.Count = 0 then
  begin
    WriteLn('usage: WasmSpecTest DIRECTORY|FILE.wast... [--verbose]');
    Halt(2);
  end;
  for Index := 0 to Files.Count - 1 do
    RunFile(Files[Index]);
  WriteLn(Format('total: %d passed, %d failed, %d of %d files with failures', [TotalPassed, TotalFailed,
    FilesFailed, Files.Count]));
  Files.Free;
  if TotalFailed > 0 then
    Halt(1);
end.
