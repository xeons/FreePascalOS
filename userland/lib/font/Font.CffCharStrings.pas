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
  Type 2 charstrings: the glyph programs of CFF and CFF2 fonts, run
  into outlines (Font.Outlines) of lines and cubic curves.

  A charstring is numbers pushed on a stack and operators that take
  them: moves (rmoveto, hmoveto, vmoveto, each starting a contour),
  lines (rlineto, hlineto, vlineto), curves (rrcurveto, hhcurveto,
  vvcurveto, hvcurveto, vhcurveto, rcurveline, rlinecurve and the flex
  family), subroutine calls (local and global, numbers biased by the
  subroutine count), hints (stems and masks, read only to be skipped:
  the hinting is the system's own, Font.Hinting) and arithmetic. In
  CFF the first stack-clearing operator may carry the glyph's width
  first (ignored: hmtx gives advances); CFF2 has no widths and no
  endchar, and its blend operator mixes deltas for a variable font,
  of which the default instance is taken (the deltas dropped).

  Every read is checked against the charstring; nesting deeper than
  ten subroutines, too many operators run, a stack overflow or a call
  to a subroutine that is not there refuses the glyph (it is drawn as
  nothing). seac (an accented glyph built from two others in endchar)
  is not supported: such glyphs end there.
}
unit Font.CffCharStrings;

{$mode objfpc}
{$H+}

interface

uses
  Font.FontData,
  Font.CffData,
  Font.Outlines;

type
  { What a charstring runs with: its subroutines, whether it is CFF2,
    and for CFF2 how many regions each variation data has (blend's
    deltas) and the variation data picked by default. }
  TCharStringContext = record
    GlobalSubroutines: TCffIndex;
    LocalSubroutines: TCffIndex;
    IsCff2: Boolean;
    RegionCounts: array of LongInt;
    DefaultVariationIndex: LongInt;
  end;

{ The outline CharString draws, in font units; False if it is broken. }
function RunCharString(const CharString: TFontTable; const Context: TCharStringContext;
  out Outline: TGlyphOutline): Boolean;

implementation

const
  MaximumStack = 513;
  MaximumDepth = 10;
  MaximumOperations = 200000;
  TransientCount = 32;

type
  TCharStringMachine = record
    Stack: array[0..MaximumStack - 1] of Double;
    Count: LongInt;
    X: Double;
    Y: Double;
    StemCount: LongInt;
    WidthDone: Boolean;
    ContourOpen: Boolean;
    Finished: Boolean;
    Failed: Boolean;
    Operations: LongInt;
    VariationIndex: LongInt;
    Transient: array[0..TransientCount - 1] of Double;
    RandomSeed: LongWord;
  end;
  PCharStringMachine = ^TCharStringMachine;

{ A stack value as a whole number, kept in reason whatever a broken
  charstring computed. }
function SafeRound(Value: Double): LongInt;
begin
  if Value > 1E9 then
    Result := 1000000000
  else if Value < -1E9 then
    Result := -1000000000
  else if Value <> Value then
    Result := 0
  else
    Result := Round(Value);
end;

procedure CloseContour(var Machine: TCharStringMachine; var Outline: TGlyphOutline);
var
  First: LongInt;
begin
  if not Machine.ContourOpen then
    Exit;
  Machine.ContourOpen := False;
  if Outline.ContourCount = 0 then
    First := 0
  else
    First := Outline.ContourEnds[Outline.ContourCount - 1] + 1;
  { A contour that ends where it started drops the repeated point:
    closing it joins them anyway. }
  if (Outline.PointCount - First > 1) and Outline.Points[Outline.PointCount - 1].OnCurve and
     (Outline.Points[Outline.PointCount - 1].X = Outline.Points[First].X) and
     (Outline.Points[Outline.PointCount - 1].Y = Outline.Points[First].Y) then
    Dec(Outline.PointCount);
  if Outline.PointCount - First < 2 then
  begin
    Outline.PointCount := First;
    Exit;
  end;
  EndOutlineContour(Outline);
end;

