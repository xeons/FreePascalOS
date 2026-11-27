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
  Js.RegExpCache,
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
  { The flag getters' names, in the order of the flags text. }
  FlagNames: array[0..7] of TJsAtomName = (anHasIndices, anGlobal, anIgnoreCase, anMultiline, anDotAll, anUnicode,
    anUnicodeSets, anSticky);
  FlagMasks: array[0..7] of Integer = (FlagHasIndices, FlagGlobal, FlagIgnoreCase, FlagMultiline, FlagDotAll,
    FlagUnicode, FlagUnicodeSets, FlagSticky);

type
  TJsRegExp = class(TJsObject)
  public
    Source: TJsString;
    FlagBits: Integer;
    Program_: TRxProgram;
    { The program's matcher (shared by the regexps of the program: a
      match runs to its end without calling scripts). }
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
  Program_.Release;
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

{ The program for the pattern and flags: the runtime's cached one, or
  compiled and cached (nil after throwing a SyntaxError). The caller
  owns a reference. }
function ProgramFor(R: TJsRealm; Pattern: TJsString; Bits: Integer): TRxProgram;
const
  { The flags that change the program. }
  CompileFlags = FlagIgnoreCase or FlagMultiline or FlagDotAll or FlagUnicode or FlagUnicodeSets;
var
  Cache: TRxProgramCache;
  Text: UnicodeString;
begin
  if R.Runtime.RegExpPrograms = nil then
    R.Runtime.RegExpPrograms := TRxProgramCache.Create;
  Cache := TRxProgramCache(R.Runtime.RegExpPrograms);
  Pattern.Flatten(R.Heap);
  Result := Cache.Lookup(Pattern, Bits and CompileFlags);
  if Result <> nil then
    Exit;
  Text := StringToUnicode(R.Heap, Pattern);
  try
    Result := CompileRegExp(Text, (Bits and FlagIgnoreCase) <> 0, (Bits and FlagMultiline) <> 0,
      (Bits and FlagDotAll) <> 0, (Bits and (FlagUnicode or FlagUnicodeSets)) <> 0);
  except
    on Error: ERegExpSyntax do
    begin
      R.ThrowError(ekSyntax, Error.Message);
      Exit(nil);
    end;
  end;
  Cache.Insert(Pattern, Text, Bits and CompileFlags, Result);
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
  Compiled := ProgramFor(R, Pattern, Bits);
  if Compiled = nil then
    Exit;
  Target.Program_.Release;
  Target.Program_ := Compiled;
  if Compiled.Matcher = nil then
    Compiled.Matcher := TRxMatcher.Create(Compiled, @R.Runtime.InterruptRequested);
  Target.Matcher := TRxMatcher(Compiled.Matcher);
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

{ The built-in exec up to its match: lastIndex read and updated, the
  legacy statics recorded. JsTrue with the capture positions when it
  matched, else JsNull or JsException. }
function BuiltinMatch(R: TJsRealm; Target: TJsRegExp; Text: TJsString; out Captures: TRxCaptures): TJsValue;
var
  LastIndex: Int64;
  Global, Sticky: Boolean;
  Outcome: TRxOutcome;
begin
  Captures := nil;
  if not GetLastIndex(R, Target, LastIndex) then
    Exit(JsException);
  Global := (Target.FlagBits and FlagGlobal) <> 0;
  Sticky := (Target.FlagBits and FlagSticky) <> 0;
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
  RecordLegacyMatch(R, Text, Captures, Target.Program_.GroupCount);
  if Global or Sticky then
    if not SetLastIndex(R, Target, Captures[1]) then
      Exit(JsException);
  Result := JsTrue;
end;

{ The text of a group of a match: undefined when it did not take part. }
function CaptureValue(R: TJsRealm; Text: TJsString; const Captures: TRxCaptures; Group: Integer): TJsValue;
var
  Start, Finish: Integer;
begin
  Start := Captures[Group * 2];
  Finish := Captures[Group * 2 + 1];
  if (Start >= 0) and (Finish >= Start) then
    Result := JsStringValue(SubStringOf(R, Text, Start, Finish - Start))
  else
    Result := JsUndefined;
end;

{ The groups object of a match from the texts of its groups (Values,
  by group number); nil when the pattern names no group. A name shared
  by groups in different alternatives takes the one that matched. }
