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
  Error and its kinds (EvalError, RangeError, ReferenceError,
  SyntaxError, TypeError, URIError, AggregateError, and InternalError
  for the engine's own failures).

  An error made by a constructor gets the message, the cause (options.cause) and the stack trace of the frames running then
  ("Name: message" and an "    at function (file:line:column)" line
  per frame), as V8 does.
}
unit Js.Builtins.Error;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Values,
  Js.Strings,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Interpreter;

procedure InstallErrors(R: TJsInterpreterRealm);

implementation

const
  KindIntrinsics: array[TJsErrorKind] of TJsIntrinsic = (inErrorPrototype, inEvalErrorPrototype,
    inRangeErrorPrototype, inReferenceErrorPrototype, inSyntaxErrorPrototype, inTypeErrorPrototype,
    inUriErrorPrototype, inAggregateErrorPrototype, inInternalErrorPrototype);

function ErrorConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Kind: TJsErrorKind;
  Target: TJsObject;
  Prototype: TJsObject;
  Message, Options, Cause, Name, Errors: TJsValue;
  Text: TJsString;
  MessageIndex: Integer;
  Header: string;
  List: TJsValueList;
  Found: Integer;
begin
  Kind := TJsErrorKind(Callee.Magic);
  if NewTarget = JsUndefined then
    Prototype := PrototypeFromConstructor(R, JsObjectValue(Callee), KindIntrinsics[Kind])
  else
    Prototype := PrototypeFromConstructor(R, NewTarget, KindIntrinsics[Kind]);
  if Prototype = nil then
    Exit(JsException);
  Target := R.NewObjectOfClass(TJsObject, Prototype, ocError);
  Result := JsObjectValue(Target);
  MessageIndex := 0;
  if Kind = ekAggregate then
    MessageIndex := 1;
  Message := Arg(Args, ArgCount, MessageIndex);
  if Message <> JsUndefined then
  begin
    Text := ToJsString(R, Message);
    if Text = nil then
      Exit(JsException);
    Target.DefineData(R, R.Atom(anMessage), JsStringValue(Text), PropertyHidden);
  end;
  Options := Arg(Args, ArgCount, MessageIndex + 1);
  if JsIsObject(Options) then
  begin
    Found := JsAsObject(Options).HasProperty(R, R.Atom(anCause));
    if Found < 0 then
      Exit(JsException);
    if Found > 0 then
    begin
      Cause := JsAsObject(Options).GetValue(R, R.Atom(anCause));
      if Cause = JsException then
        Exit(JsException);
      Target.DefineData(R, R.Atom(anCause), Cause, PropertyHidden);
    end;
  end;
  if Kind = ekAggregate then
  begin
    if not IterableToList(R, Arg(Args, ArgCount, 0), List) then
      Exit(JsException);
    Errors := JsObjectValue(R.NewArrayFrom(@List[0], Length(List)));
    Target.DefineData(R, R.Atom(anErrors), Errors, PropertyHidden);
  end;
  { The stack: the header as toString would give it, and the frames. }
  Name := Target.GetValue(R, R.Atom(anName));
  if JsIsString(Name) then
    Header := StringToUtf8(R.Heap, JsAsString(Name))
  else
    Header := ErrorKindName(Kind);
  Message := Target.GetValue(R, R.Atom(anMessage));
  if JsIsString(Message) and (JsAsString(Message).Length > 0) then
    Header := Header + ': ' + StringToUtf8(R.Heap, JsAsString(Message));
  Target.DefineData(R, R.Atom(anStack), R.NewString(Header + TJsInterpreterRealm(R).StackTraceText),
    PropertyHidden);
end;

function ErrorPrototypeToString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Name, Message: TJsValue;
  NameText, MessageText: TJsString;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('Error.prototype.toString called on non-object'));
  Target := JsAsObject(This);
  Name := Target.GetValue(R, R.Atom(anName));
  if Name = JsException then
    Exit(JsException);
  if Name = JsUndefined then
    NameText := NewStringFromUtf8(R.Heap, 'Error')
  else
  begin
    NameText := ToJsString(R, Name);
    if NameText = nil then
      Exit(JsException);
  end;
  Message := Target.GetValue(R, R.Atom(anMessage));
  if Message = JsException then
    Exit(JsException);
  if Message = JsUndefined then
    MessageText := R.Runtime.EmptyString
  else
  begin
    MessageText := ToJsString(R, Message);
    if MessageText = nil then
      Exit(JsException);
  end;
  if NameText.Length = 0 then
    Exit(JsStringValue(MessageText));
  if MessageText.Length = 0 then
    Exit(JsStringValue(NameText));
  Result := ConcatValues(R, ConcatStrings(R.Heap, NameText, NewStringFromUtf8(R.Heap, ': ')), MessageText);
end;

function ErrorCaptureStackTrace(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsValue;
  Header: TJsValue;
  Skip: TJsObject;
begin
  Target := Arg(Args, ArgCount, 0);
  if not JsIsObject(Target) then
    Exit(R.ThrowTypeError('Invalid argument'));
  Header := ToStringValue(R, Target);
  if Header = JsException then
    Exit(JsException);
  Skip := nil;
  if JsIsObject(Arg(Args, ArgCount, 1)) then
    Skip := JsAsObject(Args^[1]);
  JsAsObject(Target).DefineData(R, R.Atom(anStack), R.NewString(StringToUtf8(R.Heap, JsAsString(Header)) +
    TJsInterpreterRealm(R).StackTraceTextFor(Skip)), PropertyHidden);
  Result := JsUndefined;
end;

procedure InstallErrors(R: TJsInterpreterRealm);
var
  Kind: TJsErrorKind;
  Prototype: TJsObject;
  Constructor_, Base: TJsNativeFunction;
  Name: string;
begin
  Base := nil;
  for Kind := Low(TJsErrorKind) to High(TJsErrorKind) do
  begin
    Prototype := R.Intrinsics[KindIntrinsics[Kind]];
    Name := ErrorKindName(Kind);
    if Kind = ekAggregate then
      Constructor_ := DefineConstructor(R, R.GlobalObject, Name, @ErrorConstructor, 2, Prototype)
    else if Kind = ekInternal then
      Constructor_ := DefineConstructor(R, nil, Name, @ErrorConstructor, 1, Prototype)
    else
      Constructor_ := DefineConstructor(R, R.GlobalObject, Name, @ErrorConstructor, 1, Prototype);
    Constructor_.Magic := Ord(Kind);
    DefineValue(R, Prototype, 'name', R.NewString(Name));
    DefineValue(R, Prototype, 'message', R.Atom(anEmpty));
    if Kind = ekError then
    begin
      Base := Constructor_;
      R.Intrinsics[inError] := Constructor_;
      DefineMethod(R, Prototype, 'toString', @ErrorPrototypeToString, 0);
      DefineMethod(R, Constructor_, 'captureStackTrace', @ErrorCaptureStackTrace, 1);
      Constructor_.DefineData(R, R.Intern('stackTraceLimit'), JsInteger(10), PropertyDefault);
    end
    else
      Constructor_.Proto := Base;
  end;
end;

end.
