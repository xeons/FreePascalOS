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
                                         its feature subdirectories
    WasmSpecTest FILE.wast ...           those files
    --parse-only                         only parse and encode: report
                                         modules that did not encode
                                         (outside assert_malformed) and
                                         text modules an assert_malformed
                                         expects to fail that did encode
    --dump DIRECTORY                     also write every module that
                                         encoded to DIRECTORY, as
                                         DIR-FILE.LINE.KIND.wasm (KIND:
                                         valid, invalid or malformed, with
                                         "binary-" before it for modules
                                         written as bytes), for looking at
                                         with other tools

  DIRECTORY is the spec repository's test/core (the 2.0 or 3.0 release,
  downloaded, never committed); its subdirectories simd, gc, exceptions,
  memory64, multi-memory, relaxed-simd and bulk-memory are run too, and
  so is a "core" subdirectory (the layout of test/legacy/exceptions).
  Prints one line per file with its passed and failed assertions, the
  first failures of each file (all with --verbose) and a total; exits
  with 1 if anything failed.
}
program WasmSpecTest;

{$mode objfpc}
{$H+}

uses
  Classes,
  SysUtils,
  WasmScript,
  WasmSpecRunner;

const
  FeatureDirectories: array[0..7] of AnsiString = ('simd', 'gc', 'exceptions', 'memory64', 'multi-memory',
    'relaxed-simd', 'bulk-memory', 'core');

var
  Files: TStringList;
  Verbose, ParseOnly: Boolean;
  DumpDirectory: AnsiString;
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

{ The --parse-only check: each module's encoding against what its
  command expects of the text. A binary module's malformation is in its
  bytes, so only text and quote modules count for assert_malformed. }
procedure CheckEncoding(Commands: TScriptCommandList; var Outcome: TScriptOutcome);
var
  Index: Integer;
  Command: TScriptCommand;
begin
  for Index := 0 to Commands.Count - 1 do
  begin
    Command := Commands[Index];
    if not Command.HasModule then
      Continue;
    if Command.Kind = scAssertMalformed then
    begin
      if (Command.Module.EncodeError = '') and not Command.Module.IsBinary then
      begin
        Inc(Outcome.Failed);
        Outcome.Failures.Add(Format('line %d: malformed text encoded (%s)', [Command.Line, Command.Message]));
      end
      else
        Inc(Outcome.Passed);
    end
    else if Command.Module.EncodeError <> '' then
    begin
      Inc(Outcome.Failed);
      Outcome.Failures.Add(Format('line %d: text did not encode: %s', [Command.Line,
        Command.Module.EncodeError]));
    end
    else
      Inc(Outcome.Passed);
  end;
end;

procedure DumpModules(const FileName: AnsiString; Commands: TScriptCommandList);
var
  Index: Integer;
  Command: TScriptCommand;
  Kind: AnsiString;
  Stream: TFileStream;
begin
  for Index := 0 to Commands.Count - 1 do
  begin
    Command := Commands[Index];
    if not Command.HasModule or (Command.Module.EncodeError <> '') or (Command.Module.Bytes = nil) then
      Continue;
    if Command.Kind = scAssertInvalid then
      Kind := 'invalid'
    else if Command.Kind = scAssertMalformed then
      Kind := 'malformed'
    else
      Kind := 'valid';
    if Command.Module.IsBinary then
      Kind := 'binary-' + Kind;
    Stream := TFileStream.Create(Format('%s%s-%s.%d.%s.wasm', [IncludeTrailingPathDelimiter(DumpDirectory),
      ExtractFileName(ExtractFileDir(ExpandFileName(FileName))), ChangeFileExt(ExtractFileName(FileName), ''),
      Command.Line, Kind]), fmCreate);
    try
      Stream.WriteBuffer(Command.Module.Bytes[0], Length(Command.Module.Bytes));
    finally
      Stream.Free;
    end;
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
        if DumpDirectory <> '' then
          DumpModules(FileName, Commands);
        if ParseOnly then
          CheckEncoding(Commands, Outcome)
        else
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
  Index, Feature: Integer;
  Subdirectory: AnsiString;
begin
  Files := TStringList.Create;
  Verbose := False;
  ParseOnly := False;
  DumpDirectory := '';
  Index := 1;
  while Index <= ParamCount do
  begin
    if ParamStr(Index) = '--verbose' then
      Verbose := True
    else if (ParamStr(Index) = '--dump') and (Index < ParamCount) then
    begin
      Inc(Index);
      DumpDirectory := ParamStr(Index);
      ForceDirectories(DumpDirectory);
    end
    else if ParamStr(Index) = '--parse-only' then
      ParseOnly := True
    else if DirectoryExists(ParamStr(Index)) then
    begin
      AddDirectory(ParamStr(Index));
      for Feature := 0 to High(FeatureDirectories) do
      begin
        Subdirectory := IncludeTrailingPathDelimiter(ParamStr(Index)) + FeatureDirectories[Feature];
        if DirectoryExists(Subdirectory) then
          AddDirectory(Subdirectory);
      end;
    end
    else
      Files.Add(ParamStr(Index));
    Inc(Index);
  end;
  if Files.Count = 0 then
  begin
    WriteLn('usage: WasmSpecTest DIRECTORY|FILE.wast... [--verbose] [--parse-only] [--dump DIRECTORY]');
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
