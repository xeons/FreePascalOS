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
  captures stay, undone together if the match backtracks past it (the
  captures before it are kept on a second stack).

  A quantified single character runs as a loop; its choices (one
  character fewer for a greedy one, one more for a lazy one) are one
  stack entry that is updated in place as they are tried.

  A search tries the positions where the program's start filter says a
  match can begin (Js.RegExpStartFilter). The stacks, the captures and
  the registers belong to the matcher and are reused from one search
  to the next; the matching loop has no managed locals (no implicit
  exception frames).

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
    { ekAllCaptures: Index is where the captures are kept on the
      saved-captures stack. ekGreedyRepeat: Position is the end of the
      characters taken, Index where they began, Value how many may
      still be given back. ekLazyRepeat: Position is the end of the
      characters taken, Index the repeat instruction, Value how many
      were taken. }
    TEntryKind = (ekAlternative, ekCapture, ekCounter, ekPosition, ekAllCaptures, ekGreedyRepeat, ekLazyRepeat);
    TEntry = record
      Kind: TEntryKind;
      PC: Integer;
      Position: Integer;
      Index: Integer;
      Value: Integer;
    end;
    PEntry = ^TEntry;
  private
    FProgram: TRxProgram;
    FText: TJsString;
    FChars8: PByte;
    FChars16: PWord;
    FLength: Integer;
    FUnicode: Boolean;
    FStack: array of TEntry;
    FStackCount: Integer;
    FSavedCaptures: array of Integer;
    FSavedCaptureCount: Integer;
    FCounters: array of Integer;
    FPositions: array of Integer;
    FSteps: Integer;
    FInterrupt: PLongBool;
    FInterrupted: Boolean;
    procedure Push(Kind: TEntryKind; PC, Position, Index, Value: Integer); inline;
    procedure GrowStack;
    function UnitAt(Position: Integer): LongWord; inline;
    function ReadForward(var Position: Integer; out Code: LongWord): Boolean; inline;
    function ReadBackward(var Position: Integer; out Code: LongWord): Boolean; inline;
    function StepBack(Position, Lowest: Integer): Integer; inline;
    function IsLineTerminatorAt(Position: Integer): Boolean;
    function AtomMatches(Atom, Operand: LongInt; Character: LongWord): Boolean; inline;
    function SaveCaptures: Integer;
    procedure RestoreCaptures(Offset: Integer);
    function MatchBackReference(PC: Integer; var Position: Integer): Boolean;
    function RepeatCharacter(PC: Integer; var Position: Integer): Boolean;
    function Backtrack(Base: Integer; var PC, Position: Integer): Boolean;
    function Run(StartPC, StartPosition: Integer): Boolean;
    procedure Prepare(Text: TJsString);
    function PrefixMatchesAt(Position: Integer): Boolean;
    function NextCandidate(Position: Integer): Integer;
    function Attempt(Position: Integer): TRxOutcome;
    function SearchFrom(Position: Integer; Sticky: Boolean): TRxOutcome;
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

function IsLineTerminator(Code: LongWord): Boolean; inline;
begin
  Result := (Code = 10) or (Code = 13) or (Code = $2028) or (Code = $2029);
end;

function InLatinSet(constref Members: TRxLatinSet; Code: LongWord): Boolean; inline;
begin
  Result := (Members[Code shr 5] and (LongWord(1) shl (Code and 31))) <> 0;
end;

constructor TRxMatcher.Create(AProgram: TRxProgram; Interrupt: PLongBool);
begin
  inherited Create;
  FProgram := AProgram;
  FUnicode := AProgram.Unicode;
  FInterrupt := Interrupt;
  SetLength(Captures, (AProgram.GroupCount + 1) * 2);
  SetLength(FCounters, AProgram.CounterCount);
  SetLength(FPositions, AProgram.PositionRegisterCount);
end;

procedure TRxMatcher.GrowStack;
begin
  SetLength(FStack, Length(FStack) * 2 + 64);
end;

procedure TRxMatcher.Push(Kind: TEntryKind; PC, Position, Index, Value: Integer);
var
  Entry: PEntry;
begin
  if FStackCount >= Length(FStack) then
    GrowStack;
  Entry := @FStack[FStackCount];
  Entry^.Kind := Kind;
  Entry^.PC := PC;
  Entry^.Position := Position;
  Entry^.Index := Index;
  Entry^.Value := Value;
  Inc(FStackCount);
end;

