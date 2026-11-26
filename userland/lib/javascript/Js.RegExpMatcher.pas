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
  The backtracking matcher for compiled regular expressions.

  A thread of matching is a program counter and a position; a choice
  (a split, a quantifier deciding to go round again) pushes the other
  way onto a stack. Every change to a capture, a counter or a position
  register pushes its old value, so popping the stack back to a choice
  undoes everything done since. Lookarounds run a nested match and
  keep nothing to backtrack into (they are atomic); a positive one's
  captures stay, undone together if the match backtracks past it.

  The input is a flat string; with the u flag characters are code
  points (a surrogate pair is one). A step budget checks the interrupt
  flag now and then so that a pathological pattern can be stopped.
}
unit Js.RegExpMatcher;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils,
  Js.Strings,
  Js.RegExpCompiler;

type
  TRxCaptures = array of Integer;

  { roOutOfMemory: the backtracking stack could not grow (the memory
    is given back; the caller throws a RangeError). }
  TRxOutcome = (roNoMatch, roMatch, roInterrupted, roOutOfMemory);

  TRxMatcher = class
  private type
    TEntryKind = (ekAlternative, ekCapture, ekCounter, ekPosition, ekAllCaptures);
    TEntry = record
      Kind: TEntryKind;
      PC: Integer;
      Position: Integer;
      Index: Integer;
      Value: Integer;
      Saved: TRxCaptures;
    end;
  private
    FProgram: TRxProgram;
    FText: TJsString;
    FLength: Integer;
    FStack: array of TEntry;
    FStackCount: Integer;
    FCounters: array of Integer;
    FPositions: array of Integer;
    FSteps: Integer;
    FInterrupt: PLongBool;
    FInterrupted: Boolean;
    procedure Push(Kind: TEntryKind; PC, Position, Index, Value: Integer);
    function ReadForward(var Position: Integer; out Code: LongWord): Boolean; inline;
    function ReadBackward(var Position: Integer; out Code: LongWord): Boolean; inline;
    function UnitAt(Position: Integer): LongWord; inline;
    function IsLineTerminatorAt(Position: Integer): Boolean;
    function Run(StartPC, StartPosition: Integer; out EndPosition: Integer): Boolean;
  public
    Captures: TRxCaptures;
    constructor Create(AProgram: TRxProgram; Interrupt: PLongBool);
    { Tries a match starting exactly at Position (Captures filled). }
    function MatchAt(Text: TJsString; Position: Integer): TRxOutcome;
    { Searches from Position on: the first match (Captures filled). }
    function Search(Text: TJsString; Position: Integer; Sticky: Boolean): TRxOutcome;
  end;

implementation

const
  StepsBetweenChecks = 100000;

constructor TRxMatcher.Create(AProgram: TRxProgram; Interrupt: PLongBool);
begin
  inherited Create;
  FProgram := AProgram;
  FInterrupt := Interrupt;
  SetLength(Captures, (AProgram.GroupCount + 1) * 2);
  SetLength(FCounters, AProgram.CounterCount);
  SetLength(FPositions, AProgram.PositionRegisterCount);
end;

procedure TRxMatcher.Push(Kind: TEntryKind; PC, Position, Index, Value: Integer);
begin
  if FStackCount >= Length(FStack) then
    SetLength(FStack, Length(FStack) * 2 + 64);
  FStack[FStackCount].Kind := Kind;
  FStack[FStackCount].PC := PC;
  FStack[FStackCount].Position := Position;
  FStack[FStackCount].Index := Index;
  FStack[FStackCount].Value := Value;
  Inc(FStackCount);
end;

function TRxMatcher.UnitAt(Position: Integer): LongWord;
begin
  Result := FText.CharAt(Position);
end;

function TRxMatcher.ReadForward(var Position: Integer; out Code: LongWord): Boolean;
var
  Second: LongWord;
