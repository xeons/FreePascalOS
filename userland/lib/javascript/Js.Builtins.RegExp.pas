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
  RegExp: the constructor, exec / test / toString, the flag getters,
  and the Symbol.match / matchAll / replace / search / split methods
  String.prototype hands patterns to.

  exec runs the compiled program (Js.RegExpCompiler, Js.RegExpMatcher)
  and builds the match array with index, input, groups and, with the
  d flag, indices. The symbol methods follow the specification's
  algorithms through RegExpExec, so a subclass's exec is honoured;
  split uses the matcher directly.
}
unit Js.Builtins.RegExp;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Math,
  Js.Values,
  Js.Heap,
  Js.Strings,
  Js.Symbols,
  Js.Atoms,
  Js.Shapes,
  Js.Runtime,
  Js.Objects,
  Js.Functions,
  Js.Conversions,
  Js.Operations,
  Js.Inspect,
  Js.Interpreter,
  Js.RegExpCompiler,
  Js.RegExpMatcher,
  Js.Builtins.Strings;

procedure InstallRegExp(R: TJsInterpreterRealm);

implementation

uses
  Js.Builtins.AnnexB;

const
  FlagHasIndices = 1;
  FlagGlobal = 2;
  FlagIgnoreCase = 4;
  FlagMultiline = 8;
  FlagDotAll = 16;
  FlagUnicode = 32;
  FlagUnicodeSets = 64;
  FlagSticky = 128;

type
  TJsRegExp = class(TJsObject)
  public
    Source: TJsString;
    FlagBits: Integer;
    Program_: TRxProgram;
    Matcher: TRxMatcher;
    destructor Destroy; override;
    procedure Trace(Tracer: TJsTracer); override;
    function MemorySize: SizeInt; override;
  end;

  TJsRegExpStringIterator = class(TJsObject)
  public
    Matcher: TJsValue;
    Text: TJsString;
    Global: Boolean;
    Unicode: Boolean;
    Done: Boolean;
    procedure Trace(Tracer: TJsTracer); override;
  end;

destructor TJsRegExp.Destroy;
begin
  Matcher.Free;
  Program_.Free;
  inherited Destroy;
end;

procedure TJsRegExp.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Source);
end;

function TJsRegExp.MemorySize: SizeInt;
begin
  Result := inherited MemorySize;
  if Program_ <> nil then
    Inc(Result, Length(Program_.Code) * 4 + 256);
end;

procedure TJsRegExpStringIterator.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkValue(Matcher);
  Tracer.MarkCell(Text);
end;

function ParseFlags(Text: TJsString; out Bits: Integer): Boolean;
var
  Index, Bit: Integer;
begin
  Bits := 0;
  for Index := 0 to Text.Length - 1 do
  begin
    case Chr(Text.CharAt(Index) and $FF) of
      'd': Bit := FlagHasIndices;
      'g': Bit := FlagGlobal;
      'i': Bit := FlagIgnoreCase;
      'm': Bit := FlagMultiline;
      's': Bit := FlagDotAll;
      'u': Bit := FlagUnicode;
      'v': Bit := FlagUnicodeSets;
      'y': Bit := FlagSticky;
    else
      Exit(False);
    end;
    if (Text.CharAt(Index) > 255) or ((Bits and Bit) <> 0) then
      Exit(False);
    Bits := Bits or Bit;
  end;
  Result := (Bits and (FlagUnicode or FlagUnicodeSets)) <> (FlagUnicode or FlagUnicodeSets);
end;

function FlagsText(Bits: Integer): string;
begin
  Result := '';
  if (Bits and FlagHasIndices) <> 0 then
    Result := Result + 'd';
  if (Bits and FlagGlobal) <> 0 then
    Result := Result + 'g';
  if (Bits and FlagIgnoreCase) <> 0 then
    Result := Result + 'i';
  if (Bits and FlagMultiline) <> 0 then
    Result := Result + 'm';
  if (Bits and FlagDotAll) <> 0 then
    Result := Result + 's';
  if (Bits and FlagUnicode) <> 0 then
    Result := Result + 'u';
  if (Bits and FlagUnicodeSets) <> 0 then
    Result := Result + 'v';
  if (Bits and FlagSticky) <> 0 then
    Result := Result + 'y';
end;

{ Sets up a regexp object from pattern and flag text. }
function Initialize(R: TJsRealm; Target: TJsRegExp; Pattern, Flags: TJsString): Boolean;
var
  Bits: Integer;
  Compiled: TRxProgram;