function TRxMatcher.UnitAt(Position: Integer): LongWord;
begin
  if FChars16 <> nil then
    Result := FChars16[Position]
  else
    Result := FChars8[Position];
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
  Code := UnitAt(Position);
  Inc(Position);
  if FUnicode and (Code >= $D800) and (Code <= $DBFF) and (Position < FLength) then
  begin
    Second := UnitAt(Position);
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
  Code := UnitAt(Position);
  if FUnicode and (Code >= $DC00) and (Code <= $DFFF) and (Position > 0) then
  begin
    First := UnitAt(Position - 1);
    if (First >= $D800) and (First <= $DBFF) then
    begin
      Code := $10000 + ((First - $D800) shl 10) + (Code - $DC00);
      Dec(Position);
    end;
  end;
  Result := True;
end;

{ One character back from Position within characters read forwards
  from Lowest: a surrogate pair is one character only when both halves
  were read (the pair cannot straddle Lowest). }
function TRxMatcher.StepBack(Position, Lowest: Integer): Integer;
var
  Code: LongWord;
begin
  Result := Position - 1;
  if FUnicode and (Result > Lowest) then
  begin
    Code := UnitAt(Result);
    if (Code >= $DC00) and (Code <= $DFFF) then
    begin
      Code := UnitAt(Result - 1);
      if (Code >= $D800) and (Code <= $DBFF) then
        Dec(Result);
    end;
  end;
end;

function TRxMatcher.IsLineTerminatorAt(Position: Integer): Boolean;
begin
  Result := IsLineTerminator(UnitAt(Position));
end;

function TRxMatcher.AtomMatches(Atom, Operand: LongInt; Character: LongWord): Boolean;
begin
  case Atom of
    RxChar:
      if FProgram.IgnoreCase then
        Result := CanonicalizeCase(Character, FUnicode) = LongWord(Operand)
      else
        Result := Character = LongWord(Operand);
    RxAny:
      Result := FProgram.DotAll or not IsLineTerminator(Character);
  else
    Result := FProgram.Classes[Operand].Contains(Character);
  end;
end;

{ Keeps a copy of the captures on the saved-captures stack: its offset. }
function TRxMatcher.SaveCaptures: Integer;
var
  Count: Integer;
begin
  Count := Length(Captures);
  Result := FSavedCaptureCount;
  if Result + Count > Length(FSavedCaptures) then
    SetLength(FSavedCaptures, (Result + Count) * 2);
  if Count > 0 then
    Move(Captures[0], FSavedCaptures[Result], Count * SizeOf(Integer));
  Inc(FSavedCaptureCount, Count);
end;

{ The captures kept at Offset back, and the stack popped down to them. }
procedure TRxMatcher.RestoreCaptures(Offset: Integer);
begin
  if Length(Captures) > 0 then
    Move(FSavedCaptures[Offset], Captures[0], Length(Captures) * SizeOf(Integer));
  FSavedCaptureCount := Offset;
end;

function TRxMatcher.MatchBackReference(PC: Integer; var Position: Integer): Boolean;
var
  Code: PLongInt;
  Group, Index, Start, Finish, Length_, Probe: Integer;
  Forwards: Boolean;
begin
  Code := @FProgram.Code[0];
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
  { A group that did not take part matches the empty string. }
  if (Start < 0) or (Finish < Start) then
    Exit(True);
  Length_ := Finish - Start;
  Forwards := Code[PC + 1] = ForwardDirection;
  if Forwards then
  begin
    Result := Position + Length_ <= FLength;
    Probe := Position;
  end
  else
  begin
    Result := Position - Length_ >= 0;
    Probe := Position - Length_;
  end;
  Index := 0;
  while Result and (Index < Length_) do
  begin
    if FProgram.IgnoreCase then
      Result := CanonicalizeCase(UnitAt(Probe + Index), FUnicode) = CanonicalizeCase(UnitAt(Start + Index), FUnicode)
    else
      Result := UnitAt(Probe + Index) = UnitAt(Start + Index);
    Inc(Index);
  end;
  if Result then
    if Forwards then
      Inc(Position, Length_)
    else
      Dec(Position, Length_);
end;

{ RxCharRepeat: takes the characters (as many as allowed when greedy,
  the minimum when lazy) and pushes the other choices as one entry. }
function TRxMatcher.RepeatCharacter(PC: Integer; var Position: Integer): Boolean;
var
  Code: PLongInt;
  Atom, Operand, Minimum, Maximum, Count, Start, Next: Integer;
  Character: LongWord;
