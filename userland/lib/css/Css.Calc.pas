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
  Math functions (CSS Values and Units Level 4, section 10): calc(),
  min(), max(), clamp(), round(), mod(), rem(), abs(), sign(), the
  trigonometric and exponential functions, and the constants e, pi,
  infinity, -infinity and NaN.

  Parsing builds a calculation tree and checks its type (exponents of
  length, angle, time, frequency, resolution, flex and percent; a
  property that resolves percentages against lengths parses them as
  lengths but keeps the leaves as percentages). The tree is simplified
  as the spec describes: same-unit terms of a sum are combined,
  absolute units converted to their canonical unit, functions of
  plain numbers evaluated.

  Evaluation resolves leaves through a callback (relative lengths,
  percentages) and computes in canonical units (px, deg, s, Hz, dppx).
}
unit Css.Calc;

{$mode objfpc}
{$H+}

interface

uses
  Css.Tokens, Css.Units, Css.Keywords;

type
  TCssCalcKind = (ckLeaf, ckSum, ckProduct, ckNegate, ckInvert, ckMin, ckMax, ckClamp,
    ckRound, ckMod, ckRem, ckAbs, ckSign, ckSin, ckCos, ckTan, ckAsin, ckAcos, ckAtan,
    ckAtan2, ckPow, ckSqrt, ckHypot, ckLog, ckExp);

  TCssCalcBase = (cbLength, cbAngle, cbTime, cbFrequency, cbResolution, cbFlex, cbPercent);
  TCssCalcType = record
    Exponents: array[TCssCalcBase] of ShortInt;
    Valid: Boolean;
  end;

  TCssCalcNode = class
  public
    Kind: TCssCalcKind;
    Value: Double;
    UnitValue: TCssUnit;
    { round()'s strategy: kwNearest, kwUp, kwDown, kwToZero. }
    Strategy: TCssKeyword;
    Children: array of TCssCalcNode;
    constructor CreateLeaf(AValue: Double; AUnit: TCssUnit);
    constructor CreateNode(AKind: TCssCalcKind);
    destructor Destroy; override;
    procedure AddChild(Child: TCssCalcNode);
    function Clone: TCssCalcNode;
    function IsLeaf: Boolean; inline;
    { Whether any leaf is a percentage / a relative length. }
    function HasPercentage: Boolean;
    function HasRelativeLength: Boolean;
  end;

  { Turns a leaf into a canonical number (px, deg, s, Hz, dppx, or the
    resolved percentage). Data is the caller's. }
  TCssCalcLeafResolver = function(Value: Double; UnitValue: TCssUnit; Data: Pointer): Double;

{ Whether a function token starts a math function. }
function IsMathFunction(const Name: string): Boolean;
{ Parses the math function at Cursor (a function token), consuming it.
  Expected is what the property takes; PercentAs is what percentages
  resolve against there (ucPercent when they stay percentages, ucNumber
  when they are not allowed). Returns nil when invalid. }
function ParseMathFunction(var Cursor: TCssTokenCursor; Expected, PercentAs: TCssUnitCategory): TCssCalcNode;
procedure SimplifyCalc(var Node: TCssCalcNode);
function EvaluateCalc(Node: TCssCalcNode; Resolver: TCssCalcLeafResolver; Data: Pointer): Double;
{ The specified value form: calc(...) around sums, products and single values. }
function SerializeCalc(Node: TCssCalcNode): string;
{ A copy whose relative length leaves are converted (by Resolver) to
  px, simplified. Percentages stay. }
function AbsolutizeCalc(Node: TCssCalcNode; Resolver: TCssCalcLeafResolver; Data: Pointer): TCssCalcNode;
{ For a tree that is a px leaf, a percent leaf, or a sum of exactly
  those: the two parts. }
function CalcAsLengthPercentage(Node: TCssCalcNode; out Pixels, Percent: Double): Boolean;

implementation

uses
  Math, SysUtils, Css.Atoms, Css.Serialization;

const
  FunctionNames: array[ckMin..ckExp] of string = ('min', 'max', 'clamp', 'round', 'mod', 'rem',
    'abs', 'sign', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'atan2', 'pow', 'sqrt', 'hypot',
    'log', 'exp');

type
  TCalcParser = record
    PercentAs: TCssUnitCategory;
    Failed: Boolean;
  end;

constructor TCssCalcNode.CreateLeaf(AValue: Double; AUnit: TCssUnit);
begin
  inherited Create;
  Kind := ckLeaf;
  Value := AValue;
  UnitValue := AUnit;
end;

constructor TCssCalcNode.CreateNode(AKind: TCssCalcKind);
begin
  inherited Create;
  Kind := AKind;
  Strategy := kwNearest;
end;

destructor TCssCalcNode.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to High(Children) do
    Children[Index].Free;
  inherited Destroy;
end;

procedure TCssCalcNode.AddChild(Child: TCssCalcNode);
begin
  SetLength(Children, Length(Children) + 1);
  Children[High(Children)] := Child;
end;

function TCssCalcNode.Clone: TCssCalcNode;
var
  Index: Integer;
begin
  Result := TCssCalcNode.CreateNode(Kind);
  Result.Value := Value;
  Result.UnitValue := UnitValue;
  Result.Strategy := Strategy;
  SetLength(Result.Children, Length(Children));
  for Index := 0 to High(Children) do
    Result.Children[Index] := Children[Index].Clone;
end;

function TCssCalcNode.IsLeaf: Boolean;
begin
  Result := Kind = ckLeaf;
end;

function TCssCalcNode.HasPercentage: Boolean;
var
  Index: Integer;
begin
  if Kind = ckLeaf then
    Exit(UnitValue = cuPercent);
  for Index := 0 to High(Children) do
    if Children[Index].HasPercentage then
      Exit(True);
  Result := False;
end;

function TCssCalcNode.HasRelativeLength: Boolean;
var
  Index: Integer;
begin
  if Kind = ckLeaf then
    Exit(UnitValue in [FirstRelativeLength..LastRelativeLength]);
  for Index := 0 to High(Children) do
    if Children[Index].HasRelativeLength then
      Exit(True);
  Result := False;
end;

function IsMathFunction(const Name: string): Boolean;
var
  Lower: string;
  Kind: TCssCalcKind;
begin
  Lower := AsciiLowercase(Name);
  if (Lower = 'calc') or (Lower = '-webkit-calc') then
    Exit(True);
  for Kind := Low(FunctionNames) to High(FunctionNames) do
    if FunctionNames[Kind] = Lower then
      Exit(True);
  Result := False;
end;

{ ---- types ---- }

function NumberType: TCssCalcType;
begin
  Result := Default(TCssCalcType);
  Result.Valid := True;
end;

function InvalidType: TCssCalcType;
begin
  Result := Default(TCssCalcType);
  Result.Valid := False;
end;

function TypeOfBase(Base: TCssCalcBase): TCssCalcType;
begin
  Result := NumberType;
  Result.Exponents[Base] := 1;
end;

function SameType(const A, B: TCssCalcType): Boolean;
var
  Base: TCssCalcBase;
begin
  if not (A.Valid and B.Valid) then
    Exit(False);
  for Base := Low(TCssCalcBase) to High(TCssCalcBase) do
    if A.Exponents[Base] <> B.Exponents[Base] then
      Exit(False);
  Result := True;
end;

function IsNumberType(const A: TCssCalcType): Boolean;
begin
  Result := SameType(A, NumberType);
end;

function CategoryBase(Category: TCssUnitCategory; out Base: TCssCalcBase): Boolean;
begin
  Result := True;
  case Category of
    ucLength: Base := cbLength;
    ucAngle: Base := cbAngle;
    ucTime: Base := cbTime;
    ucFrequency: Base := cbFrequency;
    ucResolution: Base := cbResolution;
    ucFlex: Base := cbFlex;
    ucPercent: Base := cbPercent;
  else
    Result := False;
  end;
end;

function LeafType(const Parser: TCalcParser; UnitValue: TCssUnit): TCssCalcType;
var
  Category: TCssUnitCategory;
  Base: TCssCalcBase;
begin
  Category := UnitCategory(UnitValue);
  if Category = ucPercent then
  begin
    if Parser.PercentAs = ucNumber then
      Exit(InvalidType);
    Category := Parser.PercentAs;
  end;
  if CategoryBase(Category, Base) then
    Result := TypeOfBase(Base)
  else
    Result := NumberType;
end;

function TypeOf(const Parser: TCalcParser; Node: TCssCalcNode): TCssCalcType;
var
  Index: Integer;
  Child: TCssCalcType;
  Base: TCssCalcBase;
begin
  case Node.Kind of
    ckLeaf: Result := LeafType(Parser, Node.UnitValue);
    ckSum, ckMin, ckMax, ckClamp, ckHypot, ckRound, ckMod, ckRem:
      begin
        Result := TypeOf(Parser, Node.Children[0]);
        for Index := 1 to High(Node.Children) do
          if not SameType(Result, TypeOf(Parser, Node.Children[Index])) then
            Exit(InvalidType);
      end;
    ckNegate, ckAbs: Result := TypeOf(Parser, Node.Children[0]);
    ckInvert:
      begin
        Result := TypeOf(Parser, Node.Children[0]);
        for Base := Low(TCssCalcBase) to High(TCssCalcBase) do
          Result.Exponents[Base] := -Result.Exponents[Base];
      end;
    ckProduct:
      begin
        Result := NumberType;
        for Index := 0 to High(Node.Children) do
        begin
          Child := TypeOf(Parser, Node.Children[Index]);
          if not Child.Valid then
            Exit(InvalidType);
          for Base := Low(TCssCalcBase) to High(TCssCalcBase) do
            Inc(Result.Exponents[Base], Child.Exponents[Base]);
        end;
      end;
    ckSign:
      if TypeOf(Parser, Node.Children[0]).Valid then
        Result := NumberType
      else
        Result := InvalidType;
    ckSin, ckCos, ckTan:
      begin
        Child := TypeOf(Parser, Node.Children[0]);
        if IsNumberType(Child) or SameType(Child, TypeOfBase(cbAngle)) then
          Result := NumberType
        else
          Result := InvalidType;
      end;
    ckAsin, ckAcos, ckAtan:
      if IsNumberType(TypeOf(Parser, Node.Children[0])) then
        Result := TypeOfBase(cbAngle)
      else
        Result := InvalidType;
    ckAtan2:
      if SameType(TypeOf(Parser, Node.Children[0]), TypeOf(Parser, Node.Children[1])) then
        Result := TypeOfBase(cbAngle)
      else
        Result := InvalidType;
    ckPow, ckSqrt, ckLog, ckExp:
      begin
        Result := NumberType;
        for Index := 0 to High(Node.Children) do
          if not IsNumberType(TypeOf(Parser, Node.Children[Index])) then
            Exit(InvalidType);
      end;
  else
    Result := InvalidType;
  end;
end;

{ ---- parsing ---- }

function ParseSum(var Parser: TCalcParser; Cursor: TCssTokenCursor): TCssCalcNode; forward;
function ParseFunctionBody(var Parser: TCalcParser; Token: PCssToken; Contents: TCssTokenCursor): TCssCalcNode; forward;

function ParseValue(var Parser: TCalcParser; var Cursor: TCssTokenCursor): TCssCalcNode;
var
  Token: PCssToken;
  UnitValue: TCssUnit;
  Lower: string;
begin
  Result := nil;
  Cursor.SkipWhitespace;
  Token := Cursor.Next;
  case Token^.Kind of
    tkNumber: Result := TCssCalcNode.CreateLeaf(Token^.Number, cuNone);
    tkPercentage: Result := TCssCalcNode.CreateLeaf(Token^.Number, cuPercent);
    tkDimension:
      begin
        UnitValue := UnitByName(Token^.Text);
        if UnitValue = cuNone then
          Parser.Failed := True
        else
          Result := TCssCalcNode.CreateLeaf(Token^.Number, UnitValue);
      end;
    tkIdent:
      begin
        Lower := AsciiLowercase(Token^.Text);
        if Lower = 'e' then Result := TCssCalcNode.CreateLeaf(Exp(1), cuNone)
        else if Lower = 'pi' then Result := TCssCalcNode.CreateLeaf(Pi, cuNone)
        else if Lower = 'infinity' then Result := TCssCalcNode.CreateLeaf(Infinity, cuNone)
        else if Lower = '-infinity' then Result := TCssCalcNode.CreateLeaf(NegInfinity, cuNone)
        else if Lower = 'nan' then Result := TCssCalcNode.CreateLeaf(NaN, cuNone)
        else
          Parser.Failed := True;
      end;
    tkOpenParen:
      Result := ParseSum(Parser, Cursor.Contents(Token));
    tkFunction:
      if IsMathFunction(Token^.Text) then
        Result := ParseFunctionBody(Parser, Token, Cursor.Contents(Token))
      else
        Parser.Failed := True;
  else
    Parser.Failed := True;
  end;
  if Parser.Failed then
    FreeAndNil(Result);
end;

function ParseProduct(var Parser: TCalcParser; var Cursor: TCssTokenCursor): TCssCalcNode;
var
  Operand, Inverted: TCssCalcNode;
  Token: PCssToken;
  Saved: Integer;
begin
  Result := ParseValue(Parser, Cursor);
  if Result = nil then
    Exit;
  repeat
    Saved := Cursor.Position;
    Cursor.SkipWhitespace;
    Token := Cursor.Peek;
    if (Token^.Kind <> tkDelim) or ((Token^.Text <> '*') and (Token^.Text <> '/')) then
    begin
      Cursor.Position := Saved;
      Break;
    end;
    Inc(Cursor.Position);
    Operand := ParseValue(Parser, Cursor);
    if Operand = nil then
    begin
      FreeAndNil(Result);
      Exit;
    end;
    if Token^.Text = '/' then
    begin
      Inverted := TCssCalcNode.CreateNode(ckInvert);
      Inverted.AddChild(Operand);
      Operand := Inverted;
    end;
    if Result.Kind <> ckProduct then
    begin
      Inverted := TCssCalcNode.CreateNode(ckProduct);
      Inverted.AddChild(Result);
      Result := Inverted;
    end;
    Result.AddChild(Operand);
  until False;
end;

function ParseSum(var Parser: TCalcParser; Cursor: TCssTokenCursor): TCssCalcNode;
var
  Operand, Negated, Sum: TCssCalcNode;
  Token: PCssToken;
begin
  Result := ParseProduct(Parser, Cursor);
  if Result = nil then
    Exit;
  repeat
    if Cursor.AtEndIgnoringWhitespace then
      Break;
    { + and - need whitespace on both sides. }
    if Cursor.Tokens[Cursor.Position - 1].Kind <> tkWhitespace then
    begin
      Parser.Failed := True;
      Break;
    end;
    Token := Cursor.Next;
    if (Token^.Kind <> tkDelim) or ((Token^.Text <> '+') and (Token^.Text <> '-')) or
      (Cursor.PeekKind <> tkWhitespace) then
    begin
      Parser.Failed := True;
      Break;
    end;
    Operand := ParseProduct(Parser, Cursor);
    if Operand = nil then
    begin
      Parser.Failed := True;
      Break;
    end;
    if Token^.Text = '-' then
    begin
      Negated := TCssCalcNode.CreateNode(ckNegate);
      Negated.AddChild(Operand);
      Operand := Negated;
    end;
    if Result.Kind <> ckSum then
    begin
      Sum := TCssCalcNode.CreateNode(ckSum);
      Sum.AddChild(Result);
      Result := Sum;
    end;
    Result.AddChild(Operand);
  until False;
  if Parser.Failed then
    FreeAndNil(Result);
end;

{ The comma separated arguments of a math function, each a sum. }
function ParseArguments(var Parser: TCalcParser; Contents: TCssTokenCursor; Node: TCssCalcNode): Boolean;
var
  Start: Integer;
  Token: PCssToken;
  Argument: TCssCalcNode;
  Finished: Boolean;
begin
  Result := False;
  Start := Contents.Position;
  repeat
    Finished := Contents.AtEnd;
    if not Finished then
    begin
      Token := Contents.Next;
      if Token^.Kind <> tkComma then
        Continue;
    end;
    if Finished then
      Argument := ParseSum(Parser, TCssTokenCursor.CreateRange(Contents.Tokens, Start, Contents.Stop))
    else
      Argument := ParseSum(Parser, TCssTokenCursor.CreateRange(Contents.Tokens, Start, Contents.Position - 1));
    if Argument = nil then
      Exit;
    Node.AddChild(Argument);
    Start := Contents.Position;
  until Finished;
  Result := True;
end;

function ParseFunctionBody(var Parser: TCalcParser; Token: PCssToken; Contents: TCssTokenCursor): TCssCalcNode;
var
  Lower: string;
  Kind: TCssCalcKind;
  Count: Integer;
  Strategy: TCssKeyword;
  Saved: Integer;
  First: PCssToken;
begin
  Result := nil;
  Lower := AsciiLowercase(Token^.Text);
  if (Lower = 'calc') or (Lower = '-webkit-calc') then
  begin
    Result := ParseSum(Parser, Contents);
    Exit;
  end;
  Kind := ckLeaf;
  for Kind := Low(FunctionNames) to High(FunctionNames) do
    if FunctionNames[Kind] = Lower then
      Break;
  Result := TCssCalcNode.CreateNode(Kind);
  if Kind = ckRound then
  begin
    { An optional rounding strategy first. }
    Saved := Contents.Position;
    First := Contents.NextNonWhitespace;
    Strategy := kwInvalid;
    if First^.Kind = tkIdent then
      Strategy := KeywordOfAtom(FindAtom(AsciiLowercase(First^.Text)));
    if KeywordIn(Strategy, [kwNearest, kwUp, kwDown, kwToZero]) and
      (Contents.NextNonWhitespace^.Kind = tkComma) then
      Result.Strategy := Strategy
    else
      Contents.Position := Saved;
  end;
  if not ParseArguments(Parser, Contents, Result) then
  begin
    FreeAndNil(Result);
    Exit;
  end;
  Count := Length(Result.Children);
  case Kind of
    ckMin, ckMax, ckHypot: Parser.Failed := Count < 1;
    ckClamp: Parser.Failed := Count <> 3;
    ckRound: Parser.Failed := (Count < 1) or (Count > 2);
    ckMod, ckRem, ckAtan2, ckPow: Parser.Failed := Count <> 2;
    ckLog: Parser.Failed := (Count < 1) or (Count > 2);
  else
    Parser.Failed := Count <> 1;
  end;
  if Parser.Failed then
    FreeAndNil(Result);
end;

{ ---- simplification and evaluation ---- }

function CanonicalLeaf(Node: TCssCalcNode): Boolean;
var
  Factor: Double;
begin
  Result := False;
  if Node.Kind <> ckLeaf then
    Exit;
  if Node.UnitValue in [FirstRelativeLength..LastRelativeLength] then
    Exit;
  Factor := CanonicalFactor(Node.UnitValue);
  if Factor = 0 then
    Exit;
  Node.Value := Node.Value * Factor;
  Node.UnitValue := CanonicalUnit(UnitCategory(Node.UnitValue));
  Result := True;
end;

function AllLeavesSameUnit(Node: TCssCalcNode): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Node.Children) do
    if not Node.Children[Index].IsLeaf or (Node.Children[Index].UnitValue <> Node.Children[0].UnitValue) then
      Exit(False);
  Result := Length(Node.Children) > 0;
end;

function RoundValue(Strategy: TCssKeyword; A, B: Double): Double;
var
  Lower, Upper: Double;
begin
  if B = 0 then
    Exit(NaN);
  if IsInfinite(A) then
    Exit(A);
  Lower := Floor(A / B) * B;
  Upper := Ceil(A / B) * B;
  case Strategy of
    kwUp: Result := Upper;
    kwDown: Result := Lower;
    kwToZero:
      if A >= 0 then Result := Lower else Result := Upper;
  else
    if Abs(A - Lower) < Abs(Upper - A) then
      Result := Lower
    else
      Result := Upper;
  end;
end;

{ The value of a node whose leaves are canonical numbers. }
function ComputeUnguarded(const Values: array of Double; Kind: TCssCalcKind; Strategy: TCssKeyword): Double;
var
  Index: Integer;
begin
  case Kind of
    ckSum:
      begin
        Result := 0;
        for Index := 0 to High(Values) do
          Result := Result + Values[Index];
      end;
    ckProduct:
      begin
        Result := 1;
        for Index := 0 to High(Values) do
          Result := Result * Values[Index];
      end;
    ckNegate: Result := -Values[0];
    ckInvert:
      if Values[0] = 0 then
        Result := Infinity
      else
        Result := 1 / Values[0];
    ckMin:
      begin
        Result := Values[0];
        for Index := 1 to High(Values) do
          if Values[Index] < Result then
            Result := Values[Index];
      end;
    ckMax:
      begin
        Result := Values[0];
        for Index := 1 to High(Values) do
          if Values[Index] > Result then
            Result := Values[Index];
      end;
    ckClamp:
      begin
        Result := Values[1];
        if Result > Values[2] then
          Result := Values[2];
        if Result < Values[0] then
          Result := Values[0];
      end;
    ckRound:
      if Length(Values) = 2 then
        Result := RoundValue(Strategy, Values[0], Values[1])
      else
        Result := RoundValue(Strategy, Values[0], 1);
    ckMod:
      if Values[1] = 0 then
        Result := NaN
      else
        Result := Values[0] - Values[1] * Floor(Values[0] / Values[1]);
    ckRem:
      if Values[1] = 0 then
        Result := NaN
      else
        Result := Values[0] - Values[1] * Trunc(Values[0] / Values[1]);
    ckAbs: Result := Abs(Values[0]);
    ckSign: Result := Sign(Values[0]);
    ckSin: Result := Sin(Values[0]);
    ckCos: Result := Cos(Values[0]);
    ckTan: Result := Tan(Values[0]);
    ckAsin: Result := RadToDeg(ArcSin(Values[0]));
    ckAcos: Result := RadToDeg(ArcCos(Values[0]));
    ckAtan: Result := RadToDeg(ArcTan(Values[0]));
    ckAtan2: Result := RadToDeg(ArcTan2(Values[0], Values[1]));
    ckPow: Result := Power(Values[0], Values[1]);
    ckSqrt: Result := Sqrt(Values[0]);
    ckHypot:
      begin
        Result := 0;
        for Index := 0 to High(Values) do
          Result := Result + Sqr(Values[Index]);
        Result := Sqrt(Result);
      end;
    ckLog:
      if Length(Values) = 2 then
        Result := Ln(Values[0]) / Ln(Values[1])
      else
        Result := Ln(Values[0]);
    ckExp: Result := Exp(Values[0]);
  else
    Result := 0;
  end;
end;

{ Floating point exceptions are enabled in user mode: a domain error
  is NaN, as the spec has it. }
function Compute(Node: TCssCalcNode; const Values: array of Double; Kind: TCssCalcKind; Strategy: TCssKeyword): Double;
begin
  try
    Result := ComputeUnguarded(Values, Kind, Strategy);
  except
    on EMathError do
      Result := NaN;
  end;
end;

{ The trigonometric functions take radians; angle leaves are degrees. }
function TrigonometricArgument(Node: TCssCalcNode; Value: Double): Double;
begin
  if (Node.Kind in [ckSin, ckCos, ckTan]) and (Node.Children[0].IsLeaf) and
    (UnitCategory(Node.Children[0].UnitValue) = ucAngle) then
    Result := DegToRad(Value)
  else
    Result := Value;
end;

procedure ReplaceWithLeaf(var Node: TCssCalcNode; Value: Double; UnitValue: TCssUnit);
begin
  Node.Free;
  Node := TCssCalcNode.CreateLeaf(Value, UnitValue);
end;

procedure SimplifyCalc(var Node: TCssCalcNode);
var
  Index, Other: Integer;
  Values: array of Double;
  Child, Inner: TCssCalcNode;
  ResultUnit: TCssUnit;
  Merged: array of TCssCalcNode;
begin
  if Node.Kind = ckLeaf then
  begin
    CanonicalLeaf(Node);
    Exit;
  end;
  for Index := 0 to High(Node.Children) do
    SimplifyCalc(Node.Children[Index]);
  case Node.Kind of
    ckNegate:
      if Node.Children[0].IsLeaf then
      begin
        Child := Node.Children[0];
        Node.Children := nil;
        Node.Free;
        Child.Value := -Child.Value;
        Node := Child;
      end
      else if Node.Children[0].Kind = ckNegate then
      begin
        Child := Node.Children[0].Children[0];
        Node.Children[0].Children := nil;
        Node.Free;
        Node := Child;
      end;
    ckInvert:
      if Node.Children[0].IsLeaf and (Node.Children[0].UnitValue = cuNone) then
        ReplaceWithLeaf(Node, Compute(Node, [Node.Children[0].Value], ckInvert, kwInvalid), cuNone);
    ckSum:
      begin
        { Flatten nested sums, then combine leaves of one unit. }
        Merged := nil;
        for Index := 0 to High(Node.Children) do
        begin
          Child := Node.Children[Index];
          if Child.Kind = ckSum then
          begin
            for Other := 0 to High(Child.Children) do
            begin
              SetLength(Merged, Length(Merged) + 1);
              Merged[High(Merged)] := Child.Children[Other];
            end;
            Child.Children := nil;
            Child.Free;
          end
          else
          begin
            SetLength(Merged, Length(Merged) + 1);
            Merged[High(Merged)] := Child;
          end;
        end;
        Node.Children := nil;
        for Index := 0 to High(Merged) do
        begin
          Child := Merged[Index];
          if Child = nil then
            Continue;
          if Child.IsLeaf then
            for Other := Index + 1 to High(Merged) do
              if (Merged[Other] <> nil) and Merged[Other].IsLeaf and (Merged[Other].UnitValue = Child.UnitValue) then
              begin
                Child.Value := Child.Value + Merged[Other].Value;
                FreeAndNil(Merged[Other]);
              end;
          Node.AddChild(Child);
        end;
        if Length(Node.Children) = 1 then
        begin
          Child := Node.Children[0];
          Node.Children := nil;
          Node.Free;
          Node := Child;
        end;
      end;
    ckProduct:
      begin
        { Multiply the plain numbers together; one dimension leaf absorbs them. }
        Merged := nil;
        Inner := nil;
        for Index := 0 to High(Node.Children) do
        begin
          Child := Node.Children[Index];
          if Child.IsLeaf and (Child.UnitValue = cuNone) then
          begin
            if Inner = nil then
              Inner := Child
            else
            begin
              Inner.Value := Inner.Value * Child.Value;
              Child.Free;
            end;
          end
          else
          begin
            SetLength(Merged, Length(Merged) + 1);
            Merged[High(Merged)] := Child;
          end;
        end;
        Node.Children := nil;
        if (Inner <> nil) and (Length(Merged) = 1) and Merged[0].IsLeaf then
        begin
          Merged[0].Value := Merged[0].Value * Inner.Value;
          Inner.Free;
          Inner := nil;
        end;
        if (Inner <> nil) and (Length(Merged) = 1) and (Merged[0].Kind = ckSum) then
        begin
          { A number times a sum distributes over it when the sum is all leaves. }
          if AllLeavesSameUnit(Merged[0]) or True then
          begin
            Other := 0;
            for Index := 0 to High(Merged[0].Children) do
              if not Merged[0].Children[Index].IsLeaf then
                Other := 1;
            if Other = 0 then
            begin
              for Index := 0 to High(Merged[0].Children) do
                Merged[0].Children[Index].Value := Merged[0].Children[Index].Value * Inner.Value;
              Inner.Free;
              Inner := nil;
            end;
          end;
        end;
        if Inner <> nil then
          Node.AddChild(Inner);
        for Index := 0 to High(Merged) do
          Node.AddChild(Merged[Index]);
        if Length(Node.Children) = 1 then
        begin
          Child := Node.Children[0];
          Node.Children := nil;
          Node.Free;
          Node := Child;
        end
        else if Length(Node.Children) = 2 then
        begin
          { A dimension divided by the same unit is a number. }
          if Node.Children[0].IsLeaf and (Node.Children[1].Kind = ckInvert) and
            Node.Children[1].Children[0].IsLeaf and
            (Node.Children[0].UnitValue = Node.Children[1].Children[0].UnitValue) and
            (Node.Children[1].Children[0].Value <> 0) then
            ReplaceWithLeaf(Node, Node.Children[0].Value / Node.Children[1].Children[0].Value, cuNone);
        end;
      end;
  else
    { Functions whose arguments all share one unit (or are numbers)
      can be computed now, except where percentages are involved. }
    if AllLeavesSameUnit(Node) and (Node.Children[0].UnitValue <> cuPercent) then
    begin
      SetLength(Values, Length(Node.Children));
      for Index := 0 to High(Node.Children) do
        Values[Index] := TrigonometricArgument(Node, Node.Children[Index].Value);
      ResultUnit := Node.Children[0].UnitValue;
      case Node.Kind of
        ckSign, ckSin, ckCos, ckTan, ckPow, ckSqrt, ckLog, ckExp: ResultUnit := cuNone;
        ckAsin, ckAcos, ckAtan, ckAtan2: ResultUnit := cuDeg;
      end;
      if (Node.Kind in [ckSin, ckCos, ckTan, ckAsin, ckAcos, ckAtan, ckPow, ckSqrt, ckLog, ckExp]) and
        not (Node.Children[0].UnitValue in [cuNone, cuDeg]) then
        Exit;
      ReplaceWithLeaf(Node, Compute(Node, Values, Node.Kind, Node.Strategy), ResultUnit);
    end;
  end;
end;

function EvaluateCalc(Node: TCssCalcNode; Resolver: TCssCalcLeafResolver; Data: Pointer): Double;
var
  Values: array of Double;
  Index: Integer;
begin
  if Node.Kind = ckLeaf then
  begin
    if Node.UnitValue = cuNone then
      Exit(Node.Value);
    if (Resolver <> nil) and ((Node.UnitValue = cuPercent) or
      (Node.UnitValue in [FirstRelativeLength..LastRelativeLength])) then
      Exit(Resolver(Node.Value, Node.UnitValue, Data));
    Exit(Node.Value * CanonicalFactor(Node.UnitValue));
  end;
  SetLength(Values, Length(Node.Children));
  for Index := 0 to High(Node.Children) do
    Values[Index] := TrigonometricArgument(Node, EvaluateCalc(Node.Children[Index], Resolver, Data));
  Result := Compute(Node, Values, Node.Kind, Node.Strategy);
end;

function AbsolutizeCalc(Node: TCssCalcNode; Resolver: TCssCalcLeafResolver; Data: Pointer): TCssCalcNode;
var
  Index: Integer;
begin
  if Node.Kind = ckLeaf then
  begin
    if Node.UnitValue in [FirstRelativeLength..LastRelativeLength] then
      Result := TCssCalcNode.CreateLeaf(Resolver(Node.Value, Node.UnitValue, Data), cuPx)
    else
      Result := TCssCalcNode.CreateLeaf(Node.Value, Node.UnitValue);
    Exit;
  end;
  Result := TCssCalcNode.CreateNode(Node.Kind);
  Result.Strategy := Node.Strategy;
  SetLength(Result.Children, Length(Node.Children));
  for Index := 0 to High(Node.Children) do
    Result.Children[Index] := AbsolutizeCalc(Node.Children[Index], Resolver, Data);
  SimplifyCalc(Result);
end;

function CalcAsLengthPercentage(Node: TCssCalcNode; out Pixels, Percent: Double): Boolean;
var
  Index: Integer;
  Child: TCssCalcNode;
begin
  Pixels := 0;
  Percent := 0;
  if Node.Kind = ckLeaf then
  begin
    case Node.UnitValue of
      cuPx: Pixels := Node.Value;
      cuPercent: Percent := Node.Value;
      cuNone: if Node.Value <> 0 then Exit(False);
    else
      Exit(False);
    end;
    Exit(True);
  end;
  if Node.Kind <> ckSum then
    Exit(False);
  for Index := 0 to High(Node.Children) do
  begin
    Child := Node.Children[Index];
    if not Child.IsLeaf then
      Exit(False);
    case Child.UnitValue of
      cuPx: Pixels := Pixels + Child.Value;
      cuPercent: Percent := Percent + Child.Value;
    else
      Exit(False);
    end;
  end;
  Result := True;
end;

{ ---- serialization ---- }

function SerializeLeafValue(Value: Double; UnitValue: TCssUnit): string;
begin
  if IsNan(Value) then
    Result := 'NaN'
  else if IsInfinite(Value) then
  begin
    if Value > 0 then Result := 'infinity' else Result := '-infinity';
  end
  else
    Result := SerializeNumber(Value);
  if UnitValue <> cuNone then
  begin
    if IsNan(Value) or IsInfinite(Value) then
      Result := Result + ' * 1' + CssUnitName(UnitValue)
    else
      Result := Result + CssUnitName(UnitValue);
  end;
end;

function SortRank(Node: TCssCalcNode): Integer;
begin
  if not Node.IsLeaf then
    Exit(3);
  case Node.UnitValue of
    cuNone: Result := 0;
    cuPercent: Result := 1;
  else
    Result := 2;
  end;
end;

function SerializeInner(Node: TCssCalcNode; InProduct: Boolean): string; forward;

function SerializeSum(Node: TCssCalcNode): string;
var
  Order: array of TCssCalcNode;
  Index, Other: Integer;
  Swap, Child: TCssCalcNode;
begin
  SetLength(Order, Length(Node.Children));
  for Index := 0 to High(Node.Children) do
    Order[Index] := Node.Children[Index];
  { Numbers, then percentages, then dimensions by unit name, then the rest. }
  for Index := 1 to High(Order) do
  begin
    Other := Index;
    while (Other > 0) and ((SortRank(Order[Other - 1]) > SortRank(Order[Other])) or
      ((SortRank(Order[Other - 1]) = 2) and (SortRank(Order[Other]) = 2) and
      (CssUnitName(Order[Other - 1].UnitValue) > CssUnitName(Order[Other].UnitValue)))) do
    begin
      Swap := Order[Other - 1];
      Order[Other - 1] := Order[Other];
      Order[Other] := Swap;
      Dec(Other);
    end;
  end;
  Result := '';
  for Index := 0 to High(Order) do
  begin
    Child := Order[Index];
    if Index = 0 then
      Result := SerializeInner(Child, False)
    else if Child.IsLeaf and (Child.Value < 0) then
      Result := Result + ' - ' + SerializeLeafValue(-Child.Value, Child.UnitValue)
    else if Child.Kind = ckNegate then
      Result := Result + ' - ' + SerializeInner(Child.Children[0], False)
    else
      Result := Result + ' + ' + SerializeInner(Child, False);
  end;
end;

function SerializeFunction(Node: TCssCalcNode): string;
var
  Index: Integer;
begin
  Result := FunctionNames[Node.Kind] + '(';
  if (Node.Kind = ckRound) and (Node.Strategy <> kwNearest) then
    Result := Result + KeywordName(Node.Strategy) + ', ';
  for Index := 0 to High(Node.Children) do
  begin
    if Index > 0 then
      Result := Result + ', ';
    Result := Result + SerializeInner(Node.Children[Index], False);
  end;
  Result := Result + ')';
end;

function SerializeInner(Node: TCssCalcNode; InProduct: Boolean): string;
var
  Index: Integer;
  Child: TCssCalcNode;
begin
  case Node.Kind of
    ckLeaf: Result := SerializeLeafValue(Node.Value, Node.UnitValue);
    ckSum:
      begin
        Result := SerializeSum(Node);
        if InProduct then
          Result := '(' + Result + ')';
      end;
    ckNegate: Result := '-1 * ' + SerializeInner(Node.Children[0], True);
    ckInvert: Result := '1 / ' + SerializeInner(Node.Children[0], True);
    ckProduct:
      begin
        Result := '';
        for Index := 0 to High(Node.Children) do
        begin
          Child := Node.Children[Index];
          if Index = 0 then
            Result := SerializeInner(Child, True)
          else if Child.Kind = ckInvert then
            Result := Result + ' / ' + SerializeInner(Child.Children[0], True)
          else
            Result := Result + ' * ' + SerializeInner(Child, True);
        end;
      end;
  else
    Result := SerializeFunction(Node);
  end;
end;

function SerializeCalc(Node: TCssCalcNode): string;
begin
  case Node.Kind of
    ckLeaf, ckSum, ckProduct, ckNegate, ckInvert:
      Result := 'calc(' + SerializeInner(Node, False) + ')';
  else
    Result := SerializeFunction(Node);
  end;
end;

function ParseMathFunction(var Cursor: TCssTokenCursor; Expected, PercentAs: TCssUnitCategory): TCssCalcNode;
var
  Parser: TCalcParser;
  Token: PCssToken;
  NodeType, Wanted: TCssCalcType;
  Base: TCssCalcBase;
  Saved: Integer;
begin
  Result := nil;
  Saved := Cursor.Position;
  Token := Cursor.Next;
  if (Token^.Kind <> tkFunction) or not IsMathFunction(Token^.Text) then
  begin
    Cursor.Position := Saved;
    Exit;
  end;
  Parser.PercentAs := PercentAs;
  Parser.Failed := False;
  Result := ParseFunctionBody(Parser, Token, Cursor.Contents(Token));
  if Result = nil then
  begin
    Cursor.Position := Saved;
    Exit;
  end;
  NodeType := TypeOf(Parser, Result);
  if CategoryBase(Expected, Base) then
    Wanted := TypeOfBase(Base)
  else
    Wanted := NumberType;
  if not SameType(NodeType, Wanted) then
  begin
    FreeAndNil(Result);
    Cursor.Position := Saved;
    Exit;
  end;
  SimplifyCalc(Result);
end;

end.
