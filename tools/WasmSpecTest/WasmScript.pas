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
  The script format of the WebAssembly specification tests (.wast,
  described in the spec repository's interpreter/README): a sequence of
  commands, parsed here into TScriptCommand objects for a runner.

    (module $name? ...)               define a module (text, binary or
                                      quote form), instantiated by the
                                      runner and made current
    (register "name" $name?)          make a module's exports importable
                                      under "name"
    (invoke $name? "field" const*)    an action: call an export
    (get $name? "field")              an action: read an exported global
    (assert_return action result*)
    (assert_trap action "message")    also (assert_trap module "message"):
                                      instantiation traps
    (assert_exhaustion action "message")
    (assert_invalid module "message")
    (assert_malformed module "message")
    (assert_unlinkable module "message")
    (assert_uninstantiable module "message")

  Modules are encoded to binary while parsing. One that does not parse or
  encode does not stop the script: its EncodeError says why (what an
  assert_malformed expects; anywhere else the runner reports a failure).

  Values are kept as bit patterns: Bits[0] holds a scalar (an f32 in its
  low 32 bits, the number of a ref.extern), a v128 is Bits[0] (bytes 0
  to 7) and Bits[1] (bytes 8 to 15). Expected results may be NaN patterns
  instead of values (nan:canonical, nan:arithmetic), for scalars in Nan
  and per lane of an f32x4 or f64x2 vector in LaneNan; (ref.func) and
  (ref.extern) without a number match any such reference (AnyReference).
}
unit WasmScript;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  SysUtils,
  fgl,
  WasmText.Lexer,
  WasmText.Tree;

type
  TScriptValueKind = (svI32, svI64, svF32, svF64, svV128, svRefNull, svRefExtern, svRefFunc);
  TScriptNanPattern = (npNone, npCanonical, npArithmetic);
  TScriptLaneShape = (lsI8, lsI16, lsI32, lsI64, lsF32, lsF64);
  TScriptHeapKind = (shFunc, shExtern);

  TScriptValue = record
    Kind: TScriptValueKind;
    Bits: array[0..1] of QWord;
    Nan: TScriptNanPattern;
    Shape: TScriptLaneShape;
    LaneNan: array[0..3] of TScriptNanPattern;
    HeapKind: TScriptHeapKind;
    AnyReference: Boolean;
  end;

  TScriptValueArray = array of TScriptValue;

  TScriptModule = record
    Name: AnsiString;
    Bytes: TBytes;
    EncodeError: AnsiString;
    IsQuote, IsBinary: Boolean;
  end;

  TScriptActionKind = (saInvoke, saGet);

  TScriptAction = record
    Kind: TScriptActionKind;
    ModuleName, FieldName: AnsiString;
    Arguments: TScriptValueArray;
  end;

  TScriptCommandKind = (scModule, scRegister, scAction, scAssertReturn, scAssertTrap, scAssertExhaustion,
    scAssertInvalid, scAssertMalformed, scAssertUnlinkable, scAssertUninstantiable);

  TScriptCommand = class
  public
    Kind: TScriptCommandKind;
    Line: Integer;
    { The module of scModule, the assert_invalid / malformed / unlinkable
      / uninstantiable forms, and of assert_trap when HasModule. }
    Module: TScriptModule;
    HasModule: Boolean;
    Action: TScriptAction;
    Expected: TScriptValueArray;
    Message: AnsiString;
    { register: the import name and the module ('' for the current). }
    RegisterAs, RegisterModule: AnsiString;
  end;

  TScriptCommandList = specialize TFPGObjectList<TScriptCommand>;

{ The commands of a whole .wast file; raises EWasmTextError when the
  script itself (outside quoted modules) is malformed. }
function ParseScript(const Text: AnsiString): TScriptCommandList;
{ A module in text ("(module ...)" or bare fields) into binary. }
function EncodeModuleText(const Text: AnsiString): TBytes;
{ One constant ("(i32.const 1)" and so on) as a script value. }
function ParseScriptValue(Node: TTextNode; AllowPatterns: Boolean): TScriptValue;

implementation

uses
  WasmText.Numbers,
  WasmText.Module,
  WasmText.Encoder;