begin
  Code := @FProgram.Code[0];
  Atom := Code[PC + 1];
  Operand := Code[PC + 2];
  Minimum := Code[PC + 3];
  Maximum := Code[PC + 4];
  Start := Position;
  Count := 0;
  if Code[PC + 5] = 0 then
    Maximum := Minimum;
  while (Maximum < 0) or (Count < Maximum) do
  begin
    Next := Position;
    if not ReadForward(Next, Character) or not AtomMatches(Atom, Operand, Character) then
      Break;
    Position := Next;
    Inc(Count);
  end;
  Inc(FSteps, Count);
  if Count < Minimum then
    Exit(False);
  Result := True;
  if Code[PC + 5] <> 0 then
  begin
    if Count > Minimum then
      Push(ekGreedyRepeat, PC + 6, Position, Start, Count - Minimum);
  end
  else if (Code[PC + 4] < 0) or (Count < Code[PC + 4]) then
    Push(ekLazyRepeat, PC + 6, Position, PC, Count);
end;

{ Back to the most recent choice above Base: False when there is none
  (everything done since Base undone). }
function TRxMatcher.Backtrack(Base: Integer; var PC, Position: Integer): Boolean;
var
  Entry: PEntry;
  Code: PLongInt;
  Next: Integer;
  Character: LongWord;
begin
  while FStackCount > Base do
  begin
    Entry := @FStack[FStackCount - 1];
    case Entry^.Kind of
      ekAlternative:
        begin
          PC := Entry^.PC;
          Position := Entry^.Position;
          Dec(FStackCount);
          Exit(True);
        end;
      ekCapture: Captures[Entry^.Index] := Entry^.Value;
      ekCounter: FCounters[Entry^.Index] := Entry^.Value;
      ekPosition: FPositions[Entry^.Index] := Entry^.Value;
      ekAllCaptures: RestoreCaptures(Entry^.Index);
      ekGreedyRepeat:
        begin
          { One character fewer; the entry stays while more can go. }
          Entry^.Position := StepBack(Entry^.Position, Entry^.Index);
          Dec(Entry^.Value);
          PC := Entry^.PC;
          Position := Entry^.Position;
          if Entry^.Value = 0 then
            Dec(FStackCount);
          Exit(True);
        end;
      ekLazyRepeat:
        begin
          { One character more, if it matches. }
          Code := @FProgram.Code[Entry^.Index];
          Next := Entry^.Position;
          if ReadForward(Next, Character) and AtomMatches(Code[1], Code[2], Character) then
          begin
            Entry^.Position := Next;
            Inc(Entry^.Value);
            PC := Entry^.PC;
            Position := Next;
            if (Code[4] >= 0) and (Entry^.Value >= Code[4]) then
              Dec(FStackCount);
            Exit(True);
          end;
        end;
    end;
    Dec(FStackCount);
  end;
  Result := False;
end;

function TRxMatcher.Run(StartPC, StartPosition: Integer): Boolean;
var
  Code: PLongInt;
  PC, Position, Base, Group, Slot, Index, Count, Minimum, Maximum, Kind, Snapshot: Integer;
  Character, Expected: LongWord;
  Matched, Before, After: Boolean;
