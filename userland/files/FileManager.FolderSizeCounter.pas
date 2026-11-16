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
  Adding up what is in a folder (files, folders, bytes) in a thread of
  its own, so the properties dialog shows a running count of a big tree
  instead of freezing while it walks it.

  The dialog looks at the counts whenever it likes (Snapshot) and at
  Finished; Stop asks the walk to end at the next name and waits for
  the thread, so the counter can be freed right after. Links are
  counted, never followed.
}
unit FileManager.FolderSizeCounter;

{$mode objfpc}
{$H+}

interface

uses
  Sys.Locks;

type
  TFolderCounts = record
    Files: QWord;
    Folders: QWord;
    Bytes: QWord;
    Finished: Boolean;
  end;

  TFolderSizeCounter = class
  private
    FFolder: string;
    FLock: TLock;
    FCounts: TFolderCounts;
    FStopRequested: LongInt;
    FThread: Int64;
    procedure Walk(const Path: string);
  public
    constructor Create(const AFolder: string);
    destructor Destroy; override;
    { Starts counting (a thread). }
    procedure Start;
    function Snapshot: TFolderCounts;
    procedure Stop;
    { (The thread's.) }
    procedure Run;
  end;

implementation

uses
  Abi.SystemCalls,
  Sys.Threads,
  Controls.FileNames,
  FileManager.Items,
  FileManager.FolderReading;

function RunCounter(Argument: Pointer): LongInt;
begin
  TFolderSizeCounter(Argument).Run;
  Result := 0;
end;

constructor TFolderSizeCounter.Create(const AFolder: string);
begin
  inherited Create;
  FFolder := AFolder;
  UniqueString(FFolder);
  FThread := -1;
end;

destructor TFolderSizeCounter.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TFolderSizeCounter.Start;
begin
  FThread := CreateThread(@RunCounter, Self);
  if FThread < 0 then
    { No thread to spare: counted here and now. }
    Run;
end;

procedure TFolderSizeCounter.Walk(const Path: string);
var
  Children: TFolderItems;
  Index: LongInt;
  Item: TFolderItem;
begin
  if (AtomicCompareExchange32(FStopRequested, 0, 0) <> 0) or
     (ReadFolderItems(Path, True, Children) <> ErrorNone) then
    Exit;
  for Index := 0 to High(Children) do
  begin
    if AtomicCompareExchange32(FStopRequested, 0, 0) <> 0 then
      Exit;
    Item := Children[Index];
    { Items describe a link by what it points to: a link counts as one
      file of its own, whatever it leads to. }
    if (Item.Kind = ItemFolder) and not Item.IsLink then
    begin
      AcquireLock(FLock);
      Inc(FCounts.Folders);
      ReleaseLock(FLock);
      Walk(CombinePath(Path, Item.Name));
    end
    else
    begin
      AcquireLock(FLock);
      Inc(FCounts.Files);
      if (Item.Kind = ItemFile) and not Item.IsLink then
        FCounts.Bytes := FCounts.Bytes + Item.SizeInBytes;
      ReleaseLock(FLock);
    end;
  end;
end;

procedure TFolderSizeCounter.Run;
begin
  Walk(FFolder);
  AcquireLock(FLock);
  FCounts.Finished := True;
  ReleaseLock(FLock);
end;

function TFolderSizeCounter.Snapshot: TFolderCounts;
begin
  AcquireLock(FLock);
  Result := FCounts;
  ReleaseLock(FLock);
end;

procedure TFolderSizeCounter.Stop;
var
  ExitCode: LongInt;
begin
  AtomicExchange32(FStopRequested, 1);
  if FThread < 0 then
    Exit;
  WaitForThread(FThread, -1, ExitCode);
  CloseThreadHandle(FThread);
  FThread := -1;
end;

end.