procedure Fail(Node: TTextNode; const Message: AnsiString);
begin
  raise EWasmTextError.CreateFmt('line %d: %s', [Node.Line, Message]);
end;

function EncodeModuleText(const Text: AnsiString): TBytes;
begin
  Result := WasmText.Encoder.EncodeModuleText(Text);
end;

function NanPatternOf(const Text: AnsiString): TScriptNanPattern;
begin
  if Text = 'nan:canonical' then
    Result := npCanonical
  else if Text = 'nan:arithmetic' then
    Result := npArithmetic
  else
    Result := npNone;
end;

function ConstantText(Node: TTextNode; Index: Integer): AnsiString;
begin
  if (Index >= Node.Count) or not (Node[Index].IsAtomOf(ttNumber) or Node[Index].IsAtomOf(ttKeyword)) then
    Fail(Node, 'unexpected token: expected a constant');
  Result := Node[Index].Text;
end;

procedure ParseVectorValue(Node: TTextNode; AllowPatterns: Boolean; var Value: TScriptValue);
var
  Shape, Text: AnsiString;
  LaneCount, LaneBits, Lane, BitOffset: Integer;
  LaneValue: QWord;
  Pattern: TScriptNanPattern;
begin
  Shape := ConstantText(Node, 1);
  if Shape = 'i8x16' then begin Value.Shape := lsI8; LaneCount := 16; LaneBits := 8; end
  else if Shape = 'i16x8' then begin Value.Shape := lsI16; LaneCount := 8; LaneBits := 16; end
  else if Shape = 'i32x4' then begin Value.Shape := lsI32; LaneCount := 4; LaneBits := 32; end
  else if Shape = 'i64x2' then begin Value.Shape := lsI64; LaneCount := 2; LaneBits := 64; end
  else if Shape = 'f32x4' then begin Value.Shape := lsF32; LaneCount := 4; LaneBits := 32; end
  else if Shape = 'f64x2' then begin Value.Shape := lsF64; LaneCount := 2; LaneBits := 64; end
  else
  begin
    Fail(Node, 'unexpected token: unknown vector shape ' + Shape);
    Exit;
  end;
  if Node.Count <> LaneCount + 2 then
    Fail(Node, 'wrong number of lane literals');
  for Lane := 0 to LaneCount - 1 do
  begin
    Text := ConstantText(Node, Lane + 2);
    LaneValue := 0;
    Pattern := npNone;
    if Shape[1] = 'f' then
    begin
      if AllowPatterns then
        Pattern := NanPatternOf(Text);
      if Pattern <> npNone then
        Value.LaneNan[Lane] := Pattern
      else if LaneBits = 32 then
        LaneValue := ParseFloatBits(Text, fpSingle)
      else
        LaneValue := ParseFloatBits(Text, fpDouble);
    end
    else
      LaneValue := ParseIntegerBits(Text, LaneBits);
    BitOffset := Lane * LaneBits;
    if LaneBits < 64 then
      LaneValue := LaneValue and ((QWord(1) shl LaneBits) - 1);
    Value.Bits[BitOffset div 64] := Value.Bits[BitOffset div 64] or (LaneValue shl (BitOffset mod 64));
  end;
end;

function ParseScriptValue(Node: TTextNode; AllowPatterns: Boolean): TScriptValue;
var
  Head, Text: AnsiString;