begin
  Code := @FProgram.Code[0];
  PC := StartPC;
  Position := StartPosition;
  Base := FStackCount;
  Result := False;
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
              Matched := CanonicalizeCase(Character, FUnicode) = Expected
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
            Matched := not IsLineTerminator(Character);
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
      RxCharRepeat:
        begin
          Matched := RepeatCharacter(PC, Position);
          Inc(PC, 6);
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
          Before := (Position > 0) and IsRxWordCharacter(UnitAt(Position - 1), FProgram.IgnoreCase, FUnicode);
          After := (Position < FLength) and IsRxWordCharacter(UnitAt(Position), FProgram.IgnoreCase, FUnicode);
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
      RxBackReference:
        begin
          Matched := MatchBackReference(PC, Position);
          Inc(PC, 3);
        end;
      RxNamedBackReference:
        begin
          Matched := MatchBackReference(PC, Position);
          Inc(PC, 4);
        end;
      RxLook:
        begin
          Kind := Code[PC + 1];
          Snapshot := SaveCaptures;
          Before := Run(PC + 3, Position);
          if FInterrupted then
            Exit(False);
          if Before and ((Kind = 0) or (Kind = 2)) then
          begin
            { Atomic: what the lookaround did can only be undone whole.
              The nested run's own snapshots are gone with its entries. }
            FSavedCaptureCount := Snapshot + Length(Captures);
            Push(ekAllCaptures, 0, 0, Snapshot, 0);
          end
          else
            RestoreCaptures(Snapshot);
          Matched := Before = ((Kind = 0) or (Kind = 2));
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
          { A nested run's undo entries are dropped: the caller keeps
            its captures through its snapshot. }
          FStackCount := Base;
          Exit(True);
        end;
    else
      Matched := False;
    end;
    if not Matched then
      if not Backtrack(Base, PC, Position) then
        Exit(False);
  end;
end;

procedure TRxMatcher.Prepare(Text: TJsString);
var
  Index: Integer;
begin
  FText := Text;
  FLength := Text.Length;
  if Text.IsWide then
  begin
    FChars16 := Text.Chars16;
    FChars8 := nil;
  end
  else
  begin
    FChars8 := Text.Chars8;
    FChars16 := nil;
  end;
  FStackCount := 0;
  FSavedCaptureCount := 0;
  FInterrupted := False;
  for Index := 0 to High(Captures) do
    Captures[Index] := -1;
end;

function TRxMatcher.PrefixMatchesAt(Position: Integer): Boolean;
var
  Index, Count: Integer;
begin
  Count := Length(FProgram.StartFilter.Prefix);
  if Position + Count > FLength then
    Exit(False);
  for Index := 0 to Count - 1 do
    if UnitAt(Position + Index) <> FProgram.StartFilter.Prefix[Index] then
      Exit(False);
  Result := True;
end;

{ The first position from Position on whose code unit can start a
  match; FLength when none. Only units that cannot start a match are
  skipped, so a surrogate pair is never entered in the middle unless
  its high half could not start one (and then neither can its low). }
function TRxMatcher.NextCandidate(Position: Integer): Integer;
var
  Filter: ^TRxStartFilter;
  CodeUnit: LongWord;
begin
  Filter := @FProgram.StartFilter;
  Result := Position;
  if FChars8 <> nil then
  begin
    while (Result < FLength) and not InLatinSet(Filter^.LatinUnits, FChars8[Result]) do
      Inc(Result);
  end
  else
    while Result < FLength do
    begin
      CodeUnit := FChars16[Result];
      if CodeUnit < 256 then
      begin
        if InLatinSet(Filter^.LatinUnits, CodeUnit) then
          Break;
      end
      else if Filter^.HighUnits then
        Break;
      Inc(Result);
    end;
end;

function TRxMatcher.Attempt(Position: Integer): TRxOutcome;
begin
  if (Length(FProgram.StartFilter.Prefix) > 0) and not PrefixMatchesAt(Position) then
    Exit(roNoMatch);
  if Run(0, Position) then
    Exit(roMatch);
  if FInterrupted then
    Exit(roInterrupted);
  Result := roNoMatch;
end;

function TRxMatcher.SearchFrom(Position: Integer; Sticky: Boolean): TRxOutcome;
var
  Code: LongWord;
  Filtered: Boolean;
begin
  if Sticky then
    Exit(Attempt(Position));
  if FProgram.StartFilter.Anchored then
  begin
    if Position = 0 then
      Exit(Attempt(0));
    Exit(roNoMatch);
  end;
  Filtered := FProgram.StartFilter.HasStartUnits;
  while Position <= FLength do
  begin
    if Filtered then
    begin
      { Every match reads a character first: none can start at the end. }
      Position := NextCandidate(Position);
      if Position >= FLength then
        Exit(roNoMatch);
    end;
    Result := Attempt(Position);
    if Result <> roNoMatch then
      Exit;
    if FUnicode and (Position + 1 < FLength) then
    begin
      Code := UnitAt(Position);
      if (Code >= $D800) and (Code <= $DBFF) and (UnitAt(Position + 1) >= $DC00) and (UnitAt(Position + 1) <= $DFFF) then
        Inc(Position);
    end;
    Inc(Position);
  end;
  Result := roNoMatch;
end;

function TRxMatcher.Search(Text: TJsString; Position: Integer; Sticky: Boolean): TRxOutcome;
begin
  { Text is flat (the caller flattens it). }
  Prepare(Text);
  try
    Result := SearchFrom(Position, Sticky);
  except
    on EOutOfMemory do
    begin
      FStack := nil;
      FStackCount := 0;
      FSavedCaptures := nil;
      FSavedCaptureCount := 0;
      Result := roOutOfMemory;
    end;
  end;
end;

function TRxMatcher.MatchAt(Text: TJsString; Position: Integer): TRxOutcome;
begin
  Result := Search(Text, Position, True);
end;

end.
