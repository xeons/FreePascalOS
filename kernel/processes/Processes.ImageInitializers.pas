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
  Initializers and finalizers of the program and its startup libraries.

  The kernel binds every symbol before the program starts, but it cannot
  run a module's initialization code itself: that is user code and runs
  in user mode. Instead it collects, in the order they must run:

    initializers: for every module, dependencies before the modules that
                  need them (the program last): DT_INIT, then the
                  entries of DT_INIT_ARRAY in order;
    finalizers:   the reverse module order (the program first): the
                  entries of DT_FINI_ARRAY from last to first, then
                  DT_FINI;

  and Processes.UserProcess passes both lists to the program on its
  initial stack through the auxiliary vector (AuxiliaryInitializers and
  friends in Abi.SystemCalls). The user runtime calls the initializers
  before the program's main block and the finalizers when it exits.

  A library loaded at run time gets the same for itself and the
  libraries loaded with it (CollectModuleInitializers from its handle);
  each module's entries are handed out once, so libraries loaded before
  are left out. Processes.ModuleCalls keeps them until the runtime takes
  them (CallTakeModuleInitializers).
}
unit Processes.ImageInitializers;

{$mode objfpc}
{$pointermath on}

interface

uses
  Processes.Process;

type
  TInitializerLists = record
    { Kernel arrays of user code addresses; nil when empty. }
    Initializers: PQWord;
    InitializerCount: QWord;
    Finalizers: PQWord;
    FinalizerCount: QWord;
  end;

{ Collects the lists for the modules of Process (loaded and relocated).
  Returns ErrorNone or an Abi error code; free the lists with
  FreeInitializerLists either way. }
function CollectInitializers(Process: PProcess; out Lists: TInitializerLists): LongInt;
{ The same for the module RootIndex and everything it needs whose
  entries were not handed out yet (a library loaded at run time). }
function CollectModuleInitializers(Process: PProcess; RootIndex: Integer; out Lists: TInitializerLists): LongInt;
procedure FreeInitializerLists(var Lists: TInitializerLists);

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Processes.AddressSpace,
  Processes.ImageLoader;

type
  TModuleOrder = record
    Indexes: array[0..MaximumModules - 1] of Integer;
    Count: Integer;
    Visited: array[0..MaximumModules - 1] of Boolean;
  end;

{ Depth first: a module comes after everything it needs. Modules whose
  entries were handed out before are left out (with what they need,
  which was loaded and handed out with them). }
procedure OrderModule(List: PModuleList; ModuleIndex: Integer; var Order: TModuleOrder);
var
  NeededIndex: Integer;
  Module: PLoadedModule;
begin
  if (ModuleIndex < 0) or (ModuleIndex >= List^.Count) or Order.Visited[ModuleIndex] then
    Exit;
  Order.Visited[ModuleIndex] := True;
  Module := List^.Modules[ModuleIndex];
  if Module^.InitializersTaken then
    Exit;
  for NeededIndex := 0 to Module^.NeededCount - 1 do
    OrderModule(List, Module^.Needed[NeededIndex], Order);
  Order.Indexes[Order.Count] := ModuleIndex;
  Inc(Order.Count);
end;

function CountEntries(List: PModuleList; const Order: TModuleOrder; out Initializers,
  Finalizers: QWord): Boolean;
var
  Position: Integer;
  Module: PLoadedModule;
begin
  Initializers := 0;
  Finalizers := 0;
  for Position := 0 to Order.Count - 1 do
  begin
    Module := List^.Modules[Order.Indexes[Position]];
    Initializers := Initializers + Module^.InitArrayCount;
    if Module^.InitFunction <> 0 then
      Inc(Initializers);
    Finalizers := Finalizers + Module^.FiniArrayCount;
    if Module^.FiniFunction <> 0 then
      Inc(Finalizers);
  end;
  Result := (Initializers > 0) or (Finalizers > 0);
end;

{ Reads Count entries of an initializer array from user memory, which
  holds them already relocated. }
function ReadArray(Space: PAddressSpace; Address, Count: QWord; Destination: PQWord): LongInt;
begin
  if Count = 0 then
    Exit(ErrorNone);
  Result := ReadFromAddressSpace(Space, Address, Destination, Count * SizeOf(QWord));
