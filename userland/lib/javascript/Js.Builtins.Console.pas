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
  The console namespace (Console Standard): log, info, debug, warn,
  error, trace, assert, dir, dirxml, table, group, groupCollapsed,
  groupEnd, clear, count, countReset, time, timeLog and timeEnd, as
  enumerable operations of a plain object whose @@toStringTag is
  "console". Everything is written through the realm's ConsoleWriter
  with %s %d %i %f %o %O %j %c substitution; warn, error, trace and the
  counters' and timers' complaints count as errors.

  The counters and timers of a realm live in two null-prototype objects
  (label -> count, label -> start in milliseconds) that their functions
  carry as Data.
}
unit Js.Builtins.Console;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Interpreter;

procedure InstallConsole(R: TJsInterpreterRealm);

implementation

uses
  SysUtils,
  DateUtils,
  Js.Values,
  Js.Strings,
  Js.Symbols,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Inspect;

const
  ConsoleLevelLog = 0;
  ConsoleLevelError = 1;

  CounterCount = 0;
  CounterReset = 1;

  TimerStart = 0;
  TimerLog = 1;
  TimerEnd = 2;

function FormatArguments(R: TJsRealm; Args: PJsValueArray; ArgCount: Integer): string;
var
  Format_, Piece: string;
  Index, Next: Integer;
  Number: Double;
begin
  Result := '';
  if ArgCount = 0 then
    Exit;
  Next := 1;
  if JsIsString(Args^[0]) then
  begin
    Format_ := StringToUtf8(R.Heap, JsAsString(Args^[0]));
    Index := 1;
    while Index <= Length(Format_) do
    begin
      if (Format_[Index] = '%') and (Index < Length(Format_)) then
      begin
        case Format_[Index + 1] of
          's', 'd', 'i', 'f', 'o', 'O', 'j', 'c':
            if Next < ArgCount then
            begin
              case Format_[Index + 1] of
                's':
                  if JsIsString(Args^[Next]) then
                    Piece := StringToUtf8(R.Heap, JsAsString(Args^[Next]))
                  else
                    Piece := InspectNested(R, Args^[Next]);
                'd', 'i', 'f':
                  if JsIsSymbol(Args^[Next]) then
                    Piece := 'NaN'
                  else if ToDouble(R, Args^[Next], Number) then
                  begin
                    if Format_[Index + 1] <> 'f' then
                      Number := Int(Number);
                    Piece := NumberToString(Number);
                  end
                  else
                  begin
                    R.Runtime.TakeException;
                    Piece := 'NaN';
                  end;
                'c':
                  Piece := '';
              else
                Piece := InspectNested(R, Args^[Next]);
              end;
              Result := Result + Piece;
              Inc(Next);
              Inc(Index, 2);
              Continue;
            end;
          '%':
            begin
              Result := Result + '%';
              Inc(Index, 2);
              Continue;
            end;
        end;
      end;
      Result := Result + Format_[Index];
      Inc(Index);
    end;
  end
  else
    Result := InspectValue(R, Args^[0]);
  for Index := Next to ArgCount - 1 do
    Result := Result + ' ' + InspectValue(R, Args^[Index]);
end;

procedure WriteConsole(R: TJsRealm; const Text: string; IsError: Boolean);
var
  Realm: TJsInterpreterRealm;
  Indented: string;
