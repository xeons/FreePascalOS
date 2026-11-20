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
  The garbage collected heap: a precise, tracing mark-and-sweep
  collector.

  Every cell is linked into one list when it is made (Register). A
  collection marks from the roots - the providers registered with
  AddRootProvider: the interpreter's register stack and frames, the
  realms' intrinsics, values the host protects - then lets the weak
  processors run (ephemeron tables mark the values of live keys until
  nothing changes, then drop dead keys; the atom table forgets atoms
  nobody holds), tells each dead cell it is dying and frees it.

  The collector never runs inside an allocation: it runs only at safe
  points (the interpreter's calls and loop back edges, or an explicit
  Collect), where every live value is in a register or a rooted place.
  Native code that keeps a value in a Pascal variable across a call
  into JavaScript protects it (the realm's temporary roots).

  BytesAllocated counts the bytes cells hold (instances and their
  buffers): measured exactly over the survivors at each collection,
  estimated in between from what was registered and accounted; the next collection is due when it passes Threshold, which
  is set to twice what survived the last one (at least
  MinimumThreshold).
}
unit Js.Heap;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values;

type
  TJsRootProvider = procedure(Tracer: TJsTracer) of object;
  { A weak processor: Phase 0 is called repeatedly after marking until
    no processor marks anything (Result True when it marked something);
    phase 1 once before the sweep, to forget unmarked cells. }
  TJsWeakProcessor = function(Tracer: TJsTracer; Phase: Integer): Boolean of object;

  TJsHeap = class(TJsTracer)
  private
    FFirstCell: TJsCell;
    FCellCount: Integer;
    FBytesAllocated: Int64;
    FPeakBytes: Int64;
    FThreshold: Int64;
    FMinimumThreshold: Int64;
    FMemoryLimit: Int64;
    FCollections: Integer;
    FRootProviders: array of TJsRootProvider;
    FWeakProcessors: array of TJsWeakProcessor;
    FCollecting: Boolean;
    procedure Sweep;
  public
    constructor Create;
    destructor Destroy; override;
    { Links a new cell into the heap; Bytes is what it holds. }
    procedure Register(Cell: TJsCell; Kind: TJsCellKind);
    { A cell's buffers grew (or shrank, Delta < 0). }
    procedure Account(Delta: SizeInt); inline;
    procedure AddRootProvider(Provider: TJsRootProvider);
    procedure RemoveRootProvider(Provider: TJsRootProvider);
    procedure AddWeakProcessor(Processor: TJsWeakProcessor);
    function ShouldCollect: Boolean; inline;
    procedure Collect;
    { True when the heap holds more than the memory limit allows. }
    function OverLimit: Boolean; inline;
    property BytesAllocated: Int64 read FBytesAllocated;
    property PeakBytes: Int64 read FPeakBytes;
    property CellCount: Integer read FCellCount;
    property Collections: Integer read FCollections;
    property Threshold: Int64 read FThreshold write FThreshold;
    property MinimumThreshold: Int64 read FMinimumThreshold write FMinimumThreshold;
    { 0: no limit. }
    property MemoryLimit: Int64 read FMemoryLimit write FMemoryLimit;
    property Collecting: Boolean read FCollecting;
  end;

implementation

constructor TJsHeap.Create;
begin
  inherited Create;
  FMinimumThreshold := 1024 * 1024;
  FThreshold := FMinimumThreshold;
end;

destructor TJsHeap.Destroy;
var
  Cell, Next: TJsCell;
begin
  Cell := FFirstCell;
  while Cell <> nil do
  begin
    Next := Cell.NextCell;
    Cell.Free;
    Cell := Next;
  end;
  FFirstCell := nil;
  inherited Destroy;
end;

procedure TJsHeap.Register(Cell: TJsCell; Kind: TJsCellKind);
begin
  Cell.Kind := Kind;
  Cell.NextCell := FFirstCell;
  FFirstCell := Cell;
  Inc(FCellCount);
  Inc(FBytesAllocated, Cell.InstanceSize);
  if FBytesAllocated > FPeakBytes then
    FPeakBytes := FBytesAllocated;
end;

procedure TJsHeap.Account(Delta: SizeInt);
begin
  Inc(FBytesAllocated, Delta);
  if FBytesAllocated > FPeakBytes then
    FPeakBytes := FBytesAllocated;
end;

procedure TJsHeap.AddRootProvider(Provider: TJsRootProvider);
begin
  SetLength(FRootProviders, Length(FRootProviders) + 1);
  FRootProviders[High(FRootProviders)] := Provider;
end;

procedure TJsHeap.RemoveRootProvider(Provider: TJsRootProvider);
var
  Index, Last: Integer;
begin
  Last := High(FRootProviders);
  for Index := 0 to Last do
    if (TMethod(FRootProviders[Index]).Code = TMethod(Provider).Code) and
      (TMethod(FRootProviders[Index]).Data = TMethod(Provider).Data) then
    begin
      FRootProviders[Index] := FRootProviders[Last];
      SetLength(FRootProviders, Last);
      Exit;
    end;
end;

procedure TJsHeap.AddWeakProcessor(Processor: TJsWeakProcessor);
begin
  SetLength(FWeakProcessors, Length(FWeakProcessors) + 1);
  FWeakProcessors[High(FWeakProcessors)] := Processor;
end;

function TJsHeap.ShouldCollect: Boolean;
begin
  Result := FBytesAllocated >= FThreshold;
end;

function TJsHeap.OverLimit: Boolean;
begin
  Result := (FMemoryLimit > 0) and (FBytesAllocated > FMemoryLimit);
end;

procedure TJsHeap.Sweep;
var
  Cell, Previous, Next: TJsCell;
  LiveBytes: Int64;
begin
  { Dying first, while every mark still tells who lives. }
  Cell := FFirstCell;
  while Cell <> nil do
  begin
    if not Cell.Marked then
      Cell.Dying;
    Cell := Cell.NextCell;
  end;
  Previous := nil;
  LiveBytes := 0;
  Cell := FFirstCell;
  while Cell <> nil do
  begin
    Next := Cell.NextCell;
    if Cell.Marked then
    begin
      Cell.Marked := False;
      Inc(LiveBytes, Cell.MemorySize);
      Previous := Cell;
    end
    else
    begin
      if Previous = nil then
        FFirstCell := Next
      else
        Previous.NextCell := Next;
      Dec(FCellCount);
      Cell.Free;
    end;
    Cell := Next;
  end;
  { What the survivors hold, measured: the running count between
    collections is only an estimate. }
  FBytesAllocated := LiveBytes;
end;

procedure TJsHeap.Collect;
var
  Index: Integer;
  MarkedSomething: Boolean;
begin
  if FCollecting then
    Exit;
  FCollecting := True;
  try
    for Index := 0 to High(FRootProviders) do
      FRootProviders[Index](Self);
    Drain;
    repeat
      MarkedSomething := False;
      for Index := 0 to High(FWeakProcessors) do
        if FWeakProcessors[Index](Self, 0) then
          MarkedSomething := True;
      Drain;
    until not MarkedSomething;
    for Index := 0 to High(FWeakProcessors) do
      FWeakProcessors[Index](Self, 1);
    Sweep;
    Inc(FCollections);
    FThreshold := FBytesAllocated * 2;
    if FThreshold < FMinimumThreshold then
      FThreshold := FMinimumThreshold;
  finally
    FCollecting := False;
  end;
end;

end.
