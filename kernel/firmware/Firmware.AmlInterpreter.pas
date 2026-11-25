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
  The AML interpreter: runs the code in the ACPI tables.

  A table's body is run like a method at the root: its named object
  opcodes (Scope, Device, Name, Method, OperationRegion, Field...) build
  the namespace; methods keep a pointer to their code, which runs when
  they are called. Code is run straight from the table bytes, one term
  at a time: Evaluate decodes the opcode at the cursor, takes its
  operands (evaluating those that are terms themselves) and returns its
  value; statements return nothing.

  A method runs in a frame of its own (eight locals, up to seven
  arguments, its scope for names and the value it returns). Stores
  follow ACPI's rules: into a named integer, buffer or string the value
  is converted to that type (a buffer keeps its length, so buffer fields
  over it stay valid); into a local it is copied; into a field it is
  written to the hardware.

  Errors (an unknown opcode, a name that is not there, dividing by zero,
  a loop that runs too long, calls nested too deep) end the evaluation:
  it returns False and says why through AmlHost.Log. Notify is passed
  on to AmlHost.Notify. Operating system
  interface queries (\_OSI) are answered for the Windows versions and
  features firmware commonly asks about.
}
unit Firmware.AmlInterpreter;

{$mode objfpc}
{$pointermath on}

interface

uses
  Firmware.AmlValues,
  Firmware.AmlNamespace;

{ Loads a definition block (DSDT or SSDT, header included). }
function LoadAmlTable(Table: PByte): Boolean;
{ Evaluates Node: calls a method with Count arguments, reads a name or a
  field. }
function EvaluateNode(Node: PAmlNode; Arguments: PAmlValue; Count: Integer; out Value: TAmlValue): Boolean;
{ Evaluates Path (text, relative to Scope or absolute); False if it is
  not there or fails. }
function EvaluatePath(Scope: PAmlNode; Path: PChar; Arguments: PAmlValue; Count: Integer;
  out Value: TAmlValue): Boolean;
{ The integer Path evaluates to, or Default. }
function EvaluateInteger(Scope: PAmlNode; Path: PChar; Default: QWord): QWord;
{ Runs \_SB._INI, then every device's _INI where its _STA says it is
  present (the boot time initialization ACPI expects). }
procedure InitializeAmlDevices;
{ For field access (Firmware.AmlFields), which may lead through other
  fields: True, failing the evaluation, once it has used too much of the
  stack. }
function AmlStackExhausted: Boolean;

implementation

uses
  Runtime.Memory,
  Firmware.AmlHost,
  Firmware.AmlFields;

const
  MaximumCallDepth = 24;
  { Iterations of all While loops and method calls in one evaluation
    before it is given up as stuck. }
  LoopBudget = 2000000;
  { The stack an evaluation may use: AML runs on threads with 256 KiB
    stacks (the namespace loader, AcpiPower, Thermal). }
  MaximumStackBytes = 128 * 1024;
  { References followed by a store (a name holding a reference to a
    name holding a reference...). }
  MaximumReferenceHops = 8;
  { The longest field (Firmware.AmlFields reads at most 4 KiB). }
  MaximumFieldBits = 4096 * 8;
  MaximumLocals = 8;
  MaximumArguments = 7;

  OpZero = $00;
  OpOne = $01;
  OpAlias = $06;
  OpName = $08;
  OpBytePrefix = $0A;
  OpWordPrefix = $0B;
  OpDWordPrefix = $0C;
  OpStringPrefix = $0D;
  OpQWordPrefix = $0E;
  OpScope = $10;
  OpBuffer = $11;
  OpPackage = $12;
  OpVarPackage = $13;
  OpMethod = $14;
  OpExternal = $15;
  OpExtended = $5B;
  OpLocal0 = $60;
  OpLocal7 = $67;
  OpArg0 = $68;
  OpArg6 = $6E;
  OpStore = $70;
  OpRefOf = $71;
  OpAdd = $72;
  OpConcatenate = $73;
  OpSubtract = $74;
  OpIncrement = $75;
  OpDecrement = $76;
  OpMultiply = $77;
  OpDivide = $78;
  OpShiftLeft = $79;
  OpShiftRight = $7A;
  OpAnd = $7B;
  OpNand = $7C;
  OpOr = $7D;
  OpNor = $7E;
  OpXor = $7F;
  OpNot = $80;
  OpFindSetLeftBit = $81;
  OpFindSetRightBit = $82;
  OpDerefOf = $83;
  OpConcatenateResources = $84;
  OpMod = $85;
  OpNotify = $86;
  OpSizeOf = $87;
  OpIndex = $88;
  OpMatch = $89;
  OpCreateDWordField = $8A;
  OpCreateWordField = $8B;
  OpCreateByteField = $8C;
  OpCreateBitField = $8D;
  OpObjectType = $8E;
  OpCreateQWordField = $8F;
  OpLogicalAnd = $90;
  OpLogicalOr = $91;
  OpLogicalNot = $92;
  OpLogicalEqual = $93;
  OpLogicalGreater = $94;
  OpLogicalLess = $95;
  OpToBuffer = $96;
  OpToDecimalString = $97;
  OpToHexString = $98;
  OpToInteger = $99;
  OpToString = $9C;
  OpCopyObject = $9D;
  OpMid = $9E;
  OpContinue = $9F;
  OpIf = $A0;
  OpElse = $A1;
  OpWhile = $A2;
  OpNoop = $A3;
  OpReturn = $A4;
  OpBreak = $A5;
  OpBreakPoint = $CC;
  OpOnes = $FF;

  ExtMutex = $01;
  ExtEvent = $02;
  ExtCondRefOf = $12;
  ExtCreateField = $13;
  ExtLoadTable = $1F;
  ExtLoad = $20;
  ExtStall = $21;
  ExtSleep = $22;
  ExtAcquire = $23;
  ExtSignal = $24;
  ExtWait = $25;
  ExtReset = $26;
  ExtRelease = $27;
  ExtFromBcd = $28;
  ExtToBcd = $29;
  ExtRevision = $30;
  ExtDebug = $31;
  ExtFatal = $32;
  ExtTimer = $33;
  ExtOperationRegion = $80;
  ExtField = $81;
  ExtDevice = $82;
  ExtProcessor = $83;
  ExtPowerResource = $84;
  ExtThermalZone = $85;
  ExtIndexField = $86;
  ExtBankField = $87;
  ExtDataRegion = $88;

type
  TControl = (ControlNone, ControlReturn, ControlBreak, ControlContinue);

  PAmlFrame = ^TAmlFrame;
  TAmlFrame = record
    Locals: array[0..MaximumLocals - 1] of TAmlValue;
    Arguments: array[0..MaximumArguments - 1] of TAmlValue;
    Scope: PAmlNode;
    ReturnValue: TAmlValue;
    Control: TControl;
  end;

  TTargetKind = (TargetNone, TargetNode, TargetLocal, TargetArgument, TargetDebug, TargetElement);

  TTarget = record
    Kind: TTargetKind;
    Node: PAmlNode;
    Index: Integer;
    { An element reference (Index). }
    Element: TAmlValue;
  end;

var
  Aborted: Boolean;
  CallDepth: Integer;
  LoopsLeft: QWord;
  { Entry points (table loads, evaluations) active, nested ones
    included: the budget and the stack base belong to the outermost. }
  EvaluationDepth: Integer = 0;
  { Where the outermost evaluation started on the stack. }
  EvaluationStackBase: PtrUInt;

{ --- Failing -------------------------------------------------------------------- }

procedure Fail(Reason: PChar);
begin
  if not Aborted and Assigned(AmlHost.Log) then
    AmlHost.Log(Reason);
  Aborted := True;
end;

{ --- Nesting ------------------------------------------------------------------- }

{ True (after failing the evaluation) once the evaluation uses more than
  MaximumStackBytes of the stack: operators nested hundreds deep, fields
  reached through themselves. Kernel stacks are small. }
function AmlStackExhausted: Boolean;
var
  Marker: Byte;
  Used: PtrUInt;
begin
  Used := 0;
  if (EvaluationDepth > 0) and (EvaluationStackBase > PtrUInt(@Marker)) then
    Used := EvaluationStackBase - PtrUInt(@Marker);
  Result := Used > MaximumStackBytes;
  if Result then
    Fail('AML: nested too deeply');
end;