begin
  Result := Default(TScriptValue);
  Head := Node.Head;
  if (Head = 'i32.const') or (Head = 'i64.const') or (Head = 'f32.const') or (Head = 'f64.const') then
  begin
    if Node.Count <> 2 then
      Fail(Node, 'unexpected token in constant');
    Text := ConstantText(Node, 1);
    if Head = 'i32.const' then
    begin
      Result.Kind := svI32;
      Result.Bits[0] := ParseIntegerBits(Text, 32);
    end
    else if Head = 'i64.const' then
    begin
      Result.Kind := svI64;
      Result.Bits[0] := ParseIntegerBits(Text, 64);
    end
    else
    begin
      if Head = 'f32.const' then
        Result.Kind := svF32
      else
        Result.Kind := svF64;
      if AllowPatterns then
        Result.Nan := NanPatternOf(Text);
      if Result.Nan = npNone then
      begin
        if Result.Kind = svF32 then
          Result.Bits[0] := ParseFloatBits(Text, fpSingle)
        else
          Result.Bits[0] := ParseFloatBits(Text, fpDouble);
      end;
    end;
  end
  else if Head = 'v128.const' then
  begin
    Result.Kind := svV128;
    ParseVectorValue(Node, AllowPatterns, Result);
  end
  else if Head = 'ref.null' then
  begin
    Result.Kind := svRefNull;
    if (Node.Count <> 2) then
      Fail(Node, 'unexpected token in ref.null');
    if Node[1].IsKeyword('func') then
      Result.HeapKind := shFunc
    else if Node[1].IsKeyword('extern') then
      Result.HeapKind := shExtern
    else
      Fail(Node, 'unexpected token: unknown heap type');
  end
  else if (Head = 'ref.extern') or (Head = 'ref.func') then
  begin
    if Head = 'ref.extern' then
      Result.Kind := svRefExtern
    else
      Result.Kind := svRefFunc;
    if Node.Count = 1 then
    begin
      if not AllowPatterns then
        Fail(Node, 'unexpected token: reference needs a number');
      Result.AnyReference := True;
    end
    else if Node.Count = 2 then
      Result.Bits[0] := ParseUnsigned(ConstantText(Node, 1), 64)
    else
      Fail(Node, 'unexpected token in reference');
  end
  else
    Fail(Node, 'unexpected token: unknown constant ' + Head);
end;

function ParseModule(Node: TTextNode): TScriptModule;
var
  Position: Integer;
begin
  Result := Default(TScriptModule);
  if not Node.IsListOf('module') then
    Fail(Node, 'unexpected token: expected a module');
  Position := 1;
  if (Position < Node.Count) and Node[Position].IsAtomOf(ttIdentifier) then
  begin
    Result.Name := Node[Position].Text;
    Inc(Position);
  end;
  Result.IsBinary := (Position < Node.Count) and Node[Position].IsKeyword('binary');
  Result.IsQuote := (Position < Node.Count) and Node[Position].IsKeyword('quote');
  try
    Result.Bytes := EncodeModuleNode(Node, Result.Name);
  except
    on Error: EWasmTextError do
    begin
      Result.Bytes := nil;
      Result.EncodeError := Error.Message;
      if Result.EncodeError = '' then
        Result.EncodeError := 'malformed';
    end;
  end;
end;

function ParseAction(Node: TTextNode): TScriptAction;
var
  Position: Integer;
begin
  Result := Default(TScriptAction);
  if Node.IsListOf('invoke') then
    Result.Kind := saInvoke
  else if Node.IsListOf('get') then
    Result.Kind := saGet
  else
    Fail(Node, 'unexpected token: expected an action');
  Position := 1;
  if (Position < Node.Count) and Node[Position].IsAtomOf(ttIdentifier) then
  begin
    Result.ModuleName := Node[Position].Text;
    Inc(Position);
  end;
  if (Position >= Node.Count) or not Node[Position].IsAtomOf(ttString) then
    Fail(Node, 'unexpected token: expected an export name');
  Result.FieldName := Node[Position].Text;
  Inc(Position);
  if (Result.Kind = saGet) and (Position < Node.Count) then
    Fail(Node, 'unexpected token in get');
  while Position < Node.Count do
  begin
    SetLength(Result.Arguments, Length(Result.Arguments) + 1);
    Result.Arguments[High(Result.Arguments)] := ParseScriptValue(Node[Position], False);
    Inc(Position);
  end;
end;

function MessageOf(Node: TTextNode; Index: Integer): AnsiString;
begin
  if (Index <> Node.Count - 1) or not Node[Index].IsAtomOf(ttString) then
    Fail(Node, 'unexpected token: expected a message');
  Result := Node[Index].Text;
end;

function ParseCommand(Node: TTextNode): TScriptCommand;
var
  Head: AnsiString;
  Index: Integer;