begin
  if Position >= FLength then
  begin
    Code := 0;
    Exit(False);
  end;
  Code := FText.CharAt(Position);
  Inc(Position);
  if FProgram.Unicode and (Code >= $D800) and (Code <= $DBFF) and (Position < FLength) then
  begin
    Second := FText.CharAt(Position);
    if (Second >= $DC00) and (Second <= $DFFF) then
    begin
      Code := $10000 + ((Code - $D800) shl 10) + (Second - $DC00);
      Inc(Position);
    end;
  end;
  Result := True;
end;

function TRxMatcher.ReadBackward(var Position: Integer; out Code: LongWord): Boolean;
var
  First: LongWord;
begin
  if Position <= 0 then
  begin
    Code := 0;
    Exit(False);
  end;
  Dec(Position);
  Code := FText.CharAt(Position);
  if FProgram.Unicode and (Code >= $DC00) and (Code <= $DFFF) and (Position > 0) then
  begin
    First := FText.CharAt(Position - 1);
    if (First >= $D800) and (First <= $DBFF) then
    begin
      Code := $10000 + ((First - $D800) shl 10) + (Code - $DC00);
      Dec(Position);
    end;
  end;
  Result := True;
end;

function TRxMatcher.IsLineTerminatorAt(Position: Integer): Boolean;
var
  Code: LongWord;
begin
  Code := FText.CharAt(Position);
  Result := (Code = 10) or (Code = 13) or (Code = $2028) or (Code = $2029);
end;

function TRxMatcher.Run(StartPC, StartPosition: Integer; out EndPosition: Integer): Boolean;
var
  Code: PLongInt;
  PC, Position, Base, Index, Group, Start, Finish, Length_, Probe, NestedEnd, Slot: Integer;
  Character, Expected: LongWord;
  Entry: TEntry;
  Matched, Before, After: Boolean;
  Snapshot: TRxCaptures;
  Kind: Integer;
  Count, Minimum, Maximum: Integer;

  function Fail: Boolean;
  begin
    { Back to the most recent choice of this run. }
    while FStackCount > Base do
    begin
      Dec(FStackCount);
      Entry := FStack[FStackCount];
      case Entry.Kind of
        ekAlternative:
          begin
            PC := Entry.PC;
            Position := Entry.Position;
            Exit(True);
          end;
        ekCapture: Captures[Entry.Index] := Entry.Value;
        ekCounter: FCounters[Entry.Index] := Entry.Value;
        ekPosition: FPositions[Entry.Index] := Entry.Value;
        ekAllCaptures: Captures := Entry.Saved;
      end;
    end;
    Result := False;
  end;