begin
  Result := False;
  if not ParseFlags(Flags, Bits) then
  begin
    R.ThrowError(ekSyntax, 'Invalid flags supplied to RegExp constructor ''' + StringToUtf8(R.Heap, Flags) + '''');
    Exit;
  end;
  Pattern.Flatten(R.Heap);
  try
    Compiled := CompileRegExp(StringToUnicode(R.Heap, Pattern), (Bits and FlagIgnoreCase) <> 0,
      (Bits and FlagMultiline) <> 0, (Bits and FlagDotAll) <> 0, (Bits and (FlagUnicode or FlagUnicodeSets)) <> 0);
  except
    on Error: ERegExpSyntax do
    begin
      R.ThrowError(ekSyntax, Error.Message);
      Exit;
    end;
  end;
  Target.Matcher.Free;
  Target.Program_.Free;
  Target.Program_ := Compiled;
  Target.Matcher := TRxMatcher.Create(Compiled, @R.Runtime.InterruptRequested);
  Target.Source := Pattern;
  Target.FlagBits := Bits;
  Result := Target.Put(R, R.Atom(anLastIndex), JsInteger(0));
end;

function NewRegExpObject(R: TJsRealm; Prototype: TJsObject): TJsRegExp;
begin
  Result := TJsRegExp(R.NewObjectOfClass(TJsRegExp, Prototype, ocRegExp));
  Result.DefineData(R, R.Atom(anLastIndex), JsInteger(0), PropertyWritable);
end;

function IsRegExpObject(Value: TJsValue): Boolean; inline;
begin
  Result := JsIsObject(Value) and (JsAsObject(Value) is TJsRegExp);
end;

function RegExpConstructor(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Pattern, Flags, Constructor_, Source: TJsValue;
  PatternText, FlagText: TJsString;
  Prototype: TJsObject;
  Target: TJsRegExp;
  IsPattern: Boolean;
  Matcher: TJsValue;
begin
  Pattern := Arg(Args, ArgCount, 0);
  Flags := Arg(Args, ArgCount, 1);
  IsPattern := IsRegExpObject(Pattern);
  if not IsPattern and JsIsObject(Pattern) then
  begin
    Matcher := JsAsObject(Pattern).GetValue(R, R.Runtime.SymbolValue(wsMatch));
    if Matcher = JsException then
      Exit(JsException);
    IsPattern := (Matcher <> JsUndefined) and ToBoolean(Matcher);
  end;
  if (NewTarget = JsUndefined) and IsPattern and (Flags = JsUndefined) then
  begin
    Constructor_ := JsAsObject(Pattern).GetValue(R, R.ConstructorKey);
    if Constructor_ = JsException then
      Exit(JsException);
    if Constructor_ = JsObjectValue(Callee) then
      Exit(Pattern);
  end;
  if IsRegExpObject(Pattern) then
  begin
    PatternText := TJsRegExp(JsAsObject(Pattern)).Source;
    if Flags = JsUndefined then
      FlagText := NewStringFromUtf8(R.Heap, FlagsText(TJsRegExp(JsAsObject(Pattern)).FlagBits))
    else
    begin
      FlagText := ToJsString(R, Flags);
      if FlagText = nil then
        Exit(JsException);
    end;
  end
  else
  begin
    if IsPattern then
    begin
      Source := JsAsObject(Pattern).GetValue(R, R.Atom(anSource));
      if Source = JsException then
        Exit(JsException);
      if Flags = JsUndefined then
      begin
        Flags := JsAsObject(Pattern).GetValue(R, R.Atom(anFlags));
        if Flags = JsException then
          Exit(JsException);
      end;
      Pattern := Source;
    end;
    if Pattern = JsUndefined then
      PatternText := R.Runtime.EmptyString
    else
    begin
      PatternText := ToJsString(R, Pattern);
      if PatternText = nil then
        Exit(JsException);
    end;
    if Flags = JsUndefined then
      FlagText := R.Runtime.EmptyString
    else
    begin
      FlagText := ToJsString(R, Flags);
      if FlagText = nil then
        Exit(JsException);
    end;
  end;
  if NewTarget = JsUndefined then
    Prototype := R.Intrinsics[inRegExpPrototype]
  else
  begin
    Prototype := PrototypeFromConstructor(R, NewTarget, inRegExpPrototype);
    if Prototype = nil then
      Exit(JsException);
  end;
  Target := NewRegExpObject(R, Prototype);
  if not Initialize(R, Target, PatternText, FlagText) then
    Exit(JsException);
  Result := JsObjectValue(Target);
end;

{ exec }

function AdvanceIndex(Text: TJsString; Index: Int64; Unicode: Boolean): Int64;
var
  Code: Word;
begin
  if not Unicode or (Index + 1 >= Text.Length) then
    Exit(Index + 1);
  Code := Text.CharAt(Index);
  if (Code >= $D800) and (Code <= $DBFF) and (Text.CharAt(Index + 1) >= $DC00) and (Text.CharAt(Index + 1) <= $DFFF) then
    Exit(Index + 2);
  Result := Index + 1;
end;

function GetLastIndex(R: TJsRealm; Target: TJsObject; out Index: Int64): Boolean;
var
  Value: TJsValue;
begin
  Value := Target.GetValue(R, R.Atom(anLastIndex));
  if Value = JsException then
  begin
    Index := 0;
    Exit(False);
  end;
  Result := ToLength(R, Value, Index);
end;

function SetLastIndex(R: TJsRealm; Target: TJsObject; Index: Int64): Boolean;
begin
  Result := SetPropertyByKey(R, JsObjectValue(Target), R.Atom(anLastIndex), JsNumber(Index), True);
end;

function BuiltinExec(R: TJsRealm; Target: TJsRegExp; Text: TJsString): TJsValue;
var
  LastIndex: Int64;
  Global, Sticky, HasIndices: Boolean;
  Outcome: TRxOutcome;
  Captures: TRxCaptures;
  Created, Indices, Pair: TJsArray;
  Groups, IndexGroups: TJsObject;
  Index, Start, Finish, Mark: Integer;
  Value: TJsValue;
  Program_: TRxProgram;
begin
  if not GetLastIndex(R, Target, LastIndex) then
    Exit(JsException);
  Global := (Target.FlagBits and FlagGlobal) <> 0;
  Sticky := (Target.FlagBits and FlagSticky) <> 0;
  HasIndices := (Target.FlagBits and FlagHasIndices) <> 0;
  if not Global and not Sticky then
    LastIndex := 0;
  Text.Flatten(R.Heap);
  if LastIndex > Text.Length then
  begin
    if Global or Sticky then
      if not SetLastIndex(R, Target, 0) then
        Exit(JsException);
    Exit(JsNull);
  end;
  Outcome := Target.Matcher.Search(Text, LastIndex, Sticky);
  if Outcome = roOutOfMemory then
    Exit(R.ThrowRangeError('Out of memory matching the regular expression'));
  if Outcome = roInterrupted then
  begin
    R.Runtime.InterruptRequested := False;
    R.Runtime.Terminating := True;
    Exit(R.ThrowError(ekInternal, 'Script interrupted'));
  end;
  if Outcome = roNoMatch then
  begin
    if Global or Sticky then
      if not SetLastIndex(R, Target, 0) then
        Exit(JsException);
    Exit(JsNull);
  end;
  Captures := Copy(Target.Matcher.Captures);
  Program_ := Target.Program_;
  RecordLegacyMatch(R, Text, Captures, Program_.GroupCount);
  if Global or Sticky then
    if not SetLastIndex(R, Target, Captures[1]) then
      Exit(JsException);
  Created := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  try
    for Index := 0 to Program_.GroupCount do
    begin
      Start := Captures[Index * 2];
      Finish := Captures[Index * 2 + 1];
      if (Start >= 0) and (Finish >= Start) then
        Value := JsStringValue(SubString(R.Heap, Text, Start, Finish - Start))
      else
        Value := JsUndefined;
      Created.CreateDataProperty(R, JsInteger(Index), Value);
    end;
    Created.CreateDataProperty(R, R.Atom(anIndex), JsInteger(Captures[0]));
    Created.CreateDataProperty(R, R.Atom(anInput), JsStringValue(Text));
    Groups := nil;
    if Length(Program_.GroupNames) > 0 then
    begin
      Groups := R.NewObject(nil);
      for Index := 0 to High(Program_.GroupNames) do
      begin
        Value := Created.Elements^[Program_.GroupNames[Index].Group];
        if (Value = JsUndefined) and (Groups.HasProperty(R, R.Runtime.Intern(UTF8Encode(Program_.GroupNames[Index].Name))) > 0) then
          Continue;
        Groups.CreateDataProperty(R, JsStringValue(R.Runtime.Atoms.Intern(NewStringFromUnicode(R.Heap,
          Program_.GroupNames[Index].Name))), Value);
      end;
      Created.CreateDataProperty(R, R.Atom(anGroups), JsObjectValue(Groups));
    end
    else
      Created.CreateDataProperty(R, R.Atom(anGroups), JsUndefined);
    if HasIndices then
    begin
      Indices := R.NewArray(0);
      for Index := 0 to Program_.GroupCount do
      begin
        Start := Captures[Index * 2];
        Finish := Captures[Index * 2 + 1];
        if (Start >= 0) and (Finish >= Start) then
        begin
          Pair := R.NewArray(0);
          Pair.CreateDataProperty(R, JsInteger(0), JsInteger(Start));
          Pair.CreateDataProperty(R, JsInteger(1), JsInteger(Finish));
          Indices.CreateDataProperty(R, JsInteger(Index), JsObjectValue(Pair));
        end
        else
          Indices.CreateDataProperty(R, JsInteger(Index), JsUndefined);
      end;
      if Groups <> nil then
      begin
        IndexGroups := R.NewObject(nil);
        for Index := 0 to High(Program_.GroupNames) do
          IndexGroups.CreateDataProperty(R, JsStringValue(R.Runtime.Atoms.Intern(NewStringFromUnicode(R.Heap,
            Program_.GroupNames[Index].Name))), Indices.Elements^[Program_.GroupNames[Index].Group]);
        Indices.CreateDataProperty(R, R.Atom(anGroups), JsObjectValue(IndexGroups));
      end
      else
        Indices.CreateDataProperty(R, R.Atom(anGroups), JsUndefined);
      Created.CreateDataProperty(R, R.Atom(anIndices), JsObjectValue(Indices));
    end;
    Result := JsObjectValue(Created);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

{ RegExpExec: the object's exec if it has its own, else the built-in. }
function RegExpExec(R: TJsRealm; Target: TJsObject; Text: TJsString): TJsValue;
var
  Exec, Argument: TJsValue;
begin
  Exec := Target.GetValue(R, R.Atom(anExec));
  if Exec = JsException then
    Exit(JsException);
  if JsIsCallable(Exec) and not ((JsAsObject(Exec) is TJsNativeFunction) and
    (TJsNativeFunction(JsAsObject(Exec)).Magic = $E8EC) and (Target is TJsRegExp)) then
  begin
    Argument := JsStringValue(Text);
    Result := R.Call(Exec, JsObjectValue(Target), @Argument, 1);
    if (Result <> JsException) and not JsIsObject(Result) and (Result <> JsNull) then
      Result := R.ThrowTypeError('exec result must be an object or null');
    Exit;
  end;
  if not (Target is TJsRegExp) then
    Exit(R.ThrowTypeError('RegExp exec method called on incompatible receiver'));
  Result := BuiltinExec(R, TJsRegExp(Target), Text);
end;

function ThisRegExp(R: TJsRealm; Value: TJsValue; out Target: TJsRegExp): Boolean;
begin
  Target := nil;
  if not IsRegExpObject(Value) then
  begin
    R.ThrowTypeError('RegExp method called on incompatible receiver ' + ValueToPascal(R, Value));
    Exit(False);
  end;
  Target := TJsRegExp(JsAsObject(Value));
  Result := True;
end;

function RegExpPrototypeExec(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsRegExp;
  Text: TJsString;
begin
  if not ThisRegExp(R, This, Target) then
    Exit(JsException);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Result := BuiltinExec(R, Target, Text);
end;

function RegExpPrototypeTest(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Text: TJsString;
  Outcome: TJsValue;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype.test called on non-object'));
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Outcome := RegExpExec(R, JsAsObject(This), Text);
  if Outcome = JsException then
    Exit(JsException);
  Result := JsBoolean(Outcome <> JsNull);
end;

function EscapedSource(R: TJsRealm; Source: TJsString): string;
var
  Index: Integer;
  Text: UnicodeString;
  InClass: Boolean;
  Output: UnicodeString;
begin
  Text := StringToUnicode(R.Heap, Source);
  if Text = '' then
    Exit('(?:)');
  Output := '';
  InClass := False;
  Index := 1;
  while Index <= Length(Text) do
  begin
    case Text[Index] of
      '\':
        begin
          Output := Output + Text[Index];
          if Index < Length(Text) then
          begin
            Inc(Index);
            Output := Output + Text[Index];
          end;
        end;
      '/':
        if InClass then
          Output := Output + '/'
        else
          Output := Output + '\/';
      '[':
        begin
          InClass := True;
          Output := Output + '[';
        end;
      ']':
        begin
          InClass := False;
          Output := Output + ']';
        end;
      #10: Output := Output + '\n';
      #13: Output := Output + '\r';
      #$2028: Output := Output + ' ';
      #$2029: Output := Output + ' ';
    else
      Output := Output + Text[Index];
    end;
    Inc(Index);
  end;
  Result := UTF8Encode(Output);
end;

function RegExpPrototypeSource(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if This = JsObjectValue(R.Intrinsics[inRegExpPrototype]) then
    Exit(R.NewString('(?:)'));
  if not IsRegExpObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype.source getter called on non-RegExp object'));
  Result := R.NewString(EscapedSource(R, TJsRegExp(JsAsObject(This)).Source));
end;

{ The flag getters: Magic is the flag bit. }
function RegExpPrototypeFlag(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  if This = JsObjectValue(R.Intrinsics[inRegExpPrototype]) then
    Exit(JsUndefined);
  if not IsRegExpObject(This) then
    Exit(R.ThrowTypeError('RegExp flag getter called on non-RegExp object'));
  Result := JsBoolean((TJsRegExp(JsAsObject(This)).FlagBits and Callee.Magic) <> 0);
end;

function RegExpPrototypeFlags(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
const
  Names: array[0..7] of string = ('hasIndices', 'global', 'ignoreCase', 'multiline', 'dotAll', 'unicode',
    'unicodeSets', 'sticky');
  Letters: array[0..7] of Char = ('d', 'g', 'i', 'm', 's', 'u', 'v', 'y');
var
  Index: Integer;
  Value: TJsValue;
  Text: string;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype.flags getter called on non-object'));
  Text := '';
  for Index := 0 to 7 do
  begin
    Value := JsAsObject(This).GetValue(R, R.Intern(Names[Index]));
    if Value = JsException then
      Exit(JsException);
    if ToBoolean(Value) then
      Text := Text + Letters[Index];
  end;
  Result := R.NewString(Text);
end;

function RegExpPrototypeToString(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Source, Flags: TJsValue;
  SourceText, FlagText: TJsString;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype.toString called on non-object'));
  Source := JsAsObject(This).GetValue(R, R.Atom(anSource));
  if Source = JsException then
    Exit(JsException);
  SourceText := ToJsString(R, Source);
  if SourceText = nil then
    Exit(JsException);
  Flags := JsAsObject(This).GetValue(R, R.Atom(anFlags));
  if Flags = JsException then
    Exit(JsException);
  FlagText := ToJsString(R, Flags);
  if FlagText = nil then
    Exit(JsException);
  Result := R.NewString('/' + StringToUtf8(R.Heap, SourceText) + '/' + StringToUtf8(R.Heap, FlagText));
end;

function RegExpPrototypeCompile(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsRegExp;
  Pattern, Flags: TJsString;
begin
  if not ThisRegExp(R, This, Target) then
    Exit(JsException);
  if IsRegExpObject(Arg(Args, ArgCount, 0)) then
  begin
    Pattern := TJsRegExp(JsAsObject(Args^[0])).Source;
    Flags := NewStringFromUtf8(R.Heap, FlagsText(TJsRegExp(JsAsObject(Args^[0])).FlagBits));
  end
  else
  begin
    if Arg(Args, ArgCount, 0) = JsUndefined then
      Pattern := R.Runtime.EmptyString
    else
      Pattern := ToJsString(R, Args^[0]);
    if Pattern = nil then
      Exit(JsException);
    if Arg(Args, ArgCount, 1) = JsUndefined then
      Flags := R.Runtime.EmptyString
    else
      Flags := ToJsString(R, Args^[1]);
    if Flags = nil then
      Exit(JsException);
  end;
  if not Initialize(R, Target, Pattern, Flags) then
    Exit(JsException);
  Result := This;
end;

{ The symbol methods }

function FlagsOf(R: TJsRealm; Target: TJsObject; out Text: TJsString): Boolean;
var
  Flags: TJsValue;
begin
  Text := nil;
  Flags := Target.GetValue(R, R.Atom(anFlags));
  if Flags = JsException then
    Exit(False);
  Text := ToJsString(R, Flags);
  Result := Text <> nil;
end;

function HasFlag(Text: TJsString; Letter: Char): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to Text.Length - 1 do
    if Text.CharAt(Index) = Ord(Letter) then
      Exit(True);
  Result := False;
end;

function RegExpSymbolMatch(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Text, Flags, Matched: TJsString;
  Outcome, MatchedValue: TJsValue;
  Created: TJsArray;
  LastIndex: Int64;
  Mark: Integer;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype[Symbol.match] called on non-object'));
  Target := JsAsObject(This);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  if not FlagsOf(R, Target, Flags) then
    Exit(JsException);
  if not HasFlag(Flags, 'g') then
    Exit(RegExpExec(R, Target, Text));
  if not SetLastIndex(R, Target, 0) then
    Exit(JsException);
  Created := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  R.Runtime.PushRoot(JsStringValue(Text));
  try
    while True do
    begin
      Outcome := RegExpExec(R, Target, Text);
      if Outcome = JsException then
        Exit(JsException);
      if Outcome = JsNull then
      begin
        if Created.ArrayLength = 0 then
          Exit(JsNull);
        Exit(JsObjectValue(Created));
      end;
      MatchedValue := GetPropertyByKey(R, Outcome, JsInteger(0));
      if MatchedValue = JsException then
        Exit(JsException);
      Matched := ToJsString(R, MatchedValue);
      if Matched = nil then
        Exit(JsException);
      Created.CreateDataProperty(R, JsInteger(Created.ArrayLength), JsStringValue(Matched));
      if Matched.Length = 0 then
      begin
        if not GetLastIndex(R, Target, LastIndex) then
          Exit(JsException);
        if not SetLastIndex(R, Target, AdvanceIndex(Text, LastIndex, HasFlag(Flags, 'u') or HasFlag(Flags, 'v'))) then
          Exit(JsException);
      end;
    end;
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function RegExpSymbolSearch(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Text: TJsString;
  Previous, Outcome: TJsValue;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype[Symbol.search] called on non-object'));
  Target := JsAsObject(This);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Previous := Target.GetValue(R, R.Atom(anLastIndex));
  if Previous = JsException then
    Exit(JsException);
  if not SameValue(Previous, JsInteger(0), R.Heap) then
    if not Target.Put(R, R.Atom(anLastIndex), JsInteger(0)) then
      Exit(JsException);
  Outcome := RegExpExec(R, Target, Text);
  if Outcome = JsException then
    Exit(JsException);
  if not Target.Put(R, R.Atom(anLastIndex), Previous) then
    Exit(JsException);
  if Outcome = JsNull then
    Exit(JsInteger(-1));
  Result := GetPropertyByKey(R, Outcome, R.Atom(anIndex));
end;

function RegExpSymbolReplace(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Text, Flags, Replacement, Matched, Piece, Accumulated: TJsString;
  ReplaceValue, Outcome, MatchedValue, PositionValue, Capture, NamedGroups: TJsValue;
  Global, Unicode, Functional: Boolean;
  Results: TJsArray;
  Index, CaptureCount, Mark: Integer;
  ResultIndex: Integer;
  NextSourcePosition, Position: Int64;
  Number: Double;
  Captures: TJsValueList;
  CallArgs: TJsValueList;
  LastIndex: Int64;
  MatchObject: TJsObject;
  Length_: Int64;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype[Symbol.replace] called on non-object'));
  Target := JsAsObject(This);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  ReplaceValue := Arg(Args, ArgCount, 1);
  Functional := JsIsCallable(ReplaceValue);
  Replacement := nil;
  if not Functional then
  begin
    Replacement := ToJsString(R, ReplaceValue);
    if Replacement = nil then
      Exit(JsException);
  end;
  if not FlagsOf(R, Target, Flags) then
    Exit(JsException);
  Global := HasFlag(Flags, 'g');
  Unicode := HasFlag(Flags, 'u') or HasFlag(Flags, 'v');
  if Global then
    if not SetLastIndex(R, Target, 0) then
      Exit(JsException);
  Results := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Results));
  R.Runtime.PushRoot(JsStringValue(Text));
  if Replacement <> nil then
    R.Runtime.PushRoot(JsStringValue(Replacement));
  try
    while True do
    begin
      Outcome := RegExpExec(R, Target, Text);
      if Outcome = JsException then
        Exit(JsException);
      if Outcome = JsNull then
        Break;
      Results.CreateDataProperty(R, JsInteger(Results.ArrayLength), Outcome);
      if not Global then
        Break;
      MatchedValue := GetPropertyByKey(R, Outcome, JsInteger(0));
      if MatchedValue = JsException then
        Exit(JsException);
      Matched := ToJsString(R, MatchedValue);
      if Matched = nil then
        Exit(JsException);
      if Matched.Length = 0 then
      begin
        if not GetLastIndex(R, Target, LastIndex) then
          Exit(JsException);
        if not SetLastIndex(R, Target, AdvanceIndex(Text, LastIndex, Unicode)) then
          Exit(JsException);
      end;
    end;
    Accumulated := R.Runtime.EmptyString;
    NextSourcePosition := 0;
    for ResultIndex := 0 to Results.ElementCount - 1 do
    begin
      MatchObject := JsAsObject(Results.Elements^[ResultIndex]);
      if not LengthOfArrayLike(R, MatchObject, Length_) then
        Exit(JsException);
      CaptureCount := Max(Length_ - 1, 0);
      MatchedValue := MatchObject.GetValue(R, JsInteger(0));
      if MatchedValue = JsException then
        Exit(JsException);
      Matched := ToJsString(R, MatchedValue);
      if Matched = nil then
        Exit(JsException);
      PositionValue := MatchObject.GetValue(R, R.Atom(anIndex));
      if PositionValue = JsException then
        Exit(JsException);
      if not ToIntegerOrInfinity(R, PositionValue, Number) then
        Exit(JsException);
      Position := Trunc(Max(Min(Number, Text.Length), 0));
      Captures := nil;
      SetLength(Captures, CaptureCount);
      for Index := 1 to CaptureCount do
      begin
        Capture := MatchObject.GetValue(R, JsInteger(Index));
        if Capture = JsException then
          Exit(JsException);
        if Capture <> JsUndefined then
        begin
          Capture := ToStringValue(R, Capture);
          if Capture = JsException then
            Exit(JsException);
        end;
        Captures[Index - 1] := Capture;
      end;
      NamedGroups := MatchObject.GetValue(R, R.Atom(anGroups));
      if NamedGroups = JsException then
        Exit(JsException);
      if Functional then
      begin
        CallArgs := nil;
        SetLength(CallArgs, CaptureCount + 3);
        CallArgs[0] := JsStringValue(Matched);
        for Index := 0 to CaptureCount - 1 do
          CallArgs[Index + 1] := Captures[Index];
        CallArgs[CaptureCount + 1] := JsNumber(Position);
        CallArgs[CaptureCount + 2] := JsStringValue(Text);
        if NamedGroups <> JsUndefined then
        begin
          SetLength(CallArgs, CaptureCount + 4);
          CallArgs[CaptureCount + 3] := NamedGroups;
        end;
        Outcome := R.Call(ReplaceValue, JsUndefined, @CallArgs[0], Length(CallArgs));
        if Outcome = JsException then
          Exit(JsException);
        Piece := ToJsString(R, Outcome);
        if Piece = nil then
          Exit(JsException);
      end
      else
      begin
        if NamedGroups <> JsUndefined then
        begin
          NamedGroups := ToObject(R, NamedGroups);
          if NamedGroups = JsException then
            Exit(JsException);
        end;
        Piece := GetSubstitution(R, Matched, Text, Position, Captures, NamedGroups, Replacement);
      end;
      if Position >= NextSourcePosition then
      begin
        Accumulated := ConcatStrings(R.Heap, Accumulated, SubString(R.Heap, Text, NextSourcePosition,
          Position - NextSourcePosition));
        Accumulated := ConcatStrings(R.Heap, Accumulated, Piece);
        R.Runtime.PushRoot(JsStringValue(Accumulated));
        NextSourcePosition := Position + Matched.Length;
      end;
    end;
    if NextSourcePosition >= Text.Length then
      Exit(JsStringValue(Accumulated));
    Result := JsStringValue(ConcatStrings(R.Heap, Accumulated, SubString(R.Heap, Text, NextSourcePosition,
      Text.Length - NextSourcePosition)));
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function RegExpSymbolSplit(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsRegExp;
  Text: TJsString;
  Limit: LongWord;
  Created: TJsArray;
  Previous, Position, Finish, Index, Mark: Integer;
  Matcher: TRxMatcher;
  Outcome: TRxOutcome;
  Start, Stop: Integer;
  Unicode: Boolean;
begin
  if not ThisRegExp(R, This, Target) then
    Exit(JsException);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  Limit := High(LongWord);
  if Arg(Args, ArgCount, 1) <> JsUndefined then
    if not ToUint32(R, Args^[1], Limit) then
      Exit(JsException);
  Created := R.NewArray(0);
  Result := JsObjectValue(Created);
  if Limit = 0 then
    Exit;
  Matcher := Target.Matcher;
  Unicode := (Target.FlagBits and (FlagUnicode or FlagUnicodeSets)) <> 0;
  Mark := R.Runtime.PushRoot(Result);
  try
    if Text.Length = 0 then
    begin
      if Matcher.MatchAt(Text, 0) = roNoMatch then
        Created.CreateDataProperty(R, JsInteger(0), JsStringValue(Text));
      Exit;
    end;
    Previous := 0;
    Position := 0;
    while Position < Text.Length do
    begin
      Outcome := Matcher.MatchAt(Text, Position);
      if Outcome = roOutOfMemory then
        Exit(R.ThrowRangeError('Out of memory matching the regular expression'));
      if Outcome = roInterrupted then
      begin
        R.Runtime.Terminating := True;
        Exit(R.ThrowError(ekInternal, 'Script interrupted'));
      end;
      if Outcome = roNoMatch then
      begin
        Position := AdvanceIndex(Text, Position, Unicode);
        Continue;
      end;
      Finish := Matcher.Captures[1];
      if Finish > Text.Length then
        Finish := Text.Length;
      if Finish = Previous then
      begin
        Position := AdvanceIndex(Text, Position, Unicode);
        Continue;
      end;
      Created.CreateDataProperty(R, JsInteger(Created.ArrayLength),
        JsStringValue(SubString(R.Heap, Text, Previous, Position - Previous)));
      if Created.ArrayLength >= Limit then
        Exit;
      for Index := 1 to Target.Program_.GroupCount do
      begin
        Start := Matcher.Captures[Index * 2];
        Stop := Matcher.Captures[Index * 2 + 1];
        if (Start >= 0) and (Stop >= Start) then
          Created.CreateDataProperty(R, JsInteger(Created.ArrayLength),
            JsStringValue(SubString(R.Heap, Text, Start, Stop - Start)))
        else
          Created.CreateDataProperty(R, JsInteger(Created.ArrayLength), JsUndefined);
        if Created.ArrayLength >= Limit then
          Exit;
      end;
      Previous := Finish;
      Position := Finish;
    end;
    Created.CreateDataProperty(R, JsInteger(Created.ArrayLength),
      JsStringValue(SubString(R.Heap, Text, Previous, Text.Length - Previous)));
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function RegExpSymbolMatchAll(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Text, Flags: TJsString;
  Constructor_, Matcher: TJsValue;
  Pair: array[0..1] of TJsValue;
  LastIndex: Int64;
  Iterator: TJsRegExpStringIterator;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype[Symbol.matchAll] called on non-object'));
  Target := JsAsObject(This);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Constructor_ := SpeciesConstructor(R, Target, JsObjectValue(R.Intrinsics[inRegExp]));
  if Constructor_ = JsException then
    Exit(JsException);
  if not FlagsOf(R, Target, Flags) then
    Exit(JsException);
  Pair[0] := This;
  Pair[1] := JsStringValue(Flags);
  Matcher := R.Construct(Constructor_, @Pair[0], 2, Constructor_);
  if Matcher = JsException then
    Exit(JsException);
  if not GetLastIndex(R, Target, LastIndex) then
    Exit(JsException);
  if not SetLastIndex(R, JsAsObject(Matcher), LastIndex) then
    Exit(JsException);
  Iterator := TJsRegExpStringIterator(R.NewObjectOfClass(TJsRegExpStringIterator,
    R.Intrinsics[inRegExpStringIteratorPrototype], ocIterator));
  Iterator.Matcher := Matcher;
  Iterator.Text := Text;
  Iterator.Global := HasFlag(Flags, 'g');
  Iterator.Unicode := HasFlag(Flags, 'u') or HasFlag(Flags, 'v');
  Result := JsObjectValue(Iterator);
end;

function RegExpStringIteratorNext(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Iterator: TJsRegExpStringIterator;
  Outcome, MatchedValue: TJsValue;
  Matched: TJsString;
  LastIndex: Int64;
begin
  if not JsIsObject(This) or not (JsAsObject(This) is TJsRegExpStringIterator) then
    Exit(R.ThrowTypeError('next method called on incompatible receiver'));
  Iterator := TJsRegExpStringIterator(JsAsObject(This));
  if Iterator.Done then
    Exit(CreateIterResult(R, JsUndefined, True));
  Outcome := RegExpExec(R, JsAsObject(Iterator.Matcher), Iterator.Text);
  if Outcome = JsException then
    Exit(JsException);
  if Outcome = JsNull then
  begin
    Iterator.Done := True;
    Exit(CreateIterResult(R, JsUndefined, True));
  end;
  if not Iterator.Global then
  begin
    Iterator.Done := True;
    Exit(CreateIterResult(R, Outcome, False));
  end;
  MatchedValue := GetPropertyByKey(R, Outcome, JsInteger(0));
  if MatchedValue = JsException then
    Exit(JsException);
  Matched := ToJsString(R, MatchedValue);
  if Matched = nil then
    Exit(JsException);
  if Matched.Length = 0 then
  begin
    if not GetLastIndex(R, JsAsObject(Iterator.Matcher), LastIndex) then
      Exit(JsException);
    if not SetLastIndex(R, JsAsObject(Iterator.Matcher), AdvanceIndex(Iterator.Text, LastIndex, Iterator.Unicode)) then
      Exit(JsException);
  end;
  Result := CreateIterResult(R, Outcome, False);
end;

function RegExpSpecies(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
begin
  Result := This;
end;

function InspectRegExp(R: TJsRealm; Target: TJsObject; out Text: string): Boolean;
begin
  Result := Target is TJsRegExp;
  if Result then
    Text := '/' + EscapedSource(R, TJsRegExp(Target).Source) + '/' + FlagsText(TJsRegExp(Target).FlagBits);
end;

procedure InstallRegExp(R: TJsInterpreterRealm);
var
  Prototype: TJsObject;
  Constructor_: TJsNativeFunction;

  procedure Flag(const Name: string; Bit: Integer);
  begin
    DefineGetter(R, Prototype, Name, @RegExpPrototypeFlag, Bit);
  end;

begin
  Prototype := R.Intrinsics[inRegExpPrototype];
  Constructor_ := DefineConstructor(R, R.GlobalObject, 'RegExp', @RegExpConstructor, 2, Prototype);
  R.Intrinsics[inRegExp] := Constructor_;
  Constructor_.DefineAccessor(R, R.Runtime.SymbolValue(wsSpecies),
    JsObjectValue(NewNativeFunction(R, 'get [Symbol.species]', @RegExpSpecies, 0)), JsUndefined, PropertyConfigurable);
  DefineMethod(R, Prototype, 'exec', @RegExpPrototypeExec, 1, $E8EC);
  DefineMethod(R, Prototype, 'test', @RegExpPrototypeTest, 1);
  DefineMethod(R, Prototype, 'toString', @RegExpPrototypeToString, 0);
  DefineMethod(R, Prototype, 'compile', @RegExpPrototypeCompile, 2);
  DefineGetter(R, Prototype, 'source', @RegExpPrototypeSource);
  DefineGetter(R, Prototype, 'flags', @RegExpPrototypeFlags);
  Flag('hasIndices', FlagHasIndices);
  Flag('global', FlagGlobal);
  Flag('ignoreCase', FlagIgnoreCase);
  Flag('multiline', FlagMultiline);
  Flag('dotAll', FlagDotAll);
  Flag('unicode', FlagUnicode);
  Flag('unicodeSets', FlagUnicodeSets);
  Flag('sticky', FlagSticky);
  DefineSymbolMethod(R, Prototype, wsMatch, '[Symbol.match]', @RegExpSymbolMatch, 1);
  DefineSymbolMethod(R, Prototype, wsMatchAll, '[Symbol.matchAll]', @RegExpSymbolMatchAll, 1);
  DefineSymbolMethod(R, Prototype, wsReplace, '[Symbol.replace]', @RegExpSymbolReplace, 2);
  DefineSymbolMethod(R, Prototype, wsSearch, '[Symbol.search]', @RegExpSymbolSearch, 1);
  DefineSymbolMethod(R, Prototype, wsSplit, '[Symbol.split]', @RegExpSymbolSplit, 2);
  DefineMethod(R, R.Intrinsics[inRegExpStringIteratorPrototype], 'next', @RegExpStringIteratorNext, 0);
  R.Intrinsics[inRegExpStringIteratorPrototype].DefineData(R, R.Runtime.SymbolValue(wsToStringTag),
    R.NewString('RegExp String Iterator'), PropertyConfigurable);
  RegisterInspectExtra(@InspectRegExp);
end;

end.
