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
  collector whose sweeping is incremental.

  Every cell is linked into a list when it is made (Register). A
  collection marks from the roots - the providers registered with
  AddRootProvider: the interpreter's register stack and frames, the
  realms' intrinsics, values the host protects - then lets the weak
  processors run (ephemeron tables mark the values of live keys until
  nothing changes, then drop dead keys; the atom table forgets atoms
  nobody holds).

  The few kinds of cells that hold weak links of their own (shapes,
  whose parents list them as transitions; collection iterators) are
  kept on a list of their own (NeedsDying), told they are dying and
  freed during the pause. Everything else is swept afterwards, a slice
  at each safe point (SweepSome): the cells marked live are kept (their
  mark cleared), the others freed. Cells made meanwhile go on a fresh
  list, so they are never mistaken for garbage. A collection that is
  asked for explicitly (CollectGarbage, finalizers expected), or when
  memory is near its limit, sweeps at once.

  The collector never runs inside an allocation: it runs only at safe
  points (the interpreter's calls and loop back edges, or an explicit
  Collect), where every live value is in a register or a rooted place.
  Native code that keeps a value in a Pascal variable across a call
  into JavaScript protects it (the realm's temporary roots).

  BytesAllocated counts the bytes cells hold (instances and their
  buffers): measured over the survivors when a sweep ends, estimated in
  between from what was registered and accounted. The next collection
  is due when it passes Threshold: twice what survived (at least
  MinimumThreshold). While a sweep is unfinished, passing the
  threshold finishes it first.

  Pause times (LongestPause...) are measured with Js.Platform's
  monotonic clock.
}
unit Js.Heap;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  Js.Values,
  Js.Platform;

type
  TJsRootProvider = procedure(Tracer: TJsTracer) of object;
  { A weak processor: Phase 0 is called repeatedly after marking until
    no processor marks anything (Result True when it marked something);
    phase 1 once before the sweep, to forget unmarked cells. }
  TJsWeakProcessor = function(Tracer: TJsTracer; Phase: Integer): Boolean of object;

  TJsHeap = class(TJsTracer)
  private
    FFirstCell: TJsCell;
    { Shapes and the other cells with weak links of their own. }
    FFirstDyingCell: TJsCell;
    { The cells of the last collection still to sweep. }
    FSweepCell: TJsCell;
    FSweeping: Boolean;
    FSweepLiveBytes: Int64;
    { Bytes registered or accounted since the sweep started. }
    FBytesSinceSweep: Int64;
    FCellCount: Integer;
    FBytesAllocated: Int64;
    FPeakBytes: Int64;
    { The interpreter calls its safe point when BytesAllocated passes
      FThreshold: the collection threshold, or 0 while a sweep is under
      way (every safe point sweeps a slice). }
    FThreshold: Int64;
    FCollectThreshold: Int64;
    FMinimumThreshold: Int64;
    FMemoryLimit: Int64;
    FCollections: Integer;
    FRootProviders: array of TJsRootProvider;
    FWeakProcessors: array of TJsWeakProcessor;
    FCollecting: Boolean;
    FLongestPause: Double;
    FTotalPause: Double;
    FMarkTime: Double;
    FSweepTime: Double;
    procedure SweepDyingCells;
    procedure FinishSweep;
    procedure StartCollectionThreshold;
    procedure SetThreshold(Value: Int64);
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
    { A collection; Incremental leaves the sweep to SweepSome. }
    procedure Collect(Incremental: Boolean = False);
    { Sweeps a slice of the cells left by the last collection. }
    procedure SweepSome;
    property Sweeping: Boolean read FSweeping;
    { True when the heap holds more than the memory limit allows. }
    function OverLimit: Boolean; inline;
    property BytesAllocated: Int64 read FBytesAllocated;
    property PeakBytes: Int64 read FPeakBytes;
    property CellCount: Integer read FCellCount;
    property Collections: Integer read FCollections;
    property Threshold: Int64 read FThreshold write SetThreshold;
    property MinimumThreshold: Int64 read FMinimumThreshold write FMinimumThreshold;
    { 0: no limit. }
    property MemoryLimit: Int64 read FMemoryLimit write FMemoryLimit;
    property Collecting: Boolean read FCollecting;
    { Milliseconds: the longest collection, all of them, and the parts. }
    property LongestPause: Double read FLongestPause;
    property TotalPause: Double read FTotalPause;
    property MarkTime: Double read FMarkTime;
    property SweepTime: Double read FSweepTime;
  end;

implementation

constructor TJsHeap.Create;
begin
  inherited Create;
  FMinimumThreshold := 1024 * 1024;
  FThreshold := FMinimumThreshold;
  FCollectThreshold := FMinimumThreshold;
end;

procedure FreeList(Cell: TJsCell);
var
  Next: TJsCell;
begin
  while Cell <> nil do
  begin
    Next := Cell.NextCell;
    Cell.Free;
    Cell := Next;
  end;
end;

destructor TJsHeap.Destroy;
begin
  FreeList(FFirstCell);
  FreeList(FSweepCell);
  FreeList(FFirstDyingCell);
  FFirstCell := nil;
  FSweepCell := nil;
  FFirstDyingCell := nil;
  inherited Destroy;
end;