begin
  Code := @FProgram.Code[0];
  PC := StartPC;
  Position := StartPosition;
  Base := FStackCount;
  Result := False;
  EndPosition := Position;
  while True do
  begin
    Inc(FSteps);
    if FSteps >= StepsBetweenChecks then
    begin
      FSteps := 0;
      if (FInterrupt <> nil) and FInterrupt^ then
      begin
        FInterrupted := True;
        FStackCount := Base;
        Exit(False);
      end;
    end;
    Matched := True;
    case Code[PC] of
      RxChar:
        begin
          if Code[PC + 1] = ForwardDirection then
            Matched := ReadForward(Position, Character)
          else
            Matched := ReadBackward(Position, Character);
          if Matched then
          begin
            Expected := LongWord(Code[PC + 2]);
            if FProgram.IgnoreCase then
              Matched := CanonicalizeCase(Character, FProgram.Unicode) = Expected
            else
              Matched := Character = Expected;
          end;
          Inc(PC, 3);
        end;
      RxAny:
        begin
          if Code[PC + 1] = ForwardDirection then
            Matched := ReadForward(Position, Character)
          else
            Matched := ReadBackward(Position, Character);
          if Matched and not FProgram.DotAll then
            Matched := not ((Character = 10) or (Character = 13) or (Character = $2028) or (Character = $2029));
          Inc(PC, 2);
        end;
      RxClass:
        begin
          if Code[PC + 1] = ForwardDirection then
            Matched := ReadForward(Position, Character)
          else
            Matched := ReadBackward(Position, Character);
          if Matched then
            Matched := FProgram.Classes[Code[PC + 2]].Contains(Character);
          Inc(PC, 3);
        end;
      RxLineStart:
        begin
          Matched := (Position = 0) or (FProgram.Multiline and IsLineTerminatorAt(Position - 1));
          Inc(PC);
        end;
      RxLineEnd:
        begin
          Matched := (Position = FLength) or (FProgram.Multiline and IsLineTerminatorAt(Position));
          Inc(PC);
        end;
      RxWordBoundary:
        begin
          Before := (Position > 0) and IsRxWordCharacter(UnitAt(Position - 1), FProgram.IgnoreCase, FProgram.Unicode);
          After := (Position < FLength) and IsRxWordCharacter(UnitAt(Position), FProgram.IgnoreCase,
            FProgram.Unicode);
          Matched := (Before <> After) = (Code[PC + 1] = 0);
          Inc(PC, 2);
        end;
      RxSplit:
        begin
          Push(ekAlternative, Code[PC + 2], Position, 0, 0);
          PC := Code[PC + 1];
        end;
      RxJump:
        PC := Code[PC + 1];
      RxSave:
        begin
          Slot := Code[PC + 1];
          Push(ekCapture, 0, 0, Slot, Captures[Slot]);
          Captures[Slot] := Position;
          Inc(PC, 2);
        end;
      RxResetCaptures:
        begin
          for Group := Code[PC + 1] to Code[PC + 2] do
          begin
            Push(ekCapture, 0, 0, Group * 2, Captures[Group * 2]);
            Push(ekCapture, 0, 0, Group * 2 + 1, Captures[Group * 2 + 1]);
            Captures[Group * 2] := -1;
            Captures[Group * 2 + 1] := -1;
          end;
          Inc(PC, 3);
        end;
      RxBackReference, RxNamedBackReference:
        begin
          Group := Code[PC + 2];
          if Code[PC] = RxNamedBackReference then
          begin
            for Index := Code[PC + 2] to Code[PC + 3] do
              if Captures[Index * 2 + 1] >= 0 then
              begin
                Group := Index;
                Break;
              end;
          end;
          Start := Captures[Group * 2];
          Finish := Captures[Group * 2 + 1];
          if (Start >= 0) and (Finish >= Start) then
          begin
            Length_ := Finish - Start;
            if Code[PC + 1] = ForwardDirection then
            begin
              Matched := Position + Length_ <= FLength;
              Probe := Position;
            end
            else
            begin
              Matched := Position - Length_ >= 0;
              Probe := Position - Length_;
            end;
            Index := 0;
            while Matched and (Index < Length_) do
            begin
              if FProgram.IgnoreCase then
                Matched := CanonicalizeCase(UnitAt(Probe + Index), FProgram.Unicode) =
                  CanonicalizeCase(UnitAt(Start + Index), FProgram.Unicode)
              else
                Matched := UnitAt(Probe + Index) = UnitAt(Start + Index);
              Inc(Index);
            end;
            if Matched then
            begin
              if Code[PC + 1] = ForwardDirection then
                Inc(Position, Length_)
              else
                Dec(Position, Length_);
            end;
          end;
          if Code[PC] = RxNamedBackReference then
            Inc(PC, 4)
          else
            Inc(PC, 3);
        end;
      RxLook:
        begin
          Kind := Code[PC + 1];
          Snapshot := Copy(Captures);
          Before := Run(PC + 3, Position, NestedEnd);
          if FInterrupted then
            Exit(False);
          if Kind in [0, 2] then
          begin
            Matched := Before;
            if Matched then
            begin
              { Atomic: what the lookaround did can only be undone whole. }
              if FStackCount >= Length(FStack) then
                SetLength(FStack, Length(FStack) * 2 + 64);
              FStack[FStackCount].Kind := ekAllCaptures;
              FStack[FStackCount].Saved := Snapshot;
              Inc(FStackCount);
            end
            else
              Captures := Snapshot;
          end
          else
          begin
            Captures := Snapshot;
            Matched := not Before;
          end;
          PC := Code[PC + 2];
        end;
      RxRepeatStart:
        begin
          Index := Code[PC + 1];
          Push(ekCounter, 0, 0, Index, FCounters[Index]);
          FCounters[Index] := 0;
          Inc(PC, 2);
        end;
      RxRepeatLoop:
        begin
          Count := FCounters[Code[PC + 1]];
          Minimum := Code[PC + 2];
          Maximum := Code[PC + 3];
          if Count < Minimum then
            Inc(PC, 6)
          else if (Maximum >= 0) and (Count >= Maximum) then
            PC := Code[PC + 5]
          else if Code[PC + 4] <> 0 then
          begin
            Push(ekAlternative, Code[PC + 5], Position, 0, 0);
            Inc(PC, 6);
          end
          else
          begin
            Push(ekAlternative, PC + 6, Position, 0, 0);
            PC := Code[PC + 5];
          end;
        end;
      RxSavePosition:
        begin
          Index := Code[PC + 1];
          Push(ekPosition, 0, 0, Index, FPositions[Index]);
          FPositions[Index] := Position;
          Inc(PC, 2);
        end;
      RxRepeatEnd:
        begin
          Index := Code[PC + 1];
          Count := FCounters[Index];
          { An empty iteration once the minimum is met ends nothing new: fail it. }
          if (Position = FPositions[Code[PC + 2]]) and (Count + 1 > Code[Code[PC + 3] + 2]) then
            Matched := False
          else
          begin
            Push(ekCounter, 0, 0, Index, Count);
            FCounters[Index] := Count + 1;
            PC := Code[PC + 3];
          end;
        end;
      RxMatch:
        begin
          EndPosition := Position;
          { Keep the undo entries of a nested run's captures for the caller
            only through the snapshot; drop the rest. }
          FStackCount := Base;
          Exit(True);
        end;
    else
      Matched := False;
    end;
    if not Matched then
      if not Fail then
        Exit(False);
  end;
