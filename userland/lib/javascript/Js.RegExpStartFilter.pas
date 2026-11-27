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
  Where a match of a compiled regular expression can begin, so that a
  search tries the matcher only at positions that might match.

  The paths from the start of the program are followed up to the first
  instruction that reads a character; that character's possible first
  code units, over every path, are the start units. Assertions and
  lookarounds read nothing and are stepped over (the set only gets
  larger). A path that can reach the end of the pattern, a back
  reference or the end of a loop's body without reading a character
  might match the empty string anywhere: then there is no filter.

  A pattern beginning with ^ (no m flag) matches only at position 0;
  a run of literal characters at the start (no i flag) is a prefix the
  search compares before trying the matcher.
}
unit Js.RegExpStartFilter;

{$mode objfpc}{$H+}

interface

uses
  Js.RegExpCompiler;

{ Fills Target.StartFilter from its code. }
procedure ComputeStartFilter(Target: TRxProgram);

implementation

type
  TStartWalk = record
    Target: TRxProgram;
    Visited: array of Boolean;
    Pending: array of Integer;
    PendingCount: Integer;
    Units: TRxLatinSet;
    HighUnits: Boolean;
    MatchesEmpty: Boolean;
  end;

procedure AddUnit(var Walk: TStartWalk; CodeUnit: LongWord);
begin
  if CodeUnit < 256 then
    Walk.Units[CodeUnit shr 5] := Walk.Units[CodeUnit shr 5] or (LongWord(1) shl (CodeUnit and 31))
  else
    Walk.HighUnits := True;
end;

procedure AddAllUnits(var Walk: TStartWalk);
begin
  FillChar(Walk.Units, SizeOf(Walk.Units), $FF);
  Walk.HighUnits := True;
end;

{ The first code units of a character the atom matches. }
procedure AddAtomUnits(var Walk: TStartWalk; Atom, Operand: LongInt);
var
  Index: Integer;
  Code: LongWord;
  Members: TRxClass;
begin
  case Atom of
    RxChar:
      begin
        Code := LongWord(Operand);
        if not Walk.Target.IgnoreCase then
        begin
          { A code point above the BMP starts with its high surrogate. }
          AddUnit(Walk, Code);
          Exit;
        end;
        { The characters whose canonical case is Code: those of Latin-1
          by test, any other conservatively. }
        for Index := 0 to 255 do
          if CanonicalizeCase(Index, Walk.Target.Unicode) = Code then
            AddUnit(Walk, Index);
        Walk.HighUnits := True;
      end;
    RxClass:
      begin
        Members := Walk.Target.Classes[Operand];
        for Index := 0 to 7 do
          Walk.Units[Index] := Walk.Units[Index] or Members.LatinSet[Index];
        if Members.HasMembersAboveLatin then
          Walk.HighUnits := True;
      end;
  else
    AddAllUnits(Walk);
  end;
end;

procedure Follow(var Walk: TStartWalk; PC: Integer);
begin
  if (PC < 0) or (PC >= Length(Walk.Visited)) then
  begin
    Walk.MatchesEmpty := True;
    Exit;
  end;
  if Walk.Visited[PC] then
    Exit;
  Walk.Visited[PC] := True;
  if Walk.PendingCount >= Length(Walk.Pending) then
    SetLength(Walk.Pending, Walk.PendingCount * 2 + 16);
  Walk.Pending[Walk.PendingCount] := PC;
  Inc(Walk.PendingCount);
end;

{ One instruction on a path that has read nothing yet. }
procedure Step(var Walk: TStartWalk; PC: Integer);
var
  Code: array of LongInt;
begin
  Code := Walk.Target.Code;
  case Code[PC] of
    RxChar, RxAny, RxClass:
      if Code[PC + 1] <> ForwardDirection then
        Walk.MatchesEmpty := True
      else if Code[PC] = RxAny then
        AddAllUnits(Walk)
      else
        AddAtomUnits(Walk, Code[PC], Code[PC + 2]);
    RxCharRepeat:
      begin
        AddAtomUnits(Walk, Code[PC + 1], Code[PC + 2]);
        if Code[PC + 3] = 0 then
          Follow(Walk, PC + 6);
      end;
    RxLineStart, RxLineEnd:
      Follow(Walk, PC + 1);
    RxWordBoundary, RxSave, RxRepeatStart, RxSavePosition:
      Follow(Walk, PC + 2);
    RxResetCaptures:
      Follow(Walk, PC + 3);
    RxSplit:
      begin
        Follow(Walk, Code[PC + 1]);
        Follow(Walk, Code[PC + 2]);
      end;
    RxJump:
      Follow(Walk, Code[PC + 1]);
    RxLook:
      Follow(Walk, Code[PC + 2]);
    RxRepeatLoop:
      begin
        { Entered from before the loop: the counter is 0. }
        Follow(Walk, PC + 6);
        if Code[PC + 2] = 0 then
          Follow(Walk, Code[PC + 5]);
      end;
  else
    { The end of the pattern or of a loop's body, a back reference. }
    Walk.MatchesEmpty := True;
  end;
end;

{ The literal characters every match starts with (no i flag). }
procedure ComputePrefix(Target: TRxProgram; PC: Integer);
var
  Code: array of LongInt;
  Count: Integer;
  Character: LongWord;
begin
  Code := Target.Code;
  Count := 0;
  if Target.IgnoreCase then
    Exit;
  while PC < Length(Code) do
    case Code[PC] of
      RxSave:
        Inc(PC, 2);
      RxChar:
        begin
          Character := LongWord(Code[PC + 2]);
          if (Code[PC + 1] <> ForwardDirection) or (Character > $FFFF) or
            (Target.Unicode and (Character >= $D800) and (Character <= $DFFF)) then
            Break;
          SetLength(Target.StartFilter.Prefix, Count + 1);
          Target.StartFilter.Prefix[Count] := Word(Character);
          Inc(Count);
          Inc(PC, 3);
        end;
    else
      Break;
    end;
end;

procedure ComputeStartFilter(Target: TRxProgram);
const
  { The program starts by saving the match's start (RxSave 0). }
  FirstPC = 2;
var
  Walk: TStartWalk;
begin
  Target.StartFilter := Default(TRxStartFilter);
  if (Length(Target.Code) <= FirstPC) or (Target.Code[0] <> RxSave) then
    Exit;
  Target.StartFilter.Anchored := (Target.Code[FirstPC] = RxLineStart) and not Target.Multiline;
  Walk := Default(TStartWalk);
  Walk.Target := Target;
  SetLength(Walk.Visited, Length(Target.Code));
  Follow(Walk, FirstPC);
  while (Walk.PendingCount > 0) and not Walk.MatchesEmpty do
  begin
    Dec(Walk.PendingCount);
    Step(Walk, Walk.Pending[Walk.PendingCount]);
  end;
  if Walk.MatchesEmpty then
    Exit;
  Target.StartFilter.HasStartUnits := True;
  Target.StartFilter.LatinUnits := Walk.Units;
  Target.StartFilter.HighUnits := Walk.HighUnits;
  ComputePrefix(Target, FirstPC);
end;

end.