procedure TJsHeap.Register(Cell: TJsCell; Kind: TJsCellKind);
begin
  Cell.Kind := Kind;
  if Cell.NeedsDying then
  begin
    Cell.NextCell := FFirstDyingCell;
    FFirstDyingCell := Cell;
  end
  else
  begin
    Cell.NextCell := FFirstCell;
    FFirstCell := Cell;
  end;
  Inc(FCellCount);
  Inc(FBytesAllocated, Cell.InstanceSize);
  Inc(FBytesSinceSweep, Cell.InstanceSize);
  if FBytesAllocated > FPeakBytes then
    FPeakBytes := FBytesAllocated;
end;

procedure TJsHeap.Account(Delta: SizeInt);
begin
  Inc(FBytesAllocated, Delta);
  Inc(FBytesSinceSweep, Delta);
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
  Result := FBytesAllocated >= FCollectThreshold;
end;

procedure TJsHeap.SetThreshold(Value: Int64);
begin
  FThreshold := Value;
  FCollectThreshold := Value;
end;

function TJsHeap.OverLimit: Boolean;
begin
  Result := (FMemoryLimit > 0) and (FBytesAllocated > FMemoryLimit);
end;

{ The dying list, in the pause: every dead one told first (they look
  at each other's marks), then freed; the live ones unmarked. }
procedure TJsHeap.SweepDyingCells;
var
  Cell, Previous, Next: TJsCell;
begin
  Cell := FFirstDyingCell;
  while Cell <> nil do
  begin
    if not Cell.Marked then
      Cell.Dying;
    Cell := Cell.NextCell;
  end;
  Previous := nil;
  Cell := FFirstDyingCell;
  while Cell <> nil do
  begin
    Next := Cell.NextCell;
    if Cell.Marked then
    begin
      Cell.Marked := False;
      Inc(FSweepLiveBytes, Cell.MemorySize);
      Previous := Cell;
    end
    else
    begin
      if Previous = nil then
        FFirstDyingCell := Next
      else
        Previous.NextCell := Next;
      Dec(FCellCount);
      Cell.Free;
    end;
    Cell := Next;
  end;
end;

const
  { Cells looked at per SweepSome. }
  SweepSlice = 4096;

procedure TJsHeap.SweepSome;
var
  Cell, Next: TJsCell;
  Count: Integer;
begin
  if not FSweeping then
    Exit;
  Count := 0;
  Cell := FSweepCell;
  while (Cell <> nil) and (Count < SweepSlice) do
  begin
    Next := Cell.NextCell;
    if Cell.Marked then
    begin
      Cell.Marked := False;
      Inc(FSweepLiveBytes, Cell.MemorySize);
      Cell.NextCell := FFirstCell;
      FFirstCell := Cell;
    end
    else
    begin
      Dec(FCellCount);
      Cell.Free;
    end;
    Cell := Next;
    Inc(Count);
  end;
  FSweepCell := Cell;
  if Cell = nil then
  begin
    { What the survivors hold, measured, and what came since. }
    FSweeping := False;
    FBytesAllocated := FSweepLiveBytes + FBytesSinceSweep;
    FCollectThreshold := FSweepLiveBytes * 2;
    if FCollectThreshold < FMinimumThreshold then
      FCollectThreshold := FMinimumThreshold;
    if FCollectThreshold < FBytesAllocated then
      FCollectThreshold := FBytesAllocated + FMinimumThreshold div 2;
    FThreshold := FCollectThreshold;
  end;
end;

procedure TJsHeap.FinishSweep;
begin
  while FSweeping do
    SweepSome;
end;

{ While sweeping: the threshold that makes the next safe point finish
  the sweep (memory keeps growing otherwise). }
procedure TJsHeap.StartCollectionThreshold;
var
  Room: Int64;
begin
  Room := FBytesAllocated div 2;
  if Room < FMinimumThreshold then
    Room := FMinimumThreshold;
  FCollectThreshold := FBytesAllocated + Room;
  FThreshold := 0;
end;

procedure TJsHeap.Collect(Incremental: Boolean);
var
  Index: Integer;
  MarkedSomething: Boolean;
  Started, Marked, Finished: Double;
begin
  if FCollecting then
    Exit;
  if FSweeping then
  begin
    { The last collection's sweep first; maybe that is enough. }
    Started := JsMonotonicTime();
    FinishSweep;
    Finished := JsMonotonicTime();
    FSweepTime := FSweepTime + (Finished - Started);
    FTotalPause := FTotalPause + (Finished - Started);
    if Finished - Started > FLongestPause then
      FLongestPause := Finished - Started;
    { A pause of its own: the next safe point collects if still due. }
    if Incremental then
      Exit;
  end;
  FCollecting := True;
  Started := JsMonotonicTime();
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
    Marked := JsMonotonicTime();
    FSweepLiveBytes := 0;
    FBytesSinceSweep := 0;
    SweepDyingCells;
    FSweepCell := FFirstCell;
    FFirstCell := nil;
    FSweeping := True;
    Inc(FCollections);
    { Near the memory limit (or when asked): all at once. }
    if not Incremental or ((FMemoryLimit > 0) and (FBytesAllocated > FMemoryLimit div 2)) then
      FinishSweep
    else
      StartCollectionThreshold;
    Finished := JsMonotonicTime();
    FMarkTime := FMarkTime + (Marked - Started);
    FSweepTime := FSweepTime + (Finished - Marked);
    FTotalPause := FTotalPause + (Finished - Started);
    if Finished - Started > FLongestPause then
      FLongestPause := Finished - Started;
  finally
    FCollecting := False;
  end;
end;

end.
