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

{ Depth first: a module comes after everything it needs. }
procedure OrderModule(List: PModuleList; ModuleIndex: Integer; var Order: TModuleOrder);
var
  NeededIndex: Integer;
  Module: PLoadedModule;
begin
  if (ModuleIndex < 0) or (ModuleIndex >= List^.Count) or Order.Visited[ModuleIndex] then
    Exit;
  Order.Visited[ModuleIndex] := True;
  Module := List^.Modules[ModuleIndex];
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

function CollectInitializers(Process: PProcess; out Lists: TInitializerLists): LongInt;
var
  List: PModuleList;
  Order: TModuleOrder;
  InitializerTotal: QWord;
  FinalizerTotal: QWord;
begin
  FillMemory(@Lists, SizeOf(Lists), 0);
  List := PModuleList(Process^.Modules);
  if (List = nil) or (List^.Count = 0) then
    Exit(ErrorNone);

  FillMemory(@Order, SizeOf(Order), 0);
  { The program is module 0; every startup library is reachable from it. }
  OrderModule(List, 0, Order);
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
