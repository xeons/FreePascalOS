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
  The interpreter, and the realm that runs code.

  One value stack holds the registers of every frame; its capacity is
  fixed when the realm is made, so pointers into it (the arguments a
  native function is given) stay valid however deep the calls go. The
  frames are records in an array, also fixed in size (MaximumFrames:
  the deepest recursion; deeper calls throw a RangeError).

  Run executes frames until the frame it was entered with returns: a
  call from JavaScript to JavaScript pushes a frame and carries on in
  the same loop (no Pascal recursion); calls from Pascal (natives
  calling back, getters, the embedding API) enter Run again.

  An exception is JsException returned by a helper, the thrown value in
  the runtime. The loop then looks for a handler covering the faulting
  instruction in the frame (the innermost first), restores the
  environment depth the handler expects and jumps to it, or pops the
  frame and tries the caller. A return travelling through finally
  blocks (generator.return()) is a TJsReturnCompletion thrown that only
  finally handlers take. Termination (an interrupt, the memory limit)
  skips every handler.

  Generators and async functions run as frames of their own Run; at a
  yield or await the frame's registers are copied into its suspension
  and Run returns; resuming copies them back and enters Run again.

  Safe points - loop back edges and frame entries - are where the
  collector runs, the interrupt flag is checked and the memory limit
  enforced.
}
unit Js.Interpreter;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$goto on}

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
  Js.BigIntegers,
  Js.Conversions,
  Js.Operations,
  Js.Promises,
  Js.Bytecode;

const
  FrameConstruct = 1;
  FrameBase = 2;

  ResumeNext = 0;
  ResumeThrow = 1;
  ResumeReturn = 2;

  DefaultStackCapacity = 256 * 1024;
  DefaultMaximumFrames = 5000;
  DefaultMaximumRunDepth = 300;

