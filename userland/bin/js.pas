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
  js - run JavaScript

  js [-i] [-e CODE] [-m BYTES] [FILE [ARGUMENT...]]

  Runs FILE (or CODE), then the promise jobs and the timers it set,
  and exits with status 1 if anything threw. With no FILE and no CODE,
  or with -i after them, reads and runs lines interactively (a line
  that ends inside a construct continues on the next), printing each
  result. The engine is libjavascript; the shell adds print(), load(),
  scriptArgs, setTimeout / setInterval / clearTimeout and gc().

    -e CODE    run CODE
    -i         go interactive afterwards
    -m BYTES   limit the heap (K and M suffixes)
}
program js;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Streams,
  Util.Input,
  Util.LineEditor,
  Util.Messages,
  JsShell.Timers,
  JsShell.Globals,
  Js.Values,
  Js.Engine;

const
  Usage = 'usage: js [-i] [-e code] [-m bytes] [file [argument...]]';

var
  Engine: TJsEngine;
  Failed: Boolean;

function ReadSource(const Path: string; out Text: string): Boolean;
var
  Stream: PInputStream;
begin
  Text := '';
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit(False);
  Text := ReadAllText(Stream);
  CloseInput(Stream);
  Result := True;
end;

{ Runs code, then everything it left to do; reports what threw. }
procedure RunCode(const Source, FileName: string);
begin
  try
    Engine.Evaluate(Source, FileName);
    RunPendingWork(Engine);
  except
    on Error: EJsError do
    begin
      WriteLn(StdErr, Error.Message);
      Failed := True;
    end;
  end;
end;

function ParseSize(const Text: string; out Bytes: Int64): Boolean;
var
  Number: string;
  Scale: Int64;
begin
  Number := Text;
  Scale := 1;
  if (Number <> '') and (UpCase(Number[Length(Number)]) in ['K', 'M']) then
  begin
    if UpCase(Number[Length(Number)]) = 'K' then
      Scale := 1024
    else
      Scale := 1024 * 1024;
    Delete(Number, Length(Number), 1);
  end;
  Result := TryStrToInt64(Number, Bytes);
  Bytes := Bytes * Scale;
end;

{ Interactive: a line, or several while the code is unfinished. }
procedure Interact;
var
  Editor: TLineEditor;
  Line, Source: string;
  Value: TJsValue;
  Outcome: TEditResult;
begin
  Editor := TLineEditor.Create(GetEnvironmentVariable('HOME') + '/.js_history', StandardErrorHandle);
  try
    Source := '';
    while True do
    begin
      if Source = '' then
        Outcome := Editor.EditLine('> ', Line)
      else
        Outcome := Editor.EditLine('... ', Line);
      if Outcome <> EditLineReady then
        Break;
      if Source <> '' then
        Source := Source + #10;
      Source := Source + Line;
      if Trim(Source) = '' then
      begin
        Source := '';
        Continue;
      end;
      try
        Value := Engine.Evaluate(Source, '<repl>');
        Editor.AddHistoryLine(StringReplace(Source, #10, ' ', [rfReplaceAll]));
        Source := '';
        WriteLn(Engine.Inspect(Value));
        RunPendingWork(Engine);
      except
        on Error: EJsError do
        begin
          { An unfinished construct: read on. }
          if (Error.ErrorName = 'SyntaxError') and (Pos('end of input', Error.Message) > 0) then
            Continue;
          Editor.AddHistoryLine(StringReplace(Source, #10, ' ', [rfReplaceAll]));
          Source := '';
          WriteLn(StdErr, Error.Message);
        end;
      end;
    end;
    WriteLn;
  finally
    Editor.Free;
  end;
end;

var
  Index: Integer;
  Code, FileName, Text: string;
  HasCode, Interactive: Boolean;
  Limit: Int64;
  Arguments: array of string;

begin
  Code := '';
  FileName := '';
  HasCode := False;
  Interactive := False;
  Limit := 0;
  Arguments := nil;
  Index := 1;
  while Index <= ParamCount do
  begin
    if FileName <> '' then
    begin
      SetLength(Arguments, Length(Arguments) + 1);
      Arguments[High(Arguments)] := ParamStr(Index);
    end
    else if ParamStr(Index) = '-e' then
    begin
      Inc(Index);
      if Index > ParamCount then
      begin
        WriteLn(StdErr, Usage);
        Halt(2);
      end;
      Code := Code + ParamStr(Index) + #10;
      HasCode := True;
    end
    else if ParamStr(Index) = '-i' then
      Interactive := True
    else if ParamStr(Index) = '-m' then
    begin
      Inc(Index);
      if (Index > ParamCount) or not ParseSize(ParamStr(Index), Limit) then
      begin
        WriteLn(StdErr, Usage);
        Halt(2);
      end;
    end
    else if (ParamStr(Index) = '-h') or (ParamStr(Index) = '--help') then
    begin
      WriteLn(Usage);
      Halt(0);
    end
    else if (Length(ParamStr(Index)) > 1) and (ParamStr(Index)[1] = '-') then
    begin
      WriteLn(StdErr, Usage);
      Halt(2);
    end
    else
      FileName := ParamStr(Index);
    Inc(Index);
  end;
  Failed := False;
  Engine := TJsEngine.Create;
  try
    Engine.MemoryLimit := Limit;
    InstallShellGlobals(Engine, Arguments);
    if HasCode then
      RunCode(Code, '<command line>');
    if FileName <> '' then
    begin
      if not ReadSource(FileName, Text) then
        Halt(2);
      RunCode(Text, FileName);
    end;
    if Interactive or (not HasCode and (FileName = '')) then
      Interact;
  finally
    Engine.Free;
  end;
  if Failed then
    Halt(1);
end.