function GroupsObject(R: TJsRealm; Program_: TRxProgram; const Values: TJsValueList): TJsObject;
var
  Index: Integer;
  Key, Value: TJsValue;
begin
  if Length(Program_.GroupNames) = 0 then
    Exit(nil);
  Result := R.NewObject(nil);
  for Index := 0 to High(Program_.GroupNames) do
  begin
    Key := JsStringValue(R.Runtime.Atoms.Intern(NewStringFromUnicode(R.Heap, Program_.GroupNames[Index].Name)));
    Value := Values[Program_.GroupNames[Index].Group];
    if (Value = JsUndefined) and (Result.HasProperty(R, Key) > 0) then
      Continue;
    Result.CreateDataProperty(R, Key, Value);
  end;
end;

{ The d flag's indices array of a match. }
function IndicesArray(R: TJsRealm; Program_: TRxProgram; const Captures: TRxCaptures): TJsArray;
var
  Index, Start, Finish: Integer;
  Pair: TJsArray;
  IndexGroups: TJsObject;
begin
  Result := R.NewArray(0);
  for Index := 0 to Program_.GroupCount do
  begin
    Start := Captures[Index * 2];
    Finish := Captures[Index * 2 + 1];
    if (Start >= 0) and (Finish >= Start) then
    begin
      Pair := R.NewArray(0);
      AppendElement(R, Pair, JsInteger(Start));
      AppendElement(R, Pair, JsInteger(Finish));
      AppendElement(R, Result, JsObjectValue(Pair));
    end
    else
      AppendElement(R, Result, JsUndefined);
  end;
  if Length(Program_.GroupNames) > 0 then
  begin
    IndexGroups := R.NewObject(nil);
    for Index := 0 to High(Program_.GroupNames) do
      IndexGroups.CreateDataProperty(R, JsStringValue(R.Runtime.Atoms.Intern(NewStringFromUnicode(R.Heap,
        Program_.GroupNames[Index].Name))), Result.Elements^[Program_.GroupNames[Index].Group]);
    Result.CreateDataProperty(R, R.Atom(anGroups), JsObjectValue(IndexGroups));
  end
  else
    Result.CreateDataProperty(R, R.Atom(anGroups), JsUndefined);
end;

{ The result array of a built-in exec's match: the groups' texts, index,
  input, groups and, with the d flag, indices. }
function MatchArray(R: TJsRealm; Target: TJsRegExp; Text: TJsString; const Captures: TRxCaptures): TJsValue;
var
  Created: TJsArray;
  Groups: TJsObject;
  Values: TJsValueList;
  Index, Mark: Integer;
  Program_: TRxProgram;
begin
  Program_ := Target.Program_;
  Created := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  try
    SetLength(Values, Program_.GroupCount + 1);
    for Index := 0 to Program_.GroupCount do
    begin
      Values[Index] := CaptureValue(R, Text, Captures, Index);
      AppendElement(R, Created, Values[Index]);
    end;
    Created.CreateDataProperty(R, R.Atom(anIndex), JsInteger(Captures[0]));
    Created.CreateDataProperty(R, R.Atom(anInput), JsStringValue(Text));
    Groups := GroupsObject(R, Program_, Values);
    if Groups <> nil then
      Created.CreateDataProperty(R, R.Atom(anGroups), JsObjectValue(Groups))
    else
      Created.CreateDataProperty(R, R.Atom(anGroups), JsUndefined);
    if (Target.FlagBits and FlagHasIndices) <> 0 then
      Created.CreateDataProperty(R, R.Atom(anIndices), JsObjectValue(IndicesArray(R, Program_, Captures)));
    Result := JsObjectValue(Created);
  finally
    R.Runtime.PopRoots(Mark);
  end;
end;

function BuiltinExec(R: TJsRealm; Target: TJsRegExp; Text: TJsString): TJsValue;
var
  Captures: TRxCaptures;
begin
  Result := BuiltinMatch(R, Target, Text, Captures);
  if Result = JsTrue then
    Result := MatchArray(R, Target, Text, Captures);
end;

{ RegExpExec for a caller that only reads the result: when the built-in
  exec runs, JsTrue with the capture positions instead of a result
  array nobody else could see; else the object's own exec's result (an
  object or null), or JsNull or JsException. }
function RegExpExecMatch(R: TJsRealm; Target: TJsObject; Text: TJsString; out Captures: TRxCaptures): TJsValue;
var
  Exec, Argument: TJsValue;
begin
  Captures := nil;
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
  Result := BuiltinMatch(R, TJsRegExp(Target), Text, Captures);
end;

{ RegExpExec: the object's exec if it has its own, else the built-in. }
function RegExpExec(R: TJsRealm; Target: TJsObject; Text: TJsString): TJsValue;
var
  Captures: TRxCaptures;
begin
  Result := RegExpExecMatch(R, Target, Text, Captures);
  if Result = JsTrue then
    Result := MatchArray(R, TJsRegExp(Target), Text, Captures);
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
  Captures: TRxCaptures;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype.test called on non-object'));
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Outcome := RegExpExecMatch(R, JsAsObject(This), Text, Captures);
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
    Value := JsAsObject(This).GetValue(R, R.Atom(FlagNames[Index]));
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

{ Whether Holder's own Key is an accessor whose getter is the built-in
  Callback with Magic. }
function IsBuiltinGetter(R: TJsRealm; Holder: TJsObject; Key: TJsValue; Callback: TJsNativeCallback;
  Magic: Integer): Boolean;
var
  Desc: TJsPropertyDescriptor;
  Getter: TJsObject;
begin
  if (Holder.GetOwnProperty(R, Key, Desc) <= 0) or not JsIsObject(Desc.Getter) then
    Exit(False);
  Getter := JsAsObject(Desc.Getter);
  Result := (Getter is TJsNativeFunction) and (TJsNativeFunction(Getter).Callback = Callback) and
    (TJsNativeFunction(Getter).Magic = Magic);
end;

{ The flags of a regexp that has no own property but lastIndex and
  inherits the built-in flags getters: reading "flags" could run no
  script and gives its own flags. False when anything may differ. }
function IntactFlagBits(R: TJsRealm; Target: TJsObject; out Bits: Integer): Boolean;
var
  Prototype: TJsObject;
  Index: Integer;
begin
  Bits := 0;
  Prototype := R.Intrinsics[inRegExpPrototype];
  if not (Target is TJsRegExp) or (Target.Proto <> Prototype) or (Target.Shape.PropertyCount <> 1) or
    not IsBuiltinGetter(R, Prototype, R.Atom(anFlags), @RegExpPrototypeFlags, 0) then
    Exit(False);
  for Index := 0 to High(FlagNames) do
    if not IsBuiltinGetter(R, Prototype, R.Atom(FlagNames[Index]), @RegExpPrototypeFlag, FlagMasks[Index]) then
      Exit(False);
  Bits := TJsRegExp(Target).FlagBits;
  Result := True;
end;

{ The flags as Get(rx, "flags") gives them, as bits (other letters
  ignored); False after throwing. }
function FlagBitsOf(R: TJsRealm; Target: TJsObject; out Bits: Integer): Boolean;
var
  Text: TJsString;
  Index: Integer;
const
  Letters: array[0..7] of Char = ('d', 'g', 'i', 'm', 's', 'u', 'v', 'y');
begin
  if IntactFlagBits(R, Target, Bits) then
    Exit(True);
  if not FlagsOf(R, Target, Text) then
    Exit(False);
  for Index := 0 to High(Letters) do
    if HasFlag(Text, Letters[Index]) then
      Bits := Bits or FlagMasks[Index];
  Result := True;
end;

{ The matched text of RegExpExecMatch's outcome (a match's captures or a
  result object): nil after throwing. }
function MatchedText(R: TJsRealm; Text: TJsString; Outcome: TJsValue; const Captures: TRxCaptures): TJsString;
var
  MatchedValue: TJsValue;
begin
  if Outcome = JsTrue then
    Exit(SubStringOf(R, Text, Captures[0], Captures[1] - Captures[0]));
  MatchedValue := GetPropertyByKey(R, Outcome, JsInteger(0));
  if MatchedValue = JsException then
    Exit(nil);
  Result := ToJsString(R, MatchedValue);
end;

{ After an empty match of a global regexp: lastIndex past it. }
function SkipEmptyMatch(R: TJsRealm; Target: TJsObject; Text: TJsString; Unicode: Boolean): Boolean;
var
  LastIndex: Int64;
begin
  Result := GetLastIndex(R, Target, LastIndex) and SetLastIndex(R, Target, AdvanceIndex(Text, LastIndex, Unicode));
end;

function RegExpSymbolMatch(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Text, Matched: TJsString;
  Flags: Integer;
  Outcome: TJsValue;
  Created: TJsArray;
  Captures: TRxCaptures;
  Mark: Integer;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype[Symbol.match] called on non-object'));
  Target := JsAsObject(This);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  if not FlagBitsOf(R, Target, Flags) then
    Exit(JsException);
  if (Flags and FlagGlobal) = 0 then
    Exit(RegExpExec(R, Target, Text));
  if not SetLastIndex(R, Target, 0) then
    Exit(JsException);
  Created := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Created));
  R.Runtime.PushRoot(JsStringValue(Text));
  try
    while True do
    begin
      Outcome := RegExpExecMatch(R, Target, Text, Captures);
      if Outcome = JsException then
        Exit(JsException);
      if Outcome = JsNull then
      begin
        if Created.ArrayLength = 0 then
          Exit(JsNull);
        Exit(JsObjectValue(Created));
      end;
      Matched := MatchedText(R, Text, Outcome, Captures);
      if Matched = nil then
        Exit(JsException);
      AppendElement(R, Created, JsStringValue(Matched));
      if Matched.Length = 0 then
        if not SkipEmptyMatch(R, Target, Text, (Flags and (FlagUnicode or FlagUnicodeSets)) <> 0) then
          Exit(JsException);
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
  Captures: TRxCaptures;
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
  Outcome := RegExpExecMatch(R, Target, Text, Captures);
  if Outcome = JsException then
    Exit(JsException);
  if not Target.Put(R, R.Atom(anLastIndex), Previous) then
    Exit(JsException);
  if Outcome = JsNull then
    Exit(JsInteger(-1));
  if Outcome = JsTrue then
    Exit(JsInteger(Captures[0]));
  Result := GetPropertyByKey(R, Outcome, R.Atom(anIndex));
