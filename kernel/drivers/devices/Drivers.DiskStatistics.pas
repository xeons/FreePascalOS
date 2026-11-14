{
  Disk statistics: a filter driver on every disk.

  For each whole disk a filter device of the driver "diskstats" is
  attached on top of the disk's storage device (Io.Manager device
  stacks). It passes every request down unchanged, with a completion
  routine that counts the reads and writes that worked, their bytes,
  and the ones that failed. The counts of every disk are written to the
  kernel log at the end (WriteDiskStatistics).

  It is the first filter driver, and shows the pattern: a dispatch
  routine that forwards with a completion routine, which also runs for
  requests the disk driver completes later from its interrupt.
}
unit Drivers.DiskStatistics;

{$mode objfpc}

interface

{ Attaches a filter to every whole disk; call after the storage drivers
  started and before the disks are used. }
procedure AttachDiskStatistics;
procedure WriteDiskStatistics;

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Abi.SystemCalls,
  Io.Manager,
  Io.BlockDevice,
  Debug.Output;

type
  PDiskStatistics = ^TDiskStatistics;
  TDiskStatistics = record
    Disk: PBlockDevice;
    Lower: PDeviceObject;
    Reads: Int64;
    Writes: Int64;
    BytesRead: Int64;
    BytesWritten: Int64;
    Flushes: Int64;
    Failures: Int64;
  end;

const
  MaximumFilteredDisks = 16;

var
  Filters: array[0..MaximumFilteredDisks - 1] of PDiskStatistics;
  FilterCount: Integer = 0;

procedure CountCompletedRequest(Request: PIoRequest; Context: Pointer);
var
  Statistics: PDiskStatistics;
begin
  Statistics := PDiskStatistics(Context);
  if Request^.Status <> ErrorNone then
    AtomicIncrement(Statistics^.Failures)
  else if Request^.Operation = IoFunctionRead then
  begin
    AtomicIncrement(Statistics^.Reads);
    AtomicFetchAndAdd(Statistics^.BytesRead, Request^.Information);
  end
  else if Request^.Operation = IoFunctionFlush then
    AtomicIncrement(Statistics^.Flushes)
  else
  begin
    AtomicIncrement(Statistics^.Writes);
    AtomicFetchAndAdd(Statistics^.BytesWritten, Request^.Information);
  end;
end;

function TransferThroughFilter(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Statistics: PDiskStatistics;
begin
  Statistics := PDiskStatistics(Device^.Extension);
  Result := ForwardRequest(Statistics^.Lower, Request, @CountCompletedRequest, Statistics);
end;

procedure AttachDiskStatistics;
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
  Index: Integer;
  Disk: PBlockDevice;
  Filter: PDeviceObject;
  Statistics: PDiskStatistics;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferThroughFilter;
  Dispatch[IoFunctionWrite] := @TransferThroughFilter;
  Dispatch[IoFunctionFlush] := @TransferThroughFilter;
  Driver := CreateDriver('diskstats', Dispatch);
  for Index := 0 to BlockDeviceCount - 1 do
  begin
    Disk := BlockDeviceAt(Index);
    if (Disk^.StorageDevice = nil) or (FilterCount = MaximumFilteredDisks) then
      Continue;
    Filter := CreateDevice(Driver, nil, DeviceKindBlock, 0, SizeOf(TDiskStatistics));
    if Filter = nil then
      Continue;
    Statistics := PDiskStatistics(Filter^.Extension);
    Statistics^.Disk := Disk;
    Statistics^.Lower := AttachDevice(Filter, Disk^.StorageDevice);
    Filters[FilterCount] := Statistics;
    Inc(FilterCount);
  end;
end;

procedure WriteDiskStatistics;
var
  Index: Integer;
  Statistics: PDiskStatistics;
begin
  for Index := 0 to FilterCount - 1 do
  begin
    Statistics := Filters[Index];
    DebugBeginMessage;
    DebugWriteTag('diskstats');
    DebugWrite(@Statistics^.Disk^.Name[0]);
    DebugWrite(': ');
    DebugWriteDecimal(Statistics^.Reads);
    DebugWrite(' reads (');
    DebugWriteSize(Statistics^.BytesRead);
    DebugWrite('), ');
    DebugWriteDecimal(Statistics^.Writes);
    DebugWrite(' writes (');
    DebugWriteSize(Statistics^.BytesWritten);
    DebugWrite('), ');
    DebugWriteDecimal(Statistics^.Flushes);
    DebugWrite(' flushes, ');
    DebugWriteDecimal(Statistics^.Failures);
    DebugWriteLine(' failed');
    DebugEndMessage;
  end;
end;

end.