procedure MoveTo(var Machine: TCharStringMachine; var Outline: TGlyphOutline; DeltaX, DeltaY: Double);
begin
  CloseContour(Machine, Outline);
  Machine.X := Machine.X + DeltaX;
  Machine.Y := Machine.Y + DeltaY;
  AddOutlinePoint(Outline, Machine.X, Machine.Y, True);
  Machine.ContourOpen := True;
end;

{ A line or curve with no move before it starts at the current point. }
procedure EnsureContour(var Machine: TCharStringMachine; var Outline: TGlyphOutline);
begin
  if Machine.ContourOpen then
    Exit;
  AddOutlinePoint(Outline, Machine.X, Machine.Y, True);
  Machine.ContourOpen := True;
end;

procedure LineTo(var Machine: TCharStringMachine; var Outline: TGlyphOutline; DeltaX, DeltaY: Double);
begin
  EnsureContour(Machine, Outline);
  Machine.X := Machine.X + DeltaX;
  Machine.Y := Machine.Y + DeltaY;
  AddOutlinePoint(Outline, Machine.X, Machine.Y, True);
end;

procedure CurveTo(var Machine: TCharStringMachine; var Outline: TGlyphOutline;
  DeltaX1, DeltaY1, DeltaX2, DeltaY2, DeltaX3, DeltaY3: Double);
begin
  EnsureContour(Machine, Outline);
  Machine.X := Machine.X + DeltaX1;
  Machine.Y := Machine.Y + DeltaY1;
  AddCubicControlPoint(Outline, Machine.X, Machine.Y);
  Machine.X := Machine.X + DeltaX2;
  Machine.Y := Machine.Y + DeltaY2;
  AddCubicControlPoint(Outline, Machine.X, Machine.Y);
  Machine.X := Machine.X + DeltaX3;
  Machine.Y := Machine.Y + DeltaY3;
  AddOutlinePoint(Outline, Machine.X, Machine.Y, True);
end;

{ Drops a CFF width in front of the arguments the operator takes: the
  first stack-clearing operator has it when the count is off. }
function TakeWidth(var Machine: TCharStringMachine; const Context: TCharStringContext; HasExtra: Boolean): LongInt;
begin
  Result := 0;
  if not Machine.WidthDone and not Context.IsCff2 and HasExtra then
    Result := 1;
  Machine.WidthDone := True;
end;

procedure CountStems(var Machine: TCharStringMachine; const Context: TCharStringContext);
var
  First: LongInt;
begin
  First := TakeWidth(Machine, Context, Odd(Machine.Count));
  Machine.StemCount := Machine.StemCount + (Machine.Count - First) div 2;
  Machine.Count := 0;
end;

procedure DoLines(var Machine: TCharStringMachine; var Outline: TGlyphOutline; Horizontal: Boolean; First: LongInt);
var
  Index: LongInt;
begin
  Index := First;
  while Index < Machine.Count do
  begin
    if Horizontal then
      LineTo(Machine, Outline, Machine.Stack[Index], 0)
    else
      LineTo(Machine, Outline, 0, Machine.Stack[Index]);
    Horizontal := not Horizontal;
    Inc(Index);
  end;
end;

{ hvcurveto and vhcurveto: curves starting horizontal or vertical and
  ending the other way, alternating; the last may end with a slant. }
procedure DoAlternatingCurves(var Machine: TCharStringMachine; var Outline: TGlyphOutline; Horizontal: Boolean);
var
  Index: LongInt;
  Rest: LongInt;
  Last: Double;
begin
  Index := 0;
  while Machine.Count - Index >= 4 do
  begin
    Rest := Machine.Count - Index;
    if Rest = 5 then
      Last := Machine.Stack[Index + 4]
    else
      Last := 0;
    if Horizontal then
      CurveTo(Machine, Outline, Machine.Stack[Index], 0, Machine.Stack[Index + 1], Machine.Stack[Index + 2],
        Last, Machine.Stack[Index + 3])
    else
      CurveTo(Machine, Outline, 0, Machine.Stack[Index], Machine.Stack[Index + 1], Machine.Stack[Index + 2],
        Machine.Stack[Index + 3], Last);
    Horizontal := not Horizontal;
    Inc(Index, 4);
  end;
end;