end;

type
  { One result of replace's exec loop: the captures of a built-in
    match (with the program that made it: a replacer may recompile the
    regexp), or nil Captures for a result object (kept in a rooted
    array at the same index). }
  TReplaceMatch = record
    Captures: TRxCaptures;
    Compiled: TRxProgram;
  end;
  TReplaceMatches = array of TReplaceMatch;

  { What GetSubstitution or the replacer is given for one match. }
  TReplaceParts = record
    Matched: TJsString;
    Position: Int64;
    Captures: TJsValueList;
    NamedGroups: TJsValue;
  end;

{ The parts of a built-in match. }
procedure BuiltinMatchParts(R: TJsRealm; Text: TJsString; constref Match: TReplaceMatch; out Parts: TReplaceParts);
var
  Values: TJsValueList;
  Index: Integer;
  Groups: TJsObject;
begin
  Parts.Matched := SubStringOf(R, Text, Match.Captures[0], Match.Captures[1] - Match.Captures[0]);
  Parts.Position := Match.Captures[0];
  Values := nil;
  SetLength(Values, Match.Compiled.GroupCount + 1);
  for Index := 1 to Match.Compiled.GroupCount do
    Values[Index] := CaptureValue(R, Text, Match.Captures, Index);
  Parts.Captures := Copy(Values, 1, Match.Compiled.GroupCount);
  Groups := GroupsObject(R, Match.Compiled, Values);
  if Groups <> nil then
    Parts.NamedGroups := JsObjectValue(Groups)
  else
    Parts.NamedGroups := JsUndefined;
