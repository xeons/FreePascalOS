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
  What the js shell adds to the global object: print(), load(),
  scriptArgs, gc(), the timer functions and performance.now().
}
unit JsShell.Globals;

{$mode objfpc}{$H+}

interface

uses
  Js.Engine;

procedure InstallShellGlobals(Engine: TJsEngine; const Arguments: array of string);

implementation

uses
  SysUtils,
  Sys.Streams,
  Util.Input,
  Js.Values,
  Js.Objects,
  Js.Functions,
  Js.Operations,
  Js.Platform,
  JsShell.Timers;

var
  ShellEngine: TJsEngine;

function ShellPrint(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Index: Integer;
  Line: string;
begin
  Line := '';
  try
    for Index := 0 to ArgCount - 1 do
    begin
      if Index > 0 then
        Line := Line + ' ';
      Line := Line + ShellEngine.ToText(Args^[Index]);
    end;
  except
    on EJsError do
      Exit(R.ThrowTypeError('print: an argument cannot be converted to a string'));
  end;
  WriteLn(Line);
  Result := JsUndefined;
end;

function ShellLoad(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Path, Text: string;
  Stream: PInputStream;
begin
  Path := ShellEngine.ToText(Arg(Args, ArgCount, 0));
  Stream := OpenInput(Path);
  if Stream = nil then
    Exit(R.ThrowError(ekError, 'load: cannot read ' + Path));
  Text := ReadAllText(Stream);
  CloseInput(Stream);
  try
    Result := ShellEngine.Evaluate(Text, Path);
  except
    on Error: EJsError do
      Result := R.ThrowError(ekError, Error.Message);
  end;
end;

function ShellGc(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  { Collecting here would lose values the caller's frame holds only in
    Pascal; the next safe point collects. }
  R.Heap.Threshold := 0;
  Result := JsUndefined;
end;

{ setTimeout (0), setInterval (1) }
function ShellSetTimer(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Delay: Double;
  Extra: array of TJsValue;
  Index: Integer;
begin
  if not JsIsCallable(Arg(Args, ArgCount, 0)) then
    Exit(R.ThrowTypeError('The callback must be a function'));
  Delay := 0;
  if JsIsNumber(Arg(Args, ArgCount, 1)) then
    Delay := JsNumberValue(Args^[1]);
  Extra := nil;
  if ArgCount > 2 then
  begin
    SetLength(Extra, ArgCount - 2);
    for Index := 2 to ArgCount - 1 do
      Extra[Index - 2] := Args^[Index];
  end;
  Result := JsInteger(AddTimer(ShellEngine, Args^[0], Extra, Delay, Callee.Magic = 1));
end;

function ShellClearTimer(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if JsIsInteger(Arg(Args, ArgCount, 0)) then
    RemoveTimer(ShellEngine, JsAsInteger(Args^[0]));
  Result := JsUndefined;
end;

function ShellNow(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsNumber(JsMonotonicTime());
end;

procedure InstallShellGlobals(Engine: TJsEngine; const Arguments: array of string);
var
  Global, Performance: TJsObject;
  Values: array of TJsValue;
  Index: Integer;
begin
  ShellEngine := Engine;
  Global := Engine.GlobalObject;
  Engine.DefineFunction(Global, 'print', @ShellPrint, 1);
  Engine.DefineFunction(Global, 'load', @ShellLoad, 1);
  Engine.DefineFunction(Global, 'gc', @ShellGc, 0);
  Engine.DefineFunction(Global, 'setTimeout', @ShellSetTimer, 2, 0);
  Engine.DefineFunction(Global, 'setInterval', @ShellSetTimer, 2, 1);
  Engine.DefineFunction(Global, 'clearTimeout', @ShellClearTimer, 1);
  Engine.DefineFunction(Global, 'clearInterval', @ShellClearTimer, 1);
  Performance := Engine.NewObject;
  Engine.DefineValue(Global, 'performance', JsObjectValue(Performance));
  Engine.DefineFunction(Performance, 'now', @ShellNow, 0);
  Values := nil;
  SetLength(Values, Length(Arguments));
  for Index := 0 to High(Arguments) do
    Values[Index] := Engine.NewString(Arguments[Index]);
  Engine.DefineValue(Global, 'scriptArgs', Engine.NewArray(Values));
end;

end.