begin
  Realm := TJsInterpreterRealm(R);
  Indented := Text;
  if Realm.ConsoleIndent > 0 then
    Indented := StringOfChar(' ', Realm.ConsoleIndent) +
      StringReplace(Text, #10, #10 + StringOfChar(' ', Realm.ConsoleIndent), [rfReplaceAll]);
  if Assigned(Realm.ConsoleWriter) then
    Realm.ConsoleWriter(Indented, IsError)
  else if IsError then
    WriteLn(StdErr, Indented)
  else
    WriteLn(Indented);
end;

{ The label argument as text ("default" when absent); False when its
  conversion threw. }
function LabelOf(R: TJsRealm; Args: PJsValueArray; ArgCount: Integer; out Text: string): Boolean;
var
  Converted: TJsString;
begin
  Text := 'default';
  if (ArgCount = 0) or (Args^[0] = JsUndefined) then
    Exit(True);
  Converted := ToJsString(R, Args^[0]);
  if Converted = nil then
    Exit(False);
  Text := StringToUtf8(R.Heap, Converted);
  Result := True;
end;

function NowMilliseconds: Double;
begin
  Result := MilliSecondsBetween(Now, 0);
end;

{ Magic: ConsoleLevelLog or ConsoleLevelError (log, info, debug, dirxml,
  table; warn, error, trace). }
function ConsoleLog(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  WriteConsole(R, FormatArguments(R, Args, ArgCount), Callee.Magic = ConsoleLevelError);
  Result := JsUndefined;
end;

{ dir(item): the item inspected, never formatted. }
function ConsoleDir(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  WriteConsole(R, InspectValue(R, Arg(Args, ArgCount, 0)), False);
  Result := JsUndefined;
end;

function ConsoleAssert(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := JsUndefined;
  if ToBoolean(Arg(Args, ArgCount, 0)) then
    Exit;
  if ArgCount > 1 then
    WriteConsole(R, 'Assertion failed: ' + FormatArguments(R, @Args^[1], ArgCount - 1), True)
  else
    WriteConsole(R, 'Assertion failed', True);
end;

{ Magic: 0 group and groupCollapsed, 1 groupEnd, 2 clear. }
function ConsoleGroup(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Realm: TJsInterpreterRealm;
begin
  Realm := TJsInterpreterRealm(R);
  case Callee.Magic of
    0:
      begin
        if ArgCount > 0 then
          WriteConsole(R, FormatArguments(R, Args, ArgCount), False);
        Inc(Realm.ConsoleIndent, 2);
      end;
    1:
      if Realm.ConsoleIndent >= 2 then
        Dec(Realm.ConsoleIndent, 2);
  else
    Realm.ConsoleIndent := 0;
  end;
  Result := JsUndefined;
end;

{ Magic: CounterCount or CounterReset; Callee.Data: label -> count. }
function ConsoleCounter(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Counts: TJsObject;
  Text: string;
  Key, Current: TJsValue;
  Count: Double;
begin
  if not LabelOf(R, Args, ArgCount, Text) then
    Exit(JsException);
  Result := JsUndefined;
  Counts := JsAsObject(Callee.Data);
  Key := R.NewString(Text);
  Current := Counts.GetValue(R, Key);
  if Callee.Magic = CounterReset then
  begin
    if Current = JsUndefined then
      WriteConsole(R, 'Count for ''' + Text + ''' does not exist', True)
    else
      Counts.Put(R, Key, JsInteger(0));
    Exit;
  end;
  Count := 1;
  if Current <> JsUndefined then
    Count := JsNumberValue(Current) + 1;
  Counts.Put(R, Key, JsDouble(Count));
  WriteConsole(R, Text + ': ' + NumberToString(Count), False);
end;

{ Magic: TimerStart, TimerLog or TimerEnd; Callee.Data: label -> start. }
function ConsoleTimer(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Timers: TJsObject;
  Text, Line: string;
  Key, Started: TJsValue;
begin
  if not LabelOf(R, Args, ArgCount, Text) then
    Exit(JsException);
  Result := JsUndefined;
  Timers := JsAsObject(Callee.Data);
  Key := R.NewString(Text);
  Started := Timers.GetValue(R, Key);
  if Callee.Magic = TimerStart then
  begin
    if Started <> JsUndefined then
      WriteConsole(R, 'Timer ''' + Text + ''' already exists', True)
    else
      Timers.Put(R, Key, JsDouble(NowMilliseconds));
    Exit;
  end;
  if Started = JsUndefined then
  begin
    WriteConsole(R, 'Timer ''' + Text + ''' does not exist', True);
    Exit;
  end;
  Line := Text + ': ' + NumberToString(NowMilliseconds - JsNumberValue(Started)) + ' ms';
  if (Callee.Magic = TimerLog) and (ArgCount > 1) then
    Line := Line + ' ' + FormatArguments(R, @Args^[1], ArgCount - 1);
  if Callee.Magic = TimerEnd then
    Timers.DeleteProperty(R, Key);
  WriteConsole(R, Line, False);
end;

procedure InstallConsole(R: TJsInterpreterRealm);
var
  Console, Counts, Timers: TJsObject;

  function Operation(const Name: string; Callback: TJsNativeCallback; Magic: Integer): TJsNativeFunction;
  var
    Key: TJsValue;
  begin
    Key := R.Intern(Name);
    Result := NewNativeFunctionWithKey(R, Key, Callback, 0, Magic);
    Console.DefineData(R, Key, JsObjectValue(Result), PropertyDefault);
  end;

begin
  Console := R.NewPlainObject;
  DefineValue(R, R.GlobalObject, 'console', JsObjectValue(Console));
  Counts := R.NewObject(nil);
  Timers := R.NewObject(nil);
  Operation('assert', @ConsoleAssert, 0);
  Operation('clear', @ConsoleGroup, 2);
  Operation('debug', @ConsoleLog, ConsoleLevelLog);
  Operation('error', @ConsoleLog, ConsoleLevelError);
  Operation('info', @ConsoleLog, ConsoleLevelLog);
  Operation('log', @ConsoleLog, ConsoleLevelLog);
  Operation('table', @ConsoleLog, ConsoleLevelLog);
  Operation('trace', @ConsoleLog, ConsoleLevelError);
  Operation('warn', @ConsoleLog, ConsoleLevelError);
  Operation('dir', @ConsoleDir, 0);
  Operation('dirxml', @ConsoleLog, ConsoleLevelLog);
  Operation('count', @ConsoleCounter, CounterCount).Data := JsObjectValue(Counts);
  Operation('countReset', @ConsoleCounter, CounterReset).Data := JsObjectValue(Counts);
  Operation('group', @ConsoleGroup, 0);
  Operation('groupCollapsed', @ConsoleGroup, 0);
  Operation('groupEnd', @ConsoleGroup, 1);
  Operation('time', @ConsoleTimer, TimerStart).Data := JsObjectValue(Timers);
  Operation('timeLog', @ConsoleTimer, TimerLog).Data := JsObjectValue(Timers);
  Operation('timeEnd', @ConsoleTimer, TimerEnd).Data := JsObjectValue(Timers);
  Console.DefineData(R, R.Runtime.SymbolValue(wsToStringTag), R.NewString('console'), PropertyConfigurable);
end;

end.