end;

{ The parts of a result object, read as the specification says. }
function ResultObjectParts(R: TJsRealm; Text: TJsString; MatchObject: TJsObject; out Parts: TReplaceParts): Boolean;
var
  Length_: Int64;
  CaptureCount, Index: Integer;
  MatchedValue, PositionValue, Capture: TJsValue;
  Number: Double;
begin
  Result := False;
  Parts.Captures := nil;
  Parts.NamedGroups := JsUndefined;
  Parts.Matched := nil;
  Parts.Position := 0;
  if not LengthOfArrayLike(R, MatchObject, Length_) then
    Exit;
  CaptureCount := Max(Length_ - 1, 0);
  MatchedValue := MatchObject.GetValue(R, JsInteger(0));
  if MatchedValue = JsException then
    Exit;
  Parts.Matched := ToJsString(R, MatchedValue);
  if Parts.Matched = nil then
    Exit;
  PositionValue := MatchObject.GetValue(R, R.Atom(anIndex));
  if PositionValue = JsException then
    Exit;
  if not ToIntegerOrInfinity(R, PositionValue, Number) then
    Exit;
  Parts.Position := Trunc(Max(Min(Number, Text.Length), 0));
  SetLength(Parts.Captures, CaptureCount);
  for Index := 1 to CaptureCount do
  begin
    Capture := MatchObject.GetValue(R, JsInteger(Index));
    if Capture = JsException then
      Exit;
    if Capture <> JsUndefined then
    begin
      Capture := ToStringValue(R, Capture);
      if Capture = JsException then
        Exit;
    end;
    Parts.Captures[Index - 1] := Capture;
  end;
  Parts.NamedGroups := MatchObject.GetValue(R, R.Atom(anGroups));
  Result := Parts.NamedGroups <> JsException;