{ Every table load and evaluation goes between these. The outermost
  starts afresh (no failure, the whole loop budget, the stack base); a
  nested one (a field's _ADR asked for while a method runs) shares the
  budget, so loops cannot get it back by nesting. }
procedure EnterEvaluation;
var
  Marker: Byte;
begin
  if EvaluationDepth = 0 then
  begin
    Aborted := False;
    CallDepth := 0;
    LoopsLeft := LoopBudget;
    EvaluationStackBase := PtrUInt(@Marker);
  end;
  Inc(EvaluationDepth);
end;

procedure LeaveEvaluation;
begin
  Dec(EvaluationDepth);
end;

{ Takes one step of the loop budget (a While iteration, a method call);
  False (the evaluation failed) once it is spent. }
function TakeLoopStep: Boolean;
begin
  Result := LoopsLeft > 0;
  if Result then
    Dec(LoopsLeft)
  else
    Fail('AML: loop does not end');
end;

{ --- Decoding ------------------------------------------------------------------- }

{ Decodes the package length encoding at Position (one to four bytes)
  into Length. }
function ReadEncodedLength(var Position: PByte; Limit: PByte; out Length: LongWord): Boolean;
var
  Lead: Byte;
  Count: Integer;
  Index: Integer;
begin
  Length := 0;
  Result := False;
  if Position >= Limit then
  begin
    Fail('AML: unexpected end of code');
    Exit;
  end;
  Lead := Position^;
  Count := Lead shr 6;
  if Position + Count >= Limit then
  begin
    Fail('AML: unexpected end of code');
    Exit;
  end;
  if Count = 0 then
    Length := Lead and $3F
  else
  begin
    Length := Lead and $0F;
    for Index := 1 to Count do
      Length := Length or (LongWord(Position[Index]) shl (4 + 8 * (Index - 1)));
  end;
  Inc(Position, Count + 1);
  Result := True;
end;

{ Reads a package length at Position: PackageEnd is where the package
  ends (the length counts from the length's own first byte). }
function ReadPackageLength(var Position: PByte; Limit: PByte; out PackageEnd: PByte): Boolean;
var
  Start: PByte;
  Length: LongWord;
begin
  Start := Position;
  PackageEnd := Position;
  Result := ReadEncodedLength(Position, Limit, Length);
  if not Result then
    Exit;
  PackageEnd := Start + Length;
  Result := (PackageEnd <= Limit) and (PackageEnd >= Position);
  if not Result then
    Fail('AML: package length out of bounds');
end;

function ReadByte(var Position: PByte; Limit: PByte; out Value: Byte): Boolean;
begin
  Result := Position < Limit;
  if Result then
  begin
    Value := Position^;
    Inc(Position);
  end
  else
    Fail('AML: unexpected end of code');
end;

function ReadLittleEndian(var Position: PByte; Limit: PByte; Count: Integer; out Value: QWord): Boolean;
var
  Index: Integer;
begin
  Value := 0;
  Result := Position + Count <= Limit;
  if not Result then
  begin
    Fail('AML: unexpected end of code');
    Exit;
  end;
  for Index := Count - 1 downto 0 do
    Value := (Value shl 8) or Position[Index];
  Inc(Position, Count);
end;

function StartsName(Character: Byte): Boolean;
begin
  Result := (Character in [$5C, $5E, $2E, $2F, Ord('_')]) or ((Character >= Ord('A')) and (Character <= Ord('Z')));
end;

function ReadNameString(var Position: PByte; Limit: PByte; out Path: TAmlNamePath): Boolean;
var
  Length: LongWord;
begin
  Result := DecodeNameString(Position, Limit - Position, Path, Length);
  if Result then
    Inc(Position, Length)
  else
    Fail('AML: bad name string');
end;

{ --- Forward ------------------------------------------------------------------- }

function Evaluate(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; out Value: TAmlValue): Boolean; forward;
function ExecuteTermList(var Frame: TAmlFrame; Position, Limit: PByte): Boolean; forward;
function InvokeMethod(Node: PAmlNode; Arguments: PAmlValue; Count: Integer; out Value: TAmlValue): Boolean; forward;

function Concatenate(const First, Second: TAmlValue; out Value: TAmlValue): Boolean; forward;

function NoValue: TAmlValue;
begin
  ZeroMemory(@Result, SizeOf(Result));
end;

function EvaluateNumber(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; out Number: QWord): Boolean;
var
  Value: TAmlValue;
begin
  Number := 0;
  Result := Evaluate(Frame, Position, Limit, Value);
  if not Result then
    Exit;
  Result := ValueToInteger(Value, True, Number);
  ReleaseValue(Value);
  if not Result then
    Fail('AML: operand is not an integer');
end;

{ --- Reading objects -------------------------------------------------------------- }

function NodeTypeNumber(Node: PAmlNode): QWord;
begin
  case Node^.Kind of
    NodeName:
      case Node^.Value.Kind of
        AmlInteger: Result := 1;
        AmlString: Result := 2;
        AmlBuffer: Result := 3;
        AmlPackage: Result := 4;
      else
        Result := 0;
      end;
    NodeField, NodeIndexField, NodeBankField: Result := 5;
    NodeDevice: Result := 6;
    NodeEvent: Result := 7;
    NodeMethod: Result := 8;
    NodeMutex: Result := 9;
    NodeRegion: Result := 10;
    NodePowerResource: Result := 11;
    NodeProcessor: Result := 12;
    NodeThermalZone: Result := 13;
    NodeBufferField: Result := 14;
  else
    Result := 0;
  end;
end;

{ The value of a node used as an operand. }
function ReadNode(Node: PAmlNode; out Value: TAmlValue): Boolean;
begin
  Value := NoValue;
  case Node^.Kind of
    NodeName:
      begin
        Value := ShareValue(Node^.Value);
        Result := True;
      end;
    NodeField, NodeIndexField, NodeBankField, NodeBufferField:
      Result := ReadField(Node, Value);
    NodeMethod:
      Result := InvokeMethod(Node, nil, 0, Value);
  else
    begin
      Value := MakeNodeReference(Node);
      Result := True;
    end;
  end;
end;

{ What a reference (or a name in a string) refers to. }
function Dereference(const Reference: TAmlValue; out Value: TAmlValue): Boolean;
var
  Node: PAmlNode;
begin
  Value := NoValue;
  Result := False;
  case Reference.Kind of
    AmlNodeReference:
      Result := ReadNode(PAmlNode(Reference.Node), Value);
    AmlElementReference:
      if Reference.Package <> nil then
      begin
        Result := Reference.Integer < Reference.Package^.Count;
        if Result then
          Value := ShareValue(Reference.Package^.Elements[Reference.Integer]);
      end
      else if Reference.Bytes <> nil then
      begin
        Result := Reference.Integer < Reference.Bytes^.Length;
        if Result then
          Value := MakeInteger(Reference.Bytes^.Data[Reference.Integer]);
      end;
    AmlString, AmlNamePath:
      begin
        if Reference.Kind = AmlNamePath then
          Node := LookupNameString(PAmlNode(Reference.Node), Reference.Bytes^.Data, Reference.Bytes^.Length)
        else
          Node := LookupText(NamespaceRoot, PChar(Reference.Bytes^.Data));
        Result := (Node <> nil) and ReadNode(Node, Value);
      end;
  else
    Result := False;
  end;
  if not Result then
    Fail('AML: cannot dereference');
end;

{ --- Targets and storing ----------------------------------------------------------- }

function ParseTarget(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; out Target: TTarget): Boolean;
var
  Opcode: Byte;
  Path: TAmlNamePath;
  Value: TAmlValue;
begin
  ZeroMemory(@Target, SizeOf(Target));
  Result := False;
  if Position >= Limit then
  begin
    Fail('AML: missing target');
    Exit;
  end;
  Opcode := Position^;
  case Opcode of
    OpZero:
      begin
        Inc(Position);
        Result := True;
      end;
    OpLocal0..OpLocal7:
      begin
        Target.Kind := TargetLocal;
        Target.Index := Opcode - OpLocal0;
        Inc(Position);
        Result := True;
      end;
    OpArg0..OpArg6:
      begin
        Target.Kind := TargetArgument;
        Target.Index := Opcode - OpArg0;
        Inc(Position);
        Result := True;
      end;
    OpExtended:
      if (Position + 1 < Limit) and (Position[1] = ExtDebug) then
      begin
        Target.Kind := TargetDebug;
        Inc(Position, 2);
        Result := True;
      end
      else
        Fail('AML: bad target');
  else
    if StartsName(Opcode) then
    begin
      if not ReadNameString(Position, Limit, Path) then
        Exit;
      Target.Node := LookupPath(Frame.Scope, Path);
      Result := Target.Node <> nil;
      if Result then
      begin
        Target.Kind := TargetNode;
        { A name holding a reference stores through it. }
      end
      else
        Fail('AML: target name not found');
    end
    else
    begin
      { A reference: Index, DerefOf, RefOf, or a method returning one. }
      if Opcode = OpDerefOf then
        Inc(Position);
      if not Evaluate(Frame, Position, Limit, Value) then
        Exit;
      case Value.Kind of
        AmlNodeReference:
          begin
            Target.Kind := TargetNode;
            Target.Node := PAmlNode(Value.Node);
            Result := True;
          end;
        AmlElementReference:
          begin
            Target.Kind := TargetElement;
            Target.Element := Value;
            Exit(True);
          end;
      else
        Fail('AML: target is not a reference');
      end;
      ReleaseValue(Value);
    end;
  end;
end;

procedure ReleaseTarget(var Target: TTarget);
begin
  ReleaseValue(Target.Element);
end;

{ A store to the Debug object: logged, marked as the firmware's. }
procedure LogValue(const Value: TAmlValue);
var
  Prefix: TAmlValue;
  Text: TAmlValue;
  Line: TAmlValue;
begin
  if not Assigned(AmlHost.Log) then
    Exit;
  Prefix := MakeStringFromText('AML debug: ');
  Text := ValueToHexString(Value);
  if (Prefix.Kind = AmlString) and (Text.Kind = AmlString) and Concatenate(Prefix, Text, Line) then
  begin
    AmlHost.Log(PChar(Line.Bytes^.Data));
    ReleaseValue(Line);
  end;
  ReleaseValue(Prefix);
  ReleaseValue(Text);
end;

{ Stores into a named object, converting to its type. }
function StoreToName(Node: PAmlNode; const Value: TAmlValue): Boolean;
var
  Number: QWord;
  Source: TAmlValue;
  Count: LongWord;
begin
  Result := True;
  case Node^.Value.Kind of
    AmlInteger:
      if ValueToInteger(Value, True, Number) then
      begin
        Node^.Value.Integer := Number;
        Exit;
      end;
    AmlBuffer:
      if Value.Kind in [AmlInteger, AmlString, AmlBuffer] then
      begin
        { Into the buffer as it is: cut, or padded with zeros. }
        Source := ValueToBuffer(Value);
        if Source.Kind = AmlBuffer then
        begin
          Count := Source.Bytes^.Length;
          if Count > Node^.Value.Bytes^.Length then
            Count := Node^.Value.Bytes^.Length;
          ZeroMemory(Node^.Value.Bytes^.Data, Node^.Value.Bytes^.Length);
          if Count > 0 then
            MoveMemory(Node^.Value.Bytes^.Data, Source.Bytes^.Data, Count);
          ReleaseValue(Source);
          Exit;
        end;
      end;
    AmlString:
      if Value.Kind in [AmlInteger, AmlBuffer] then
      begin
        Source := ValueToHexString(Value);
        ReleaseValue(Node^.Value);
        Node^.Value := Source;
        Exit;
      end;
  end;
  ReleaseValue(Node^.Value);
  Node^.Value := CopyValue(Value);
end;

function StoreToNodeWithin(Node: PAmlNode; const Value: TAmlValue; HopsLeft: Integer): Boolean;
begin
  case Node^.Kind of
    NodeName:
      if Node^.Value.Kind = AmlNodeReference then
      begin
        { A name may hold a reference to itself, or a ring of them. }
        if HopsLeft <= 0 then
          Exit(False);
        Result := StoreToNodeWithin(PAmlNode(Node^.Value.Node), Value, HopsLeft - 1);
      end
      else
        Result := StoreToName(Node, Value);
    NodeField, NodeIndexField, NodeBankField, NodeBufferField:
      Result := WriteField(Node, Value);
  else
    Result := True;
  end;
end;

function StoreToNode(Node: PAmlNode; const Value: TAmlValue): Boolean;
begin
  Result := StoreToNodeWithin(Node, Value, MaximumReferenceHops);
end;

function StoreToElement(const Element: TAmlValue; const Value: TAmlValue): Boolean;
var
  Number: QWord;
  Copy: TAmlValue;
begin
  Result := False;
  if Element.Package <> nil then
  begin
    if Element.Integer < Element.Package^.Count then
    begin
      Copy := CopyValue(Value);
      { A copy of a package nested too deep is not made. }
      if (Copy.Kind = AmlNone) and (Value.Kind <> AmlNone) then
        Exit(False);
      ReleaseValue(Element.Package^.Elements[Element.Integer]);
      Element.Package^.Elements[Element.Integer] := Copy;
      Result := True;
    end;
  end
  else if (Element.Bytes <> nil) and (Element.Integer < Element.Bytes^.Length) and
          ValueToInteger(Value, True, Number) then
  begin
    Element.Bytes^.Data[Element.Integer] := Byte(Number);
    Result := True;
  end;
end;

function StoreToTarget(var Frame: TAmlFrame; var Target: TTarget; const Value: TAmlValue): Boolean;
begin
  Result := True;
  case Target.Kind of
    TargetNode:
      Result := StoreToNode(Target.Node, Value);
    TargetLocal:
      begin
        ReleaseValue(Frame.Locals[Target.Index]);
        Frame.Locals[Target.Index] := CopyValue(Value);
      end;
    TargetArgument:
      if Frame.Arguments[Target.Index].Kind = AmlNodeReference then
        Result := StoreToNode(PAmlNode(Frame.Arguments[Target.Index].Node), Value)
      else
      begin
        ReleaseValue(Frame.Arguments[Target.Index]);
        Frame.Arguments[Target.Index] := CopyValue(Value);
      end;
    TargetDebug:
      LogValue(Value);
    TargetElement:
      Result := StoreToElement(Target.Element, Value);
  end;
  if not Result then
    Fail('AML: store failed');
end;

{ The value now in a target (Increment, SizeOf, ObjectType). }
function ReadTarget(var Frame: TAmlFrame; const Target: TTarget; out Value: TAmlValue): Boolean;
begin
  Value := NoValue;
  Result := True;
  case Target.Kind of
    TargetNode:
      if Target.Node^.Kind = NodeMethod then
        { Not called: SizeOf and ObjectType look at it. }
        Value := MakeNodeReference(Target.Node)
      else
        Result := ReadNode(Target.Node, Value);
    TargetLocal:
      Value := ShareValue(Frame.Locals[Target.Index]);
    TargetArgument:
      Value := ShareValue(Frame.Arguments[Target.Index]);
    TargetElement:
      Result := Dereference(Target.Element, Value);
  else
    Value := MakeInteger(0);
  end;
end;

{ Evaluates an operand's target and stores Value there (if any). }
function StoreResult(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; const Value: TAmlValue): Boolean;
var
  Target: TTarget;
begin
  Result := ParseTarget(Frame, Position, Limit, Target);
  if Result and (Target.Kind <> TargetNone) then
    Result := StoreToTarget(Frame, Target, Value);
  ReleaseTarget(Target);
end;

{ --- Creating named objects --------------------------------------------------------- }

function NewNamed(var Frame: TAmlFrame; const Path: TAmlNamePath; Kind: TAmlNodeKind): PAmlNode;
var
  Scope: PAmlNode;
  Segment: TAmlNameSegment;
begin
  Result := nil;
  Scope := ScopeForNewName(Frame.Scope, Path, Segment);
  if Scope = nil then
  begin
    Fail('AML: scope of a new name not found');
    Exit;
  end;
  Result := CreateChild(Scope, Segment, Kind);
  if Result = nil then
    Fail('AML: out of memory');
end;

{ Runs a body (Scope, Device...) with Node as the scope. }
function RunBodyIn(var Frame: TAmlFrame; Node: PAmlNode; Position, Limit: PByte): Boolean;
var
  Saved: PAmlNode;
begin
  Saved := Frame.Scope;
  Frame.Scope := Node;
  Result := ExecuteTermList(Frame, Position, Limit);
  Frame.Scope := Saved;
end;

{ Scope, Device, Processor, PowerResource, ThermalZone. }
function DefineContainer(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; Kind: TAmlNodeKind;
  HeaderBytes: Integer): Boolean;
var
  PackageEnd: PByte;
  Path: TAmlNamePath;
  Node: PAmlNode;
begin
  Result := False;
  if not ReadPackageLength(Position, Limit, PackageEnd) or not ReadNameString(Position, PackageEnd, Path) then
    Exit;
  if Kind = NodeScope then
  begin
    Node := LookupPath(Frame.Scope, Path);
    { Lenient: a scope opened on a name not defined yet is made. }
    if Node = nil then
      Node := NewNamed(Frame, Path, NodeScope);
  end
  else
    Node := NewNamed(Frame, Path, Kind);
  if Node = nil then
    Exit;
  { Processor and power resource data before the body. }
  if Position + HeaderBytes > PackageEnd then
  begin
    Fail('AML: object header out of bounds');
    Exit;
  end;
  Inc(Position, HeaderBytes);
  Result := RunBodyIn(Frame, Node, Position, PackageEnd);
  Position := PackageEnd;
end;

function DefineMethod(var Frame: TAmlFrame; var Position: PByte; Limit: PByte): Boolean;
var
  PackageEnd: PByte;
  Path: TAmlNamePath;
  Flags: Byte;
  Node: PAmlNode;
begin
  Result := False;
  if not ReadPackageLength(Position, Limit, PackageEnd) or not ReadNameString(Position, PackageEnd, Path) or
     not ReadByte(Position, PackageEnd, Flags) then
    Exit;
  Node := NewNamed(Frame, Path, NodeMethod);
  if Node = nil then
    Exit;
  Node^.Code := Position;
  Node^.CodeLength := PackageEnd - Position;
  Node^.ArgumentCount := Flags and 7;
  Node^.Native := nil;
  Position := PackageEnd;
  Result := True;
end;

{ The field list of Field, IndexField and BankField. Template holds what
  every field unit shares. }
function DefineFieldList(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; const Template: TAmlNode;
  Flags: Byte): Boolean;
var
  BitOffset: QWord;
  AccessBytes: Byte;
  Lead: Byte;
  Segment: TAmlNameSegment;
  BitLength: LongWord;
  BitCount: QWord;
  Node: PAmlNode;
  AccessType: Byte;
  Path: TAmlNamePath;
  BufferEnd: PByte;

  function AccessWidthOf(AccessKind: Byte): Byte;
  begin
    case AccessKind and $0F of
      2: Result := 2;
      3: Result := 4;
      4: Result := 8;
    else
      Result := 1;
    end;
  end;

begin
  Result := False;
  BitOffset := 0;
  AccessBytes := AccessWidthOf(Flags);
  while Position < Limit do
  begin
    Lead := Position^;
    case Lead of
      $00:
        begin
          { Reserved bits. }
          Inc(Position);
          if not ReadEncodedLength(Position, Limit, BitLength) then
            Exit;
          BitOffset := BitOffset + BitLength;
        end;
      $01, $03:
        begin
          { Access type changes for the fields after it. }
          if Position + 3 > Limit then
            Exit;
          AccessType := Position[1];
          AccessBytes := AccessWidthOf(AccessType);
          if Lead = $03 then
            Inc(Position, 4)
          else
            Inc(Position, 3);
        end;
      $02:
        begin
          { A connection (GPIO, serial bus): skipped. }
          Inc(Position);
          if (Position < Limit) and (Position^ = OpBuffer) then
          begin
            Inc(Position);
            if not ReadPackageLength(Position, Limit, BufferEnd) then
              Exit;
            Position := BufferEnd;
          end
          else if not ReadNameString(Position, Limit, Path) then
            Exit;
        end;
    else
      begin
        if Position + 4 >= Limit then
        begin
          Fail('AML: field list out of bounds');
          Exit;
        end;
        CopyMemory(@Segment[0], Position, 4);
        Inc(Position, 4);
        { The length encoding holds the field's size in bits. }
        if not ReadEncodedLength(Position, Limit, BitLength) then
          Exit;
        BitCount := BitLength;
        Node := CreateChild(Frame.Scope, Segment, Template.Kind);
        if Node = nil then
        begin
          Fail('AML: out of memory');
          Exit;
        end;
        Node^.Region := Template.Region;
        Node^.IndexField := Template.IndexField;
        Node^.DataField := Template.DataField;
        Node^.BankField := Template.BankField;
        Node^.BankValue := Template.BankValue;
        Node^.BitOffset := BitOffset;
        Node^.BitLength := BitCount;
        Node^.AccessBytes := AccessBytes;
        Node^.UpdateRule := (Flags shr 5) and 3;
        BitOffset := BitOffset + BitCount;
      end;
    end;
  end;
  Result := True;
end;

function IsFieldNode(Node: PAmlNode): Boolean;
begin
  Result := (Node <> nil) and (Node^.Kind in [NodeField, NodeIndexField, NodeBankField, NodeBufferField]);
end;

function FieldTemplateIsComplete(const Template: TAmlNode): Boolean;
begin
  case Template.Kind of
    NodeField:
      Result := (Template.Region <> nil) and (Template.Region^.Kind = NodeRegion);
    NodeIndexField:
      Result := IsFieldNode(Template.IndexField) and IsFieldNode(Template.DataField);
    NodeBankField:
      Result := (Template.Region <> nil) and (Template.Region^.Kind = NodeRegion) and
        IsFieldNode(Template.BankField);
  else
    Result := False;
  end;
end;

function DefineField(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; Kind: TAmlNodeKind): Boolean;
var
  PackageEnd: PByte;
  Path: TAmlNamePath;
  Template: TAmlNode;
  Flags: Byte;
  Bank: QWord;
begin
  Result := False;
  ZeroMemory(@Template, SizeOf(Template));
  Template.Kind := Kind;
  if not ReadPackageLength(Position, Limit, PackageEnd) or not ReadNameString(Position, PackageEnd, Path) then
    Exit;
  case Kind of
    NodeField:
      Template.Region := LookupPath(Frame.Scope, Path);
    NodeIndexField:
      begin
        Template.IndexField := LookupPath(Frame.Scope, Path);
        if not ReadNameString(Position, PackageEnd, Path) then
          Exit;
        Template.DataField := LookupPath(Frame.Scope, Path);
      end;
    NodeBankField:
      begin
        Template.Region := LookupPath(Frame.Scope, Path);
        if not ReadNameString(Position, PackageEnd, Path) then
          Exit;
        Template.BankField := LookupPath(Frame.Scope, Path);
        if not EvaluateNumber(Frame, Position, PackageEnd, Bank) then
          Exit;
        Template.BankValue := Bank;
      end;
  end;
  { Fields whose region, index, data or bank field is missing (or not
    one) are left out: reaching them would follow nothing. }
  if not FieldTemplateIsComplete(Template) then
  begin
    if Assigned(AmlHost.Log) then
      AmlHost.Log('AML: field over a missing region or field left out');
    Position := PackageEnd;
    Exit(True);
  end;
  if not ReadByte(Position, PackageEnd, Flags) then
    Exit;
  Result := DefineFieldList(Frame, Position, PackageEnd, Template, Flags);
  Position := PackageEnd;
end;

function DefineRegion(var Frame: TAmlFrame; var Position: PByte; Limit: PByte): Boolean;
var
  Path: TAmlNamePath;
  Space: Byte;
  Offset: QWord;
  Length: QWord;
  Node: PAmlNode;
begin
  Result := ReadNameString(Position, Limit, Path) and ReadByte(Position, Limit, Space) and
    EvaluateNumber(Frame, Position, Limit, Offset) and EvaluateNumber(Frame, Position, Limit, Length);
  if not Result then
    Exit;
  Node := NewNamed(Frame, Path, NodeRegion);
  if Node = nil then
    Exit(False);
  Node^.Space := Space;
  Node^.RegionOffset := Offset;
  Node^.RegionLength := Length;
  Node^.PciAddressKnown := False;
end;

{ CreateBitField ... CreateQWordField, and CreateField. }
function DefineBufferField(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; Bits: Integer): Boolean;
var
  Source: TAmlValue;
  BitOffset: QWord;
  Index: QWord;
  Count: QWord;
  Path: TAmlNamePath;
  Node: PAmlNode;
begin
  Result := False;
  if not Evaluate(Frame, Position, Limit, Source) then
    Exit;
  if Source.Kind <> AmlBuffer then
  begin
    ReleaseValue(Source);
    Fail('AML: buffer field over something not a buffer');
    Exit;
  end;
  Count := QWord(Bits);
  if not EvaluateNumber(Frame, Position, Limit, Index) or
     ((Bits = 0) and not EvaluateNumber(Frame, Position, Limit, Count)) or
     not ReadNameString(Position, Limit, Path) then
  begin
    ReleaseValue(Source);
    Exit;
  end;
  { Bit fields and CreateField count in bits, the others in bytes. }
  if Bits in [8, 16, 32, 64] then
  begin
    if Index > High(QWord) div 8 then
      Index := High(QWord) div 8;
    BitOffset := Index * 8;
  end
  else
    BitOffset := Index;
  { The field must lie in the buffer (and be one a field may be). }
  if (Count = 0) or (Count > QWord(MaximumFieldBits)) or
     (BitOffset > QWord(Source.Bytes^.Length) * 8) or
     (Count > QWord(Source.Bytes^.Length) * 8 - BitOffset) then
  begin
    ReleaseValue(Source);
    Fail('AML: buffer field past the end of its buffer');
    Exit;
  end;
  Node := NewNamed(Frame, Path, NodeBufferField);
  if Node = nil then
  begin
    ReleaseValue(Source);
    Exit;
  end;
  Node^.BitOffset := BitOffset;
  Node^.BitLength := Count;
  Node^.AccessBytes := 1;
  { The field keeps the buffer's storage: its count passes to the node. }
  Node^.FieldBytes := Source.Bytes;
  Result := True;
end;

{ --- Data objects ------------------------------------------------------------------ }

function EvaluateBuffer(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; out Value: TAmlValue): Boolean;
var
  PackageEnd: PByte;
  Size: QWord;
  Available: QWord;
begin
  Value := NoValue;
  Result := False;
  if not ReadPackageLength(Position, Limit, PackageEnd) or not EvaluateNumber(Frame, Position, PackageEnd, Size) then
    Exit;
  if Size > 1024 * 1024 then
  begin
    Fail('AML: buffer too large');
    Exit;
  end;
  Value := MakeBuffer(Size);
  if Value.Kind <> AmlBuffer then
  begin
    Fail('AML: out of memory');
    Exit;
  end;
  Available := PackageEnd - Position;
  if Available > Size then
    Available := Size;
  if Available > 0 then
    CopyMemory(Value.Bytes^.Data, Position, Available);
  Position := PackageEnd;
  Result := True;
end;

function EvaluatePackage(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; Variable: Boolean;
  out Value: TAmlValue): Boolean;
var
  PackageEnd: PByte;
  Count: QWord;
  CountByte: Byte;
  Index: LongWord;
  Path: TAmlNamePath;
  Start: PByte;
begin
  Value := NoValue;
  Result := False;
  if not ReadPackageLength(Position, Limit, PackageEnd) then
    Exit;
  if Variable then
  begin
    if not EvaluateNumber(Frame, Position, PackageEnd, Count) then
      Exit;
  end
  else
  begin
    if not ReadByte(Position, PackageEnd, CountByte) then
      Exit;
    Count := CountByte;
  end;
  if Count > 65536 then
  begin
    Fail('AML: package too large');
    Exit;
  end;
  Value := MakePackage(Count);
  if Value.Kind <> AmlPackage then
  begin
    Fail('AML: out of memory');
    Exit;
  end;
  Index := 0;
  while (Position < PackageEnd) and (Index < Count) do
  begin
    if StartsName(Position^) then
    begin
      { A name: kept as a path, looked up when used. }
      Start := Position;
      if not ReadNameString(Position, PackageEnd, Path) then
      begin
        ReleaseValue(Value);
        Exit;
      end;
      Value.Package^.Elements[Index] := MakeNamePath(Start, Position - Start, Frame.Scope);
    end
    else if not Evaluate(Frame, Position, PackageEnd, Value.Package^.Elements[Index]) then
    begin
      ReleaseValue(Value);
      Exit;
    end;
    Inc(Index);
  end;
  Position := PackageEnd;
  Result := True;
end;

function EvaluateStringLiteral(var Position: PByte; Limit: PByte; out Value: TAmlValue): Boolean;
var
  Length: LongWord;
begin
  Length := 0;
  while (Position + Length < Limit) and (Position[Length] <> 0) do
    Inc(Length);
  Result := Position + Length < Limit;
  if not Result then
  begin
    Fail('AML: string without an end');
    Value := NoValue;
    Exit;
  end;
  Value := MakeString(Position, Length);
  Inc(Position, Length + 1);
end;

{ --- Operators ----------------------------------------------------------------------- }

function BinaryInteger(Opcode: Byte; Left, Right: QWord; out Number: QWord): Boolean;
begin
  Result := True;
  case Opcode of
    OpAdd: Number := Left + Right;
    OpSubtract: Number := Left - Right;
    OpMultiply: Number := Left * Right;
    OpShiftLeft:
      if Right >= 64 then
        Number := 0
      else
        Number := Left shl Right;
    OpShiftRight:
      if Right >= 64 then
        Number := 0
      else
        Number := Left shr Right;
    OpAnd: Number := Left and Right;
    OpNand: Number := not (Left and Right);
    OpOr: Number := Left or Right;
    OpNor: Number := not (Left or Right);
    OpXor: Number := Left xor Right;
    OpMod:
      if Right = 0 then
      begin
        Fail('AML: modulo by zero');
        Result := False;
      end
      else
        Number := Left mod Right;
  else
    Result := False;
  end;
  Number := AmlMask(Number);
end;

function BooleanValue(Condition: Boolean): TAmlValue;
begin
  if Condition then
    Result := MakeInteger(AmlOnes)
  else
    Result := MakeInteger(0);
end;

function Concatenate(const First, Second: TAmlValue; out Value: TAmlValue): Boolean;
var
  Left: TAmlValue;
  Right: TAmlValue;
begin
  Value := NoValue;
  if First.Kind = AmlString then
  begin
    Left := ShareValue(First);
    Right := ValueToHexString(Second);
    { The second operand may not convert (a package, a reference). }
    if (Left.Bytes <> nil) and (Right.Kind = AmlString) and (Right.Bytes <> nil) then
      Value := MakeString(nil, Left.Bytes^.Length + Right.Bytes^.Length);
  end
  else
  begin
    Left := ValueToBuffer(First);
    Right := ValueToBuffer(Second);
    if (Left.Kind = AmlBuffer) and (Right.Kind = AmlBuffer) then
      Value := MakeBuffer(Left.Bytes^.Length + Right.Bytes^.Length);
  end;
  Result := (Value.Kind <> AmlNone) and (Left.Kind <> AmlNone) and (Right.Kind <> AmlNone);
  if Result then
  begin
    if Left.Bytes^.Length > 0 then
      CopyMemory(Value.Bytes^.Data, Left.Bytes^.Data, Left.Bytes^.Length);
    if Right.Bytes^.Length > 0 then
      CopyMemory(Value.Bytes^.Data + Left.Bytes^.Length, Right.Bytes^.Data, Right.Bytes^.Length);
  end
  else
    Fail('AML: cannot concatenate');
  ReleaseValue(Left);
  ReleaseValue(Right);
end;

{ Two resource templates as one: the first without its end tag, the
  second with its own. }
function ConcatenateResources(const First, Second: TAmlValue; out Value: TAmlValue): Boolean;
var
  FirstLength: LongWord;
  SecondLength: LongWord;
begin
  Value := NoValue;
  Result := (First.Kind = AmlBuffer) and (Second.Kind = AmlBuffer);
  if not Result then
  begin
    Fail('AML: resource templates must be buffers');
    Exit;
  end;
  FirstLength := First.Bytes^.Length;
  if FirstLength >= 2 then
    Dec(FirstLength, 2);
  SecondLength := Second.Bytes^.Length;
  Value := MakeBuffer(FirstLength + SecondLength);
  if Value.Kind <> AmlBuffer then
    Exit(False);
  if FirstLength > 0 then
    CopyMemory(Value.Bytes^.Data, First.Bytes^.Data, FirstLength);
  if SecondLength > 0 then
    CopyMemory(Value.Bytes^.Data + FirstLength, Second.Bytes^.Data, SecondLength);
end;

function MatchOne(Operation: Byte; const Element, Operand: TAmlValue): Boolean;
var
  Order: Integer;
begin
  if Operation = 0 then
    Exit(True);
  if not (Element.Kind in [AmlInteger, AmlString, AmlBuffer]) or not CompareValues(Element, Operand, Order) then
    Exit(False);
  case Operation of
    1: Result := Order = 0;
    2: Result := Order <= 0;
    3: Result := Order < 0;
    4: Result := Order >= 0;
    5: Result := Order > 0;
  else
    Result := False;
  end;
end;

function SubstringOf(const Source: TAmlValue; Start, Count: QWord; out Value: TAmlValue): Boolean;
var
  Length: QWord;
begin
  Value := NoValue;
  Result := Source.Kind in [AmlString, AmlBuffer];
  if not Result then
  begin
    Fail('AML: Mid of something not a string or buffer');
    Exit;
  end;
  Length := Source.Bytes^.Length;
  if Start > Length then
    Start := Length;
  if Count > Length - Start then
    Count := Length - Start;
  if Source.Kind = AmlString then
    Value := MakeString(Source.Bytes^.Data + Start, Count)
  else
    Value := MakeBufferFrom(Source.Bytes^.Data + Start, Count);
end;

function ToBinaryCodedDecimal(Number: QWord): QWord;
var
  Shift: Integer;
begin
  Result := 0;
  Shift := 0;
  while (Number > 0) and (Shift < 64) do
  begin
    Result := Result or ((Number mod 10) shl Shift);
    Number := Number div 10;
    Inc(Shift, 4);
  end;
end;

function FromBinaryCodedDecimal(Number: QWord): QWord;
var
  Scale: QWord;
begin
  Result := 0;
  Scale := 1;
  while Number > 0 do
  begin
    Result := Result + (Number and $F) * Scale;
    Number := Number shr 4;
    Scale := Scale * 10;
  end;
end;

{ --- Calling a name ------------------------------------------------------------------ }

procedure ReleaseArguments(var Arguments: array of TAmlValue; Count: Integer);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    ReleaseValue(Arguments[Index]);
end;

{ A name in a term: a method is called with its arguments (taken from
  the code), anything else read. }
function EvaluateName(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; out Value: TAmlValue): Boolean;
var
  Path: TAmlNamePath;
  Node: PAmlNode;
  Arguments: array[0..MaximumArguments - 1] of TAmlValue;
  Count: Integer;
  Index: Integer;
begin
  Value := NoValue;
  Result := False;
  if not ReadNameString(Position, Limit, Path) then
    Exit;
  Node := LookupPath(Frame.Scope, Path);
  if Node = nil then
  begin
    Fail('AML: name not found');
    Exit;
  end;
  if not (Node^.Kind in [NodeMethod, NodeExternal]) then
    Exit(ReadNode(Node, Value));
  Count := Node^.ArgumentCount;
  if Count > MaximumArguments then
    Count := MaximumArguments;
  ZeroMemory(@Arguments[0], SizeOf(Arguments));
  for Index := 0 to Count - 1 do
    if not Evaluate(Frame, Position, Limit, Arguments[Index]) then
    begin
      ReleaseArguments(Arguments, Index);
      Exit;
    end;
  if Node^.Kind = NodeExternal then
  begin
    Fail('AML: call to an external method that was never defined');
    Result := False;
  end
  else
    Result := InvokeMethod(Node, @Arguments[0], Count, Value);
  for Index := 0 to Count - 1 do
    ReleaseValue(Arguments[Index]);
end;

{ --- Statements ------------------------------------------------------------------------ }

function ExecuteIf(var Frame: TAmlFrame; var Position: PByte; Limit: PByte): Boolean;
var
  PackageEnd: PByte;
  ElseEnd: PByte;
  Predicate: QWord;
  HasElse: Boolean;
begin
  Result := False;
  if not ReadPackageLength(Position, Limit, PackageEnd) or
     not EvaluateNumber(Frame, Position, PackageEnd, Predicate) then
    Exit;
  HasElse := (PackageEnd < Limit) and (PackageEnd^ = OpElse);
  if Predicate <> 0 then
  begin
    Result := ExecuteTermList(Frame, Position, PackageEnd);
    Position := PackageEnd;
    if HasElse then
    begin
      Inc(Position);
      if not ReadPackageLength(Position, Limit, ElseEnd) then
        Exit(False);
      Position := ElseEnd;
    end;
  end
  else
  begin
    Position := PackageEnd;
    Result := True;
    if HasElse then
    begin
      Inc(Position);
      if not ReadPackageLength(Position, Limit, ElseEnd) then
        Exit(False);
      Result := ExecuteTermList(Frame, Position, ElseEnd);
      Position := ElseEnd;
    end;
  end;
end;

function ExecuteWhile(var Frame: TAmlFrame; var Position: PByte; Limit: PByte): Boolean;
var
  PackageEnd: PByte;
  Start: PByte;
  Cursor: PByte;
  Predicate: QWord;
begin
  Result := False;
  if not ReadPackageLength(Position, Limit, PackageEnd) then
    Exit;
  Start := Position;
  repeat
    if not TakeLoopStep then
      Exit;
    Cursor := Start;
    if not EvaluateNumber(Frame, Cursor, PackageEnd, Predicate) then
      Exit;
    if Predicate = 0 then
      Break;
    if not ExecuteTermList(Frame, Cursor, PackageEnd) then
      Exit;
    if Frame.Control = ControlBreak then
    begin
      Frame.Control := ControlNone;
      Break;
    end;
    if Frame.Control = ControlContinue then
      Frame.Control := ControlNone;
  until Frame.Control = ControlReturn;
  Position := PackageEnd;
  Result := True;
end;

{ --- Evaluating a term ----------------------------------------------------------------- }

function EvaluateExtended(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; out Value: TAmlValue): Boolean;
var
  Opcode: Byte;
  Number: QWord;
  Other: QWord;
  Ignored: Byte;
  Path: TAmlNamePath;
  Node: PAmlNode;
  Target: TTarget;
  Operand: TAmlValue;
  Third: TAmlValue;
  Fourth: TAmlValue;
begin
  Value := NoValue;
  Result := False;
  if not ReadByte(Position, Limit, Opcode) then
    Exit;
  case Opcode of
    ExtMutex:
      begin
        Result := ReadNameString(Position, Limit, Path) and ReadByte(Position, Limit, Ignored);
        if Result then
          Result := NewNamed(Frame, Path, NodeMutex) <> nil;
      end;
    ExtEvent:
      begin
        Result := ReadNameString(Position, Limit, Path);
        if Result then
          Result := NewNamed(Frame, Path, NodeEvent) <> nil;
      end;
    ExtCondRefOf:
      begin
        { The name may well not be there: that is the question. }
        Node := nil;
        if (Position < Limit) and StartsName(Position^) then
        begin
          if not ReadNameString(Position, Limit, Path) then
            Exit;
          Node := LookupPath(Frame.Scope, Path);
        end
        else
        begin
          if not ParseTarget(Frame, Position, Limit, Target) then
            Exit;
          if Target.Kind = TargetNode then
            Node := Target.Node;
          ReleaseTarget(Target);
        end;
        if Node <> nil then
        begin
          Result := StoreResult(Frame, Position, Limit, MakeNodeReference(Node));
          Value := BooleanValue(True);
        end
        else
        begin
          Result := ParseTarget(Frame, Position, Limit, Target);
          ReleaseTarget(Target);
          Value := BooleanValue(False);
        end;
      end;
    ExtCreateField:
      Result := DefineBufferField(Frame, Position, Limit, 0);
    ExtLoadTable, ExtLoad:
      Fail('AML: loading tables at run time is not supported');
    ExtStall:
      begin
        Result := EvaluateNumber(Frame, Position, Limit, Number);
        if Result and Assigned(AmlHost.Stall) then
          AmlHost.Stall(Number);
      end;
    ExtSleep:
      begin
        Result := EvaluateNumber(Frame, Position, Limit, Number);
        if Result and Assigned(AmlHost.Sleep) then
          AmlHost.Sleep(Number);
      end;
    ExtAcquire:
      begin
        Result := ParseTarget(Frame, Position, Limit, Target) and ReadLittleEndian(Position, Limit, 2, Number);
        ReleaseTarget(Target);
        { Always acquired (Zero: did not time out). }
        Value := MakeInteger(0);
      end;
    ExtSignal, ExtReset, ExtRelease:
      begin
        Result := ParseTarget(Frame, Position, Limit, Target);
        ReleaseTarget(Target);
      end;
    ExtWait:
      begin
        Result := ParseTarget(Frame, Position, Limit, Target) and EvaluateNumber(Frame, Position, Limit, Number);
        ReleaseTarget(Target);
        Value := MakeInteger(0);
      end;
    ExtFromBcd, ExtToBcd:
      begin
        Result := EvaluateNumber(Frame, Position, Limit, Number);
        if not Result then
          Exit;
        if Opcode = ExtFromBcd then
          Value := MakeInteger(FromBinaryCodedDecimal(Number))
        else
          Value := MakeInteger(ToBinaryCodedDecimal(Number));
        Result := StoreResult(Frame, Position, Limit, Value);
      end;
    ExtRevision:
      begin
        Value := MakeInteger($20240827);
        Result := True;
      end;
    ExtDebug:
      Result := True;
    ExtFatal:
      begin
        Result := ReadByte(Position, Limit, Ignored) and ReadLittleEndian(Position, Limit, 4, Number) and
          EvaluateNumber(Frame, Position, Limit, Other);
        Fail('AML: the firmware reported a fatal error');
        Result := False;
      end;
    ExtTimer:
      begin
        if Assigned(AmlHost.Timer) then
          Value := MakeInteger(AmlHost.Timer())
        else
          Value := MakeInteger(0);
        Result := True;
      end;
    ExtOperationRegion:
      Result := DefineRegion(Frame, Position, Limit);
    ExtField:
      Result := DefineField(Frame, Position, Limit, NodeField);
    ExtIndexField:
      Result := DefineField(Frame, Position, Limit, NodeIndexField);
    ExtBankField:
      Result := DefineField(Frame, Position, Limit, NodeBankField);
    ExtDevice:
      Result := DefineContainer(Frame, Position, Limit, NodeDevice, 0);
    ExtProcessor:
      Result := DefineContainer(Frame, Position, Limit, NodeProcessor, 6);
    ExtPowerResource:
      Result := DefineContainer(Frame, Position, Limit, NodePowerResource, 3);
    ExtThermalZone:
      Result := DefineContainer(Frame, Position, Limit, NodeThermalZone, 0);
    ExtDataRegion:
      begin
        { A region over a table: made, but reads as zeros. }
        Result := ReadNameString(Position, Limit, Path) and Evaluate(Frame, Position, Limit, Operand) and
          Evaluate(Frame, Position, Limit, Third) and Evaluate(Frame, Position, Limit, Fourth);
        ReleaseValue(Operand);
        ReleaseValue(Third);
        ReleaseValue(Fourth);
        if Result then
        begin
          Node := NewNamed(Frame, Path, NodeRegion);
          if Node <> nil then
            Node^.Space := $FF;
        end;
      end;
  else
    Fail('AML: unknown extended opcode');
  end;
end;

function EvaluateOperation(var Frame: TAmlFrame; var Position: PByte; Limit: PByte;
  out Value: TAmlValue): Boolean; forward;

function Evaluate(var Frame: TAmlFrame; var Position: PByte; Limit: PByte; out Value: TAmlValue): Boolean;
begin
  if AmlStackExhausted then
  begin
    Value := NoValue;
    Exit(False);
  end;
  Result := EvaluateOperation(Frame, Position, Limit, Value);
end;

function EvaluateOperation(var Frame: TAmlFrame; var Position: PByte; Limit: PByte;
  out Value: TAmlValue): Boolean;
var
  Opcode: Byte;
  Number: QWord;
  Left: QWord;
  Right: QWord;
  Remainder: QWord;
  First: TAmlValue;
  Second: TAmlValue;
  Operand: TAmlValue;
  Target: TTarget;
  Path: TAmlNamePath;
  Other: TAmlNamePath;
  Node: PAmlNode;
  Order: Integer;
  Operation1: Byte;
  Operation2: Byte;
  Start: QWord;
  Index: QWord;
  Bit: Integer;
  Count: QWord;
  Ignored: Byte;
  ElseEnd: PByte;
  Scope: PAmlNode;
  Segment: TAmlNameSegment;
begin
  Value := NoValue;
  Result := False;
  if Aborted then
    Exit;
  if Position >= Limit then
  begin
    Fail('AML: unexpected end of code');
    Exit;
  end;
  Opcode := Position^;
  if StartsName(Opcode) then
    Exit(EvaluateName(Frame, Position, Limit, Value));
  Inc(Position);
  case Opcode of
    OpZero:
      begin
        Value := MakeInteger(0);
        Result := True;
      end;
    OpOne:
      begin
        Value := MakeInteger(1);
        Result := True;
      end;
    OpOnes:
      begin
        Value := MakeInteger(AmlOnes);
        Result := True;
      end;
    OpBytePrefix, OpWordPrefix, OpDWordPrefix, OpQWordPrefix:
      begin
        case Opcode of
          OpBytePrefix: Count := 1;
          OpWordPrefix: Count := 2;
          OpDWordPrefix: Count := 4;
        else
          Count := 8;
        end;
        Result := ReadLittleEndian(Position, Limit, Count, Number);
        Value := MakeInteger(Number);
      end;
    OpStringPrefix:
      Result := EvaluateStringLiteral(Position, Limit, Value);
    OpBuffer:
      Result := EvaluateBuffer(Frame, Position, Limit, Value);
    OpPackage:
      Result := EvaluatePackage(Frame, Position, Limit, False, Value);
    OpVarPackage:
      Result := EvaluatePackage(Frame, Position, Limit, True, Value);
    OpLocal0..OpLocal7:
      begin
        Value := ShareValue(Frame.Locals[Opcode - OpLocal0]);
        Result := True;
      end;
    OpArg0..OpArg6:
      begin
        Value := ShareValue(Frame.Arguments[Opcode - OpArg0]);
        Result := True;
      end;
    OpExtended:
      Result := EvaluateExtended(Frame, Position, Limit, Value);

    { Named objects. }
    OpName:
      begin
        if not ReadNameString(Position, Limit, Path) or not Evaluate(Frame, Position, Limit, Operand) then
          Exit;
        Node := NewNamed(Frame, Path, NodeName);
        Result := Node <> nil;
        if Result then
          Node^.Value := Operand
        else
          ReleaseValue(Operand);
      end;
    OpAlias:
      begin
        if not ReadNameString(Position, Limit, Path) or not ReadNameString(Position, Limit, Other) then
          Exit;
        Node := NewNamed(Frame, Other, NodeAlias);
        Result := Node <> nil;
        if Result then
          Node^.Target := LookupPath(Frame.Scope, Path);
      end;
    OpScope:
      Result := DefineContainer(Frame, Position, Limit, NodeScope, 0);
    OpMethod:
      Result := DefineMethod(Frame, Position, Limit);
    OpExternal:
      begin
        if not ReadNameString(Position, Limit, Path) or not ReadByte(Position, Limit, Ignored) or
           not ReadByte(Position, Limit, Operation1) then
          Exit;
        { Only a declaration: kept for its argument count, where its
          scope exists already. }
        Result := True;
        if LookupPath(Frame.Scope, Path) = nil then
        begin
          Scope := ScopeForNewName(Frame.Scope, Path, Segment);
          if Scope <> nil then
          begin
            Node := CreateChild(Scope, Segment, NodeExternal);
            if Node <> nil then
              Node^.ArgumentCount := Operation1 and 7;
          end;
        end;
      end;
    OpCreateBitField:
      Result := DefineBufferField(Frame, Position, Limit, 1);
    OpCreateByteField:
      Result := DefineBufferField(Frame, Position, Limit, 8);
    OpCreateWordField:
      Result := DefineBufferField(Frame, Position, Limit, 16);
    OpCreateDWordField:
      Result := DefineBufferField(Frame, Position, Limit, 32);
    OpCreateQWordField:
      Result := DefineBufferField(Frame, Position, Limit, 64);

    { Control. }
    OpIf:
      Result := ExecuteIf(Frame, Position, Limit);
    OpElse:
      begin
        { An Else is taken care of by its If; a stray one is skipped. }
        Result := ReadPackageLength(Position, Limit, ElseEnd);
        if Result then
          Position := ElseEnd;
      end;
    OpWhile:
      Result := ExecuteWhile(Frame, Position, Limit);
    OpReturn:
      begin
        if not Evaluate(Frame, Position, Limit, Operand) then
          Exit;
        ReleaseValue(Frame.ReturnValue);
        { A name returned by reference comes back as its value. }
        if Operand.Kind = AmlNodeReference then
        begin
          Result := ReadNode(PAmlNode(Operand.Node), Frame.ReturnValue);
          ReleaseValue(Operand);
          if not Result then
            Exit;
        end
        else
          Frame.ReturnValue := Operand;
        Frame.Control := ControlReturn;
        Result := True;
      end;
    OpBreak:
      begin
        Frame.Control := ControlBreak;
        Result := True;
      end;
    OpContinue:
      begin
        Frame.Control := ControlContinue;
        Result := True;
      end;
    OpNoop, OpBreakPoint:
      Result := True;
    OpNotify:
      begin
        Result := ParseTarget(Frame, Position, Limit, Target) and EvaluateNumber(Frame, Position, Limit, Number);
        if Result and (Target.Kind = TargetNode) and Assigned(AmlHost.Notify) then
          AmlHost.Notify(Target.Node, Number);
        ReleaseTarget(Target);
      end;

    { Storing and references. }
    OpStore, OpCopyObject:
      begin
        if not Evaluate(Frame, Position, Limit, Operand) then
          Exit;
        if not ParseTarget(Frame, Position, Limit, Target) then
        begin
          ReleaseValue(Operand);
          Exit;
        end;
        if (Opcode = OpCopyObject) and (Target.Kind = TargetNode) and (Target.Node^.Kind = NodeName) then
        begin
          { CopyObject replaces, whatever the type was. }
          ReleaseValue(Target.Node^.Value);
          Target.Node^.Value := CopyValue(Operand);
          Result := True;
        end
        else
          Result := StoreToTarget(Frame, Target, Operand);
        ReleaseTarget(Target);
        Value := Operand;
      end;
    OpRefOf:
      begin
        if not ParseTarget(Frame, Position, Limit, Target) then
          Exit;
        case Target.Kind of
          TargetNode:
            begin
              Value := MakeNodeReference(Target.Node);
              Result := True;
            end;
          TargetLocal, TargetArgument:
            Result := ReadTarget(Frame, Target, Value);
          TargetElement:
            begin
              Value := ShareValue(Target.Element);
              Result := True;
            end;
        else
          Fail('AML: RefOf of something that cannot be referred to');
        end;
        ReleaseTarget(Target);
      end;
    OpDerefOf:
      begin
        if not Evaluate(Frame, Position, Limit, Operand) then
          Exit;
        Result := Dereference(Operand, Value);
        ReleaseValue(Operand);
      end;
    OpIndex:
      begin
        if not Evaluate(Frame, Position, Limit, First) then
          Exit;
        if not EvaluateNumber(Frame, Position, Limit, Index) then
        begin
          ReleaseValue(First);
          Exit;
        end;
        Value := NoValue;
        Value.Kind := AmlElementReference;
        Value.Integer := Index;
        case First.Kind of
          AmlPackage:
            begin
              Value.Package := First.Package;
              Result := Index < First.Package^.Count;
            end;
          AmlBuffer, AmlString:
            begin
              Value.Bytes := First.Bytes;
              Result := Index < First.Bytes^.Length;
            end;
        else
          Result := False;
        end;
        { The reference keeps the storage: First's count passes to it. }
        if not Result then
        begin
          ReleaseValue(First);
          Value := NoValue;
          Fail('AML: index out of range');
          Exit;
        end;
        Result := StoreResult(Frame, Position, Limit, Value);
      end;
    OpSizeOf:
      begin
        if not ParseTarget(Frame, Position, Limit, Target) then
          Exit;
        Result := ReadTarget(Frame, Target, Operand);
        ReleaseTarget(Target);
        if not Result then
          Exit;
        if Operand.Kind = AmlElementReference then
        begin
          First := Operand;
          Result := Dereference(First, Operand);
          ReleaseValue(First);
        end;
        Value := MakeInteger(ValueLength(Operand));
        ReleaseValue(Operand);
      end;
    OpObjectType:
      begin
        if not ParseTarget(Frame, Position, Limit, Target) then
          Exit;
        case Target.Kind of
          TargetNode:
            Value := MakeInteger(NodeTypeNumber(Target.Node));
          TargetDebug:
            Value := MakeInteger(16);
        else
          begin
            Result := ReadTarget(Frame, Target, Operand);
            case Operand.Kind of
              AmlInteger: Value := MakeInteger(1);
              AmlString: Value := MakeInteger(2);
              AmlBuffer: Value := MakeInteger(3);
              AmlPackage: Value := MakeInteger(4);
            else
              Value := MakeInteger(0);
            end;
            ReleaseValue(Operand);
          end;
        end;
        ReleaseTarget(Target);
        Result := True;
      end;

    { Integer arithmetic. }
    OpAdd, OpSubtract, OpMultiply, OpShiftLeft, OpShiftRight, OpAnd, OpNand, OpOr, OpNor, OpXor, OpMod:
      begin
        Result := EvaluateNumber(Frame, Position, Limit, Left) and EvaluateNumber(Frame, Position, Limit, Right) and
          BinaryInteger(Opcode, Left, Right, Number);
        if not Result then
          Exit;
        Value := MakeInteger(Number);
        Result := StoreResult(Frame, Position, Limit, Value);
      end;
    OpDivide:
      begin
        if not EvaluateNumber(Frame, Position, Limit, Left) or not EvaluateNumber(Frame, Position, Limit, Right) then
          Exit;
        if Right = 0 then
        begin
          Fail('AML: division by zero');
          Exit;
        end;
        Remainder := Left mod Right;
        Value := MakeInteger(Left div Right);
        Result := StoreResult(Frame, Position, Limit, MakeInteger(Remainder)) and
          StoreResult(Frame, Position, Limit, Value);
      end;
    OpNot, OpFindSetLeftBit, OpFindSetRightBit:
      begin
        if not EvaluateNumber(Frame, Position, Limit, Number) then
          Exit;
        case Opcode of
          OpNot: Number := AmlMask(not Number);
          OpFindSetLeftBit:
            begin
              Bit := 0;
              while (Bit < 64) and (Number shr Bit <> 0) do
                Inc(Bit);
              Number := Bit;
            end;
        else
          begin
            Bit := 0;
            if Number <> 0 then
            begin
              Bit := 1;
              while (Number and 1) = 0 do
              begin
                Number := Number shr 1;
                Inc(Bit);
              end;
            end;
            Number := Bit;
          end;
        end;
        Value := MakeInteger(Number);
        Result := StoreResult(Frame, Position, Limit, Value);
      end;
    OpIncrement, OpDecrement:
      begin
        if not ParseTarget(Frame, Position, Limit, Target) then
          Exit;
        Result := ReadTarget(Frame, Target, Operand) and ValueToInteger(Operand, True, Number);
        ReleaseValue(Operand);
        if Result then
        begin
          if Opcode = OpIncrement then
            Value := MakeInteger(Number + 1)
          else
            Value := MakeInteger(Number - 1);
          Result := StoreToTarget(Frame, Target, Value);
        end
        else
          Fail('AML: cannot increment or decrement');
        ReleaseTarget(Target);
      end;

    { Logic. }
    OpLogicalAnd, OpLogicalOr:
      begin
        Result := EvaluateNumber(Frame, Position, Limit, Left) and EvaluateNumber(Frame, Position, Limit, Right);
        if Opcode = OpLogicalAnd then
          Value := BooleanValue((Left <> 0) and (Right <> 0))
        else
          Value := BooleanValue((Left <> 0) or (Right <> 0));
      end;
    OpLogicalNot:
      begin
        Result := EvaluateNumber(Frame, Position, Limit, Number);
        Value := BooleanValue(Number = 0);
      end;
    OpLogicalEqual, OpLogicalGreater, OpLogicalLess:
      begin
        if not Evaluate(Frame, Position, Limit, First) then
          Exit;
        if not Evaluate(Frame, Position, Limit, Second) then
        begin
          ReleaseValue(First);
          Exit;
        end;
        Result := CompareValues(First, Second, Order);
        ReleaseValue(First);
        ReleaseValue(Second);
        if not Result then
        begin
          Fail('AML: cannot compare');
          Exit;
        end;
        case Opcode of
          OpLogicalEqual: Value := BooleanValue(Order = 0);
          OpLogicalGreater: Value := BooleanValue(Order > 0);
        else
          Value := BooleanValue(Order < 0);
        end;
      end;

    { Strings, buffers, conversions. }
    OpConcatenate, OpConcatenateResources:
      begin
        if not Evaluate(Frame, Position, Limit, First) then
          Exit;
        if not Evaluate(Frame, Position, Limit, Second) then
        begin
          ReleaseValue(First);
          Exit;
        end;
        if Opcode = OpConcatenate then
          Result := Concatenate(First, Second, Value)
        else
          Result := ConcatenateResources(First, Second, Value);
        ReleaseValue(First);
        ReleaseValue(Second);
        if Result then
          Result := StoreResult(Frame, Position, Limit, Value);
      end;
    OpToBuffer, OpToDecimalString, OpToHexString, OpToInteger:
      begin
        if not Evaluate(Frame, Position, Limit, Operand) then
          Exit;
        case Opcode of
          OpToBuffer: Value := ValueToBuffer(Operand);
          OpToDecimalString: Value := ValueToDecimalString(Operand);
          OpToHexString: Value := ValueToHexString(Operand);
        else
          if ValueToInteger(Operand, False, Number) then
            Value := MakeInteger(Number);
        end;
        ReleaseValue(Operand);
        if Value.Kind = AmlNone then
        begin
          Fail('AML: conversion failed');
          Exit;
        end;
        Result := StoreResult(Frame, Position, Limit, Value);
      end;
    OpToString:
      begin
        if not Evaluate(Frame, Position, Limit, Operand) or not EvaluateNumber(Frame, Position, Limit, Count) then
          Exit;
        First := ValueToBuffer(Operand);
        ReleaseValue(Operand);
        if First.Kind <> AmlBuffer then
        begin
          Fail('AML: ToString of something not a buffer');
          Exit;
        end;
        Number := 0;
        while (Number < First.Bytes^.Length) and (Number < Count) and (First.Bytes^.Data[Number] <> 0) do
          Inc(Number);
        Value := MakeString(First.Bytes^.Data, Number);
        ReleaseValue(First);
        Result := StoreResult(Frame, Position, Limit, Value);
      end;
    OpMid:
      begin
        if not Evaluate(Frame, Position, Limit, Operand) then
          Exit;
        Result := EvaluateNumber(Frame, Position, Limit, Start) and EvaluateNumber(Frame, Position, Limit, Count) and
          SubstringOf(Operand, Start, Count, Value);
        ReleaseValue(Operand);
        if Result then
          Result := StoreResult(Frame, Position, Limit, Value);
      end;
    OpMatch:
      begin
        if not Evaluate(Frame, Position, Limit, Operand) then
          Exit;
        Result := ReadByte(Position, Limit, Operation1) and Evaluate(Frame, Position, Limit, First) and
          ReadByte(Position, Limit, Operation2) and Evaluate(Frame, Position, Limit, Second) and
          EvaluateNumber(Frame, Position, Limit, Start);
        if Result and (Operand.Kind = AmlPackage) then
        begin
          Number := AmlOnes;
          Index := Start;
          while Index < Operand.Package^.Count do
          begin
            if MatchOne(Operation1, Operand.Package^.Elements[Index], First) and
               MatchOne(Operation2, Operand.Package^.Elements[Index], Second) then
            begin
              Number := Index;
              Break;
            end;
            Inc(Index);
          end;
          Value := MakeInteger(Number);
        end
        else if Result then
        begin
          Fail('AML: Match needs a package');
          Result := False;
        end;
        ReleaseValue(Operand);
        ReleaseValue(First);
        ReleaseValue(Second);
      end;
  else
    Fail('AML: unknown opcode');
  end;
  if not Result then
  begin
    ReleaseValue(Value);
    Value := NoValue;
  end;
end;

function ExecuteTermList(var Frame: TAmlFrame; Position, Limit: PByte): Boolean;
var
  Value: TAmlValue;
begin
  while (Position < Limit) and (Frame.Control = ControlNone) do
  begin
    if not Evaluate(Frame, Position, Limit, Value) then
      Exit(False);
    ReleaseValue(Value);
  end;
  Result := not Aborted;
end;

{ --- Methods ------------------------------------------------------------------------- }

function InvokeMethod(Node: PAmlNode; Arguments: PAmlValue; Count: Integer; out Value: TAmlValue): Boolean;
var
  Frame: PAmlFrame;
  Index: Integer;
begin
  Value := NoValue;
  if Assigned(Node^.Native) then
    Exit(Node^.Native(Arguments, Count, Value));
  if CallDepth >= MaximumCallDepth then
  begin
    Fail('AML: methods nested too deep');
    Exit(False);
  end;
  { A method calling itself twice, 24 deep, would make 2^24 calls. }
  if not TakeLoopStep or AmlStackExhausted then
    Exit(False);
  Frame := PAmlFrame(AmlHost.Allocate(SizeOf(TAmlFrame)));
  if Frame = nil then
  begin
    Fail('AML: out of memory');
    Exit(False);
  end;
  Frame^.Scope := Node;
  for Index := 0 to Count - 1 do
    if Index < MaximumArguments then
      Frame^.Arguments[Index] := CopyValue(Arguments[Index]);
  Inc(CallDepth);
  Result := ExecuteTermList(Frame^, Node^.Code, Node^.Code + Node^.CodeLength);
  Dec(CallDepth);
  if Result then
    Value := Frame^.ReturnValue
  else
    ReleaseValue(Frame^.ReturnValue);
  for Index := 0 to MaximumLocals - 1 do
    ReleaseValue(Frame^.Locals[Index]);
  for Index := 0 to MaximumArguments - 1 do
    ReleaseValue(Frame^.Arguments[Index]);
  AmlHost.Free(Frame);
end;

{ --- \_OSI ---------------------------------------------------------------------------- }

function OperatingSystemInterface(Arguments: PAmlValue; Count: Integer; out Value: TAmlValue): Boolean;
const
  Known: array[0..15] of PChar = ('Windows 2000', 'Windows 2001', 'Windows 2001 SP1', 'Windows 2001.1',
    'Windows 2001 SP2', 'Windows 2006', 'Windows 2006 SP1', 'Windows 2009', 'Windows 2012', 'Windows 2013',
    'Windows 2015', 'Windows 2016', 'Windows 2017', 'Windows 2018', 'Windows 2019', 'Windows 2020');
var
  Index: Integer;
  Text: PChar;
  Position: Integer;
  Same: Boolean;
begin
  Value := MakeInteger(0);
  Result := True;
  if (Count < 1) or (Arguments[0].Kind <> AmlString) then
    Exit;
  Text := PChar(Arguments[0].Bytes^.Data);
  for Index := Low(Known) to High(Known) do
  begin
    Position := 0;
    Same := True;
    while Same and ((Known[Index][Position] <> #0) or (Text[Position] <> #0)) do
    begin
      Same := Known[Index][Position] = Text[Position];
      Inc(Position);
    end;
    if Same then
    begin
      Value := MakeInteger(AmlOnes);
      Exit;
    end;
  end;
end;

procedure AddNativeMethods;
var
  Node: PAmlNode;
begin
  Node := CreateChild(NamespaceRoot, SegmentOf('_OSI'), NodeMethod);
  if Node <> nil then
  begin
    Node^.Native := @OperatingSystemInterface;
    Node^.ArgumentCount := 1;
  end;
end;

{ --- Loading and evaluating -------------------------------------------------------------- }


function LoadAmlTable(Table: PByte): Boolean;
const
  HeaderBytes = 36;
  MaximumTableBytes = 16 * 1024 * 1024;
var
  Length: LongWord;
  Frame: PAmlFrame;
  Index: Integer;
begin
  Result := False;
  if (NamespaceRoot = nil) and not InitializeNamespace then
    Exit;
  if FindChild(NamespaceRoot, SegmentOf('_OSI')) = nil then
    AddNativeMethods;
  Length := PLongWord(Table + 4)^;
  { A length of gigabytes would have the parser read far past the table. }
  if (Length < HeaderBytes) or (Length > MaximumTableBytes) then
    Exit;
  { Revision 1 tables have 32-bit integers. }
  if (Table[0] = Ord('D')) and (Table[1] = Ord('S')) then
    if Table[8] < 2 then
      AmlIntegerBytes := 4
    else
      AmlIntegerBytes := 8;
  Frame := PAmlFrame(AmlHost.Allocate(SizeOf(TAmlFrame)));
  if Frame = nil then
    Exit;
  Frame^.Scope := NamespaceRoot;
  EnterEvaluation;
  Result := ExecuteTermList(Frame^, Table + HeaderBytes, Table + Length);
  LeaveEvaluation;
  for Index := 0 to MaximumLocals - 1 do
    ReleaseValue(Frame^.Locals[Index]);
  ReleaseValue(Frame^.ReturnValue);
  AmlHost.Free(Frame);
end;

function EvaluateNode(Node: PAmlNode; Arguments: PAmlValue; Count: Integer; out Value: TAmlValue): Boolean;
var
  SavedAborted: Boolean;
  SavedDepth: Integer;
  IsNested: Boolean;
begin
  { It may be asked for from inside another evaluation (a field's _ADR):
    then its failure is its own (the outer evaluation goes on, with a
    default), but the loop budget it spent stays spent. }
  IsNested := EvaluationDepth > 0;
  SavedAborted := Aborted;
  SavedDepth := CallDepth;
  EnterEvaluation;
  if Node^.Kind = NodeMethod then
    Result := InvokeMethod(Node, Arguments, Count, Value)
  else
    Result := ReadNode(Node, Value);
  LeaveEvaluation;
  if IsNested then
  begin
    Aborted := SavedAborted;
    CallDepth := SavedDepth;
  end;
end;

function IsSingleSegment(Path: PChar): Boolean;
var
  Position: Integer;
begin
  Result := (Path[0] <> '\') and (Path[0] <> '^');
  Position := 0;
  while Result and (Path[Position] <> #0) do
  begin
    if Path[Position] = '.' then
      Result := False;
    Inc(Position);
  end;
end;

function EvaluatePath(Scope: PAmlNode; Path: PChar; Arguments: PAmlValue; Count: Integer;
  out Value: TAmlValue): Boolean;
var
  Node: PAmlNode;
begin
  Value := NoValue;
  if Scope = nil then
    Scope := NamespaceRoot;
  Node := LookupText(Scope, Path);
  if Node = nil then
    Exit(False);
  { A single name asked of a scope means that scope's own object, not
    one found further up. }
  if IsSingleSegment(Path) and (Node^.Parent <> Scope) then
    Exit(False);
  Result := EvaluateNode(Node, Arguments, Count, Value);
end;

function EvaluateInteger(Scope: PAmlNode; Path: PChar; Default: QWord): QWord;
var
  Value: TAmlValue;
begin
  Result := Default;
  if EvaluatePath(Scope, Path, nil, 0, Value) then
  begin
    if not ValueToInteger(Value, True, Result) then
      Result := Default;
    ReleaseValue(Value);
  end;
end;

{ --- Device initialization ---------------------------------------------------------------- }

const
  StatusPresent = 1;
  StatusFunctioning = 8;

procedure InitializeDevicesUnder(Parent: PAmlNode);
var
  Child: PAmlNode;
  Status: QWord;
  Value: TAmlValue;
begin
  Child := Parent^.FirstChild;
  while Child <> nil do
  begin
    if Child^.Kind in [NodeDevice, NodeProcessor, NodeThermalZone, NodePowerResource, NodeScope] then
    begin
      Status := StatusPresent or StatusFunctioning;
      if Child^.Kind = NodeDevice then
        Status := EvaluateInteger(Child, '_STA', $0F);
      if ((Status and StatusPresent) <> 0) and (Child^.Kind = NodeDevice) and
         (FindChild(Child, SegmentOf('_INI')) <> nil) then
      begin
        EvaluatePath(Child, '_INI', nil, 0, Value);
        ReleaseValue(Value);
      end;
      { Children of a device that is absent but functioning still count. }
      if (Status and (StatusPresent or StatusFunctioning)) <> 0 then
        InitializeDevicesUnder(Child);
    end;
    Child := Child^.NextSibling;
  end;
end;

procedure InitializeAmlDevices;
var
  Value: TAmlValue;
begin
  if NamespaceRoot = nil then
    Exit;
  if EvaluatePath(NamespaceRoot, '\_SB_._INI', nil, 0, Value) then
    ReleaseValue(Value);
  InitializeDevicesUnder(NamespaceRoot);
end;

end.