end;

procedure ReverseEntries(Entries: PQWord; Count: QWord);
var
  Low: QWord;
  High: QWord;
  Saved: QWord;
begin
  if Count < 2 then
    Exit;
  Low := 0;
  High := Count - 1;
  while Low < High do
  begin
    Saved := Entries[Low];
    Entries[Low] := Entries[High];
    Entries[High] := Saved;
    Inc(Low);
    Dec(High);
  end;
end;

function FillLists(Space: PAddressSpace; List: PModuleList; const Order: TModuleOrder;
  var Lists: TInitializerLists): LongInt;
var
  Position: Integer;
  Module: PLoadedModule;
begin
  Result := ErrorNone;
  for Position := 0 to Order.Count - 1 do
  begin
    Module := List^.Modules[Order.Indexes[Position]];
    if Module^.InitFunction <> 0 then
    begin
      Lists.Initializers[Lists.InitializerCount] := Module^.InitFunction;
      Inc(Lists.InitializerCount);
    end;
    Result := ReadArray(Space, Module^.InitArray, Module^.InitArrayCount,
      Lists.Initializers + Lists.InitializerCount);
    if Result <> ErrorNone then
      Exit;
    Lists.InitializerCount := Lists.InitializerCount + Module^.InitArrayCount;
  end;

  { Built forwards with each module's entries in calling order reversed,
    then the whole list is reversed. }
  for Position := 0 to Order.Count - 1 do
  begin
    Module := List^.Modules[Order.Indexes[Position]];
    if Module^.FiniFunction <> 0 then
    begin
      Lists.Finalizers[Lists.FinalizerCount] := Module^.FiniFunction;
      Inc(Lists.FinalizerCount);
    end;
    Result := ReadArray(Space, Module^.FiniArray, Module^.FiniArrayCount,
      Lists.Finalizers + Lists.FinalizerCount);
    if Result <> ErrorNone then
      Exit;
    Lists.FinalizerCount := Lists.FinalizerCount + Module^.FiniArrayCount;
  end;
  ReverseEntries(Lists.Finalizers, Lists.FinalizerCount);
end;

procedure MarkTaken(List: PModuleList; const Order: TModuleOrder);
var
  Position: Integer;
begin
  for Position := 0 to Order.Count - 1 do
    List^.Modules[Order.Indexes[Position]]^.InitializersTaken := True;
end;

function CollectInitializers(Process: PProcess; out Lists: TInitializerLists): LongInt;
begin
  { The program is module 0; every startup library is reachable from it. }
  Result := CollectModuleInitializers(Process, 0, Lists);
end;

function CollectModuleInitializers(Process: PProcess; RootIndex: Integer; out Lists: TInitializerLists): LongInt;
var
  List: PModuleList;
  Order: TModuleOrder;
  InitializerTotal: QWord;
  FinalizerTotal: QWord;
begin
  FillMemory(@Lists, SizeOf(Lists), 0);
  List := PModuleList(Process^.Modules);
  if (List = nil) or (RootIndex < 0) or (RootIndex >= List^.Count) then
    Exit(ErrorNone);

  FillMemory(@Order, SizeOf(Order), 0);
  OrderModule(List, RootIndex, Order);
  MarkTaken(List, Order);
  if not CountEntries(List, Order, InitializerTotal, FinalizerTotal) then
    Exit(ErrorNone);

  Lists.Initializers := PQWord(AllocateZeroedKernelMemory((InitializerTotal + 1) * SizeOf(QWord)));
  Lists.Finalizers := PQWord(AllocateZeroedKernelMemory((FinalizerTotal + 1) * SizeOf(QWord)));
  if (Lists.Initializers = nil) or (Lists.Finalizers = nil) then
    Exit(ErrorOutOfMemory);
  Result := FillLists(Process^.AddressSpace, List, Order, Lists);
end;

procedure FreeInitializerLists(var Lists: TInitializerLists);
begin
  FreeKernelMemory(Lists.Initializers);
  FreeKernelMemory(Lists.Finalizers);
  FillMemory(@Lists, SizeOf(Lists), 0);
end;

end.