begin
  if Node.Kind <> tnList then
    Fail(Node, 'unexpected token ' + Node.Text);
  Head := Node.Head;
  Result := TScriptCommand.Create;
  try
    Result.Line := Node.Line;
    if Head = 'module' then
    begin
      Result.Kind := scModule;
      Result.Module := ParseModule(Node);
      Result.HasModule := True;
    end
    else if Head = 'register' then
    begin
      Result.Kind := scRegister;
      if (Node.Count < 2) or (Node.Count > 3) or not Node[1].IsAtomOf(ttString) then
        Fail(Node, 'unexpected token in register');
      Result.RegisterAs := Node[1].Text;
      if Node.Count = 3 then
      begin
        if not Node[2].IsAtomOf(ttIdentifier) then
          Fail(Node, 'unexpected token in register');
        Result.RegisterModule := Node[2].Text;
      end;
    end
    else if (Head = 'invoke') or (Head = 'get') then
    begin
      Result.Kind := scAction;
      Result.Action := ParseAction(Node);
    end
    else if Head = 'assert_return' then
    begin
      Result.Kind := scAssertReturn;
      if Node.Count < 2 then
        Fail(Node, 'unexpected token in assert_return');
      Result.Action := ParseAction(Node[1]);
      SetLength(Result.Expected, Node.Count - 2);
      for Index := 2 to Node.Count - 1 do
        Result.Expected[Index - 2] := ParseScriptValue(Node[Index], True);
    end
    else if (Head = 'assert_trap') or (Head = 'assert_exhaustion') then
    begin
      if Head = 'assert_trap' then
        Result.Kind := scAssertTrap
      else
        Result.Kind := scAssertExhaustion;
      if Node.Count <> 3 then
        Fail(Node, 'unexpected token in ' + Head);
      if Node[1].IsListOf('module') then
      begin
        Result.HasModule := True;
        Result.Module := ParseModule(Node[1]);
      end
      else
        Result.Action := ParseAction(Node[1]);
      Result.Message := MessageOf(Node, 2);
    end
    else if (Head = 'assert_invalid') or (Head = 'assert_malformed') or (Head = 'assert_unlinkable') or
            (Head = 'assert_uninstantiable') then
    begin
      if Head = 'assert_invalid' then Result.Kind := scAssertInvalid
      else if Head = 'assert_malformed' then Result.Kind := scAssertMalformed
      else if Head = 'assert_unlinkable' then Result.Kind := scAssertUnlinkable
      else Result.Kind := scAssertUninstantiable;
      if Node.Count <> 3 then
        Fail(Node, 'unexpected token in ' + Head);
      Result.HasModule := True;
      Result.Module := ParseModule(Node[1]);
      Result.Message := MessageOf(Node, 2);
    end
    else
      Fail(Node, 'unexpected token: unknown command ' + Head);
  except
    Result.Free;
    raise;
  end;
end;

function IsModuleField(Node: TTextNode): Boolean;
var
  Head: AnsiString;
begin
  Head := Node.Head;
  Result := (Head = 'type') or (Head = 'import') or (Head = 'func') or (Head = 'table') or
    (Head = 'memory') or (Head = 'global') or (Head = 'export') or (Head = 'start') or
    (Head = 'elem') or (Head = 'data');
end;

{ A script that is just module fields is one module (the text format's
  abbreviation for a module alone in its file). }
function ParseInlineModule(Tree: TTextNode): TScriptCommand;
begin
  Result := TScriptCommand.Create;
  Result.Kind := scModule;
  Result.Line := Tree.Line;
  Result.HasModule := True;
  try
    Result.Module.Bytes := EncodeModuleFields(Tree, 0);
  except
    on Error: EWasmTextError do
      Result.Module.EncodeError := Error.Message;
  end;
end;

function ParseScript(const Text: AnsiString): TScriptCommandList;
var
  Tree: TTextNode;
  Index: Integer;
begin
  Result := TScriptCommandList.Create(True);
  try
    Tree := ParseTextTree(Text);
    try
      if (Tree.Count > 0) and IsModuleField(Tree[0]) then
        Result.Add(ParseInlineModule(Tree))
      else
        for Index := 0 to Tree.Count - 1 do
          Result.Add(ParseCommand(Tree[Index]));
    finally
      Tree.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