end;

{ The replacement of one match: the replacer's result or the expanded
  replacement text; nil after throwing. }
function ReplacementOf(R: TJsRealm; Text: TJsString; var Parts: TReplaceParts; ReplaceValue: TJsValue;
  Replacement: TJsString): TJsString;
var
  CallArgs: TJsValueList;
  Index, CaptureCount: Integer;
  Outcome: TJsValue;
begin
  CaptureCount := Length(Parts.Captures);
  if Replacement = nil then
  begin
    CallArgs := nil;
    SetLength(CallArgs, CaptureCount + 3);
    CallArgs[0] := JsStringValue(Parts.Matched);
    for Index := 0 to CaptureCount - 1 do
      CallArgs[Index + 1] := Parts.Captures[Index];
    CallArgs[CaptureCount + 1] := JsNumber(Parts.Position);
    CallArgs[CaptureCount + 2] := JsStringValue(Text);
    if Parts.NamedGroups <> JsUndefined then
    begin
      SetLength(CallArgs, CaptureCount + 4);
      CallArgs[CaptureCount + 3] := Parts.NamedGroups;
    end;
    Outcome := R.Call(ReplaceValue, JsUndefined, @CallArgs[0], Length(CallArgs));
    if Outcome = JsException then
      Exit(nil);
    Exit(ToJsString(R, Outcome));
  end;
  if Parts.NamedGroups <> JsUndefined then
  begin
    Parts.NamedGroups := ToObject(R, Parts.NamedGroups);
    if Parts.NamedGroups = JsException then
      Exit(nil);
  end;
  Result := GetSubstitution(R, Parts.Matched, Text, Parts.Position, Parts.Captures, Parts.NamedGroups, Replacement);
end;