end;

function TRxMatcher.MatchAt(Text: TJsString; Position: Integer): TRxOutcome;
var
  Index, EndPosition: Integer;
begin
  FText := Text;
  FLength := Text.Length;
  FStackCount := 0;
  FInterrupted := False;
  for Index := 0 to High(Captures) do
    Captures[Index] := -1;
  try
    if Run(0, Position, EndPosition) then
      Exit(roMatch);
  except
    on EOutOfMemory do
    begin
      FStack := nil;
      FStackCount := 0;
      Exit(roOutOfMemory);
    end;
  end;
  if FInterrupted then
    Exit(roInterrupted);
  Result := roNoMatch;
end;

function TRxMatcher.Search(Text: TJsString; Position: Integer; Sticky: Boolean): TRxOutcome;
var
  Code: LongWord;
begin
  { Text is flat (the caller flattens it). }
  while Position <= Text.Length do
  begin
    Result := MatchAt(Text, Position);
    if Result <> roNoMatch then
      Exit;
    if Sticky then
      Exit(roNoMatch);
    if FProgram.Unicode and (Position < Text.Length) then
    begin
      Code := Text.CharAt(Position);
      if (Code >= $D800) and (Code <= $DBFF) and (Position + 1 < Text.Length) and
        (Text.CharAt(Position + 1) >= $DC00) and (Text.CharAt(Position + 1) <= $DFFF) then
        Inc(Position);
    end;
    Inc(Position);
  end;
  Result := roNoMatch;
end;

end.