procedure DoFlex(var Machine: TCharStringMachine; var Outline: TGlyphOutline; Kind: LongInt);
var
  S: array[0..12] of Double;
  Index: LongInt;
  StartY: Double;
  DeltaX: Double;
  DeltaY: Double;
begin
  for Index := 0 to 12 do
    if Index < Machine.Count then
      S[Index] := Machine.Stack[Index]
    else
      S[Index] := 0;
  case Kind of
    35: { flex }
      begin
        CurveTo(Machine, Outline, S[0], S[1], S[2], S[3], S[4], S[5]);
        CurveTo(Machine, Outline, S[6], S[7], S[8], S[9], S[10], S[11]);
      end;
    34: { hflex }
      begin
        StartY := Machine.Y;
        CurveTo(Machine, Outline, S[0], 0, S[1], S[2], S[3], 0);
        CurveTo(Machine, Outline, S[4], 0, S[5], StartY - Machine.Y, S[6], 0);
      end;
    36: { hflex1 }
      begin
        StartY := Machine.Y;
        CurveTo(Machine, Outline, S[0], S[1], S[2], S[3], S[4], 0);
        CurveTo(Machine, Outline, S[5], 0, S[6], S[7], S[8], StartY - Machine.Y - S[7]);
        { The last y brings the pen back to the start's height. }
      end;
    37: { flex1 }
      begin
        DeltaX := S[0] + S[2] + S[4] + S[6] + S[8];
        DeltaY := S[1] + S[3] + S[5] + S[7] + S[9];
        CurveTo(Machine, Outline, S[0], S[1], S[2], S[3], S[4], S[5]);
        if Abs(DeltaX) > Abs(DeltaY) then
          CurveTo(Machine, Outline, S[6], S[7], S[8], S[9], S[10], -DeltaY)
        else
          CurveTo(Machine, Outline, S[6], S[7], S[8], S[9], -DeltaX, S[10]);
      end;
  end;
  Machine.Count := 0;
end;

function Pop(var Machine: TCharStringMachine): Double;
begin
  if Machine.Count <= 0 then
  begin
    Machine.Failed := True;
    Exit(0);
  end;
  Dec(Machine.Count);
  Result := Machine.Stack[Machine.Count];
end;

procedure Push(var Machine: TCharStringMachine; Value: Double);
begin
  if Machine.Count >= MaximumStack then
  begin
    Machine.Failed := True;
    Exit;
  end;
  Machine.Stack[Machine.Count] := Value;
  Inc(Machine.Count);
end;

{ The arithmetic and storage operators (12 x). }
procedure DoArithmetic(var Machine: TCharStringMachine; OperatorCode: LongInt);
var
  A: Double;
  B: Double;
  C: Double;
  D: Double;
  Index: LongInt;
  Shift: LongInt;
  Count: LongInt;
  Step: LongInt;
  Copy: array of Double;
begin
  case OperatorCode of
    3: begin B := Pop(Machine); A := Pop(Machine); Push(Machine, Ord((A <> 0) and (B <> 0))); end;
    4: begin B := Pop(Machine); A := Pop(Machine); Push(Machine, Ord((A <> 0) or (B <> 0))); end;
    5: begin A := Pop(Machine); Push(Machine, Ord(A = 0)); end;
    9: begin A := Pop(Machine); Push(Machine, Abs(A)); end;
    10: begin B := Pop(Machine); A := Pop(Machine); Push(Machine, A + B); end;
    11: begin B := Pop(Machine); A := Pop(Machine); Push(Machine, A - B); end;
    12:
      begin
        B := Pop(Machine);
        A := Pop(Machine);
        if B = 0 then
          Push(Machine, 0)
        else
          Push(Machine, A / B);
      end;
    14: begin A := Pop(Machine); Push(Machine, -A); end;
    15: begin B := Pop(Machine); A := Pop(Machine); Push(Machine, Ord(A = B)); end;
    18: Pop(Machine);
    20:
      begin
        Index := SafeRound(Pop(Machine));
        A := Pop(Machine);
        if (Index >= 0) and (Index < TransientCount) then
          Machine.Transient[Index] := A;
      end;
    21:
      begin
        Index := SafeRound(Pop(Machine));
        if (Index >= 0) and (Index < TransientCount) then
          Push(Machine, Machine.Transient[Index])
        else
          Push(Machine, 0);
      end;
    22:
      begin
        D := Pop(Machine);
        C := Pop(Machine);
        B := Pop(Machine);
        A := Pop(Machine);
        if C <= D then
          Push(Machine, A)
        else
          Push(Machine, B);
      end;
    23:
      begin
        Machine.RandomSeed := LongWord((QWord(Machine.RandomSeed) * 1103515245 + 12345) and $FFFFFFFF);
        Push(Machine, ((Machine.RandomSeed shr 16) and $7FFF + 1) / 32769);
      end;
    24: begin B := Pop(Machine); A := Pop(Machine); Push(Machine, A * B); end;
    26:
      begin
        A := Pop(Machine);
        if A < 0 then
          A := 0;
        Push(Machine, Sqrt(A));
      end;
    27: begin A := Pop(Machine); Push(Machine, A); Push(Machine, A); end;
    28: begin B := Pop(Machine); A := Pop(Machine); Push(Machine, B); Push(Machine, A); end;
    29:
      begin
        Index := SafeRound(Pop(Machine));
        if Index < 0 then
          Index := 0;
        if Index >= Machine.Count then
          Machine.Failed := True
        else
          Push(Machine, Machine.Stack[Machine.Count - 1 - Index]);
      end;
    30:
      begin
        Shift := SafeRound(Pop(Machine));
        Count := SafeRound(Pop(Machine));
        if (Count <= 0) or (Count > Machine.Count) then
        begin
          Machine.Failed := (Count < 0) or (Count > Machine.Count);
          Exit;
        end;
        SetLength(Copy, Count);
        for Step := 0 to Count - 1 do
          Copy[Step] := Machine.Stack[Machine.Count - Count + Step];
        Shift := ((Shift mod Count) + Count) mod Count;
        for Step := 0 to Count - 1 do
          Machine.Stack[Machine.Count - Count + (Step + Shift) mod Count] := Copy[Step];
      end;
  else
    Machine.Count := 0;
  end;
end;

{ CFF2's blend: n defaults, n times the region count of deltas, n. The
  defaults stay. }
procedure DoBlend(var Machine: TCharStringMachine; const Context: TCharStringContext);
var
  Count: LongInt;
  Regions: LongInt;
begin
  Count := SafeRound(Pop(Machine));
  Regions := 0;
  if (Machine.VariationIndex >= 0) and (Machine.VariationIndex < Length(Context.RegionCounts)) then
    Regions := Context.RegionCounts[Machine.VariationIndex];
  if (Count < 0) or (Int64(Count) * (Regions + 1) > Machine.Count) then
  begin
    Machine.Failed := True;
    Exit;
  end;
  Machine.Count := Machine.Count - Count * Regions;
end;

function ReadNumber(const CharString: TFontTable; var Position: QWord; First: LongWord; out Value: Double): Boolean;
begin
  Result := False;
  Value := 0;
  case First of
    32..246:
      Value := LongInt(First) - 139;
    247..250:
      begin
        if not Has(CharString, Position, 1) then
          Exit;
        Value := (LongInt(First) - 247) * 256 + LongInt(ReadByte(CharString, Position)) + 108;
        Inc(Position);
      end;
    251..254:
      begin
        if not Has(CharString, Position, 1) then
          Exit;
        Value := -(LongInt(First) - 251) * 256 - LongInt(ReadByte(CharString, Position)) - 108;
        Inc(Position);
      end;
    28:
      begin
        if not Has(CharString, Position, 2) then
          Exit;
        Value := ReadSigned16(CharString, Position);
        Inc(Position, 2);
      end;
    255:
      begin
        if not Has(CharString, Position, 4) then
          Exit;
        Value := LongInt(ReadUnsigned32(CharString, Position)) / 65536;
        Inc(Position, 4);
      end;
  else
    Exit;
  end;
  Result := True;
end;

procedure Run(var Machine: TCharStringMachine; const Context: TCharStringContext; const CharString: TFontTable;
  Depth: LongInt; var Outline: TGlyphOutline);
var
  Position: QWord;
  First: LongWord;
  Value: Double;
  Start: LongInt;
  Index: LongInt;
  Number: LongInt;
  MaskBytes: LongInt;
  Subroutines: TCffIndex;
begin
  if Depth > MaximumDepth then
  begin
    Machine.Failed := True;
    Exit;
  end;
  Position := 0;
  while not Machine.Finished and not Machine.Failed and Has(CharString, Position, 1) do
  begin
    Inc(Machine.Operations);
    if Machine.Operations > MaximumOperations then
    begin
      Machine.Failed := True;
      Exit;
    end;
    First := ReadByte(CharString, Position);
    Inc(Position);
    if (First >= 32) or (First = 28) then
    begin
      if not ReadNumber(CharString, Position, First, Value) then
      begin
        Machine.Failed := True;
        Exit;
      end;
      Push(Machine, Value);
      Continue;
    end;
    case First of
      1, 3, 18, 23: { hstem, vstem, hstemhm, vstemhm }
        CountStems(Machine, Context);
      19, 20: { hintmask, cntrmask: a bit a stem }
        begin
          if Machine.Count > 0 then
            CountStems(Machine, Context)
          else
            Machine.WidthDone := True;
          MaskBytes := (Machine.StemCount + 7) div 8;
          if not Has(CharString, Position, MaskBytes) then
          begin
            Machine.Failed := True;
            Exit;
          end;
          Inc(Position, MaskBytes);
        end;
      21: { rmoveto }
        begin
          Start := TakeWidth(Machine, Context, Machine.Count > 2);
          if Machine.Count - Start >= 2 then
            MoveTo(Machine, Outline, Machine.Stack[Start], Machine.Stack[Start + 1])
          else
            Machine.Failed := True;
          Machine.Count := 0;
        end;
      22: { hmoveto }
        begin
          Start := TakeWidth(Machine, Context, Machine.Count > 1);
          if Machine.Count - Start >= 1 then
            MoveTo(Machine, Outline, Machine.Stack[Start], 0)
          else
            Machine.Failed := True;
          Machine.Count := 0;
        end;
      4: { vmoveto }
        begin
          Start := TakeWidth(Machine, Context, Machine.Count > 1);
          if Machine.Count - Start >= 1 then
            MoveTo(Machine, Outline, 0, Machine.Stack[Start])
          else
            Machine.Failed := True;
          Machine.Count := 0;
        end;
      5: { rlineto }
        begin
          Index := 0;
          while Index + 1 < Machine.Count do
          begin
            LineTo(Machine, Outline, Machine.Stack[Index], Machine.Stack[Index + 1]);
            Inc(Index, 2);
          end;
          Machine.Count := 0;
        end;
      6, 7: { hlineto, vlineto }
        begin
          DoLines(Machine, Outline, First = 6, 0);
          Machine.Count := 0;
        end;
      8: { rrcurveto }
        begin
          Index := 0;
          while Index + 5 < Machine.Count do
          begin
            CurveTo(Machine, Outline, Machine.Stack[Index], Machine.Stack[Index + 1], Machine.Stack[Index + 2],
              Machine.Stack[Index + 3], Machine.Stack[Index + 4], Machine.Stack[Index + 5]);
            Inc(Index, 6);
          end;
          Machine.Count := 0;
        end;
      27: { hhcurveto }
        begin
          Index := 0;
          Value := 0;
          if Odd(Machine.Count) then
          begin
            Value := Machine.Stack[0];
            Index := 1;
          end;
          while Index + 3 < Machine.Count do
          begin
            CurveTo(Machine, Outline, Machine.Stack[Index], Value, Machine.Stack[Index + 1], Machine.Stack[Index + 2],
              Machine.Stack[Index + 3], 0);
            Value := 0;
            Inc(Index, 4);
          end;
          Machine.Count := 0;
        end;
      26: { vvcurveto }
        begin
          Index := 0;
          Value := 0;
          if Odd(Machine.Count) then
          begin
            Value := Machine.Stack[0];
            Index := 1;
          end;
          while Index + 3 < Machine.Count do
          begin
            CurveTo(Machine, Outline, Value, Machine.Stack[Index], Machine.Stack[Index + 1], Machine.Stack[Index + 2],
              0, Machine.Stack[Index + 3]);
            Value := 0;
            Inc(Index, 4);
          end;
          Machine.Count := 0;
        end;
      30, 31: { vhcurveto, hvcurveto }
        begin
          DoAlternatingCurves(Machine, Outline, First = 31);
          Machine.Count := 0;
        end;
      24: { rcurveline }
        begin
          Index := 0;
          while Index + 7 < Machine.Count do
          begin
            CurveTo(Machine, Outline, Machine.Stack[Index], Machine.Stack[Index + 1], Machine.Stack[Index + 2],
              Machine.Stack[Index + 3], Machine.Stack[Index + 4], Machine.Stack[Index + 5]);
            Inc(Index, 6);
          end;
          if Index + 1 < Machine.Count then
            LineTo(Machine, Outline, Machine.Stack[Index], Machine.Stack[Index + 1]);
          Machine.Count := 0;
        end;
      25: { rlinecurve }
        begin
          Index := 0;
          while Index + 7 < Machine.Count do
          begin
            LineTo(Machine, Outline, Machine.Stack[Index], Machine.Stack[Index + 1]);
            Inc(Index, 2);
          end;
          if Index + 5 < Machine.Count then
            CurveTo(Machine, Outline, Machine.Stack[Index], Machine.Stack[Index + 1], Machine.Stack[Index + 2],
              Machine.Stack[Index + 3], Machine.Stack[Index + 4], Machine.Stack[Index + 5]);
          Machine.Count := 0;
        end;
      10, 29: { callsubr, callgsubr }
        begin
          if First = 10 then
            Subroutines := Context.LocalSubroutines
          else
            Subroutines := Context.GlobalSubroutines;
          Number := SafeRound(Pop(Machine)) + SubroutineBias(Subroutines.Count);
          if Machine.Failed or not Subroutines.Present or (Number < 0) or (LongWord(Number) >= Subroutines.Count) then
          begin
            Machine.Failed := True;
            Exit;
          end;
          Run(Machine, Context, CffIndexItem(Subroutines, Number), Depth + 1, Outline);
        end;
      11: { return }
        Exit;
      14: { endchar }
        begin
          TakeWidth(Machine, Context, Odd(Machine.Count));
          CloseContour(Machine, Outline);
          Machine.Finished := True;
          Exit;
        end;
      15: { vsindex (CFF2) }
        begin
          Machine.VariationIndex := SafeRound(Pop(Machine));
          Machine.Count := 0;
        end;
      16: { blend (CFF2) }
        DoBlend(Machine, Context);
      12:
        begin
          if not Has(CharString, Position, 1) then
          begin
            Machine.Failed := True;
            Exit;
          end;
          First := ReadByte(CharString, Position);
          Inc(Position);
          if First in [34, 35, 36, 37] then
            DoFlex(Machine, Outline, First)
          else
            DoArithmetic(Machine, First);
        end;
    else
      { Reserved: ignored with its arguments. }
      Machine.Count := 0;
    end;
  end;
end;

{ Whether every point is a number within a reasonable distance (a
  broken charstring's arithmetic can make anything). }
function PointsInReason(const Outline: TGlyphOutline): Boolean;
const
  Farthest = 1000000;
var
  Index: LongInt;
begin
  for Index := 0 to Outline.PointCount - 1 do
    if not ((Abs(Outline.Points[Index].X) <= Farthest) and (Abs(Outline.Points[Index].Y) <= Farthest)) then
      Exit(False);
  Result := True;
end;

function RunCharString(const CharString: TFontTable; const Context: TCharStringContext;
  out Outline: TGlyphOutline): Boolean;
var
  Machine: PCharStringMachine;
begin
  ClearOutline(Outline);
  New(Machine);
  try
    FillChar(Machine^, SizeOf(Machine^), 0);
    Machine^.VariationIndex := Context.DefaultVariationIndex;
    Machine^.RandomSeed := 1;
    Run(Machine^, Context, CharString, 0, Outline);
    CloseContour(Machine^, Outline);
    Result := not Machine^.Failed and PointsInReason(Outline);
  finally
    Dispose(Machine);
  end;
  if not Result then
    ClearOutline(Outline);
end;

end.