procedure ReleaseMatches(var Matches: TReplaceMatches; Count: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    Matches[Index].Compiled.Release;
end;

function RegExpSymbolReplace(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Text, Replacement, Matched, Piece, Accumulated: TJsString;
  Flags: Integer;
  ReplaceValue, Outcome: TJsValue;
  Global, Unicode: Boolean;
  Results: TJsArray;
  Matches: TReplaceMatches;
  MatchCount, ResultIndex, Mark, AccumulatedRoot: Integer;
  Captures: TRxCaptures;
  NextSourcePosition: Int64;
  Parts: TReplaceParts;
begin
  if not JsIsObject(This) then
    Exit(R.ThrowTypeError('RegExp.prototype[Symbol.replace] called on non-object'));
  Target := JsAsObject(This);
  Text := ToJsString(R, Arg(Args, ArgCount, 0));
  if Text = nil then
    Exit(JsException);
  Text.Flatten(R.Heap);
  ReplaceValue := Arg(Args, ArgCount, 1);
  Replacement := nil;
  if not JsIsCallable(ReplaceValue) then
  begin
    Replacement := ToJsString(R, ReplaceValue);
    if Replacement = nil then
      Exit(JsException);
  end;
  if not FlagBitsOf(R, Target, Flags) then
    Exit(JsException);
  Global := (Flags and FlagGlobal) <> 0;
  Unicode := (Flags and (FlagUnicode or FlagUnicodeSets)) <> 0;
  if Global then
    if not SetLastIndex(R, Target, 0) then
      Exit(JsException);
  Results := R.NewArray(0);
  Mark := R.Runtime.PushRoot(JsObjectValue(Results));
  R.Runtime.PushRoot(JsStringValue(Text));
  if Replacement <> nil then
    R.Runtime.PushRoot(JsStringValue(Replacement));
  AccumulatedRoot := R.Runtime.PushRoot(JsUndefined);
  Matches := nil;
  MatchCount := 0;
  try
    { Every match first, then the replacements (the replacer runs after
      the last exec). }
    while True do
    begin
      Outcome := RegExpExecMatch(R, Target, Text, Captures);
      if Outcome = JsException then
        Exit(JsException);
      if Outcome = JsNull then
        Break;
      if MatchCount >= Length(Matches) then
        SetLength(Matches, MatchCount * 2 + 4);
      Matches[MatchCount].Captures := Captures;
      Matches[MatchCount].Compiled := nil;
      if Outcome = JsTrue then
      begin
        Matches[MatchCount].Compiled := TJsRegExp(Target).Program_;
        Matches[MatchCount].Compiled.AddReference;
        AppendElement(R, Results, JsUndefined);
      end
      else
        AppendElement(R, Results, Outcome);
      Inc(MatchCount);
      if not Global then
        Break;
      Matched := MatchedText(R, Text, Outcome, Captures);
      if Matched = nil then
        Exit(JsException);
      if Matched.Length = 0 then
        if not SkipEmptyMatch(R, Target, Text, Unicode) then
          Exit(JsException);
    end;
    Accumulated := R.Runtime.EmptyString;
    NextSourcePosition := 0;
    for ResultIndex := 0 to MatchCount - 1 do
    begin
      if Matches[ResultIndex].Compiled <> nil then
        BuiltinMatchParts(R, Text, Matches[ResultIndex], Parts)
      else if not ResultObjectParts(R, Text, JsAsObject(Results.Elements^[ResultIndex]), Parts) then
        Exit(JsException);
      Piece := ReplacementOf(R, Text, Parts, ReplaceValue, Replacement);
      if Piece = nil then
        Exit(JsException);
      if Parts.Position >= NextSourcePosition then
      begin
        Accumulated := ConcatStrings(R.Heap, Accumulated, SubString(R.Heap, Text, NextSourcePosition,
          Parts.Position - NextSourcePosition));
        Accumulated := ConcatStrings(R.Heap, Accumulated, Piece);
        R.Runtime.SetRoot(AccumulatedRoot, JsStringValue(Accumulated));
        NextSourcePosition := Parts.Position + Parts.Matched.Length;
      end;
    end;
    if NextSourcePosition >= Text.Length then
      Exit(JsStringValue(Accumulated));
    Result := JsStringValue(ConcatStrings(R.Heap, Accumulated, SubString(R.Heap, Text, NextSourcePosition,
      Text.Length - NextSourcePosition)));
  finally
    ReleaseMatches(Matches, MatchCount);
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
        AppendElement(R, Created, JsStringValue(Text));
      Exit;
    end;
    Previous := 0;
    Position := 0;
    while Position < Text.Length do
    begin
      { The next position from here where the splitter matches (the
        specification tries each in turn). }
      Outcome := Matcher.Search(Text, Position, False);
      if Outcome = roOutOfMemory then
        Exit(R.ThrowRangeError('Out of memory matching the regular expression'));
      if Outcome = roInterrupted then
      begin
        R.Runtime.Terminating := True;
        Exit(R.ThrowError(ekInternal, 'Script interrupted'));
      end;
      if (Outcome = roNoMatch) or (Matcher.Captures[0] >= Text.Length) then
        Break;
      Position := Matcher.Captures[0];
      Finish := Matcher.Captures[1];
      if Finish > Text.Length then
        Finish := Text.Length;
      if Finish = Previous then
      begin
        Position := AdvanceIndex(Text, Position, Unicode);
        Continue;
      end;
      AppendElement(R, Created, JsStringValue(SubStringOf(R, Text, Previous, Position - Previous)));
      if Created.ArrayLength >= Limit then
        Exit;
      for Index := 1 to Target.Program_.GroupCount do
      begin
        AppendElement(R, Created, CaptureValue(R, Text, Matcher.Captures, Index));
        if Created.ArrayLength >= Limit then
          Exit;
      end;
      Previous := Finish;
      Position := Finish;
    end;
    AppendElement(R, Created, JsStringValue(SubStringOf(R, Text, Previous, Text.Length - Previous)));
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