type
  TJsFrame = record
    Code: TJsCode;
    Callee: TJsObject;
    Environment: TJsEnvironment;
    NewTarget: TJsValue;
    Suspension: TJsSuspension;
    Base: Integer;
    PC: Integer;
    ReturnRegister: Integer;
    ArgumentCount: Integer;
    EnvironmentDepth: Integer;
    Flags: Integer;
    SavedTop: Integer;
  end;
  PJsFrame = ^TJsFrame;
  TJsFrameArray = array[0..(MaxInt div SizeOf(TJsFrame)) - 1] of TJsFrame;
  PJsFrameArray = ^TJsFrameArray;

  TJsExitKind = (exReturn, exSuspend);

  { Where console output goes (the host's choice). }
  TJsConsoleWriter = procedure(const Text: string; IsError: Boolean) of object;

  { The iteration state of a for-in loop. }
  TJsForInIterator = class(TJsObject)
  public
    Target: TJsObject;
    Keys: TJsValueList;
    Position: Integer;
    procedure Trace(Tracer: TJsTracer); override;
  end;

  TJsInterpreterRealm = class(TJsRealm)
  private
    FStack: PJsValue;
    FStackCapacity: Integer;
    FStackTop: Integer;
    FFrames: PJsFrameArray;
    FMaximumFrames: Integer;
    FFrameCount: Integer;
    FRunDepth: Integer;
    FExit: TJsExitKind;
    function Run(StartThrowing: Boolean): TJsValue;
    function EnterFrame(Closure: TJsClosure; Base, ArgumentCount: Integer; NewTarget: TJsValue;
      Flags, ReturnRegister: Integer): Boolean;
    function CallClosure(Closure: TJsClosure; This: TJsValue; Args: PJsValue; Count: Integer;
      NewTarget: TJsValue; IsConstruct: Boolean): TJsValue;
    function StartGenerator(Closure: TJsClosure; This: TJsValue; Args: PJsValue; Count: Integer): TJsValue;
    function StartAsync(Closure: TJsClosure; This: TJsValue; Args: PJsValue; Count: Integer): TJsValue;
    procedure SaveFrame(Suspension: TJsSuspension; Frame: PJsFrame; NextPC, SuspendPC, ResumeRegister: Integer);
    function CreateArguments(Closure: TJsClosure; Args: PJsValue; Count: Integer): TJsObject;
    function Safepoint: Boolean;
    function Terminate(const Message: string): TJsValue;
    function FindHandler(Frame: PJsFrame; IsReturnCompletion: Boolean): Integer;
    { Property access with inline caches. }
    function GetNamedSlow(Base, Key: TJsValue; Cache: PJsPropertyCache): TJsValue;
    function SetNamedSlow(Base, Key, Value: TJsValue; Cache: PJsPropertyCache; Strict: Boolean): Boolean;
    function DefineFieldSlow(Target: TJsObject; Key, Value: TJsValue; Cache: PJsPropertyCache): Boolean;
    function GetGlobal(Key: TJsValue; Cache: PJsPropertyCache; ForTypeof: Boolean): TJsValue;
    function SetGlobal(Key, Value: TJsValue; Cache: PJsPropertyCache; Strict: Boolean): Boolean;
    function DeclareGlobalVar(Key, Value: TJsValue; HasValue: Boolean): Boolean;
    function DeclareGlobalLexical(Key: TJsValue; IsConst: Boolean): Boolean;
    function DeleteGlobal(Key: TJsValue): TJsValue;
    { Classes and private names. }
    function MakeClass(Constructor_: TJsValue; Heritage: TJsValue; HasHeritage: Boolean;
      out Prototype: TJsObject): Boolean;
    function FindPrivate(Target: TJsValue; Name: TJsValue; out Holder: TJsObject; out Slot: Integer;
      out Flags: Byte): Boolean;
    function GetPrivate(Target, Name: TJsValue): TJsValue;
    function SetPrivate(Target, Name, Value: TJsValue): Boolean;
    function DefinePrivate(Target, Name, Value, Getter, Setter: TJsValue; IsAccessor: Boolean): Boolean;
    function ForInStart(Value: TJsValue): TJsValue;
    function ForInNext(Iterator: TJsForInIterator; out Key: TJsValue): Integer;
    function SuperCall(Function_, NewTarget: TJsValue; Args: PJsValue; Count: Integer): TJsValue;
    function NotCallable(Value: TJsValue): TJsValue;
  protected
    procedure TraceRealm(Tracer: TJsTracer); override;
  public
    FunctionShape: TJsShape;
    GlobalLexicals: TJsObject;
    GlobalEpoch: LongWord;
    MaximumRunDepth: Integer;
    { Unhandled rejections noted by the tracker. }
    UnhandledRejections: TJsValueList;
    ConsoleWriter: TJsConsoleWriter;
    { The weak collections' state (Js.Builtins.Collections), freed with
      the realm. }
    WeakState: TObject;
    { For console.time: milliseconds now (Js.Platform). }
    ConsoleIndent: Integer;
    constructor Create(ARuntime: TJsRuntime; StackCapacity: Integer = DefaultStackCapacity;
      MaximumFrames: Integer = DefaultMaximumFrames);
    destructor Destroy; override;
    function Call(F, This: TJsValue; Args: PJsValue; Count: Integer): TJsValue; override;
    function Construct(F: TJsValue; Args: PJsValue; Count: Integer; NewTarget: TJsValue): TJsValue; override;
    function NewError(Kind: TJsErrorKind; const Message: string): TJsObject; override;
    { The stack trace text of the frames running now. }
    function StackTraceText: string;
    function NewClosure(Code: TJsCode; Environment: TJsEnvironment): TJsClosure;
    function RunScript(Code: TJsCode): TJsValue;
    { Resumes a generator or async function: the value it yields or
      returns, JsException; LastExitSuspended says which. }
    function ResumeSuspension(Suspension: TJsSuspension; Kind: Integer; Value: TJsValue): TJsValue;
    function LastExitSuspended: Boolean; inline;
    property FrameCount: Integer read FFrameCount;
  end;

function ErrorKindName(Kind: TJsErrorKind): string;

var
  { Called for each async generator made (Js.Generators sets up its
    driver). }
  JsAsyncGeneratorCreated: procedure(R: TJsRealm; Suspension: TJsSuspension) = nil;

implementation

const
  ErrorNames: array[TJsErrorKind] of string = ('Error', 'EvalError', 'RangeError', 'ReferenceError',
    'SyntaxError', 'TypeError', 'URIError', 'AggregateError', 'InternalError');
  ErrorPrototypeIntrinsics: array[TJsErrorKind] of TJsIntrinsic = (inErrorPrototype, inEvalErrorPrototype,
    inRangeErrorPrototype, inReferenceErrorPrototype, inSyntaxErrorPrototype, inTypeErrorPrototype,
    inUriErrorPrototype, inAggregateErrorPrototype, inInternalErrorPrototype);

function ErrorKindName(Kind: TJsErrorKind): string;
begin
  Result := ErrorNames[Kind];
end;

procedure TJsForInIterator.Trace(Tracer: TJsTracer);
begin
  inherited Trace(Tracer);
  Tracer.MarkCell(Target);
  Tracer.MarkValues(@Keys[0], Length(Keys));
end;

function AsyncResume(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue; forward;

procedure TrackRejection(R: TJsRealm; Promise: TJsPromise; Handled: Boolean);
var
  Realm: TJsInterpreterRealm;
  Index, Count: Integer;
begin
  Realm := TJsInterpreterRealm(R);
  Count := Length(Realm.UnhandledRejections);
  if Handled then
  begin
    for Index := 0 to Count - 1 do
      if Realm.UnhandledRejections[Index] = JsObjectValue(Promise) then
      begin
        Realm.UnhandledRejections[Index] := Realm.UnhandledRejections[Count - 1];
        SetLength(Realm.UnhandledRejections, Count - 1);
        Exit;
      end;
    Exit;
  end;
  SetLength(Realm.UnhandledRejections, Count + 1);
  Realm.UnhandledRejections[Count] := JsObjectValue(Promise);
end;

{ TJsInterpreterRealm }

constructor TJsInterpreterRealm.Create(ARuntime: TJsRuntime; StackCapacity: Integer; MaximumFrames: Integer);
begin
  inherited Create(ARuntime);
  FStackCapacity := StackCapacity;
  FStack := GetMem(StackCapacity * SizeOf(TJsValue));
  FMaximumFrames := MaximumFrames;
  FFrames := GetMem(MaximumFrames * SizeOf(TJsFrame));
  MaximumRunDepth := DefaultMaximumRunDepth;
  FunctionShape := ShapeWithProperty(Heap, ARuntime.RootShape, LengthKey, PropertyConfigurable);
  FunctionShape := ShapeWithProperty(Heap, FunctionShape, ARuntime.AtomValue(anName), PropertyConfigurable);
  GlobalLexicals := NewObject(nil);
  JsRejectionTracker := @TrackRejection;
end;

destructor TJsInterpreterRealm.Destroy;
begin
  WeakState.Free;
  FreeMem(FStack);
  FreeMem(FFrames);
  inherited Destroy;
end;

procedure TJsInterpreterRealm.TraceRealm(Tracer: TJsTracer);
var
  Index: Integer;
  Frame: PJsFrame;
begin
  inherited TraceRealm(Tracer);
  Tracer.MarkValues(FStack, FStackTop);
  for Index := 0 to FFrameCount - 1 do
  begin
    Frame := @FFrames^[Index];
    Tracer.MarkCell(Frame^.Code);
    Tracer.MarkCell(Frame^.Callee);
    Tracer.MarkCell(Frame^.Environment);
    Tracer.MarkValue(Frame^.NewTarget);
    Tracer.MarkCell(Frame^.Suspension);
  end;
  Tracer.MarkCell(FunctionShape);
  Tracer.MarkCell(GlobalLexicals);
  Tracer.MarkValues(@UnhandledRejections[0], Length(UnhandledRejections));
end;

function TJsInterpreterRealm.LastExitSuspended: Boolean;
begin
  Result := FExit = exSuspend;
end;

function TJsInterpreterRealm.NewClosure(Code: TJsCode; Environment: TJsEnvironment): TJsClosure;
var
  Prototype: TJsObject;
  Flags: LongWord;
begin
  Flags := Code.Flags;
  if (Flags and CodeGenerator) <> 0 then
  begin
    if (Flags and CodeAsync) <> 0 then
      Prototype := Intrinsics[inAsyncGeneratorFunctionPrototype]
    else
      Prototype := Intrinsics[inGeneratorFunctionPrototype];
  end
  else if (Flags and CodeAsync) <> 0 then
    Prototype := Intrinsics[inAsyncFunctionPrototype]
  else
    Prototype := Intrinsics[inFunctionPrototype];
  Result := TJsClosure.Create;
  Heap.Register(Result, ckObject);
  Result.Shape := FunctionShape;
  Result.Proto := Prototype;
  Result.ObjectClass := ocFunction;
  Result.ObjectFlags := ObjectExtensible or ObjectCallable;
  if (Flags and CodeConstructor) <> 0 then
  begin
    Result.ObjectFlags := Result.ObjectFlags or ObjectConstructor;
    if (Flags and CodeClassConstructor) = 0 then
      Result.ObjectFlags := Result.ObjectFlags or ObjectLazyPrototype;
  end
  else if (Flags and CodeGenerator) <> 0 then
    Result.ObjectFlags := Result.ObjectFlags or ObjectLazyPrototype;
  Result.InlineSlots[0] := JsInteger(Code.Length);
  if Code.Name <> nil then
    Result.InlineSlots[1] := JsStringValue(Code.Name)
  else
    Result.InlineSlots[1] := Runtime.AtomValue(anEmpty);
  Result.Code := Code;
  Result.Environment := Environment;
  Result.FieldInitializer := JsUndefined;
end;

function TJsInterpreterRealm.Terminate(const Message: string): TJsValue;
begin
  Runtime.Terminating := True;
  Result := Throw(JsObjectValue(NewError(ekInternal, Message)));
end;

function TJsInterpreterRealm.Safepoint: Boolean;
begin
  if Runtime.InterruptRequested then
  begin
    Runtime.InterruptRequested := False;
    Terminate('Script interrupted');
    Exit(False);
  end;
  if Heap.ShouldCollect then
  begin
    Heap.Collect;
    if Heap.OverLimit then
    begin
      Terminate('Out of memory');
      Exit(False);
    end;
  end;
  Result := True;
end;

function TJsInterpreterRealm.NotCallable(Value: TJsValue): TJsValue;
begin
  Result := ThrowTypeError(ValueToPascal(Self, Value) + ' is not a function');
end;

{ Errors }

function TJsInterpreterRealm.StackTraceText: string;
var
  Index, Line, Column: Integer;
  Frame: PJsFrame;
  Name, FileName: string;
begin
  Result := '';
  for Index := FFrameCount - 1 downto 0 do
  begin
    Frame := @FFrames^[Index];
    Line := Frame^.Code.LineAt(Frame^.PC, Column);
    Name := '';
    if Frame^.Code.Name <> nil then
      Name := StringToUtf8(Heap, Frame^.Code.Name);
    FileName := '';
    if Frame^.Code.Source <> nil then
      FileName := Frame^.Code.Source.FileName;
    if (Frame^.Code.Flags and CodeScript) <> 0 then
      Result := Result + #10'    at ' + FileName + ':' + IntToStr(Line) + ':' + IntToStr(Column)
    else
    begin
      if Name = '' then
        Name := '<anonymous>';
      Result := Result + #10'    at ' + Name + ' (' + FileName + ':' + IntToStr(Line) + ':' + IntToStr(Column) + ')';
    end;
    if Length(Result) > 4000 then
      Break;
  end;
end;

function TJsInterpreterRealm.NewError(Kind: TJsErrorKind; const Message: string): TJsObject;
var
  Header: string;
begin
  Result := NewObjectOfClass(TJsObject, Intrinsics[ErrorPrototypeIntrinsics[Kind]], ocError);
  if Message <> '' then
    Result.DefineData(Self, Atom(anMessage), NewString(Message), PropertyHidden);
  Header := ErrorNames[Kind];
  if Message <> '' then
    Header := Header + ': ' + Message;
  Result.DefineData(Self, Atom(anStack), NewString(Header + StackTraceText), PropertyHidden);
end;

{ Calls }

function TJsInterpreterRealm.CreateArguments(Closure: TJsClosure; Args: PJsValue; Count: Integer): TJsObject;
var
  Index: Integer;
  Thrower: TJsValue;
begin
  Result := NewObjectOfClass(TJsObject, Intrinsics[inObjectPrototype], ocArguments);
  if Count > 0 then
  begin
    Result.EnsureElementCapacity(Self, Count);
    for Index := 0 to Count - 1 do
      Result.Elements^[Index] := Args[Index];
    Result.ElementCount := Count;
  end;
  Result.DefineData(Self, LengthKey, JsInteger(Count), PropertyHidden);
  Result.DefineData(Self, Runtime.SymbolValue(wsIterator), JsObjectValue(Intrinsics[inArrayValues]), PropertyHidden);
  if (Closure.Code.Flags and CodeStrict) <> 0 then
  begin
    Thrower := JsObjectValue(Intrinsics[inThrowTypeError]);
    Result.DefineAccessor(Self, Atom(anCallee), Thrower, Thrower, 0);
  end
  else
    Result.DefineData(Self, Atom(anCallee), JsObjectValue(Closure), PropertyHidden);
end;

function TJsInterpreterRealm.EnterFrame(Closure: TJsClosure; Base, ArgumentCount: Integer; NewTarget: TJsValue;
  Flags, ReturnRegister: Integer): Boolean;
var
  Code: TJsCode;
  Registers: PJsValue;
  Index, Start, Count: Integer;
  Rest: TJsArray;
  Arguments: TJsObject;
  This: TJsValue;
  Frame: PJsFrame;
begin
  Code := Closure.Code;
  if (FFrameCount >= FMaximumFrames) or (Base + Code.RegisterCount + 8 > FStackCapacity) then
  begin
    ThrowRangeError('Maximum call stack size exceeded');
    Exit(False);
  end;
  Registers := @FStack[Base];
  Rest := nil;
  Arguments := nil;
  if (Code.Flags and (CodeHasRest or CodeNeedsArguments)) <> 0 then
  begin
    if (Code.Flags and CodeHasRest) <> 0 then
    begin
      if ArgumentCount > Code.ParameterCount then
        Rest := NewArrayFrom(@Registers[Code.ParameterCount], ArgumentCount - Code.ParameterCount)
      else
        Rest := NewArray(0);
    end;
    if (Code.Flags and CodeNeedsArguments) <> 0 then
      Arguments := CreateArguments(Closure, Registers, ArgumentCount);
  end;
  Start := ArgumentCount;
  if Start > Code.ParameterCount then
    Start := Code.ParameterCount;
  Count := Code.RegisterCount;
  for Index := Start to Count - 1 do
    Registers[Index] := JsUndefined;
  if Rest <> nil then
    Registers[Code.RestRegister] := JsObjectValue(Rest);
  if Arguments <> nil then
    Registers[Code.ArgumentsRegister] := JsObjectValue(Arguments);
  if (Code.Flags and (CodeStrict or CodeArrow)) = 0 then
  begin
    This := Registers[-1];
    if JsIsNullish(This) then
      Registers[-1] := JsObjectValue(GlobalObject)
    else if not JsIsObject(This) then
      Registers[-1] := ToObject(Self, This);
  end;
  Frame := @FFrames^[FFrameCount];
  Frame^.Code := Code;
  Frame^.Callee := Closure;
  Frame^.Environment := Closure.Environment;
  Frame^.NewTarget := NewTarget;
  Frame^.Suspension := nil;
  Frame^.Base := Base;
  Frame^.PC := 0;
  Frame^.ReturnRegister := ReturnRegister;
  Frame^.ArgumentCount := ArgumentCount;
  Frame^.EnvironmentDepth := 0;
  Frame^.Flags := Flags;
  Frame^.SavedTop := FStackTop;
  FStackTop := Base + Count;
  Inc(FFrameCount);
  Result := True;
end;

function TJsInterpreterRealm.CallClosure(Closure: TJsClosure; This: TJsValue; Args: PJsValue; Count: Integer;
  NewTarget: TJsValue; IsConstruct: Boolean): TJsValue;
var
  Code: TJsCode;
  Base, Index, Flags: Integer;
  Prototype: TJsObject;
begin
  Code := Closure.Code;
  if ((Code.Flags and CodeClassConstructor) <> 0) and not IsConstruct then
    Exit(ThrowTypeError('Class constructor ' + StringToUtf8(Heap, Code.Name) + ' cannot be invoked without ''new'''));
  if (Code.Flags and CodeGenerator) <> 0 then
    Exit(StartGenerator(Closure, This, Args, Count));
  if (Code.Flags and CodeAsync) <> 0 then
    Exit(StartAsync(Closure, This, Args, Count));
  if FRunDepth >= MaximumRunDepth then
    Exit(ThrowRangeError('Maximum call stack size exceeded'));
  Base := FStackTop + 2;
  if Base + Count + 8 > FStackCapacity then
    Exit(ThrowRangeError('Maximum call stack size exceeded'));
  FStack[Base - 2] := JsObjectValue(Closure);
  FStack[Base - 1] := This;
  for Index := 0 to Count - 1 do
    FStack[Base + Index] := Args[Index];
  Flags := FrameBase;
  if IsConstruct then
  begin
    Flags := Flags or FrameConstruct;
    if (Code.Flags and CodeDerivedConstructor) = 0 then
    begin
      { The new object, protected on the stack while the prototype is
        read (a getter could run). }
      FStackTop := Base + Count;
      Prototype := PrototypeFromConstructor(Self, NewTarget, inObjectPrototype);
      FStackTop := Base - 2;
      if Prototype = nil then
        Exit(JsException);
      FStack[Base - 1] := JsObjectValue(NewObject(Prototype));
    end
    else
      FStack[Base - 1] := JsUndefined;
  end;
  if not EnterFrame(Closure, Base, Count, NewTarget, Flags, -1) then
    Exit(JsException);
  Result := Run(False);
end;

function TJsInterpreterRealm.StartGenerator(Closure: TJsClosure; This: TJsValue; Args: PJsValue;
  Count: Integer): TJsValue;
var
  Suspension: TJsSuspension;
  Base, Index: Integer;
  PrototypeValue: TJsValue;
  Prototype: TJsObject;
  Mark: Integer;
begin
  PrototypeValue := Closure.GetValue(Self, PrototypeKey);
  if PrototypeValue = JsException then
    Exit(JsException);
  if JsIsObject(PrototypeValue) then
    Prototype := JsAsObject(PrototypeValue)
  else if (Closure.Code.Flags and CodeAsync) <> 0 then
    Prototype := Intrinsics[inAsyncGeneratorPrototype]
  else
    Prototype := Intrinsics[inGeneratorPrototype];
  if (Closure.Code.Flags and CodeAsync) <> 0 then
    Suspension := TJsSuspension(NewObjectOfClass(TJsSuspension, Prototype, ocAsyncGenerator))
  else
    Suspension := TJsSuspension(NewObjectOfClass(TJsSuspension, Prototype, ocGenerator));
  Suspension.IsAsyncGenerator := (Closure.Code.Flags and CodeAsync) <> 0;
  Suspension.Promise := JsUndefined;
  Suspension.ResolveFunction := JsUndefined;
  Suspension.RejectFunction := JsUndefined;
  Suspension.Queue := JsUndefined;
  Suspension.Callee := JsObjectValue(Closure);
  Suspension.NewTarget := JsUndefined;
  Suspension.ThisValue := JsUndefined;
  Suspension.ResumeRegister := -1;
  Mark := Runtime.PushRoot(JsObjectValue(Suspension));
  try
    if Suspension.IsAsyncGenerator and Assigned(JsAsyncGeneratorCreated) then
      JsAsyncGeneratorCreated(Self, Suspension);
    Base := FStackTop + 2;
    if Base + Count + 8 > FStackCapacity then
      Exit(ThrowRangeError('Maximum call stack size exceeded'));
    FStack[Base - 2] := JsObjectValue(Closure);
    FStack[Base - 1] := This;
    for Index := 0 to Count - 1 do
      FStack[Base + Index] := Args[Index];
    if not EnterFrame(Closure, Base, Count, JsUndefined, FrameBase, -1) then
      Exit(JsException);
    FFrames^[FFrameCount - 1].Suspension := Suspension;
    Result := Run(False);
    if Result = JsException then
      Exit;
    Result := JsObjectValue(Suspension);
  finally
    Runtime.PopRoots(Mark);
  end;
end;

function TJsInterpreterRealm.StartAsync(Closure: TJsClosure; This: TJsValue; Args: PJsValue;
  Count: Integer): TJsValue;
var
  Suspension: TJsSuspension;
  Promise: TJsPromise;
  Base, Index, Mark: Integer;
  Outcome, Reason: TJsValue;
begin
  Promise := NewPromise(Self);
  Suspension := TJsSuspension(NewObjectOfClass(TJsSuspension, nil, ocObject));
  Suspension.Promise := JsObjectValue(Promise);
  Suspension.ResolveFunction := JsUndefined;
  Suspension.RejectFunction := JsUndefined;
  Suspension.Queue := JsUndefined;
  Suspension.Callee := JsObjectValue(Closure);
  Suspension.NewTarget := JsUndefined;
  Suspension.ThisValue := JsUndefined;
  Suspension.ResumeRegister := -1;
  Mark := Runtime.PushRoot(JsObjectValue(Suspension));
  try
    Base := FStackTop + 2;
    if Base + Count + 8 > FStackCapacity then
      Exit(ThrowRangeError('Maximum call stack size exceeded'));
    FStack[Base - 2] := JsObjectValue(Closure);
    FStack[Base - 1] := This;
    for Index := 0 to Count - 1 do
      FStack[Base + Index] := Args[Index];
    if not EnterFrame(Closure, Base, Count, JsUndefined, FrameBase, -1) then
    begin
      Reason := Runtime.TakeException;
      RejectPromise(Self, Promise, Reason);
      Exit(JsObjectValue(Promise));
    end;
    FFrames^[FFrameCount - 1].Suspension := Suspension;
    Suspension.State := ssExecuting;
    Outcome := Run(False);
    if Outcome = JsException then
    begin
      if Runtime.Terminating then
        Exit(JsException);
      Reason := Runtime.TakeException;
      Suspension.State := ssCompleted;
      RejectPromise(Self, Promise, Reason);
    end
    else if FExit = exReturn then
    begin
      Suspension.State := ssCompleted;
      ResolvePromise(Self, Promise, Outcome);
    end;
    Result := JsObjectValue(Promise);
  finally
    Runtime.PopRoots(Mark);
  end;
end;

procedure TJsInterpreterRealm.SaveFrame(Suspension: TJsSuspension; Frame: PJsFrame; NextPC, SuspendPC,
  ResumeRegister: Integer);
var
  Count: Integer;
  Registers: PJsValue;
begin
  Count := Frame^.Code.RegisterCount;
  Registers := @FStack[Frame^.Base];
  if Length(Suspension.Registers) <> Count then
    SetLength(Suspension.Registers, Count);
  if Count > 0 then
    Move(Registers^, Suspension.Registers[0], Count * SizeOf(TJsValue));
  Suspension.Code := Frame^.Code;
  Suspension.Callee := Registers[-2];
  Suspension.ThisValue := Registers[-1];
  Suspension.NewTarget := Frame^.NewTarget;
  Suspension.PC := NextPC;
  Suspension.SuspendPC := SuspendPC;
  Suspension.ResumeRegister := ResumeRegister;
  Suspension.Environment := Frame^.Environment;
  Suspension.EnvironmentDepth := Frame^.EnvironmentDepth;
  Suspension.ArgumentCount := Frame^.ArgumentCount;
end;

function TJsInterpreterRealm.ResumeSuspension(Suspension: TJsSuspension; Kind: Integer; Value: TJsValue): TJsValue;
var
  Base, Count: Integer;
  Frame: PJsFrame;
  Completion: TJsReturnCompletion;
  Throwing: Boolean;
begin
  if FRunDepth >= MaximumRunDepth then
    Exit(ThrowRangeError('Maximum call stack size exceeded'));
  Count := Suspension.Code.RegisterCount;
  Base := FStackTop + 2;
  if (FFrameCount >= FMaximumFrames) or (Base + Count + 8 > FStackCapacity) then
    Exit(ThrowRangeError('Maximum call stack size exceeded'));
  FStack[Base - 2] := Suspension.Callee;
  FStack[Base - 1] := Suspension.ThisValue;
  if Count > 0 then
    Move(Suspension.Registers[0], FStack[Base], Count * SizeOf(TJsValue));
  Frame := @FFrames^[FFrameCount];
  Frame^.Code := Suspension.Code;
  Frame^.Callee := JsAsObject(Suspension.Callee);
  Frame^.Environment := Suspension.Environment;
  Frame^.NewTarget := Suspension.NewTarget;
  Frame^.Suspension := Suspension;
  Frame^.Base := Base;
  Frame^.PC := Suspension.PC;
  Frame^.ReturnRegister := -1;
  Frame^.ArgumentCount := Suspension.ArgumentCount;
  Frame^.EnvironmentDepth := Suspension.EnvironmentDepth;
  Frame^.Flags := FrameBase;
  Frame^.SavedTop := FStackTop;
  FStackTop := Base + Count;
  Inc(FFrameCount);
  Suspension.State := ssExecuting;
  Suspension.Awaiting := False;
  Throwing := False;
  if Suspension.Delegating then
  begin
    Suspension.Delegating := False;
    Suspension.ResumeKind := Kind;
    FStack[Base + Suspension.ResumeRegister] := Value;
    Frame^.PC := Suspension.SuspendPC;
  end
  else
    case Kind of
      ResumeNext:
        if Suspension.ResumeRegister >= 0 then
          FStack[Base + Suspension.ResumeRegister] := Value;
      ResumeThrow:
        begin
          Throw(Value);
          Frame^.PC := Suspension.SuspendPC;
          Throwing := True;
        end;
    else
      Completion := TJsReturnCompletion.Create;
      Heap.Register(Completion, ckOther);
      Completion.Value := Value;
      Throw(JsCellValue(JsObjectBase, Completion));
      Frame^.PC := Suspension.SuspendPC;
      Throwing := True;
    end;
  Result := Run(Throwing);
  if (Result = JsException) or (FExit = exReturn) then
    Suspension.State := ssCompleted;
end;

function TJsInterpreterRealm.Call(F, This: TJsValue; Args: PJsValue; Count: Integer): TJsValue;
var
  Target: TJsObject;
  Native: TJsNativeFunction;
  Bound: TJsBoundFunction;
  Merged: TJsValueList;
  Index, BoundCount: Integer;
begin
  if not JsIsObject(F) then
    Exit(NotCallable(F));
  Target := JsAsObject(F);
  if Target is TJsClosure then
    Exit(CallClosure(TJsClosure(Target), This, Args, Count, JsUndefined, False));
  if Target is TJsNativeFunction then
  begin
    Native := TJsNativeFunction(Target);
    if FRunDepth >= MaximumRunDepth then
      Exit(ThrowRangeError('Maximum call stack size exceeded'));
    Inc(FRunDepth);
    try
      if Assigned(Native.Callback) then
        Result := Native.Callback(Self, This, PJsValueArray(Args), Count, Native, JsUndefined)
      else
        Result := Native.Method(Self, This, PJsValueArray(Args), Count, Native, JsUndefined);
    finally
      Dec(FRunDepth);
    end;
    Exit;
  end;
  if Target is TJsBoundFunction then
  begin
    Bound := TJsBoundFunction(Target);
    BoundCount := Length(Bound.BoundArguments);
    if BoundCount = 0 then
      Exit(Call(Bound.Target, Bound.BoundThis, Args, Count));
    Merged := nil;
    SetLength(Merged, BoundCount + Count);
    for Index := 0 to BoundCount - 1 do
      Merged[Index] := Bound.BoundArguments[Index];
    for Index := 0 to Count - 1 do
      Merged[BoundCount + Index] := Args[Index];
    Exit(Call(Bound.Target, Bound.BoundThis, @Merged[0], Length(Merged)));
  end;
  if Target.IsCallable then
    Exit(Target.CallAsFunction(Self, This, Args, Count));
  Result := NotCallable(F);
end;

function TJsInterpreterRealm.Construct(F: TJsValue; Args: PJsValue; Count: Integer; NewTarget: TJsValue): TJsValue;
var
  Target: TJsObject;
  Native: TJsNativeFunction;
  Bound: TJsBoundFunction;
  Merged: TJsValueList;
  Index, BoundCount: Integer;
begin
  if not JsIsConstructor(F) then
    Exit(ThrowTypeError(ValueToPascal(Self, F) + ' is not a constructor'));
  Target := JsAsObject(F);
  if Target is TJsClosure then
    Exit(CallClosure(TJsClosure(Target), JsUndefined, Args, Count, NewTarget, True));
  if Target is TJsNativeFunction then
  begin
    Native := TJsNativeFunction(Target);
    if FRunDepth >= MaximumRunDepth then
      Exit(ThrowRangeError('Maximum call stack size exceeded'));
    Inc(FRunDepth);
    try
      if Assigned(Native.Callback) then
        Result := Native.Callback(Self, JsUndefined, PJsValueArray(Args), Count, Native, NewTarget)
      else
        Result := Native.Method(Self, JsUndefined, PJsValueArray(Args), Count, Native, NewTarget);
    finally
      Dec(FRunDepth);
    end;
    Exit;
  end;
  if Target is TJsBoundFunction then
  begin
    Bound := TJsBoundFunction(Target);
    if NewTarget = F then
      NewTarget := Bound.Target;
    BoundCount := Length(Bound.BoundArguments);
    Merged := nil;
    SetLength(Merged, BoundCount + Count + 1);
    for Index := 0 to BoundCount - 1 do
      Merged[Index] := Bound.BoundArguments[Index];
    for Index := 0 to Count - 1 do
      Merged[BoundCount + Index] := Args[Index];
    Exit(Construct(Bound.Target, @Merged[0], BoundCount + Count, NewTarget));
  end;
  Result := Target.ConstructAsFunction(Self, Args, Count, NewTarget);
end;

function TJsInterpreterRealm.RunScript(Code: TJsCode): TJsValue;
var
  Script: TJsClosure;
  Mark: Integer;
begin
  Script := NewClosure(Code, nil);
  Mark := Runtime.PushRoot(JsObjectValue(Script));
  try
    Result := CallClosure(Script, JsObjectValue(GlobalObject), nil, 0, JsUndefined, False);
  finally
    Runtime.PopRoots(Mark);
  end;
end;

function TJsInterpreterRealm.SuperCall(Function_, NewTarget: TJsValue; Args: PJsValue; Count: Integer): TJsValue;
var
  Parent: TJsObject;
begin
  if not JsAsObject(Function_).GetPrototype(Self, Parent) then
    Exit(JsException);
  if (Parent = nil) or not JsIsConstructor(JsObjectValue(Parent)) then
    Exit(ThrowTypeError('Super constructor is not a constructor'));
  Result := Construct(JsObjectValue(Parent), Args, Count, NewTarget);
end;

{ Property access }

function TJsInterpreterRealm.GetNamedSlow(Base, Key: TJsValue; Cache: PJsPropertyCache): TJsValue;
var
  Target, Holder: TJsObject;
  Slot: Integer;
  Flags: Byte;
begin
  if JsIsObject(Base) then
  begin
    Target := JsAsObject(Base);
    if ((Target.ObjectFlags and (ObjectExotic or ObjectLazyPrototype)) = 0) and (Key <> LengthKey) then
    begin
      Slot := Target.Shape.Find(Key, Flags);
      if Slot >= 0 then
      begin
        if (Flags and PropertyAccessor) = 0 then
        begin
          Cache^.Shape := Target.Shape;
          Cache^.Generation := Target.Shape.Generation;
          Cache^.Slot := Slot;
          Cache^.Holder := nil;
          Exit(Target.GetSlot(Slot));
        end;
      end
      else if not Target.Shape.IsDictionary then
      begin
        Holder := Target.Proto;
        if (Holder <> nil) and ((Holder.ObjectFlags and (ObjectExotic or ObjectLazyPrototype)) = 0) and
          not Holder.Shape.IsDictionary and (Target.ObjectClass <> ocArray) or
          ((Holder <> nil) and (Target.ObjectClass = ocArray) and not JsIsInteger(Key) and
          ((Holder.ObjectFlags and (ObjectExotic or ObjectLazyPrototype)) = 0) and not Holder.Shape.IsDictionary) then
        begin
          Slot := Holder.Shape.Find(Key, Flags);
          if (Slot >= 0) and ((Flags and PropertyAccessor) = 0) then
          begin
            Cache^.Shape := Target.Shape;
            Cache^.Generation := Target.Shape.Generation;
            Cache^.Slot := Slot;
            Cache^.Holder := Holder;
            Cache^.HolderShape := Holder.Shape;
            Exit(Holder.GetSlot(Slot));
          end;
        end;
      end;
    end;
    Exit(Target.Get(Self, Key, Base));
  end;
  Result := GetPropertyByKey(Self, Base, Key);
end;

function TJsInterpreterRealm.SetNamedSlow(Base, Key, Value: TJsValue; Cache: PJsPropertyCache; Strict: Boolean): Boolean;
var
  Target: TJsObject;
  OldShape, NewShape: TJsShape;
  Slot: Integer;
  Flags: Byte;
begin
  if not JsIsObject(Base) then
    Exit(SetPropertyByKey(Self, Base, Key, Value, Strict));
  Target := JsAsObject(Base);
  OldShape := Target.Shape;
  if not SetPropertyByKey(Self, Base, Key, Value, Strict) then
    Exit(False);
  Result := True;
  if ((Target.ObjectFlags and (ObjectExotic or ObjectLazyPrototype)) <> 0) or (Target.ObjectClass = ocArray) and
    (Key = LengthKey) then
    Exit;
  NewShape := Target.Shape;
  if NewShape = OldShape then
  begin
    Slot := NewShape.Find(Key, Flags);
    if (Slot >= 0) and ((Flags and (PropertyAccessor or PropertyWritable)) = PropertyWritable) then
    begin
      Cache^.Shape := NewShape;
      Cache^.Generation := NewShape.Generation;
      Cache^.Slot := Slot;
      Cache^.NewShape := nil;
    end;
  end
  else if (not NewShape.IsDictionary) and (NewShape.Parent = OldShape) and (NewShape.Key = Key) and
    (NewShape.Flags = PropertyDefault) then
  begin
    Cache^.Shape := OldShape;
    Cache^.Generation := 0;
    Cache^.Slot := NewShape.Slot;
    Cache^.NewShape := NewShape;
    Cache^.Epoch := Runtime.PrototypeEpoch;
  end;
end;

function TJsInterpreterRealm.DefineFieldSlow(Target: TJsObject; Key, Value: TJsValue; Cache: PJsPropertyCache): Boolean;
var
  OldShape, NewShape: TJsShape;
begin
  OldShape := Target.Shape;
  if not Target.CreateDataProperty(Self, Key, Value) then
  begin
    if HasException then
      Exit(False);
    ThrowTypeError('Cannot define property ' + KeyToPascal(Self, Key));
    Exit(False);
  end;
  NewShape := Target.Shape;
  if (not NewShape.IsDictionary) and (NewShape.Parent = OldShape) and (NewShape.Key = Key) and
    ((Target.ObjectFlags and ObjectExotic) = 0) then
  begin
    Cache^.Shape := OldShape;
    Cache^.Slot := NewShape.Slot;
    Cache^.NewShape := NewShape;
  end;
  Result := True;
end;

{ Globals }

function TJsInterpreterRealm.GetGlobal(Key: TJsValue; Cache: PJsPropertyCache; ForTypeof: Boolean): TJsValue;
var
  Slot: Integer;
  Flags: Byte;
  Found: Integer;
begin
  Slot := GlobalLexicals.Shape.Find(Key, Flags);
  if Slot >= 0 then
  begin
    Result := GlobalLexicals.GetSlot(Slot);
    if Result = JsHole then
      Exit(ThrowReferenceError('Cannot access ''' + KeyToPascal(Self, Key) + ''' before initialization'));
    Cache^.Holder := GlobalLexicals;
    Cache^.Shape := GlobalLexicals.Shape;
    Cache^.Generation := GlobalLexicals.Shape.Generation;
    Cache^.Slot := Slot;
    Cache^.Epoch := GlobalEpoch;
    Exit;
  end;
  Slot := GlobalObject.Shape.Find(Key, Flags);
  if (Slot >= 0) and ((Flags and PropertyAccessor) = 0) then
  begin
    Cache^.Holder := GlobalObject;
    Cache^.Shape := GlobalObject.Shape;
    Cache^.Generation := GlobalObject.Shape.Generation;
    Cache^.Slot := Slot;
    Cache^.Epoch := GlobalEpoch;
    Exit(GlobalObject.GetSlot(Slot));
  end;
  Found := GlobalObject.HasProperty(Self, Key);
  if Found < 0 then
    Exit(JsException);
  if Found = 0 then
  begin
    if ForTypeof then
      Exit(JsUndefined);
    Exit(ThrowReferenceError(KeyToPascal(Self, Key) + ' is not defined'));
  end;
  Result := GlobalObject.GetValue(Self, Key);
end;

function TJsInterpreterRealm.SetGlobal(Key, Value: TJsValue; Cache: PJsPropertyCache; Strict: Boolean): Boolean;
var
  Slot, Found: Integer;
  Flags: Byte;
begin
  Slot := GlobalLexicals.Shape.Find(Key, Flags);
  if Slot >= 0 then
  begin
    if GlobalLexicals.GetSlot(Slot) = JsHole then
    begin
      ThrowReferenceError('Cannot access ''' + KeyToPascal(Self, Key) + ''' before initialization');
      Exit(False);
    end;
    if (Flags and PropertyWritable) = 0 then
    begin
      ThrowTypeError('Assignment to constant variable.');
      Exit(False);
    end;
    GlobalLexicals.SetSlot(Slot, Value);
    Cache^.Holder := GlobalLexicals;
    Cache^.Shape := GlobalLexicals.Shape;
    Cache^.Generation := GlobalLexicals.Shape.Generation;
    Cache^.Slot := Slot;
    Cache^.Epoch := GlobalEpoch;
    Exit(True);
  end;
  Slot := GlobalObject.Shape.Find(Key, Flags);
  if (Slot >= 0) and ((Flags and (PropertyAccessor or PropertyWritable)) = PropertyWritable) then
  begin
    GlobalObject.SetSlot(Slot, Value);
    Cache^.Holder := GlobalObject;
    Cache^.Shape := GlobalObject.Shape;
    Cache^.Generation := GlobalObject.Shape.Generation;
    Cache^.Slot := Slot;
    Cache^.Epoch := GlobalEpoch;
    Exit(True);
  end;
  if Strict then
  begin
    Found := GlobalObject.HasProperty(Self, Key);
    if Found < 0 then
      Exit(False);
    if Found = 0 then
    begin
      ThrowReferenceError(KeyToPascal(Self, Key) + ' is not defined');
      Exit(False);
    end;
  end;
  Result := SetPropertyByKey(Self, JsObjectValue(GlobalObject), Key, Value, Strict);
end;

function TJsInterpreterRealm.DeclareGlobalVar(Key, Value: TJsValue; HasValue: Boolean): Boolean;
var
  Flags: Byte;
  Desc: TJsPropertyDescriptor;
  Found: Integer;
begin
  if GlobalLexicals.Shape.Find(Key, Flags) >= 0 then
  begin
    ThrowError(ekSyntax, 'Identifier ''' + KeyToPascal(Self, Key) + ''' has already been declared');
    Exit(False);
  end;
  Found := GlobalObject.GetOwnProperty(Self, Key, Desc);
  if Found < 0 then
    Exit(False);
  if Found = 0 then
  begin
    if HasValue then
      GlobalObject.DefineData(Self, Key, Value, PropertyWritable or PropertyEnumerable)
    else
      GlobalObject.DefineData(Self, Key, JsUndefined, PropertyWritable or PropertyEnumerable);
    Exit(True);
  end;
  if HasValue then
  begin
    if (Desc.Flags and PropertyConfigurable) <> 0 then
      GlobalObject.DefineOwnProperty(Self, Key, DataDescriptor(Value, PropertyWritable or PropertyEnumerable), False)
    else
      GlobalObject.Put(Self, Key, Value);
  end;
  Result := True;
end;

function TJsInterpreterRealm.DeclareGlobalLexical(Key: TJsValue; IsConst: Boolean): Boolean;
var
  Flags: Byte;
  Desc: TJsPropertyDescriptor;
begin
  if (GlobalLexicals.Shape.Find(Key, Flags) >= 0) or ((GlobalObject.GetOwnProperty(Self, Key, Desc) > 0) and
    ((Desc.Flags and PropertyConfigurable) = 0)) then
  begin
    ThrowError(ekSyntax, 'Identifier ''' + KeyToPascal(Self, Key) + ''' has already been declared');
    Exit(False);
  end;
  if IsConst then
    GlobalLexicals.DefineData(Self, Key, JsHole, PropertyEnumerable)
  else
    GlobalLexicals.DefineData(Self, Key, JsHole, PropertyEnumerable or PropertyWritable);
  Inc(GlobalEpoch);
  Result := True;
end;

function TJsInterpreterRealm.DeleteGlobal(Key: TJsValue): TJsValue;
var
  Flags: Byte;
  Outcome: Integer;
begin
  if GlobalLexicals.Shape.Find(Key, Flags) >= 0 then
    Exit(JsFalse);
  Outcome := GlobalObject.DeleteProperty(Self, Key);
  if Outcome < 0 then
    Exit(JsException);
  Result := JsBoolean(Outcome > 0);
end;

{ Classes }

function TJsInterpreterRealm.MakeClass(Constructor_: TJsValue; Heritage: TJsValue; HasHeritage: Boolean;
  out Prototype: TJsObject): Boolean;
var
  ProtoParent, ConstructorParent: TJsObject;
  ParentPrototype: TJsValue;
  Closure: TJsClosure;
begin
  Result := False;
  Prototype := nil;
  ProtoParent := Intrinsics[inObjectPrototype];
  ConstructorParent := Intrinsics[inFunctionPrototype];
  if HasHeritage then
  begin
    if Heritage = JsNull then
      ProtoParent := nil
    else
    begin
      if not JsIsConstructor(Heritage) then
      begin
        ThrowTypeError('Class extends value ' + ValueToPascal(Self, Heritage) + ' is not a constructor or null');
        Exit;
      end;
      ParentPrototype := JsAsObject(Heritage).GetValue(Self, PrototypeKey);
      if ParentPrototype = JsException then
        Exit;
      if ParentPrototype = JsNull then
        ProtoParent := nil
      else if JsIsObject(ParentPrototype) then
        ProtoParent := JsAsObject(ParentPrototype)
      else
      begin
        ThrowTypeError('Class extends value does not have valid prototype property');
        Exit;
      end;
      ConstructorParent := JsAsObject(Heritage);
    end;
  end;
  Prototype := NewObject(ProtoParent);
  if ProtoParent <> nil then
    NoteIsPrototype(ProtoParent);
  NoteIsPrototype(ConstructorParent);
  Closure := TJsClosure(JsAsObject(Constructor_));
  Closure.Proto := ConstructorParent;
  Closure.ObjectFlags := (Closure.ObjectFlags or ObjectConstructor) and not ObjectLazyPrototype;
  Closure.DefineData(Self, PrototypeKey, JsObjectValue(Prototype), 0);
  Prototype.DefineData(Self, ConstructorKey, Constructor_, PropertyHidden);
  Closure.HomeObject := Prototype;
  NoteIsPrototype(Prototype);
  Result := True;
end;

function TJsInterpreterRealm.FindPrivate(Target: TJsValue; Name: TJsValue; out Holder: TJsObject; out Slot: Integer;
  out Flags: Byte): Boolean;
begin
  Holder := nil;
  Slot := -1;
  Flags := 0;
  if not JsIsObject(Target) then
    Exit(False);
  Holder := JsAsObject(Target);
  Slot := Holder.Shape.Find(Name, Flags);
  Result := Slot >= 0;
end;

function PrivateDescription(R: TJsRealm; Name: TJsValue): string;
begin
  if JsAsSymbol(Name).Description <> nil then
    Result := StringToUtf8(R.Heap, JsAsSymbol(Name).Description)
  else
    Result := '#<private>';
end;

function TJsInterpreterRealm.GetPrivate(Target, Name: TJsValue): TJsValue;
var
  Holder: TJsObject;
  Slot: Integer;
  Flags: Byte;
  Pair: TJsAccessorPair;
begin
  if not FindPrivate(Target, Name, Holder, Slot, Flags) then
    Exit(ThrowTypeError('Cannot read private member ' + PrivateDescription(Self, Name) +
      ' from an object whose class did not declare it'));
  if (Flags and PropertyAccessor) = 0 then
    Exit(Holder.GetSlot(Slot));
  Pair := TJsAccessorPair(JsAsCell(Holder.GetSlot(Slot)));
  if Pair.Getter = JsUndefined then
    Exit(ThrowTypeError('''' + PrivateDescription(Self, Name) + ''' was defined without a getter'));
  Result := Call(Pair.Getter, Target, nil, 0);
end;

function TJsInterpreterRealm.SetPrivate(Target, Name, Value: TJsValue): Boolean;
var
  Holder: TJsObject;
  Slot: Integer;
  Flags: Byte;
  Pair: TJsAccessorPair;
begin
  Result := False;
  if not FindPrivate(Target, Name, Holder, Slot, Flags) then
  begin
    ThrowTypeError('Cannot write private member ' + PrivateDescription(Self, Name) +
      ' to an object whose class did not declare it');
    Exit;
  end;
  if (Flags and PropertyAccessor) = 0 then
  begin
    if (Flags and PropertyWritable) = 0 then
    begin
      ThrowTypeError('Private method ' + PrivateDescription(Self, Name) + ' is not writable');
      Exit;
    end;
    Holder.SetSlot(Slot, Value);
    Exit(True);
  end;
  Pair := TJsAccessorPair(JsAsCell(Holder.GetSlot(Slot)));
  if Pair.Setter = JsUndefined then
  begin
    ThrowTypeError('''' + PrivateDescription(Self, Name) + ''' was defined without a setter');
    Exit;
  end;
  Result := Call(Pair.Setter, Target, @Value, 1) <> JsException;
end;

function TJsInterpreterRealm.DefinePrivate(Target, Name, Value, Getter, Setter: TJsValue;
  IsAccessor: Boolean): Boolean;
var
  Holder: TJsObject;
  Slot: Integer;
  Flags: Byte;
  Pair: TJsAccessorPair;
begin
  Result := False;
  if not JsIsObject(Target) then
  begin
    ThrowTypeError('Cannot define a private member on a non-object');
    Exit;
  end;
  if FindPrivate(Target, Name, Holder, Slot, Flags) then
  begin
    if IsAccessor and ((Flags and PropertyAccessor) <> 0) then
    begin
      Pair := TJsAccessorPair(JsAsCell(Holder.GetSlot(Slot)));
      if Getter <> JsUndefined then
        Pair.Getter := Getter;
      if Setter <> JsUndefined then
        Pair.Setter := Setter;
      Exit(True);
    end;
    ThrowTypeError('Cannot initialize ' + PrivateDescription(Self, Name) + ' twice on the same object');
    Exit;
  end;
  Holder := JsAsObject(Target);
  if IsAccessor then
    Holder.DefineAccessor(Self, Name, Getter, Setter, 0)
  else
    Holder.DefineData(Self, Name, Value, PropertyWritable);
  Result := True;
end;

{ for-in }

function TJsInterpreterRealm.ForInStart(Value: TJsValue): TJsValue;
var
  Iterator: TJsForInIterator;
  Target, Walk: TJsObject;
  Own: TJsValueList;
  Seen: TJsValueList;
  Index, Position, Count, SeenCount: Integer;
  Key: TJsValue;
  Desc: TJsPropertyDescriptor;
  Duplicate: Boolean;
  Found: Integer;
begin
  Iterator := TJsForInIterator(NewObjectOfClass(TJsForInIterator, nil, ocForIn));
  Result := JsObjectValue(Iterator);
  if JsIsNullish(Value) then
    Exit;
  Value := ToObject(Self, Value);
  if Value = JsException then
    Exit(JsException);
  Target := JsAsObject(Value);
  Iterator.Target := Target;
  Count := 0;
  Seen := nil;
  SeenCount := 0;
  Walk := Target;
  while Walk <> nil do
  begin
    if not Walk.OwnPropertyKeys(Self, KeysStrings, Own) then
      Exit(JsException);
    for Index := 0 to High(Own) do
    begin
      Key := Own[Index];
      Duplicate := False;
      if Walk <> Target then
        for Position := 0 to SeenCount - 1 do
          if Seen[Position] = Key then
          begin
            Duplicate := True;
            Break;
          end;
      if Duplicate then
        Continue;
      if SeenCount >= Length(Seen) then
        SetLength(Seen, Length(Seen) * 2 + 16);
      Seen[SeenCount] := Key;
      Inc(SeenCount);
      Found := Walk.GetOwnProperty(Self, Key, Desc);
      if Found < 0 then
        Exit(JsException);
      if (Found > 0) and ((Desc.Flags and PropertyEnumerable) <> 0) then
      begin
        if Count >= Length(Iterator.Keys) then
          SetLength(Iterator.Keys, Length(Iterator.Keys) * 2 + 8);
        Iterator.Keys[Count] := Key;
        Inc(Count);
      end;
    end;
    if not Walk.GetPrototype(Self, Walk) then
      Exit(JsException);
  end;
  SetLength(Iterator.Keys, Count);
end;

function TJsInterpreterRealm.ForInNext(Iterator: TJsForInIterator; out Key: TJsValue): Integer;
var
  Found: Integer;
begin
  Key := JsUndefined;
  while Iterator.Position < Length(Iterator.Keys) do
  begin
    Key := Iterator.Keys[Iterator.Position];
    Inc(Iterator.Position);
    { Deleted while iterating: skipped. }
    Found := Iterator.Target.HasProperty(Self, Key);
    if Found < 0 then
      Exit(-1);
    if Found > 0 then
    begin
      Key := KeyToStringValue(Self, Key);
      Exit(1);
    end;
  end;
  Result := 0;
end;

function TJsInterpreterRealm.FindHandler(Frame: PJsFrame; IsReturnCompletion: Boolean): Integer;
var
  Index, PC: Integer;
  Code: TJsCode;
begin
  Code := Frame^.Code;
  PC := Frame^.PC;
  for Index := 0 to High(Code.Handlers) do
    if (PC >= Code.Handlers[Index].StartPC) and (PC < Code.Handlers[Index].EndPC) and
      (Code.Handlers[Index].IsFinally or not IsReturnCompletion) then
      Exit(Index);
  Result := -1;
end;

function AsyncResume(R: TJsRealm; const This: TJsValue; Args: PJsValueArray; ArgCount: Integer;
  Callee: TJsNativeFunction; const NewTarget: TJsValue): TJsValue;
var
  Realm: TJsInterpreterRealm;
  Suspension: TJsSuspension;
  Outcome, Reason: TJsValue;
  Promise: TJsPromise;
begin
  Realm := TJsInterpreterRealm(R);
  Suspension := TJsSuspension(JsAsObject(Callee.Data));
  Result := JsUndefined;
  if Suspension.IsAsyncGenerator then
  begin
    { Async generators resume through their own driver. }
    Outcome := Realm.Call(Callee.Data2, JsObjectValue(Suspension), PJsValue(Args), ArgCount);
    Exit(Outcome);
  end;
  Outcome := Realm.ResumeSuspension(Suspension, Callee.Magic, Arg(Args, ArgCount, 0));
  Promise := TJsPromise(JsAsObject(Suspension.Promise));
  if Outcome = JsException then
  begin
    if R.Runtime.Terminating then
      Exit(JsException);
    Reason := R.Runtime.TakeException;
    RejectPromise(R, Promise, Reason);
  end
  else if not Realm.LastExitSuspended then
    ResolvePromise(R, Promise, Outcome);
end;

{ The loop }

function TJsInterpreterRealm.Run(StartThrowing: Boolean): TJsValue;
var
  FrameIndex, EntryIndex, PC, Handler, Index, Count: Integer;
  Frame: PJsFrame;
  CodeObject: TJsCode;
  Code: PLongInt;
  Regs: PJsValue;
  Constants: PJsValue;
  Op: TJsOpcode;
  A, B, Value, Key, Outcome, Callee: TJsValue;
  Target: TJsObject;
  Cache: PJsPropertyCache;
  Environment: TJsEnvironment;
  X, Y: LongInt;
  Wide: Int64;
  DA, DB: Double;
  Closure: TJsClosure;
  Native: TJsNativeFunction;
  Comparison: Integer;
  Equal: Boolean;
  Flags: Byte;
  Text: TJsString;
  Suspension: TJsSuspension;
  Prototype: TJsObject;
  Completion: TJsReturnCompletion;
  Iterator: TJsIteratorRecord;
  List: TJsValueList;
  ArrayValue: TJsArray;
  ReturnValue: TJsValue;
  Promise: TJsPromise;
  OnFulfilled, OnRejected: TJsNativeFunction;
  IsReturnCompletion: Boolean;
  Slot: Integer;
  PrivateName: TJsSymbol;
  TypeofCache: TJsPropertyCache;
  Descriptor: TJsPropertyDescriptor;
label
  ReloadFrame, DispatchLoop, Unwind, DoReturn, Finished;
begin
  Inc(FRunDepth);
  EntryIndex := FFrameCount - 1;
  FrameIndex := EntryIndex;
  Result := JsUndefined;
  if StartThrowing then
    goto Unwind;
  if not Safepoint then
    goto Unwind;
ReloadFrame:
  Frame := @FFrames^[FrameIndex];
  CodeObject := Frame^.Code;
  Code := @CodeObject.Instructions[0];
  Regs := @FStack[Frame^.Base];
  Constants := @CodeObject.Constants[0];
  PC := Frame^.PC;
DispatchLoop:
  while True do
  begin
    Frame^.PC := PC;
    Op := TJsOpcode(Code[PC]);
    case Op of
      opNop:
        Inc(PC);
      opLoadUndefined:
        begin
          Regs[Code[PC + 1]] := JsUndefined;
          Inc(PC, 2);
        end;
      opLoadNull:
        begin
          Regs[Code[PC + 1]] := JsNull;
          Inc(PC, 2);
        end;
      opLoadTrue:
        begin
          Regs[Code[PC + 1]] := JsTrue;
          Inc(PC, 2);
        end;
      opLoadFalse:
        begin
          Regs[Code[PC + 1]] := JsFalse;
          Inc(PC, 2);
        end;
      opLoadHole:
        begin
          Regs[Code[PC + 1]] := JsHole;
          Inc(PC, 2);
        end;
      opLoadInteger:
        begin
          Regs[Code[PC + 1]] := JsInteger(Code[PC + 2]);
          Inc(PC, 3);
        end;
      opLoadConstant:
        begin
          Regs[Code[PC + 1]] := Constants[Code[PC + 2]];
          Inc(PC, 3);
        end;
      opMove:
        begin
          Regs[Code[PC + 1]] := Regs[Code[PC + 2]];
          Inc(PC, 3);
        end;
      opGetEnvironment, opGetEnvironmentChecked:
        begin
          Environment := Frame^.Environment;
          for Index := 1 to Code[PC + 2] do
            Environment := Environment.Parent;
          Value := Environment.Slots^[Code[PC + 3]];
          if (Op = opGetEnvironmentChecked) and (Value = JsHole) then
          begin
            ThrowReferenceError('Cannot access ''' + ValueToPascal(Self, Constants[Code[PC + 4]]) +
              ''' before initialization');
            goto Unwind;
          end;
          Regs[Code[PC + 1]] := Value;
          if Op = opGetEnvironment then
            Inc(PC, 4)
          else
            Inc(PC, 5);
        end;
      opSetEnvironment, opSetEnvironmentChecked:
        begin
          Environment := Frame^.Environment;
          for Index := 1 to Code[PC + 1] do
            Environment := Environment.Parent;
          if (Op = opSetEnvironmentChecked) and (Environment.Slots^[Code[PC + 2]] = JsHole) then
          begin
            ThrowReferenceError('Cannot access ''' + ValueToPascal(Self, Constants[Code[PC + 4]]) +
              ''' before initialization');
            goto Unwind;
          end;
          Environment.Slots^[Code[PC + 2]] := Regs[Code[PC + 3]];
          if Op = opSetEnvironment then
            Inc(PC, 4)
          else
            Inc(PC, 5);
        end;
      opCheckInitialized:
        begin
          if Regs[Code[PC + 1]] = JsHole then
          begin
            ThrowReferenceError('Cannot access ''' + ValueToPascal(Self, Constants[Code[PC + 2]]) +
              ''' before initialization');
            goto Unwind;
          end;
          Inc(PC, 3);
        end;
      opGetGlobal:
        begin
          Cache := @CodeObject.Caches[Code[PC + 3]];
          Target := Cache^.Holder;
          if (Target <> nil) and (Target.Shape = Cache^.Shape) and (Target.Shape.Generation = Cache^.Generation) and
            (Cache^.Epoch = GlobalEpoch) then
          begin
            Value := Target.GetSlot(Cache^.Slot);
            if Value = JsHole then
            begin
              ThrowReferenceError('Cannot access ''' + ValueToPascal(Self, Constants[Code[PC + 2]]) +
                ''' before initialization');
              goto Unwind;
            end;
          end
          else
          begin
            Value := GetGlobal(Constants[Code[PC + 2]], Cache, False);
            if Value = JsException then
              goto Unwind;
          end;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opTypeofGlobal:
        begin
          TypeofCache := Default(TJsPropertyCache);
          Value := GetGlobal(Constants[Code[PC + 2]], @TypeofCache, True);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := TypeofValue(Self, Value);
          Inc(PC, 3);
        end;
      opSetGlobal:
        begin
          Cache := @CodeObject.Caches[Code[PC + 3]];
          Target := Cache^.Holder;
          { Filled only for writable data bindings by SetGlobal. }
          if (Target <> nil) and (Target.Shape = Cache^.Shape) and (Target.Shape.Generation = Cache^.Generation) and
            (Cache^.Epoch = GlobalEpoch) and (Target.GetSlot(Cache^.Slot) <> JsHole) then
          begin
            Target.SetSlot(Cache^.Slot, Regs[Code[PC + 1]]);
            Inc(PC, 5);
            Continue;
          end;
          if not SetGlobal(Constants[Code[PC + 2]], Regs[Code[PC + 1]], Cache, Code[PC + 4] <> 0) then
            goto Unwind;
          Inc(PC, 5);
        end;
      opDeclareGlobalVar:
        begin
          if Code[PC + 2] >= 0 then
            Equal := DeclareGlobalVar(Constants[Code[PC + 1]], Regs[Code[PC + 2]], True)
          else
            Equal := DeclareGlobalVar(Constants[Code[PC + 1]], JsUndefined, False);
          if not Equal then
            goto Unwind;
          Inc(PC, 3);
        end;
      opDeclareGlobalLexical:
        begin
          if not DeclareGlobalLexical(Constants[Code[PC + 1]], Code[PC + 2] <> 0) then
            goto Unwind;
          Inc(PC, 3);
        end;
      opInitializeGlobalLexical:
        begin
          Slot := GlobalLexicals.Shape.Find(Constants[Code[PC + 1]], Flags);
          if Slot >= 0 then
            GlobalLexicals.SetSlot(Slot, Regs[Code[PC + 2]]);
          Inc(PC, 3);
        end;
      opDeleteGlobal:
        begin
          Value := DeleteGlobal(Constants[Code[PC + 2]]);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 3);
        end;
      opPushScope:
        begin
          Frame^.Environment := NewEnvironment(Heap, Frame^.Environment, Code[PC + 1]);
          Inc(Frame^.EnvironmentDepth);
          Inc(PC, 2);
        end;
      opPopScope:
        begin
          Frame^.Environment := Frame^.Environment.Parent;
          Dec(Frame^.EnvironmentDepth);
          Inc(PC);
        end;
      opCopyScope:
        begin
          Environment := Frame^.Environment;
          Frame^.Environment := NewEnvironment(Heap, Environment.Parent, Environment.Count);
          if Environment.Count > 0 then
            Move(Environment.Slots^[0], Frame^.Environment.Slots^[0], Environment.Count * SizeOf(TJsValue));
          Inc(PC);
        end;
      opThrowConstAssign:
        begin
          ThrowTypeError('Assignment to constant variable.');
          goto Unwind;
        end;
      opThrowReference:
        begin
          ThrowReferenceError(ValueToPascal(Self, Constants[Code[PC + 1]]));
          goto Unwind;
        end;
      opClosure:
        begin
          Regs[Code[PC + 1]] := JsObjectValue(NewClosure(CodeObject.Functions[Code[PC + 2]], Frame^.Environment));
          Inc(PC, 3);
        end;
      opLoadHome:
        begin
          Target := Frame^.Callee;
          if (Target is TJsClosure) and (TJsClosure(Target).HomeObject <> nil) then
            Regs[Code[PC + 1]] := JsObjectValue(TJsClosure(Target).HomeObject)
          else
            Regs[Code[PC + 1]] := JsUndefined;
          Inc(PC, 2);
        end;
      opLoadNewTarget:
        begin
          Regs[Code[PC + 1]] := Frame^.NewTarget;
          Inc(PC, 2);
        end;
      opLoadCallee:
        begin
          Regs[Code[PC + 1]] := Regs[-2];
          Inc(PC, 2);
        end;
      opNewObject:
        begin
          Regs[Code[PC + 1]] := JsObjectValue(NewPlainObject);
          Inc(PC, 2);
        end;
      opNewArray:
        begin
          ArrayValue := NewArray(0);
          if Code[PC + 2] > 0 then
            ArrayValue.EnsureElementCapacity(Self, Code[PC + 2]);
          Regs[Code[PC + 1]] := JsObjectValue(ArrayValue);
          Inc(PC, 3);
        end;
      opGetNamed:
        begin
          A := Regs[Code[PC + 2]];
          Cache := @CodeObject.Caches[Code[PC + 4]];
          if JsIsObject(A) then
          begin
            Target := JsAsObject(A);
            if (Target.Shape = Cache^.Shape) and (Target.Shape.Generation = Cache^.Generation) then
            begin
              if Cache^.Holder = nil then
              begin
                Regs[Code[PC + 1]] := Target.GetSlot(Cache^.Slot);
                Inc(PC, 5);
                Continue;
              end;
              if (Target.Proto = Cache^.Holder) and (Cache^.Holder.Shape = Cache^.HolderShape) then
              begin
                Regs[Code[PC + 1]] := Cache^.Holder.GetSlot(Cache^.Slot);
                Inc(PC, 5);
                Continue;
              end;
            end;
          end;
          Value := GetNamedSlow(A, Constants[Code[PC + 3]], Cache);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 5);
        end;
      opGetLength:
        begin
          A := Regs[Code[PC + 2]];
          if JsIsObject(A) and (JsAsObject(A).ObjectClass = ocArray) then
            Regs[Code[PC + 1]] := JsNumber(TJsArray(JsAsObject(A)).ArrayLength)
          else if JsIsString(A) then
            Regs[Code[PC + 1]] := JsInteger(JsAsString(A).Length)
          else
          begin
            Value := GetPropertyByKey(Self, A, LengthKey);
            if Value = JsException then
              goto Unwind;
            Regs[Code[PC + 1]] := Value;
          end;
          Inc(PC, 4);
        end;
      opSetNamed:
        begin
          A := Regs[Code[PC + 1]];
          Cache := @CodeObject.Caches[Code[PC + 4]];
          if JsIsObject(A) then
          begin
            Target := JsAsObject(A);
            if Target.Shape = Cache^.Shape then
            begin
              if Cache^.NewShape = nil then
              begin
                if Target.Shape.Generation = Cache^.Generation then
                begin
                  Target.SetSlot(Cache^.Slot, Regs[Code[PC + 3]]);
                  Inc(PC, 5);
                  Continue;
                end;
              end
              else if (Cache^.Epoch = Runtime.PrototypeEpoch) and ((Target.ObjectFlags and ObjectExtensible) <> 0) then
              begin
                Target.EnsureSlotCapacity(Self, Cache^.Slot + 1);
                Target.Shape := Cache^.NewShape;
                Target.SetSlot(Cache^.Slot, Regs[Code[PC + 3]]);
                Inc(PC, 5);
                Continue;
              end;
            end;
          end;
          if not SetNamedSlow(A, Constants[Code[PC + 2]], Regs[Code[PC + 3]], Cache,
            (CodeObject.Flags and CodeStrict) <> 0) then
            goto Unwind;
          Inc(PC, 5);
        end;
      opGetIndex:
        begin
          A := Regs[Code[PC + 2]];
          Key := Regs[Code[PC + 3]];
          if JsIsInteger(Key) and JsIsObject(A) then
          begin
            Target := JsAsObject(A);
            X := JsAsInteger(Key);
            if (X >= 0) and (X < Target.ElementCount) and ((Target.ObjectFlags and ObjectExotic) = 0) then
            begin
              Value := Target.Elements^[X];
              if Value <> JsHole then
              begin
                Regs[Code[PC + 1]] := Value;
                Inc(PC, 4);
                Continue;
              end;
            end;
          end
          else if JsIsInteger(Key) and JsIsString(A) then
          begin
            Text := JsAsString(A);
            X := JsAsInteger(Key);
            if (X >= 0) and (X < Text.Length) then
            begin
              Text.Flatten(Heap);
              Regs[Code[PC + 1]] := JsStringValue(Runtime.CharacterString(Text.CharAt(X)));
              Inc(PC, 4);
              Continue;
            end;
          end;
          Value := GetProperty(Self, A, Key);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opSetIndex:
        begin
          A := Regs[Code[PC + 1]];
          Key := Regs[Code[PC + 2]];
          if JsIsInteger(Key) and JsIsObject(A) then
          begin
            Target := JsAsObject(A);
            X := JsAsInteger(Key);
            if (X >= 0) and ((Target.ObjectFlags and (ObjectExotic or ObjectElementsFrozen)) = 0) then
            begin
              if (X < Target.ElementCount) and (Target.Elements^[X] <> JsHole) then
              begin
                Target.Elements^[X] := Regs[Code[PC + 3]];
                Inc(PC, 4);
                Continue;
              end;
            end;
          end;
          if not SetProperty(Self, A, Key, Regs[Code[PC + 3]], (CodeObject.Flags and CodeStrict) <> 0) then
            goto Unwind;
          Inc(PC, 4);
        end;
      opDeleteNamed, opDeleteIndex:
        begin
          if Op = opDeleteNamed then
            Key := Constants[Code[PC + 3]]
          else
            Key := Regs[Code[PC + 3]];
          Value := DeleteProperty(Self, Regs[Code[PC + 2]], Key, (CodeObject.Flags and CodeStrict) <> 0);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opDefineField:
        begin
          Target := JsAsObject(Regs[Code[PC + 1]]);
          Cache := @CodeObject.Caches[Code[PC + 4]];
          if (Target.Shape = Cache^.Shape) and (Cache^.NewShape <> nil) and
            ((Target.ObjectFlags and ObjectExtensible) <> 0) then
          begin
            Target.EnsureSlotCapacity(Self, Cache^.Slot + 1);
            Target.Shape := Cache^.NewShape;
            Target.SetSlot(Cache^.Slot, Regs[Code[PC + 3]]);
          end
          else if not DefineFieldSlow(Target, Constants[Code[PC + 2]], Regs[Code[PC + 3]], Cache) then
            goto Unwind;
          Inc(PC, 5);
        end;
      opDefineIndex:
        begin
          Key := Regs[Code[PC + 2]];
          if not (JsIsInteger(Key) or JsIsSymbol(Key) or (JsIsString(Key) and JsAsString(Key).IsAtom)) then
          begin
            Key := ToPropertyKey(Self, Key);
            if Key = JsException then
              goto Unwind;
          end;
          Target := JsAsObject(Regs[Code[PC + 1]]);
          if not Target.CreateDataProperty(Self, Key, Regs[Code[PC + 3]]) then
          begin
            if not HasException then
              ThrowTypeError('Cannot define property ' + KeyToPascal(Self, Key));
            goto Unwind;
          end;
          Inc(PC, 4);
        end;
      opDefineMethod, opDefineGetter, opDefineSetter:
        begin
          Target := JsAsObject(Regs[Code[PC + 1]]);
          Key := Regs[Code[PC + 2]];
          if not (JsIsInteger(Key) or JsIsSymbol(Key) or (JsIsString(Key) and JsAsString(Key).IsAtom)) then
          begin
            Key := ToPropertyKey(Self, Key);
            if Key = JsException then
              goto Unwind;
          end;
          Value := Regs[Code[PC + 3]];
          if Code[PC + 4] <> 0 then
            Flags := PropertyEnumerable or PropertyConfigurable
          else
            Flags := PropertyConfigurable;
          case Op of
            opDefineMethod:
              Comparison := Target.DefineOwnProperty(Self, Key, DataDescriptor(Value, Flags or PropertyWritable), True);
            opDefineGetter:
              begin
                { Only the getter: a setter defined before stays. }
                Descriptor := AccessorDescriptor(Value, JsUndefined, Flags);
                Descriptor.Present := Descriptor.Present and not HasSetter;
                Comparison := Target.DefineOwnProperty(Self, Key, Descriptor, True);
              end;
          else
            Descriptor := AccessorDescriptor(JsUndefined, Value, Flags);
            Descriptor.Present := Descriptor.Present and not HasGetter;
            Comparison := Target.DefineOwnProperty(Self, Key, Descriptor, True);
          end;
          if Comparison < 0 then
            goto Unwind;
          Inc(PC, 5);
        end;
      opSetPrototypeLiteral:
        begin
          Value := Regs[Code[PC + 2]];
          if JsIsObject(Value) then
            JsAsObject(Regs[Code[PC + 1]]).SetPrototype(Self, JsAsObject(Value))
          else if Value = JsNull then
            JsAsObject(Regs[Code[PC + 1]]).SetPrototype(Self, nil);
          Inc(PC, 3);
        end;
      opCopyDataProperties:
        begin
          if Code[PC + 3] >= 0 then
            Target := JsAsObject(Regs[Code[PC + 3]])
          else
            Target := nil;
          if Code[PC + 3] >= 0 then
          begin
            Value := Regs[Code[PC + 2]];
            if JsIsNullish(Value) then
            begin
              ThrowTypeError('Cannot destructure ' + ValueToPascal(Self, Value));
              goto Unwind;
            end;
          end;
          if not CopyDataProperties(Self, JsAsObject(Regs[Code[PC + 1]]), Regs[Code[PC + 2]], Target) then
            goto Unwind;
          Inc(PC, 4);
        end;
      opArrayPush:
        begin
          ArrayValue := TJsArray(JsAsObject(Regs[Code[PC + 1]]));
          Index := ArrayValue.ArrayLength;
          if Index = ArrayValue.ElementCount then
          begin
            ArrayValue.EnsureElementCapacity(Self, Index + 1);
            ArrayValue.Elements^[Index] := Regs[Code[PC + 2]];
            ArrayValue.ElementCount := Index + 1;
            ArrayValue.ArrayLength := Index + 1;
          end
          else
            ArrayValue.CreateDataProperty(Self, JsInteger(Index), Regs[Code[PC + 2]]);
          Inc(PC, 3);
        end;
      opArrayHole:
        begin
          ArrayValue := TJsArray(JsAsObject(Regs[Code[PC + 1]]));
          ArrayValue.ArrayLength := ArrayValue.ArrayLength + 1;
          Inc(PC, 2);
        end;
      opArraySpread:
        begin
          if not SpreadInto(Self, TJsArray(JsAsObject(Regs[Code[PC + 1]])), Regs[Code[PC + 2]]) then
            goto Unwind;
          Inc(PC, 3);
        end;
      opGetSuper:
        begin
          Value := Regs[Code[PC + 4]];
          if not JsIsObject(Value) then
          begin
            ThrowError(ekSyntax, '''super'' keyword unexpected here');
            goto Unwind;
          end;
          if not JsAsObject(Value).GetPrototype(Self, Prototype) then
            goto Unwind;
          Key := ToPropertyKey(Self, Regs[Code[PC + 3]]);
          if Key = JsException then
            goto Unwind;
          if Prototype = nil then
          begin
            ThrowTypeError('Cannot read properties of null');
            goto Unwind;
          end;
          Value := Prototype.Get(Self, Key, Regs[Code[PC + 2]]);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 5);
        end;
      opSetSuper:
        begin
          Value := Regs[Code[PC + 4]];
          if not JsIsObject(Value) or not JsAsObject(Value).GetPrototype(Self, Prototype) then
          begin
            if not HasException then
              ThrowError(ekSyntax, '''super'' keyword unexpected here');
            goto Unwind;
          end;
          Key := ToPropertyKey(Self, Regs[Code[PC + 2]]);
          if Key = JsException then
            goto Unwind;
          if Prototype = nil then
          begin
            ThrowTypeError('Cannot set properties of null');
            goto Unwind;
          end;
          Comparison := Prototype.SetValue(Self, Key, Regs[Code[PC + 3]], Regs[Code[PC + 1]]);
          if Comparison < 0 then
            goto Unwind;
          if Comparison = 0 then
          begin
            ThrowTypeError('Cannot assign to read only property ''' + KeyToPascal(Self, Key) + '''');
            goto Unwind;
          end;
          Inc(PC, 5);
        end;
      opGetPrivate:
        begin
          Value := GetPrivate(Regs[Code[PC + 2]], Regs[Code[PC + 3]]);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opSetPrivate:
        begin
          if not SetPrivate(Regs[Code[PC + 1]], Regs[Code[PC + 2]], Regs[Code[PC + 3]]) then
            goto Unwind;
          Inc(PC, 4);
        end;
      opDefinePrivate:
        begin
          if not DefinePrivate(Regs[Code[PC + 1]], Regs[Code[PC + 2]], Regs[Code[PC + 3]], JsUndefined,
            JsUndefined, False) then
            goto Unwind;
          Inc(PC, 4);
        end;
      opDefinePrivateAccessor:
        begin
          A := JsUndefined;
          B := JsUndefined;
          if Code[PC + 3] >= 0 then
            A := Regs[Code[PC + 3]];
          if Code[PC + 4] >= 0 then
            B := Regs[Code[PC + 4]];
          if not DefinePrivate(Regs[Code[PC + 1]], Regs[Code[PC + 2]], JsUndefined, A, B, True) then
            goto Unwind;
          Inc(PC, 5);
        end;
      opPrivateIn:
        begin
          Value := Regs[Code[PC + 3]];
          if not JsIsObject(Value) then
          begin
            ThrowTypeError('Cannot use ''in'' operator to search for a private field in ' + ValueToPascal(Self, Value));
            goto Unwind;
          end;
          Regs[Code[PC + 1]] := JsBoolean(JsAsObject(Value).Shape.Find(Regs[Code[PC + 2]], Flags) >= 0);
          Inc(PC, 4);
        end;
      opNewPrivateName:
        begin
          PrivateName := NewSymbol(Heap, JsAsString(Constants[Code[PC + 2]]));
          PrivateName.IsPrivate := True;
          Regs[Code[PC + 1]] := JsSymbolValue(PrivateName);
          Inc(PC, 3);
        end;
      opMakeClass:
        begin
          if Code[PC + 3] >= 0 then
            Equal := MakeClass(Regs[Code[PC + 2]], Regs[Code[PC + 3]], True, Prototype)
          else
            Equal := MakeClass(Regs[Code[PC + 2]], JsUndefined, False, Prototype);
          if not Equal then
            goto Unwind;
          Regs[Code[PC + 1]] := Regs[Code[PC + 2]];
          Regs[Code[PC + 1] + 1] := JsObjectValue(Prototype);
          Inc(PC, 4);
        end;
      opSetClassFields:
        begin
          TJsClosure(JsAsObject(Regs[Code[PC + 1]])).FieldInitializer := Regs[Code[PC + 2]];
          Inc(PC, 3);
        end;
      opRunClassFields:
        begin
          Value := Regs[Code[PC + 2]];
          if JsIsObject(Value) and (JsAsObject(Value) is TJsClosure) and
            JsIsCallable(TJsClosure(JsAsObject(Value)).FieldInitializer) then
          begin
            if Call(TJsClosure(JsAsObject(Value)).FieldInitializer, Regs[Code[PC + 1]], nil, 0) = JsException then
              goto Unwind;
          end;
          Inc(PC, 3);
        end;
      opSetClassSlot:
        begin
          Closure := TJsClosure(JsAsObject(Regs[Code[PC + 1]]));
          Index := Code[PC + 2];
          if Index >= Length(Closure.ClassSlots) then
            SetLength(Closure.ClassSlots, Index + 1);
          Closure.ClassSlots[Index] := Regs[Code[PC + 3]];
          Inc(PC, 4);
        end;
      opGetClassSlot:
        begin
          Closure := TJsClosure(JsAsObject(Regs[-2]));
          Regs[Code[PC + 1]] := Closure.ClassSlots[Code[PC + 2]];
          Inc(PC, 3);
        end;
      opSetHome:
        begin
          Value := Regs[Code[PC + 2]];
          if JsIsObject(Value) then
            TJsClosure(JsAsObject(Regs[Code[PC + 1]])).HomeObject := JsAsObject(Value);
          Inc(PC, 3);
        end;
      opSetFunctionName:
        begin
          case Code[PC + 3] of
            1: SetFunctionName(Self, JsAsObject(Regs[Code[PC + 1]]), Regs[Code[PC + 2]], 'get');
            2: SetFunctionName(Self, JsAsObject(Regs[Code[PC + 1]]), Regs[Code[PC + 2]], 'set');
          else
            SetFunctionName(Self, JsAsObject(Regs[Code[PC + 1]]), Regs[Code[PC + 2]], '');
          end;
          Inc(PC, 4);
        end;
      opAdd:
        begin
          A := Regs[Code[PC + 2]];
          B := Regs[Code[PC + 3]];
          if JsIsInteger(A) and JsIsInteger(B) then
          begin
            Wide := Int64(JsAsInteger(A)) + JsAsInteger(B);
            if (Wide >= -2147483648) and (Wide <= 2147483647) then
              Regs[Code[PC + 1]] := JsInteger(LongInt(Wide))
            else
              Regs[Code[PC + 1]] := JsDouble(Wide);
          end
          else if JsIsNumber(A) and JsIsNumber(B) then
            Regs[Code[PC + 1]] := JsNumber(JsNumberValue(A) + JsNumberValue(B))
          else if JsIsString(A) and JsIsString(B) then
          begin
            Value := ConcatValues(Self, JsAsString(A), JsAsString(B));
            if Value = JsException then
              goto Unwind;
            Regs[Code[PC + 1]] := Value;
          end
          else
          begin
            Value := AddValues(Self, A, B);
            if Value = JsException then
              goto Unwind;
            Regs[Code[PC + 1]] := Value;
          end;
          Inc(PC, 4);
        end;
      opSubtract:
        begin
          A := Regs[Code[PC + 2]];
          B := Regs[Code[PC + 3]];
          if JsIsInteger(A) and JsIsInteger(B) then
          begin
            Wide := Int64(JsAsInteger(A)) - JsAsInteger(B);
            if (Wide >= -2147483648) and (Wide <= 2147483647) then
              Regs[Code[PC + 1]] := JsInteger(LongInt(Wide))
            else
              Regs[Code[PC + 1]] := JsDouble(Wide);
          end
          else if JsIsNumber(A) and JsIsNumber(B) then
            Regs[Code[PC + 1]] := JsNumber(JsNumberValue(A) - JsNumberValue(B))
          else
          begin
            Value := Arithmetic(Self, opSubtract, A, B);
            if Value = JsException then
              goto Unwind;
            Regs[Code[PC + 1]] := Value;
          end;
          Inc(PC, 4);
        end;
      opMultiply:
        begin
          A := Regs[Code[PC + 2]];
          B := Regs[Code[PC + 3]];
          if JsIsInteger(A) and JsIsInteger(B) then
          begin
            Wide := Int64(JsAsInteger(A)) * JsAsInteger(B);
            if (Wide >= -2147483648) and (Wide <= 2147483647) and
              ((Wide <> 0) or ((JsAsInteger(A) >= 0) and (JsAsInteger(B) >= 0))) then
              Regs[Code[PC + 1]] := JsInteger(LongInt(Wide))
            else
              Regs[Code[PC + 1]] := JsNumber(Double(JsAsInteger(A)) * JsAsInteger(B));
          end
          else if JsIsNumber(A) and JsIsNumber(B) then
            Regs[Code[PC + 1]] := JsNumber(JsNumberValue(A) * JsNumberValue(B))
          else
          begin
            Value := Arithmetic(Self, opMultiply, A, B);
            if Value = JsException then
              goto Unwind;
            Regs[Code[PC + 1]] := Value;
          end;
          Inc(PC, 4);
        end;
      opDivide, opModulo, opExponent, opBitAnd, opBitOr, opBitXor, opShiftLeft, opShiftRight,
      opShiftRightUnsigned:
        begin
          A := Regs[Code[PC + 2]];
          B := Regs[Code[PC + 3]];
          if JsIsInteger(A) and JsIsInteger(B) then
          begin
            X := JsAsInteger(A);
            Y := JsAsInteger(B);
            case Op of
              opBitAnd: Value := JsInteger(X and Y);
              opBitOr: Value := JsInteger(X or Y);
              opBitXor: Value := JsInteger(X xor Y);
              opShiftLeft: Value := JsInteger(LongInt(LongWord(X) shl (Y and 31)));
              opShiftRight: Value := JsInteger(SarLongint(X, Y and 31));
              opShiftRightUnsigned: Value := JsNumber(LongWord(X) shr (Y and 31));
              opModulo:
                if (X >= 0) and (Y > 0) then
                  Value := JsInteger(X mod Y)
                else
                  Value := Arithmetic(Self, Op, A, B);
              opDivide:
                if (Y <> 0) and (X mod Y = 0) and not ((X = 0) and (Y < 0)) and
                  not ((X = -2147483647 - 1) and (Y = -1)) then
                  Value := JsInteger(X div Y)
                else
                  Value := Arithmetic(Self, Op, A, B);
            else
              Value := Arithmetic(Self, Op, A, B);
            end;
          end
          else if (Op = opDivide) and JsIsNumber(A) and JsIsNumber(B) and (JsNumberValue(B) <> 0) then
            Value := JsNumber(JsNumberValue(A) / JsNumberValue(B))
          else
            Value := Arithmetic(Self, Op, A, B);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opEqual, opNotEqual:
        begin
          A := Regs[Code[PC + 2]];
          B := Regs[Code[PC + 3]];
          if JsIsInteger(A) and JsIsInteger(B) then
            Equal := A = B
          else if not LooselyEquals(Self, A, B, Equal) then
            goto Unwind;
          Regs[Code[PC + 1]] := JsBoolean(Equal = (Op = opEqual));
          Inc(PC, 4);
        end;
      opStrictEqual:
        begin
          Regs[Code[PC + 1]] := JsBoolean(StrictEquals(Regs[Code[PC + 2]], Regs[Code[PC + 3]], Heap));
          Inc(PC, 4);
        end;
      opStrictNotEqual:
        begin
          Regs[Code[PC + 1]] := JsBoolean(not StrictEquals(Regs[Code[PC + 2]], Regs[Code[PC + 3]], Heap));
          Inc(PC, 4);
        end;
      opLess, opLessEqual, opGreater, opGreaterEqual:
        begin
          A := Regs[Code[PC + 2]];
          B := Regs[Code[PC + 3]];
          if JsIsInteger(A) and JsIsInteger(B) then
          begin
            X := JsAsInteger(A);
            Y := JsAsInteger(B);
            case Op of
              opLess: Equal := X < Y;
              opLessEqual: Equal := X <= Y;
              opGreater: Equal := X > Y;
            else
              Equal := X >= Y;
            end;
          end
          else if JsIsNumber(A) and JsIsNumber(B) then
          begin
            DA := JsNumberValue(A);
            DB := JsNumberValue(B);
            case Op of
              opLess: Equal := DA < DB;
              opLessEqual: Equal := DA <= DB;
              opGreater: Equal := DA > DB;
            else
              Equal := DA >= DB;
            end;
          end
          else
          begin
            case Op of
              opLess: Comparison := LessThan(Self, A, B, True);
              opLessEqual: Comparison := LessThan(Self, B, A, False);
              opGreater: Comparison := LessThan(Self, B, A, False);
            else
              Comparison := LessThan(Self, A, B, True);
            end;
            if Comparison < 0 then
              goto Unwind;
            if Op in [opLess, opGreater] then
              Equal := Comparison = 1
            else
              Equal := Comparison = 0;
          end;
          Regs[Code[PC + 1]] := JsBoolean(Equal);
          Inc(PC, 4);
        end;
      opInstanceof:
        begin
          Value := InstanceOf(Self, Regs[Code[PC + 2]], Regs[Code[PC + 3]]);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opIn:
        begin
          Value := HasPropertyValue(Self, Regs[Code[PC + 2]], Regs[Code[PC + 3]]);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opNegate, opBitNot, opIncrement, opDecrement, opToNumeric, opPlus:
        begin
          A := Regs[Code[PC + 2]];
          if JsIsInteger(A) then
          begin
            X := JsAsInteger(A);
            case Op of
              opIncrement:
                if X < 2147483647 then
                  Value := JsInteger(X + 1)
                else
                  Value := JsDouble(Double(X) + 1);
              opDecrement:
                if X > -2147483647 - 1 then
                  Value := JsInteger(X - 1)
                else
                  Value := JsDouble(Double(X) - 1);
              opNegate:
                if (X <> 0) and (X <> -2147483647 - 1) then
                  Value := JsInteger(-X)
                else
                  Value := JsDouble(-Double(X));
              opBitNot: Value := JsInteger(not X);
            else
              Value := A;
            end;
          end
          else if JsIsDouble(A) then
          begin
            DA := JsAsDouble(A);
            case Op of
              opIncrement: Value := JsNumber(DA + 1);
              opDecrement: Value := JsNumber(DA - 1);
              opNegate: Value := JsNumber(-DA);
              opBitNot: Value := JsInteger(not DoubleToInt32(DA));
            else
              Value := A;
            end;
          end
          else
          begin
            if Op = opPlus then
              Value := ToNumber(Self, A)
            else
              Value := UnaryArithmetic(Self, Op, A);
            if Value = JsException then
              goto Unwind;
          end;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 3);
        end;
      opNot:
        begin
          Regs[Code[PC + 1]] := JsBoolean(not ToBoolean(Regs[Code[PC + 2]]));
          Inc(PC, 3);
        end;
      opTypeof:
        begin
          Regs[Code[PC + 1]] := TypeofValue(Self, Regs[Code[PC + 2]]);
          Inc(PC, 3);
        end;
      opToPropertyKey:
        begin
          Value := ToPropertyKey(Self, Regs[Code[PC + 2]]);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 3);
        end;
      opToString:
        begin
          Value := ToStringValue(Self, Regs[Code[PC + 2]]);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 3);
        end;
      opVoid:
        begin
          Regs[Code[PC + 1]] := JsUndefined;
          Inc(PC, 3);
        end;
      opTemplateAppend:
        begin
          Value := Regs[Code[PC + 2]];
          if not JsIsString(Value) then
          begin
            if JsIsObject(Value) then
              Value := ToPrimitive(Self, Value, ptString);
            if Value <> JsException then
              Value := ToStringValue(Self, Value);
            if Value = JsException then
              goto Unwind;
          end;
          Value := ConcatValues(Self, JsAsString(Regs[Code[PC + 1]]), JsAsString(Value));
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 3);
        end;
      opJump:
        begin
          if Code[PC + 1] <= PC then
          begin
            PC := Code[PC + 1];
            Frame^.PC := PC;
            if (Heap.BytesAllocated >= Heap.Threshold) or Runtime.InterruptRequested then
              if not Safepoint then
                goto Unwind;
          end
          else
            PC := Code[PC + 1];
        end;
      opJumpIfTrue, opJumpIfFalse:
        begin
          Value := Regs[Code[PC + 1]];
          if Value = JsTrue then
            Equal := True
          else if Value = JsFalse then
            Equal := False
          else
            Equal := ToBoolean(Value);
          if Equal = (Op = opJumpIfTrue) then
          begin
            if Code[PC + 2] <= PC then
            begin
              PC := Code[PC + 2];
              Frame^.PC := PC;
              if not Safepoint then
                goto Unwind;
            end
            else
              PC := Code[PC + 2];
          end
          else
            Inc(PC, 3);
        end;
      opJumpIfNullish, opJumpIfNotNullish:
        begin
          if JsIsNullish(Regs[Code[PC + 1]]) = (Op = opJumpIfNullish) then
            PC := Code[PC + 2]
          else
            Inc(PC, 3);
        end;
      opJumpIfUndefined, opJumpIfNotUndefined:
        begin
          if (Regs[Code[PC + 1]] = JsUndefined) = (Op = opJumpIfUndefined) then
            PC := Code[PC + 2]
          else
            Inc(PC, 3);
        end;
      opJumpIfLessFalse, opJumpIfLessEqualFalse, opJumpIfGreaterFalse, opJumpIfGreaterEqualFalse:
        begin
          A := Regs[Code[PC + 1]];
          B := Regs[Code[PC + 2]];
          if JsIsInteger(A) and JsIsInteger(B) then
          begin
            X := JsAsInteger(A);
            Y := JsAsInteger(B);
            case Op of
              opJumpIfLessFalse: Equal := X < Y;
              opJumpIfLessEqualFalse: Equal := X <= Y;
              opJumpIfGreaterFalse: Equal := X > Y;
            else
              Equal := X >= Y;
            end;
          end
          else if JsIsNumber(A) and JsIsNumber(B) then
          begin
            DA := JsNumberValue(A);
            DB := JsNumberValue(B);
            case Op of
              opJumpIfLessFalse: Equal := DA < DB;
              opJumpIfLessEqualFalse: Equal := DA <= DB;
              opJumpIfGreaterFalse: Equal := DA > DB;
            else
              Equal := DA >= DB;
            end;
          end
          else
          begin
            case Op of
              opJumpIfLessFalse: Comparison := LessThan(Self, A, B, True);
              opJumpIfLessEqualFalse: Comparison := LessThan(Self, B, A, False);
              opJumpIfGreaterFalse: Comparison := LessThan(Self, B, A, False);
            else
              Comparison := LessThan(Self, A, B, True);
            end;
            if Comparison < 0 then
              goto Unwind;
            if Op in [opJumpIfLessFalse, opJumpIfGreaterFalse] then
              Equal := Comparison = 1
            else
              Equal := Comparison = 0;
          end;
          if Equal then
            Inc(PC, 4)
          else
            PC := Code[PC + 3];
        end;
      opJumpIfStrictEqualFalse, opJumpIfStrictNotEqualFalse:
        begin
          Equal := StrictEquals(Regs[Code[PC + 1]], Regs[Code[PC + 2]], Heap);
          if Equal = (Op = opJumpIfStrictEqualFalse) then
            Inc(PC, 4)
          else
            PC := Code[PC + 3];
        end;
      opCall, opCallMethod:
        begin
          Index := Code[PC + 2];
          Callee := Regs[Index];
          Count := Code[PC + 3];
          if JsIsObject(Callee) then
          begin
            Target := JsAsObject(Callee);
            if (Target is TJsClosure) and ((TJsClosure(Target).Code.Flags and
              (CodeGenerator or CodeAsync or CodeClassConstructor)) = 0) then
            begin
              Frame^.PC := PC + 4;
              if not EnterFrame(TJsClosure(Target), Frame^.Base + Index + 2, Count, JsUndefined, 0,
                Frame^.Base + Code[PC + 1]) then
              begin
                Frame^.PC := PC;
                goto Unwind;
              end;
              FrameIndex := FFrameCount - 1;
              Frame := @FFrames^[FrameIndex];
              if (Heap.BytesAllocated >= Heap.Threshold) or Runtime.InterruptRequested then
                if not Safepoint then
                  goto Unwind;
              goto ReloadFrame;
            end;
            if Target is TJsNativeFunction then
            begin
              Native := TJsNativeFunction(Target);
              Inc(FRunDepth);
              if Assigned(Native.Callback) then
                Value := Native.Callback(Self, Regs[Index + 1], PJsValueArray(@Regs[Index + 2]), Count, Native,
                  JsUndefined)
              else
                Value := Native.Method(Self, Regs[Index + 1], PJsValueArray(@Regs[Index + 2]), Count, Native,
                  JsUndefined);
              Dec(FRunDepth);
              Frame := @FFrames^[FrameIndex];
              if Value = JsException then
                goto Unwind;
              Regs[Code[PC + 1]] := Value;
              Inc(PC, 4);
              Continue;
            end;
          end;
          FStackTop := Frame^.Base + CodeObject.RegisterCount;
          Value := Call(Callee, Regs[Index + 1], @Regs[Index + 2], Count);
          Frame := @FFrames^[FrameIndex];
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opCallSpread, opNewSpread:
        begin
          Index := Code[PC + 2];
          ArrayValue := TJsArray(JsAsObject(Regs[Code[PC + 3]]));
          if not CreateListFromArrayLike(Self, JsObjectValue(ArrayValue), List) then
            goto Unwind;
          if Op = opCallSpread then
            Value := Call(Regs[Index], Regs[Index + 1], @List[0], Length(List))
          else
            Value := Construct(Regs[Index], @List[0], Length(List), Regs[Index]);
          Frame := @FFrames^[FrameIndex];
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opNew:
        begin
          Index := Code[PC + 2];
          Callee := Regs[Index];
          Count := Code[PC + 3];
          if JsIsObject(Callee) and (JsAsObject(Callee) is TJsClosure) and
            ((TJsClosure(JsAsObject(Callee)).Code.Flags and (CodeConstructor or CodeDerivedConstructor or
            CodeGenerator or CodeAsync)) = CodeConstructor) and JsIsConstructor(Callee) then
          begin
            Closure := TJsClosure(JsAsObject(Callee));
            FStackTop := Frame^.Base + CodeObject.RegisterCount;
            Prototype := PrototypeFromConstructor(Self, Callee, inObjectPrototype);
            if Prototype = nil then
              goto Unwind;
            Regs[Index + 1] := JsObjectValue(NewObject(Prototype));
            Frame^.PC := PC + 4;
            if not EnterFrame(Closure, Frame^.Base + Index + 2, Count, Callee, FrameConstruct,
              Frame^.Base + Code[PC + 1]) then
            begin
              Frame^.PC := PC;
              goto Unwind;
            end;
            FrameIndex := FFrameCount - 1;
            goto ReloadFrame;
          end;
          FStackTop := Frame^.Base + CodeObject.RegisterCount;
          Value := Construct(Callee, @Regs[Index + 2], Count, Callee);
          Frame := @FFrames^[FrameIndex];
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opSuperCall:
        begin
          Value := SuperCall(Regs[Code[PC + 2]], Regs[Code[PC + 3]], @Regs[Code[PC + 4]], Code[PC + 5]);
          Frame := @FFrames^[FrameIndex];
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 6);
        end;
      opSuperCallSpread:
        begin
          if not CreateListFromArrayLike(Self, Regs[Code[PC + 4]], List) then
            goto Unwind;
          Value := SuperCall(Regs[Code[PC + 2]], Regs[Code[PC + 3]], @List[0], Length(List));
          Frame := @FFrames^[FrameIndex];
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 5);
        end;
      opThrowIfNotHole:
        begin
          if Regs[Code[PC + 1]] <> JsHole then
          begin
            ThrowReferenceError('Super constructor may only be called once');
            goto Unwind;
          end;
          Inc(PC, 2);
        end;
      opReturn:
        begin
          ReturnValue := Regs[Code[PC + 1]];
          goto DoReturn;
        end;
      opReturnUndefined:
        begin
          ReturnValue := JsUndefined;
          goto DoReturn;
        end;
      opThrow:
        begin
          Throw(Regs[Code[PC + 1]]);
          goto Unwind;
        end;
      opThrowIfNullish:
        begin
          Value := Regs[Code[PC + 1]];
          if JsIsNullish(Value) then
          begin
            ThrowTypeError('Cannot destructure ''' + ValueToPascal(Self, Value) + ''' as it is ' +
              ValueToPascal(Self, Value) + '.');
            goto Unwind;
          end;
          Inc(PC, 3);
        end;
      opThrowIfNotObject:
        begin
          Value := Regs[Code[PC + 1]];
          if not JsIsObject(Value) then
          begin
            ThrowTypeError('Iterator result ' + ValueToPascal(Self, Value) + ' is not an object');
            goto Unwind;
          end;
          Inc(PC, 3);
        end;
      opGetIterator:
        begin
          Index := Code[PC + 1];
          Value := Regs[Code[PC + 2]];
          if (Code[PC + 3] = 0) and IsPlainArrayIteration(Self, Value) then
          begin
            Regs[Index] := Value;
            Regs[Index + 1] := JsInteger(0);
          end
          else
          begin
            FStackTop := Frame^.Base + CodeObject.RegisterCount;
            if not GetIterator(Self, Value, Code[PC + 3] <> 0, Iterator) then
              goto Unwind;
            Frame := @FFrames^[FrameIndex];
            Regs[Index] := Iterator.Iterator;
            Regs[Index + 1] := Iterator.NextMethod;
          end;
          Inc(PC, 4);
        end;
      opIteratorNext:
        begin
          Index := Code[PC + 2];
          B := Regs[Index + 1];
          if JsIsInteger(B) then
          begin
            ArrayValue := TJsArray(JsAsObject(Regs[Index]));
            X := JsAsInteger(B);
            if LongWord(X) < ArrayValue.ArrayLength then
            begin
              if (X < ArrayValue.ElementCount) and (ArrayValue.Elements^[X] <> JsHole) then
                Value := ArrayValue.Elements^[X]
              else
              begin
                Value := ArrayValue.Get(Self, JsInteger(X), Regs[Index]);
                if Value = JsException then
                  goto Unwind;
              end;
              Regs[Index + 1] := JsInteger(X + 1);
              Regs[Code[PC + 1]] := Value;
              Inc(PC, 4);
            end
            else
            begin
              Regs[Index + 1] := JsHole;
              Regs[Code[PC + 1]] := JsUndefined;
              PC := Code[PC + 3];
            end;
            Continue;
          end;
          if B = JsHole then
          begin
            Regs[Code[PC + 1]] := JsUndefined;
            PC := Code[PC + 3];
            Continue;
          end;
          Regs[Index + 1] := JsHole;
          FStackTop := Frame^.Base + CodeObject.RegisterCount;
          Outcome := Call(B, Regs[Index], nil, 0);
          Frame := @FFrames^[FrameIndex];
          if Outcome = JsException then
            goto Unwind;
          if not JsIsObject(Outcome) then
          begin
            ThrowTypeError('Iterator result ' + ValueToPascal(Self, Outcome) + ' is not an object');
            goto Unwind;
          end;
          Regs[Code[PC + 1]] := Outcome;
          Value := JsAsObject(Outcome).GetValue(Self, Atom(anDone));
          if Value = JsException then
            goto Unwind;
          if ToBoolean(Value) then
          begin
            Regs[Code[PC + 1]] := JsUndefined;
            PC := Code[PC + 3];
            Continue;
          end;
          Value := JsAsObject(Outcome).GetValue(Self, Atom(anValue));
          if Value = JsException then
            goto Unwind;
          Regs[Index + 1] := B;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
      opIteratorClose, opIteratorCloseQuiet:
        begin
          Index := Code[PC + 1];
          B := Regs[Index + 1];
          if (B <> JsHole) and not JsIsInteger(B) then
          begin
            Regs[Index + 1] := JsHole;
            FStackTop := Frame^.Base + CodeObject.RegisterCount;
            Equal := IteratorClose(Self, Regs[Index], Op = opIteratorCloseQuiet);
            Frame := @FFrames^[FrameIndex];
            if not Equal then
              goto Unwind;
          end;
          Inc(PC, 2);
        end;
      opIteratorRest:
        begin
          Index := Code[PC + 2];
          ArrayValue := NewArray(0);
          Regs[Code[PC + 1]] := JsObjectValue(ArrayValue);
          B := Regs[Index + 1];
          if JsIsInteger(B) then
          begin
            Target := JsAsObject(Regs[Index]);
            X := JsAsInteger(B);
            while LongWord(X) < TJsArray(Target).ArrayLength do
            begin
              Value := Target.Get(Self, JsInteger(X), Regs[Index]);
              if Value = JsException then
                goto Unwind;
              ArrayValue.CreateDataProperty(Self, JsInteger(LongInt(ArrayValue.ArrayLength)), Value);
              Inc(X);
            end;
            Regs[Index + 1] := JsHole;
          end
          else if B <> JsHole then
          begin
            Iterator.Iterator := Regs[Index];
            Iterator.NextMethod := B;
            Iterator.Done := False;
            Regs[Index + 1] := JsHole;
            FStackTop := Frame^.Base + CodeObject.RegisterCount;
            while IteratorStep(Self, Iterator, Value) do
              ArrayValue.CreateDataProperty(Self, JsInteger(LongInt(ArrayValue.ArrayLength)), Value);
            Frame := @FFrames^[FrameIndex];
            if HasException then
              goto Unwind;
          end;
          Inc(PC, 3);
        end;
      opForInStart:
        begin
          Value := ForInStart(Regs[Code[PC + 2]]);
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 3);
        end;
      opForInNext:
        begin
          Comparison := ForInNext(TJsForInIterator(JsAsObject(Regs[Code[PC + 2]])), Value);
          if Comparison < 0 then
            goto Unwind;
          if Comparison = 0 then
            PC := Code[PC + 3]
          else
          begin
            Regs[Code[PC + 1]] := Value;
            Inc(PC, 4);
          end;
        end;
      opInitialYield:
        begin
          Suspension := Frame^.Suspension;
          SaveFrame(Suspension, Frame, PC + 1, PC, -1);
          Suspension.State := ssSuspendedStart;
          FStackTop := Frame^.SavedTop;
          Dec(FFrameCount);
          FExit := exSuspend;
          Result := JsUndefined;
          goto Finished;
        end;
      opYield, opAsyncGeneratorYield:
        begin
          Suspension := Frame^.Suspension;
          ReturnValue := Regs[Code[PC + 2]];
          SaveFrame(Suspension, Frame, PC + 3, PC, Code[PC + 1]);
          Suspension.State := ssSuspendedYield;
          FStackTop := Frame^.SavedTop;
          Dec(FFrameCount);
          FExit := exSuspend;
          Result := ReturnValue;
          goto Finished;
        end;
      opYieldDelegate:
        begin
          Suspension := Frame^.Suspension;
          Index := Code[PC + 2];
          Value := Regs[Code[PC + 1]];
          Comparison := Suspension.ResumeKind;
          Suspension.ResumeKind := ResumeNext;
          FStackTop := Frame^.Base + CodeObject.RegisterCount;
          case Comparison of
            ResumeNext:
              begin
                if JsIsInteger(Regs[Index + 1]) then
                begin
                  { A plain array iterated in place: use its iterator. }
                  if not GetIterator(Self, Regs[Index], False, Iterator) then
                    goto Unwind;
                  Regs[Index] := Iterator.Iterator;
                  Regs[Index + 1] := Iterator.NextMethod;
                end;
                Outcome := Call(Regs[Index + 1], Regs[Index], @Value, 1);
              end;
            ResumeThrow:
              begin
                Callee := GetMethod(Self, Regs[Index], Atom(anThrow));
                if Callee = JsException then
                  goto Unwind;
                if Callee = JsUndefined then
                begin
                  IteratorClose(Self, Regs[Index], False);
                  ThrowTypeError('The iterator does not provide a ''throw'' method');
                  goto Unwind;
                end;
                Outcome := Call(Callee, Regs[Index], @Value, 1);
              end;
          else
            Callee := GetMethod(Self, Regs[Index], Atom(anReturn));
            if Callee = JsException then
              goto Unwind;
            if Callee = JsUndefined then
            begin
              Completion := TJsReturnCompletion.Create;
              Heap.Register(Completion, ckOther);
              Completion.Value := Value;
              Throw(JsCellValue(JsObjectBase, Completion));
              goto Unwind;
            end;
            Outcome := Call(Callee, Regs[Index], @Value, 1);
          end;
          Frame := @FFrames^[FrameIndex];
          if Outcome = JsException then
            goto Unwind;
          if not JsIsObject(Outcome) then
          begin
            ThrowTypeError('Iterator result ' + ValueToPascal(Self, Outcome) + ' is not an object');
            goto Unwind;
          end;
          Value := JsAsObject(Outcome).GetValue(Self, Atom(anDone));
          if Value = JsException then
            goto Unwind;
          if ToBoolean(Value) then
          begin
            Value := JsAsObject(Outcome).GetValue(Self, Atom(anValue));
            if Value = JsException then
              goto Unwind;
            if Comparison = ResumeReturn then
            begin
              Completion := TJsReturnCompletion.Create;
              Heap.Register(Completion, ckOther);
              Completion.Value := Value;
              Throw(JsCellValue(JsObjectBase, Completion));
              goto Unwind;
            end;
            Regs[Code[PC + 1]] := Value;
            Inc(PC, 3);
            Continue;
          end;
          { Yield the inner result as it is; resume here. }
          if Suspension.IsAsyncGenerator then
          begin
            Value := JsAsObject(Outcome).GetValue(Self, Atom(anValue));
            if Value = JsException then
              goto Unwind;
            Outcome := Value;
          end;
          SaveFrame(Suspension, Frame, PC, PC, Code[PC + 1]);
          Suspension.Delegating := True;
          Suspension.State := ssSuspendedYield;
          FStackTop := Frame^.SavedTop;
          Dec(FFrameCount);
          FExit := exSuspend;
          { A sync generator hands the inner result object on unchanged
            (its next() sees Delegating set and does not wrap it). }
          Result := Outcome;
          goto Finished;
        end;
      opAwait:
        begin
          Suspension := Frame^.Suspension;
          if Suspension = nil then
          begin
            ThrowError(ekSyntax, 'await is only valid in async functions');
            goto Unwind;
          end;
          FStackTop := Frame^.Base + CodeObject.RegisterCount;
          Promise := PromiseResolveIntrinsic(Self, Regs[Code[PC + 2]]);
          if Promise = nil then
            goto Unwind;
          Frame := @FFrames^[FrameIndex];
          OnFulfilled := NewNativeFunctionWithKey(Self, Atom(anEmpty), @AsyncResume, 1, ResumeNext);
          OnFulfilled.Data := JsObjectValue(Suspension);
          OnRejected := NewNativeFunctionWithKey(Self, Atom(anEmpty), @AsyncResume, 1, ResumeThrow);
          OnRejected.Data := JsObjectValue(Suspension);
          if Suspension.IsAsyncGenerator then
          begin
            OnFulfilled.Data2 := Suspension.ResolveFunction;
            OnRejected.Data2 := Suspension.RejectFunction;
          end;
          PerformPromiseThen(Self, Promise, JsObjectValue(OnFulfilled), JsObjectValue(OnRejected), JsUndefined,
            JsUndefined, JsUndefined);
          SaveFrame(Suspension, Frame, PC + 3, PC, Code[PC + 1]);
          Suspension.State := ssSuspendedYield;
          Suspension.Awaiting := True;
          FStackTop := Frame^.SavedTop;
          Dec(FFrameCount);
          FExit := exSuspend;
          Result := JsUndefined;
          goto Finished;
        end;
      opRethrowCompletion:
        begin
          Throw(Regs[Code[PC + 1]]);
          goto Unwind;
        end;
      opDebugger, opResumeKind, opReturnCompletion, opEnterWith, opLast:
        Inc(PC, 1 + OperandCounts[Op]);
      opRegExp:
        begin
          FStackTop := Frame^.Base + CodeObject.RegisterCount;
          List := nil;
          SetLength(List, 2);
          List[0] := Constants[Code[PC + 2]];
          List[1] := Constants[Code[PC + 3]];
          Value := Construct(JsObjectValue(Intrinsics[inRegExp]), @List[0], 2, JsObjectValue(Intrinsics[inRegExp]));
          Frame := @FFrames^[FrameIndex];
          if Value = JsException then
            goto Unwind;
          Regs[Code[PC + 1]] := Value;
          Inc(PC, 4);
        end;
    else
      ThrowError(ekInternal, 'Unknown opcode ' + IntToStr(Ord(Op)));
      goto Unwind;
    end;
  end;

DoReturn:
  Frame := @FFrames^[FrameIndex];
  if ((Frame^.Flags and FrameConstruct) <> 0) and not JsIsObject(ReturnValue) then
  begin
    if (Frame^.Code.Flags and CodeDerivedConstructor) <> 0 then
    begin
      if ReturnValue <> JsUndefined then
      begin
        ThrowTypeError('Derived constructors may only return object or undefined');
        goto Unwind;
      end;
    end
    else
      ReturnValue := FStack[Frame^.Base - 1];
  end;
  if Frame^.Suspension <> nil then
    Frame^.Suspension.State := ssCompleted;
  FStackTop := Frame^.SavedTop;
  Dec(FFrameCount);
  if (Frame^.Flags and FrameBase) <> 0 then
  begin
    FExit := exReturn;
    Result := ReturnValue;
    goto Finished;
  end;
  FStack[Frame^.ReturnRegister] := ReturnValue;
  FrameIndex := FFrameCount - 1;
  goto ReloadFrame;

Unwind:
  while True do
  begin
    Frame := @FFrames^[FrameIndex];
    Value := Runtime.Exception;
    IsReturnCompletion := JsIsObject(Value) and (JsAsCell(Value) is TJsReturnCompletion);
    if not Runtime.Terminating then
    begin
      Handler := FindHandler(Frame, IsReturnCompletion);
      if Handler >= 0 then
      begin
        CodeObject := Frame^.Code;
        while Frame^.EnvironmentDepth > CodeObject.Handlers[Handler].EnvironmentDepth do
        begin
          Frame^.Environment := Frame^.Environment.Parent;
          Dec(Frame^.EnvironmentDepth);
        end;
        Code := @CodeObject.Instructions[0];
        Regs := @FStack[Frame^.Base];
        Constants := @CodeObject.Constants[0];
        FStackTop := Frame^.Base + CodeObject.RegisterCount;
        Regs[CodeObject.Handlers[Handler].Register] := Runtime.TakeException;
        PC := CodeObject.Handlers[Handler].HandlerPC;
        goto DispatchLoop;
      end;
      if IsReturnCompletion then
      begin
        { A return that went through every finally block. }
        ReturnValue := TJsReturnCompletion(JsAsCell(Value)).Value;
        Runtime.TakeException;
        goto DoReturn;
      end;
    end;
    if Frame^.Suspension <> nil then
      Frame^.Suspension.State := ssCompleted;
    FStackTop := Frame^.SavedTop;
    Dec(FFrameCount);
    if (Frame^.Flags and FrameBase) <> 0 then
    begin
      FExit := exReturn;
      Result := JsException;
      goto Finished;
    end;
    FrameIndex := FFrameCount - 1;
  end;

Finished:
  Dec(FRunDepth);
end;

end.
