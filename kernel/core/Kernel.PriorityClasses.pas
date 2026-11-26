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
  Priority classes: where a process's threads stand against those of
  other processes. The rules, kept apart from the process manager so
  they can be checked on the host (tools/SchedulerPolicyTest).

  Every process is in one class (PriorityClass* in the Abi); the class
  gives its threads' base priority, which the process's nice value
  moves by one level for every 4 steps, never out of the variable class
  (1-15):

    Idle         4   only when nothing else wants the processor
    Background   6   a browser's content processes
    Normal       8   ordinary programs
    Interactive 10   the desktop, the task manager, the session manager
    System      12   the display server and the input path

  So the display server preempts every program, the desktop and the
  task manager every ordinary program and a page's renderer never
  holds up the browser's own window - whatever their wake boosts, a
  thread of a lower class reaches a higher one only through a boost,
  which decays.

  Setting a class: a process may put itself, or another of its own
  user's, in any class up to Normal, or up to its own class when that
  is higher (the desktop may give the task manager it starts its own
  Interactive class); root may set any.

  Inheriting: a process started by one in the Idle or Background class
  gets that class (a content process's helpers stay down); one started
  by a process of a higher class gets Normal (what the user starts from
  the desktop is an ordinary program).
}
unit Kernel.PriorityClasses;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

const
  IdleClassBasePriority = 4;
  BackgroundClassBasePriority = 6;
  NormalClassBasePriority = 8;
  InteractiveClassBasePriority = 10;
  SystemClassBasePriority = 12;

  { Nice moves the base one level for every NiceStepsPerLevel steps. }
  NiceStepsPerLevel = 4;
  LowestClassPriority = 1;
  HighestClassPriority = 15;

{ True for PriorityClassIdle .. PriorityClassSystem. }
function IsValidPriorityClass(PriorityClass: LongWord): Boolean;
{ The base priority of the class itself (nice 0). }
function ClassBasePriority(PriorityClass: LongWord): LongWord;
{ The base priority of a thread of a process in PriorityClass with the
  nice value Nice (-20 .. 19). }
function ThreadBasePriority(PriorityClass: LongWord; Nice: LongInt): LongWord;
{ The class a process started by one in ParentClass begins in. }
function InheritedPriorityClass(ParentClass: LongWord): LongWord;
{ Whether a caller in CallerClass (root if CallerIsRoot), allowed to
  control the target at all, may put it in Wanted. }
function MaySetPriorityClass(CallerIsRoot: Boolean; CallerClass, Wanted: LongWord): Boolean;
{ Processes of this class are part of how the user drives the system:
  they may use the memory reserve and are ended for memory last. }
function IsEssentialPriorityClass(PriorityClass: LongWord): Boolean;
function PriorityClassName(PriorityClass: LongWord): PChar;

implementation

function IsValidPriorityClass(PriorityClass: LongWord): Boolean;
begin
  Result := PriorityClass <= PriorityClassHighest;
end;

function ClassBasePriority(PriorityClass: LongWord): LongWord;
begin
  case PriorityClass of
    PriorityClassIdle: Result := IdleClassBasePriority;
    PriorityClassBackground: Result := BackgroundClassBasePriority;
    PriorityClassInteractive: Result := InteractiveClassBasePriority;
    PriorityClassSystem: Result := SystemClassBasePriority;
  else
    Result := NormalClassBasePriority;
  end;
end;

function ThreadBasePriority(PriorityClass: LongWord; Nice: LongInt): LongWord;
var
  Priority: LongInt;
begin
  Priority := LongInt(ClassBasePriority(PriorityClass)) - Nice div NiceStepsPerLevel;
  if Priority < LowestClassPriority then
    Priority := LowestClassPriority;
  if Priority > HighestClassPriority then
    Priority := HighestClassPriority;
  Result := LongWord(Priority);
end;

function InheritedPriorityClass(ParentClass: LongWord): LongWord;
begin
  if (ParentClass = PriorityClassIdle) or (ParentClass = PriorityClassBackground) then
    Result := ParentClass
  else
    Result := PriorityClassNormal;
end;

function MaySetPriorityClass(CallerIsRoot: Boolean; CallerClass, Wanted: LongWord): Boolean;
begin
  if not IsValidPriorityClass(Wanted) then
    Exit(False);
  if CallerIsRoot or (Wanted <= PriorityClassNormal) then
    Exit(True);
  Result := Wanted <= CallerClass;
end;

function IsEssentialPriorityClass(PriorityClass: LongWord): Boolean;
begin
  Result := IsValidPriorityClass(PriorityClass) and (PriorityClass >= PriorityClassInteractive);
end;

function PriorityClassName(PriorityClass: LongWord): PChar;
begin
  case PriorityClass of
    PriorityClassIdle: Result := 'idle';
    PriorityClassBackground: Result := 'background';
    PriorityClassNormal: Result := 'normal';
    PriorityClassInteractive: Result := 'interactive';
    PriorityClassSystem: Result := 'system';
  else
    Result := 'unknown';
  end;
end;

end.
